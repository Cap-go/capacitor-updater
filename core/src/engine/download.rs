//! Zip bundle downloads and the shared download lifecycle (gates, progress,
//! cancellation, status transitions, post-install actions).

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Map, Value};

use super::archive::{self, ExtractError};
use super::fsutil;
use super::store::{random_id, remove_path, TEMP_UNZIP_PREFIX};
use super::Engine;
use crate::bundle::{iso8601_now, BundleInfo, BundleStatus};
use crate::crypto;
use crate::error::{CoreError, CoreResult};
use crate::host::HostLog;
use crate::net::NetError;

/// Minimum free space (x2 margin) required before any bundle download.
const MIN_FREE_BYTES: u64 = 50 * 1024 * 1024;
const MAX_ZIP_ATTEMPTS: u32 = 3;

/// What to do with the bundle once it is installed (PENDING).
#[derive(Debug, Clone, Default)]
pub struct DownloadRequest {
    /// Existing DOWNLOADING record to fill (hosts that schedule downloads
    /// themselves create it up front); a new id is generated otherwise.
    pub id: Option<String>,
    pub url: String,
    pub version: String,
    pub session_key: String,
    pub checksum: String,
    pub manifest: Option<Vec<Value>>,
    pub link: Option<String>,
    pub comment: Option<String>,
    /// Schedule the bundle (`setNextBundle`) or, with `direct_update`, hand it
    /// to the host for an immediate install (`directUpdateFinish` event).
    pub set_next: bool,
    pub direct_update: bool,
    /// Emit `updateAvailable` / `downloadFailed` (hosts whose plugin layer
    /// reports those events itself pass `false`).
    pub emit_events: bool,
}

impl DownloadRequest {
    pub fn from_json(input: &Value) -> CoreResult<Self> {
        let text = |key: &str| input.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
        let version = text("version");
        if version.is_empty() {
            return Err(CoreError::invalid_input("Download called without version"));
        }
        Ok(Self {
            id: input
                .get("id")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .map(str::to_string),
            url: text("url"),
            version,
            session_key: text("sessionKey"),
            checksum: text("checksum"),
            manifest: input.get("manifest").and_then(Value::as_array).cloned(),
            link: input.get("link").and_then(Value::as_str).map(str::to_string),
            comment: input.get("comment").and_then(Value::as_str).map(str::to_string),
            set_next: input.get("setNext").and_then(Value::as_bool).unwrap_or(false),
            direct_update: input.get("directUpdate").and_then(Value::as_bool).unwrap_or(false),
            emit_events: input.get("emitEvents").and_then(Value::as_bool).unwrap_or(true),
        })
    }
}

/// Cancellation token for one in-flight download.
#[derive(Clone, Default)]
pub struct Cancel(pub(crate) Arc<AtomicBool>);

impl Cancel {
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

impl Engine {
    pub(crate) fn progress(&self, id: &str, percent: i64) {
        self.notify_download(id, percent.clamp(0, 100));
    }

    /// Cancels an in-flight download of `version` (returns whether one was running).
    pub fn cancel_download(&self, version: &str) -> bool {
        match self.downloads.lock().unwrap().get(version) {
            Some(token) => {
                token.0.store(true, Ordering::SeqCst);
                true
            }
            None => false,
        }
    }

    pub fn is_downloading(&self, version: &str) -> bool {
        self.downloads.lock().unwrap().contains_key(version)
    }

    /// Refuses unencrypted delivery when a public key is configured.
    pub(crate) fn require_session_key(&self, session_key: &str, version: &str) -> CoreResult<()> {
        if !self.config().public_key.is_empty() && !crypto::is_valid_session_key(Some(session_key)) {
            self.host.error("Public key present but no valid session key provided");
            self.send_stats("session_key_required", Some(version), None, None);
            return Err(CoreError::new(
                "session_key_required",
                "Session key required when public key is present",
            ));
        }
        Ok(())
    }

    pub(crate) fn require_checksum(&self, checksum: &str, version: &str) -> CoreResult<()> {
        if checksum.is_empty() {
            self.host.error("No checksum provided");
            self.send_stats("checksum_required", Some(version), None, None);
            return Err(CoreError::new("checksum_required", "Checksum required"));
        }
        Ok(())
    }

