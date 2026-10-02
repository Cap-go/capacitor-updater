//! Downloads run as jobs of the host's scheduler (Android WorkManager): they wait for
//! the network, retry with the scheduler's backoff and survive the app process.
//!
//! The engine keeps the download logic. When the host answers the `scheduleDownload`
//! hook, the engine writes the job (request + engine settings) to
//! `<storageRoot>/capgo_download_jobs/<id>.json` and the caller waits. The host's job
//! runs `runScheduledDownload {id}`, which performs one attempt of the normal transfer
//! and install and answers `success`, `retry` (the scheduler backs off and runs it
//! again, resuming the partial file) or `failure`. The final result wakes the waiting
//! caller, which carries on exactly like an in-process download (events, `setNext`,
//! direct update, the JavaScript promise). A job whose caller is gone (the process
//! died) still records the bundle: the next update check finds it downloaded.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::{Condvar, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use serde_json::{json, Value};

use super::download::{is_retryable_download_error, Cancel, DownloadRequest};
use super::fsutil;
use super::plugin::hooks;
use super::Engine;
use crate::bundle::BundleInfo;
use crate::error::{CoreError, CoreResult};
use crate::host::HostLog;

pub(crate) const JOBS_DIR: &str = "capgo_download_jobs";
/// How often a waiting caller re-checks cancellation and engine release.
const WAIT_TICK: Duration = Duration::from_millis(500);

/// How a scheduled download ended for its waiting caller.
pub(crate) enum Scheduled {
    /// The job finished; a failure already has its ERROR record.
    Settled(CoreResult<BundleInfo>),
    /// The job was cancelled (bundle deleted, reset) before it finished.
    Cancelled,
    /// The engine was released (plugin destroyed): the job goes on without this caller.
    Detached,
}

struct Waiter {
    version: String,
    /// Failed attempts the scheduler will retry.
    retries: u32,
    outcome: Option<Scheduled>,
}

/// Process-wide: the job may run on another engine of the process (a worker started
/// before the plugin loaded) than the one waiting for it.
#[derive(Default)]
struct Jobs {
    waiters: HashMap<String, Waiter>,
    /// Attempts running in this process, by job id.
    running: HashMap<String, Cancel>,
}

#[derive(Default)]
struct Registry {
    jobs: Mutex<Jobs>,
    changed: Condvar,
}

fn registry() -> &'static Registry {
    static REGISTRY: OnceLock<Registry> = OnceLock::new();
    REGISTRY.get_or_init(Registry::default)
}

fn jobs() -> MutexGuard<'static, Jobs> {
    registry().jobs.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// Tells the caller waiting for job `id` (if any) that an attempt failed and is retried.
fn count_retry(id: &str) {
    if let Some(waiter) = jobs().waiters.get_mut(id) {
        waiter.retries += 1;
    }
    registry().changed.notify_all();
}

/// Hands the final outcome to the caller waiting for job `id` (if any).
fn publish(id: &str, outcome: Scheduled) {
    let mut jobs = jobs();
    if let Some(waiter) = jobs.waiters.get_mut(id) {
        waiter.outcome = Some(outcome);
    }
    drop(jobs);
    registry().changed.notify_all();
}

/// Scheduled download attempts running in this process.
pub(crate) fn running_jobs() -> usize {
    jobs().running.len()
}

fn failure_reply(error: &CoreError) -> Value {
    json!({ "result": "failure", "error": { "code": error.code, "message": error.message } })
}

impl Engine {
    fn jobs_dir(&self) -> PathBuf {
        self.config().storage_root.join(JOBS_DIR)
    }

    fn job_path(&self, id: &str) -> PathBuf {
        self.jobs_dir().join(format!("{id}.json"))
    }