    pub(crate) fn check_disk_space(&self, needed: u64, version: &str) -> CoreResult<()> {
        let root = self.config().storage_root.clone();
        match fsutil::available_space(&root) {
            Some(free) if free < needed.saturating_mul(2) => {
                self.host.error(format!(
                    "Insufficient disk space: {free} bytes free, {} needed",
                    needed.saturating_mul(2)
                ));
                self.send_stats("insufficient_disk_space", Some(version), None, None);
                Err(CoreError::new(
                    "insufficient_disk_space",
                    "Insufficient disk space for download",
                ))
            }
            Some(_) => Ok(()),
            None => {
                self.host.warn("Could not determine free disk space; continuing");
                Ok(())
            }
        }
    }

    /// Deletes a previous failed/deleted record for the same version before retrying.
    fn clear_failed_version(&self, version: &str) -> CoreResult<()> {
        if let Some(existing) = self.get_bundle_info_by_name(version) {
            if existing.is_error() || existing.is_deleted() || existing.is_deleting() {
                self.host.info(format!(
                    "Found existing failed bundle for version {version}, deleting before retry"
                ));
                if !self.delete_bundle(existing.id(), true, false) {
                    return Err(CoreError::new(
                        "delete_failed",
                        "Failed to delete existing bundle before retry",
                    ));
                }
            }
        }
        Ok(())
    }

    pub(crate) fn start_record(&self, request: &DownloadRequest) -> BundleInfo {
        let id = request.id.clone().unwrap_or_else(random_id);
        let mut info = BundleInfo::new(
            id.clone(),
            Some(request.version.clone()),
            BundleStatus::Downloading,
            iso8601_now(),
            "",
        );
        info.link = request.link.clone();
        info.comment = request.comment.clone();
        self.save_bundle_info(&id, Some(&info));
        info
    }

    /// Marks a download failed: ERROR record, `downloadFailed` event, `download_fail` stat.
    pub(crate) fn fail_download(&self, record: &BundleInfo, error: &CoreError, emit_events: bool) {
        self.host.error(format!("Download failed: {}", error.message));
        self.save_bundle_info(record.id(), Some(&record.with_status(BundleStatus::Error)));
        if emit_events {
            self.host.emit(
                "downloadFailed",
                &json!({ "version": record.version_name(), "error": error.code }),
            );
        }
        self.send_stats("download_fail", Some(record.version_name()), None, None);
    }

    /// Final step shared by zip and manifest downloads.
    pub(crate) fn finish_install(&self, record: &BundleInfo, checksum: &str, request: &DownloadRequest) -> BundleInfo {
        let mut installed = BundleInfo::new(
            record.id(),
            record.version.clone(),
            BundleStatus::Pending,
            iso8601_now(),
            checksum,
        );
        installed.link = record.link.clone();
        installed.comment = record.comment.clone();
        self.save_bundle_info(record.id(), Some(&installed));
        self.progress(record.id(), 100);
        if request.emit_events {
            self.host
                .emit("updateAvailable", &json!({ "bundle": installed.to_js() }));
        }
        if request.set_next {
            if self.config().preview_session {
                self.host
                    .info("Preview session is active, skipping automatic install of downloaded bundle");
            } else if request.direct_update {
                self.host
                    .emit("directUpdateFinish", &json!({ "bundle": installed.to_raw() }));
            } else {
                self.set_next_bundle(Some(record.id()));
            }
        }
        installed
    }

    /// Downloads, verifies and installs a zip bundle. Blocking.
    pub fn download_zip(&self, request: &DownloadRequest) -> CoreResult<BundleInfo> {
        self.require_session_key(&request.session_key, &request.version)?;
        self.require_checksum(&request.checksum, &request.version)?;
        self.host
            .before_download()
            .map_err(|message| CoreError::new("download_blocked", message))?;
        self.clear_failed_version(&request.version)?;
        let cancel = self.register_download_token(&request.version);
        let record = self.start_record(request);
        self.progress(record.id(), 0);
        self.progress(record.id(), 5);
        let result = self.download_zip_inner(request, &record, &cancel);
        self.unregister_download_token(&request.version);
        match result {
            Ok(installed) => Ok(installed),
            Err(error) => {
                self.fail_download(&record, &error, request.emit_events);
                Err(error)
            }
        }
    }

    fn download_zip_inner(
        &self,
        request: &DownloadRequest,
        record: &BundleInfo,
        cancel: &Cancel,
    ) -> CoreResult<BundleInfo> {
        let id = record.id().to_string();
        self.check_disk_space(MIN_FREE_BYTES, &request.version)?;
        self.send_stats("download_zip_start", Some(&request.version), None, None);
        let storage = self.config().storage_root.clone();
        fs::create_dir_all(&storage).map_err(|error| CoreError::io("Cannot create updater storage", error))?;
        let temp = storage.join(format!("temp_{id}.tmp"));
        let info = storage.join(format!("update_{id}.dat"));
        let cleanup = |paths: &[&Path]| {
            for path in paths {
                let _ = fs::remove_file(path);
            }
        };

        let transfer = self.transfer_zip(&request.url, &request.version, &id, &temp, &info, cancel);
        cleanup(&[&info]);
        if let Err(error) = transfer {
            cleanup(&[&temp]);
            return Err(error);
        }
        self.send_stats("download_zip_complete", Some(&request.version), None, None);
        self.progress(&id, 71);

        let verified = self.verify_zip(&temp, request);
        let checksum = match verified {
            Ok(checksum) => checksum,
            Err(error) => {
                cleanup(&[&temp]);
                return Err(error);
            }
        };

        let extract_dir = storage.join(format!("{TEMP_UNZIP_PREFIX}{}", random_id()));
        self.progress(&id, 75);
        let mut last = 75;
        let extracted = archive::extract_zip(
            &temp,
            &extract_dir,
            &mut |done, total| {
                let percent = 75 + (done * 15 / total.max(1)) as i64;
                if percent != last {
                    last = percent;
                    self.progress(&id, percent);
                }
            },
            &|| cancel.is_cancelled(),
        );
        cleanup(&[&temp]);
        if let Err(error) = extracted {
            let _ = remove_path(&extract_dir);
            if let Some(stat) = error.stat() {
                self.send_stats(stat, Some(&request.version), None, None);
            }
            if error != ExtractError::Cancelled {
                self.send_stats("unzip_fail", Some(&request.version), None, None);
            }
            return Err(CoreError::new(
                if error == ExtractError::Cancelled {
                    "download_stopped"
                } else {
                    "unzip_fail"
                },
                error.message(),
            ));
        }
        let bundle_dir = self.bundle_directory(&id)?;
        if let Err(error) = archive::install_extracted(&extract_dir, &bundle_dir) {
            let _ = remove_path(&extract_dir);
            let _ = remove_path(&bundle_dir);
            return Err(error);
        }
        self.progress(&id, 91);
        let installed = self.finish_install(record, &checksum, request);
        if let Some(engine) = self.weak_self().upgrade() {
            std::thread::spawn(move || engine.populate_delta_cache(&id));
        }
        Ok(installed)
    }

    /// Decrypts (when encrypted) and checks the zip against the expected checksum
    /// before anything is extracted. Returns the SHA-256 of the plain zip.
    fn verify_zip(&self, zip: &Path, request: &DownloadRequest) -> CoreResult<String> {
        let public_key = self.config().public_key.clone();
        let mut expected = request.checksum.clone();
        if crypto::is_valid_session_key(Some(&request.session_key)) {
            crypto::decrypt_bundle_file(zip, &public_key, Some(&request.session_key)).map_err(|error| {
                self.send_stats("decrypt_fail", Some(&request.version), None, None);
                CoreError::new("decrypt_fail", format!("AES file decryption failed: {}", error.message))
            })?;
            expected = crypto::decrypt_checksum(&request.checksum, &public_key)?;
        } else if !public_key.is_empty() {
            expected = crypto::decrypt_checksum(&request.checksum, &public_key)?;
        }
        let actual = crypto::checksum::sha256_file(zip)?;
        if !expected.eq_ignore_ascii_case(&actual) {
            self.host.error("Checksum mismatch");
            self.host.debug(format!("Expected: {expected}, Got: {actual}"));
            self.send_stats("checksum_fail", Some(&request.version), None, None);
            return Err(CoreError::new(
                "checksum_fail",
                format!("Checksum failed: expected {expected}, got {actual}"),
            ));
        }
        Ok(actual)
    }