    /// Ids of the scheduled downloads not finished yet.
    pub(crate) fn pending_job_ids(&self) -> Vec<String> {
        let Ok(entries) = fs::read_dir(self.jobs_dir()) else {
            return Vec::new();
        };
        entries
            .filter_map(Result::ok)
            .filter_map(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .strip_suffix(".json")
                    .map(str::to_string)
            })
            .collect()
    }

    /// Settings a job needs when it runs on an engine the plugin did not configure
    /// (process started by the scheduler): endpoints, identity, public key, timeouts.
    fn job_settings(&self) -> Value {
        let config = self.config();
        json!({
            "appId": config.app_id,
            "pluginVersion": config.plugin_version,
            "versionBuild": config.version_build,
            "versionCode": config.version_code,
            "versionOs": config.version_os,
            "deviceId": config.device_id,
            "customId": config.custom_id,
            "defaultChannel": config.default_channel,
            "installSource": config.install_source,
            "updateUrl": config.update_url,
            "statsUrl": config.stats_url,
            "channelUrl": config.channel_url,
            "isEmulator": config.is_emulator,
            "isProd": config.is_prod,
            "previewSession": config.preview_session,
            "allowHttpsToHttpRedirect": config.allow_https_to_http_redirect,
            "timeoutMs": config.timeout_ms,
            "publicKey": config.public_key,
        })
    }

    /// Job `id` downloads a manifest (its partial files are named by file, not job).
    pub(crate) fn job_has_manifest(&self, id: &str) -> bool {
        fs::read(self.job_path(id))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .is_some_and(|job| job["request"]["manifest"].is_array())
    }

    fn remove_job(&self, id: &str) {
        let _ = fs::remove_file(self.job_path(id));
    }

    /// Removes a job and its partial download files.
    fn discard_job(&self, id: &str) {
        self.remove_job(id);
        let storage = self.config().storage_root.clone();
        for name in [
            format!("temp_{id}.tmp"),
            format!("temp_{id}.plain"),
            format!("update_{id}.dat"),
        ] {
            let _ = fs::remove_file(storage.join(name));
        }
    }

    /// Offers the transfer of a started download to the host's scheduler. `None`: the
    /// host does not schedule downloads (iOS) and the caller runs it in-process.
    pub(crate) fn schedule_download(
        &self,
        request: &DownloadRequest,
        record: &BundleInfo,
        cancel: &Cancel,
    ) -> Option<Scheduled> {
        let id = record.id().to_string();
        let mut job_request = request.clone();
        job_request.id = Some(id.clone());
        let job = json!({ "request": job_request.to_json(), "settings": self.job_settings() });
        // Written before the hook: the scheduler may start the job right away.
        if fs::create_dir_all(self.jobs_dir()).is_err()
            || fsutil::write_atomically(&self.job_path(&id), job.to_string().as_bytes()).is_err()
        {
            return None;
        }
        if !self.hand_to_scheduler(&id, &request.version) {
            self.remove_job(&id);
            return None;
        }
        self.host.info(format!(
            "Download of {} scheduled (job {id}), waiting for it",
            request.version
        ));
        Some(self.await_scheduled(&id, &request.version, cancel))
    }

    /// Registers the caller of job `id` and asks the host to run it (idempotent for a job
    /// it already has). `false`: the host does not schedule downloads.
    fn hand_to_scheduler(&self, id: &str, version: &str) -> bool {
        jobs().waiters.insert(
            id.to_string(),
            Waiter {
                version: version.to_string(),
                retries: 0,
                outcome: None,
            },
        );
        let scheduled = self
            .hook(hooks::SCHEDULE_DOWNLOAD, json!({ "id": id, "version": version }))
            .and_then(|reply| reply.get("scheduled").and_then(Value::as_bool))
            .unwrap_or(false);
        if !scheduled {
            jobs().waiters.remove(id);
        }
        scheduled
    }

    /// Waits for a scheduled job of `version` an earlier process started: the process
    /// died, the scheduler kept the job (and its partial file). `None` when there is no
    /// such job or nobody runs it; the caller then downloads again.
    pub(crate) fn adopt_scheduled_download(&self, version: &str) -> Option<CoreResult<BundleInfo>> {
        let (record, request) = self.pending_job_ids().into_iter().find_map(|id| {
            let request = fs::read(self.job_path(&id))
                .ok()
                .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                .and_then(|job| DownloadRequest::from_json(&job["request"]).ok())
                .filter(|request| request.version == version)?;
            let record = self.get_bundle_info(Some(&id));
            (record.is_downloading() && record.version_name() == version).then_some((record, request))
        })?;
        let id = record.id();
        if jobs().waiters.contains_key(id) || !self.hand_to_scheduler(id, &request.version) {
            return None;
        }
        self.host.info(format!(
            "Resuming the scheduled download of {} started before the app restarted",
            request.version
        ));
        let cancel = self.register_download_token(&request.version);
        let outcome = self.await_scheduled(id, &request.version, &cancel);
        self.unregister_download_token(&request.version, &cancel);
        Some(self.scheduled_result(&request, &record, outcome))
    }

    /// Blocks until job `id` ends, is cancelled, or the engine is released. Without a
    /// network the job waits for it, so this can take as long as the device stays offline.
    fn await_scheduled(&self, id: &str, version: &str, cancel: &Cancel) -> Scheduled {
        crate::host::release_method_lane();
        self.scheduled_download_waiting(version, true);
        let registry = registry();
        let mut seen_retries = 0;
        let mut jobs = jobs();
        let outcome = loop {
            let Some(waiter) = jobs.waiters.get_mut(id) else {
                break Scheduled::Cancelled;
            };
            if let Some(outcome) = waiter.outcome.take() {
                break outcome;
            }
            if self.downloads_detached.load(Ordering::SeqCst) {
                break Scheduled::Detached;
            }
            if cancel.is_cancelled() {
                break Scheduled::Cancelled;
            }
            if waiter.retries > seen_retries {
                seen_retries = waiter.retries;
                drop(jobs);
                self.scheduled_download_retrying(version);
                jobs = self::jobs();
                continue;
            }
            jobs = registry
                .changed
                .wait_timeout(jobs, WAIT_TICK)
                .unwrap_or_else(|poison| poison.into_inner())
                .0;
        };
        jobs.waiters.remove(id);
        drop(jobs);
        self.scheduled_download_waiting(version, false);
        outcome
    }

    /// Result of a scheduled download for its caller, like the in-process one.
    pub(crate) fn scheduled_result(
        &self,
        request: &DownloadRequest,
        record: &BundleInfo,
        scheduled: Scheduled,
    ) -> CoreResult<BundleInfo> {
        match scheduled {
            Scheduled::Settled(result) => result,
            Scheduled::Cancelled => {
                let error = CoreError::new("download_stopped", "Download cancelled");
                // A deleted bundle keeps its delete: only a live record becomes ERROR.
                if self.get_bundle_info(Some(record.id())).is_downloading() {
                    self.settle_download(request, record, Err(error))
                } else {
                    Err(error)
                }
            }
            Scheduled::Detached => Err(CoreError::new(
                "download_detached",
                "The updater was released; the scheduled download continues in the background",
            )),
        }
    }

    /// `runScheduledDownload {id}`: one attempt of scheduled job `id`.
    /// Answers `{result: "success" | "retry" | "failure", bundle?, error?}`.
    pub fn run_scheduled_download(&self, id: &str) -> Value {
        let job = fs::read(self.job_path(id))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
        let request = job
            .as_ref()
            .and_then(|job| job.get("request"))
            .and_then(|request| DownloadRequest::from_json(request).ok());
        let (Some(job), Some(request)) = (job, request) else {
            // Cancelled (or never written): nothing to run.
            let error = CoreError::new("download_obsolete", "Scheduled download no longer exists");
            publish(id, Scheduled::Settled(Err(error.clone())));
            return failure_reply(&error);
        };
        if !self.plugin_state().loaded {
            // Engine created for the job alone (no plugin in this process yet).
            if let Err(error) = self.configure(job.get("settings").unwrap_or(&Value::Null)) {
                self.host
                    .warn(format!("Scheduled download settings rejected: {}", error.message));
            }
        }
        let record = self.get_bundle_info(Some(id));
        if !record.is_downloading() || record.version_name() != request.version {
            self.host.info(format!(
                "Scheduled download {id} is obsolete (bundle deleted or settled)"
            ));
            self.discard_job(id);
            let error = CoreError::new("download_obsolete", "Scheduled download no longer exists");
            publish(id, Scheduled::Settled(Err(error.clone())));
            return failure_reply(&error);
        }
        let cancel = self.register_download_token(&request.version);
        jobs().running.insert(id.to_string(), cancel.clone());
        let result = self.transfer_and_install(&request, &record, &cancel, true);
        jobs().running.remove(id);
        self.unregister_download_token(&request.version, &cancel);
        match result {
            Ok(installed) => {
                self.remove_job(id);
                let reply = json!({ "result": "success", "bundle": installed.to_raw() });
                publish(id, Scheduled::Settled(Ok(installed)));
                reply
            }
            // Stopped by the scheduler (constraints lost, time limit): it runs the job again.
            // A cancel also lands here; the scheduler then drops the job.
            Err(error) if error.code == "download_stopped" => {
                self.host.info(format!("Scheduled download {id} stopped"));
                // Waiting for the constraints again is a retry for the caller too (a direct
                // update stops holding the launch). A cancelled job is gone: nothing to retry.
                if self.job_path(id).exists() {
                    count_retry(id);
                }
                json!({ "result": "retry", "error": { "code": error.code, "message": error.message } })
            }
            Err(error) if is_retryable_download_error(&error) => {
                self.host.warn(format!(
                    "Scheduled download {id} failed ({}), the scheduler retries it",
                    error.message
                ));
                count_retry(id);
                json!({ "result": "retry", "error": { "code": error.code, "message": error.message } })
            }
            Err(error) => {
                let reply = failure_reply(&error);
                let settled = self.settle_download(&request, &record, Err(error));
                self.discard_job(id);
                publish(id, Scheduled::Settled(settled));
                reply
            }
        }
    }

    /// `stopScheduledDownload {id}`: the scheduler stopped the job; abort its attempt.
    pub fn stop_scheduled_download(&self, id: &str) {
        if let Some(cancel) = jobs().running.get(id) {
            cancel.0.store(true, Ordering::SeqCst);
        }
    }

    /// Cancels the scheduled downloads of `version` (every one with `None`) after the
    /// host cancelled their jobs: their files go and their callers stop waiting.
    pub(crate) fn cancel_scheduled_downloads(&self, version: Option<&str>) {
        let ids: Vec<String> = self
            .pending_job_ids()
            .into_iter()
            .filter(|id| match version {
                None => true,
                Some(version) => {
                    let job_version = fs::read(self.job_path(id))
                        .ok()
                        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                        .and_then(|job| job["request"]["version"].as_str().map(str::to_string));
                    let waiting_version = jobs().waiters.get(id).map(|waiter| waiter.version.clone());
                    job_version.as_deref() == Some(version) || waiting_version.as_deref() == Some(version)
                }
            })
            .collect();
        for id in ids {
            self.host.info(format!("Cancelling scheduled download {id}"));
            self.discard_job(&id);
            self.stop_scheduled_download(&id);
            publish(&id, Scheduled::Cancelled);
        }
    }

    /// Cancels the platform jobs of `version`, then their engine side.
    pub(crate) fn cancel_version_download(&self, version: &str) -> bool {
        if !self.host.cancel_version_download(version) {
            return false;
        }
        self.cancel_scheduled_downloads(Some(version));
        true
    }

    /// `detachScheduledDownloads`: the host releases this engine. Callers waiting for a
    /// scheduled download return (`download_detached`); the jobs keep running and record
    /// their bundle themselves.
    pub fn detach_scheduled_downloads(&self) {
        self.downloads_detached.store(true, Ordering::SeqCst);
        registry().changed.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::MemoryHost;
    use std::sync::Arc;

    #[test]
    fn unscheduled_downloads_leave_no_job() {
        let dir = tempfile::tempdir().unwrap();
        let engine = Engine::new(
            Arc::new(MemoryHost::default()),
            &json!({ "bundleRoot": dir.path().join("versions").to_string_lossy() }),
        )
        .unwrap();
        let record = engine.new_download_record("2.0.0");
        let request = DownloadRequest {
            version: "2.0.0".into(),
            ..Default::default()
        };
        assert!(engine
            .schedule_download(&request, &record, &Cancel::default())
            .is_none());
        assert!(engine.pending_job_ids().is_empty());
        assert!(!jobs().waiters.contains_key(record.id()));
    }
}