    /// GET with resume and bounded retries into `temp`.
    fn transfer_zip(
        &self,
        url: &str,
        version: &str,
        id: &str,
        temp: &Path,
        info: &Path,
        cancel: &Cancel,
    ) -> CoreResult<()> {
        let _ = fs::write(info, version);
        let _ = fs::remove_file(temp);
        let mut attempt = 0;
        loop {
            attempt += 1;
            match self.transfer_zip_once(url, version, id, temp, cancel) {
                Ok(()) => return Ok(()),
                Err((error, retryable)) => {
                    if !retryable || attempt >= MAX_ZIP_ATTEMPTS || cancel.is_cancelled() {
                        return Err(error);
                    }
                    self.host.warn(format!(
                        "Download attempt {attempt} failed ({}), retrying",
                        error.message
                    ));
                    std::thread::sleep(Duration::from_millis(500 * u64::from(attempt)));
                }
            }
        }
    }

    fn transfer_zip_once(
        &self,
        url: &str,
        version: &str,
        id: &str,
        temp: &Path,
        cancel: &Cancel,
    ) -> Result<(), (CoreError, bool)> {
        let existing = fs::metadata(temp).map(|metadata| metadata.len()).unwrap_or(0);
        let range = format!("bytes={existing}-");
        let headers: Vec<(&str, &str)> = if existing > 0 {
            vec![("Range", range.as_str())]
        } else {
            Vec::new()
        };
        let mut file: Option<fs::File> = None;
        let mut written: u64 = 0;
        let mut expected_total: Option<u64> = None;
        let mut offset: u64 = 0;
        let mut last_percent = 0;
        let mut plan_status = 0u16;
        let mut content_range = None;
        let mut body_len: Option<u64> = None;
        let stopped = || NetError {
            kind: crate::net::NetErrorKind::Io,
            message: "download_stopped".into(),
        };
        let result = self.http.download(url, &headers, &mut |event| match event {
            crate::net::Stream::Head(head) => {
                if !(head.status == 200 || head.status == 206) {
                    return Err(NetError {
                        kind: crate::net::NetErrorKind::Network,
                        message: format!("HTTP error: {}", head.status),
                    });
                }
                let plan = crate::http::plan_zip_resume_write(
                    head.status as i64,
                    existing as i64,
                    head.header("Content-Range"),
                )
                .map_err(|code| NetError {
                    kind: crate::net::NetErrorKind::Network,
                    message: code.to_string(),
                })?;
                plan_status = plan.response_code as u16;
                offset = plan.write_offset as u64;
                content_range = head.header("Content-Range").map(str::to_string);
                body_len = head.content_length;
                let append = crate::http::should_append_http_body(plan.response_code, existing as i64);
                expected_total = head
                    .content_length
                    .map(|length| if append { length + offset } else { length });
                if let (Some(total), Some(free)) = (expected_total, fsutil::available_space(temp)) {
                    if free < total.saturating_mul(2) {
                        return Err(NetError {
                            kind: crate::net::NetErrorKind::Io,
                            message: "insufficient_disk_space".into(),
                        });
                    }
                }
                let handle = OpenOptions::new()
                    .create(true)
                    .write(true)
                    .append(append)
                    .truncate(!append)
                    .open(temp)
                    .map_err(|error| NetError {
                        kind: crate::net::NetErrorKind::Io,
                        message: error.to_string(),
                    })?;
                written = if append { existing } else { 0 };
                file = Some(handle);
                Ok(())
            }
            crate::net::Stream::Chunk(chunk) => {
                if cancel.is_cancelled() {
                    return Err(stopped());
                }
                let handle = file.as_mut().ok_or_else(stopped)?;
                handle.write_all(chunk).map_err(|error| NetError {
                    kind: crate::net::NetErrorKind::Io,
                    message: error.to_string(),
                })?;
                written += chunk.len() as u64;
                if let Some(total) = expected_total.filter(|total| *total > 0) {
                    let percent = (((written as f64 / total as f64) * 100.0) as i64).clamp(10, 70);
                    if percent >= last_percent + 10 {
                        last_percent = (percent / 10) * 10;
                        self.progress(id, last_percent);
                    }
                }
                Ok(())
            }
        });
        if let Some(mut handle) = file {
            let _ = handle.flush();
        }
        match result {
            Ok(_) => {}
            Err(error) => {
                if error.message == "insufficient_disk_space" {
                    self.send_stats("insufficient_disk_space", Some(version), None, None);
                    return Err((
                        CoreError::new("insufficient_disk_space", "Insufficient disk space for download"),
                        false,
                    ));
                }
                if error.message == "download_stopped" {
                    return Err((CoreError::new("download_stopped", "Download cancelled"), false));
                }
                let retryable = match error
                    .message
                    .strip_prefix("HTTP error: ")
                    .and_then(|code| code.parse::<i64>().ok())
                {
                    Some(status) => crate::http::is_retryable_http_status(status),
                    None => {
                        error.kind != crate::net::NetErrorKind::InvalidUrl
                            && error.kind != crate::net::NetErrorKind::Tls
                    }
                };
                let code = if error.message.starts_with("HTTP error") {
                    "http_error"
                } else if error.is_timeout() {
                    "timeout"
                } else {
                    "network_error"
                };
                return Err((CoreError::new(code, error.message), retryable));
            }
        }
        // Completeness checks (resume safety).
        let length = fs::metadata(temp).map(|metadata| metadata.len()).unwrap_or(0);
        let incomplete = |reason: &str| Err((CoreError::new("incomplete_download", reason.to_string()), true));
        if plan_status == 206 {
            match crate::http::parse_content_range(content_range.as_deref()) {
                Some(range) if range.total >= 0 => {
                    if range.start as u64 != offset {
                        return incomplete("content_range_mismatch");
                    }
                    if length - offset != (range.end - range.start + 1) as u64 {
                        return incomplete("incomplete_content_range");
                    }
                    if length != range.total as u64 {
                        return incomplete("incomplete_download");
                    }
                }
                _ => return incomplete("unknown_content_range_total"),
            }
        } else if let Some(body) = body_len {
            if length != body {
                return incomplete("incomplete_download");
            }
        }
        Ok(())
    }

    /// Copies the files of an installed bundle into the delta cache
    /// (`<hash>_<name>`) so the next manifest download can reuse them.
    pub fn populate_delta_cache(&self, id: &str) {
        let Ok(bundle) = self.bundle_directory(id) else {
            return;
        };
        let cache = self.config().cache_dir.clone();
        if cache.as_os_str().is_empty() || !bundle.is_dir() || fs::create_dir_all(&cache).is_err() {
            return;
        }
        let builtin = self.config().builtin_dir.clone();
        let mut files = Vec::new();
        collect_files(&bundle, &mut files);
        for file in files {
            let Ok(hash) = crypto::checksum::sha256_file(&file) else {
                continue;
            };
            let relative = file.strip_prefix(&bundle).unwrap_or(&file);
            if !builtin.as_os_str().is_empty() && fsutil::file_matches_hash(&builtin.join(relative), &hash) {
                continue;
            }
            let name = file
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default();
            let target = cache.join(format!("{hash}_{name}"));
            if target.exists() {
                continue;
            }
            if fsutil::copy_atomically(&file, &target).is_err() {
                self.host.debug(format!("Delta cache copy failed: {}", file.display()));
            }
        }
    }

    /// Sweeps download leftovers older than one hour.
    pub fn cleanup_download_temp_files(&self) {
        let age = Duration::from_secs(3600);
        let storage = self.config().storage_root.clone();
        let cache = self.config().cache_dir.clone();
        for dir in [storage, cache] {
            let Ok(entries) = fs::read_dir(&dir) else {
                continue;
            };
            for entry in entries.filter_map(Result::ok) {
                let name = entry.file_name().to_string_lossy().into_owned();
                let stale = (name.starts_with("temp_") && name.ends_with(".tmp"))
                    || (name.starts_with("update_") && name.ends_with(".dat"))
                    || (name.starts_with("partial_") && name.ends_with(".tmp"))
                    || name.starts_with("work_");
                if stale && fsutil::modified_before(&entry.path(), age) {
                    let _ = remove_path(&entry.path());
                }
            }
        }
    }
}

pub(crate) fn collect_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.filter_map(Result::ok) {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with("__MACOSX") || name.starts_with('.') {
            continue;
        }
        let path = entry.path();
        if path.is_dir() {
            collect_files(&path, out);
        } else if path.is_file() {
            out.push(path);
        }
    }
}

#[allow(dead_code)]
fn _json(_: Map<String, Value>) {}
