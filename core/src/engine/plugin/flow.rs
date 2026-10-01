//! Plugin load, app lifecycle and the auto-update cycle.

use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};

use super::{hooks, keys, DelaySource, PluginConfig, DOWNLOAD_STUCK_TIMEOUT, OBSOLETE_DELETE_PACING};
use crate::bundle::{BundleInfo, ID_BUILTIN};
use crate::engine::download::DownloadRequest;
use crate::engine::Engine;
use crate::error::CoreResult;
use crate::host::HostLog;
use crate::policy;

/// How one update cycle ends (`endBackGroundTaskWithNotif`).
pub(crate) struct CycleEnd<'a> {
    pub message: &'a str,
    pub latest_version: &'a str,
    pub current: &'a BundleInfo,
    pub error: bool,
    pub planned_direct_update: bool,
    pub send_stats: bool,
    pub notify_no_need_update: bool,
    /// Version the failure stat is about (defaults to the current bundle).
    pub stat_version: Option<&'a str>,
}

impl<'a> CycleEnd<'a> {
    pub fn new(message: &'a str, latest_version: &'a str, current: &'a BundleInfo, error: bool, planned: bool) -> Self {
        Self {
            message,
            latest_version,
            current,
            error,
            planned_direct_update: planned,
            send_stats: true,
            notify_no_need_update: true,
            stat_version: None,
        }
    }
}

fn is_http_url(value: &str) -> bool {
    url::Url::parse(value)
        .map(|url| matches!(url.scheme(), "http" | "https") && url.host().is_some())
        .unwrap_or(false)
}

fn text(object: &Map<String, Value>, key: &str) -> Option<String> {
    object
        .get(key)
        .filter(|value| !value.is_null())
        .map(|value| value.as_str().map_or_else(|| value.to_string(), str::to_string))
}

impl Engine {
    // ---- load --------------------------------------------------------------------------------

    pub(crate) fn load_plugin(&self, input: &Value) -> CoreResult<Value> {
        let config_json = input.get("config").cloned().unwrap_or(Value::Null);
        let native = input.get("native").cloned().unwrap_or(Value::Null);
        let (config, warnings) = PluginConfig::from_json(&config_json, &native);
        for warning in warnings {
            self.host.error(warning);
        }
        let object = config_json.as_object().cloned().unwrap_or_default();
        {
            let mut state = self.plugin_state();
            state.config = config.clone();
            state.shake_menu_enabled = config.shake_menu;
            state.shake_channel_selector_enabled = config.allow_shake_channel_selector;
            state.shake_menu_gesture = config.shake_menu_gesture.clone();
            state.launch_started_at_ms = super::now_ms();
            state.loaded = true;
        }
        self.mark_cleanup(false);

        // Endpoints, keys and HTTP settings (persisted URL overrides when allowed).
        let persisted = |key: &str| {
            if config.persist_modify_url {
                self.kv_text(key)
            } else {
                None
            }
        };
        let mut runtime = Map::new();
        if let Some(app_id) = text(&object, "appId").filter(|app_id| !app_id.is_empty()) {
            runtime.insert("appId".into(), json!(app_id));
        }
        if self.config().app_id.is_empty() && !runtime.contains_key("appId") {
            return Err(crate::error::CoreError::invalid_input(
                "appId is missing in capacitor.config.json or plugin config, and cannot be retrieved from the native app, please add it globally or in the plugin config",
            ));
        }
        runtime.insert(
            "updateUrl".into(),
            json!(persisted(keys::UPDATE_URL)
                .or_else(|| text(&object, "updateUrl"))
                .unwrap_or_else(|| super::DEFAULT_UPDATE_URL.into())),
        );
        runtime.insert(
            "statsUrl".into(),
            json!(persisted(keys::STATS_URL)
                .or_else(|| text(&object, "statsUrl"))
                .unwrap_or_else(|| super::DEFAULT_STATS_URL.into())),
        );
        runtime.insert(
            "channelUrl".into(),
            json!(persisted(keys::CHANNEL_URL)
                .or_else(|| text(&object, "channelUrl"))
                .unwrap_or_else(|| super::DEFAULT_CHANNEL_URL.into())),
        );
        runtime.insert(
            "publicKey".into(),
            json!(text(&object, "publicKey").unwrap_or_default()),
        );
        let response_timeout = super::object_i64(&object, "responseTimeout", 20);
        runtime.insert(
            "timeoutMs".into(),
            json!(if response_timeout > 0 {
                response_timeout as u64 * 1000
            } else {
                20_000
            }),
        );
        runtime.insert(
            "allowHttpsToHttpRedirect".into(),
            json!(super::object_bool(&object, "allowHttpsToHttpRedirect", false)),
        );
        if !config.native_version.is_empty() && self.config().version_build.is_empty() {
            runtime.insert("versionBuild".into(), json!(config.native_version));
        }
        if let Err(error) = self.configure(&Value::Object(runtime)) {
            // An invalid public key must not make the plugin inert: encryption stays required.
            self.host.error(error.message.clone());
            return Err(error);
        }
        let key_id = self.config().key_id.clone();
        if !key_id.is_empty() {
            self.host.info(format!("Public key prefix: {key_id}"));
        }

        let native_build = config.native_build.clone();
        let stored_build = self.stored_native_build();
        let native_build_changed = !stored_build.is_empty() && stored_build != native_build;

        self.prepare_default_channel(native_build_changed);
        self.restore_pending_stats();
        if config.persist_custom_id {
            if let Some(custom_id) = self.kv_text(keys::CUSTOM_ID).filter(|value| !value.is_empty()) {
                self.config_mut().custom_id = custom_id;
                self.host.info("Loaded persisted customId");
            }
        }
        self.host.info(format!("init for device {}", self.config().device_id));
        self.host.info(format!("version native {}", config.native_version));
        self.report_app_launch_start();

        self.restore_preview_state_at_load();
        self.plugin_state().was_recently_installed_or_updated = stored_build.is_empty() || stored_build != native_build;
        self.auto_reset(&native_build, config.reset_when_update);
        if native_build_changed {
            self.clear_preview_session_for_native_build_change();
        }
        if let Some(url) = native.get("launchUrl").and_then(Value::as_str) {
            self.leave_preview_for_launch_url(url);
        }
        self.report_native_version_stats_if_changed();
        if let Some(stats) = native.get("previousExits").and_then(Value::as_array) {
            self.report_previous_exits(stats);
        }
        self.report_previous_render_process_gone();
        if config.track_unclean_exits {
            self.report_previous_unclean_exit_and_start_session();
        }
        if !config.reset_when_update {
            self.persist_native_build_version();
        }
        self.cleanup_obsolete_versions(config.reset_when_update, native_build_changed);
        self.check_cancel_delay(DelaySource::Killed);
        self.start_periodic_check();
        self.show_preview_notice_if_needed();
        self.sync_shake_menu();
        self.hook(
            hooks::KEEP_URL_PATH,
            json!({ "enabled": config.keep_url_path_after_reload }),
        );
        // The first appReady waits for notifyAppReady from the initial page.
        self.arm_pending_ready_wait();
        let current = self.current_bundle();
        Ok(json!({
            "appId": self.config().app_id,
            "bundle": current.to_js(),
            "path": self.current_bundle_path(),
            "isBuiltin": self.is_using_builtin(),
            "autoUpdate": config.auto_update_mode,
            "previewSession": self.plugin_state().preview_session_enabled,
        }))
    }

    pub(crate) fn stored_native_build(&self) -> String {
        let keys = self.config().keys.clone();
        let current = self.host.kv_get(&keys.native_build_version, None).unwrap_or_default();
        if current.is_empty() {
            self.host
                .kv_get(&keys.legacy_native_build_version, None)
                .unwrap_or_default()
        } else {
            current
        }
    }

    pub(crate) fn persist_native_build_version(&self) {
        if self.plugin_state().default_channel_cleanup_must_retry {
            self.host
                .warn("Keeping the previous native build version so default channel cleanup retries");
            return;
        }
        let build = self.plugin_config().native_build;
        let key = self.config().keys.native_build_version.clone();
        self.kv_write(&key, Some(&build));
    }

    /// Deletes obsolete bundles after a native update and sweeps leftovers;
    /// downloads wait on it ([`Engine::wait_for_cleanup`]).
    fn cleanup_obsolete_versions(&self, reset_when_update: bool, native_build_changed: bool) {
        self.mark_cleanup(false);
        self.hook(
            hooks::BACKGROUND_TASK,
            json!({ "action": "begin", "name": "CapgoBundleCleanup" }),
        );
        let weak = self.weak_self();
        std::thread::spawn(move || {
            let Some(engine) = weak.upgrade() else {
                return;
            };
            if reset_when_update && native_build_changed {
                engine.host.info(format!(
                    "New native build version detected: {}",
                    engine.plugin_config().native_build
                ));
                for bundle in engine.list(false) {
                    engine.host.info(format!("Deleting obsolete bundle: {}", bundle.id()));
                    if !engine.delete_bundle(bundle.id(), true, true) {
                        engine.host.error(format!("Failed to delete: {}", bundle.id()));
                    }
                    std::thread::sleep(OBSOLETE_DELETE_PACING);
                }
                engine.cleanup_delta_cache();
            }
            engine.drain_pending_deletes();
            let allowed = engine.allowed_bundle_ids_for_cleanup();
            engine.cleanup_download_directories(&allowed, &|| false);
            engine.cleanup_orphaned_temp_folders(&|| false);
            engine.cleanup_download_temp_files();
            engine.persist_native_build_version();
            engine.mark_cleanup(true);
            engine.host.info("Cleanup complete");
            engine.hook(
                hooks::BACKGROUND_TASK,
                json!({ "action": "end", "name": "CapgoBundleCleanup" }),
            );
        });
    }

    // ---- lifecycle ---------------------------------------------------------------------------

    pub(crate) fn app_moved_to_foreground(&self) {
        // A check armed before or during the background must not fire on thaw: this
        // foreground arms a fresh one below.
        self.invalidate_app_ready_check();
        self.plugin_state().in_background = false;
        self.mark_session_foreground(true);
        let current = self.current_bundle();
        self.send_stats("app_moved_to_foreground", Some(current.version_name()), None, None);
        self.check_cancel_delay(DelaySource::Foreground);
        self.unset_background_timestamp();
        if self.is_auto_update_enabled() {
            if self.is_update_cycle_running() {
                self.host
                    .info("Download already in progress, skipping duplicate download request");
            } else {
                self.background_download();
            }
        } else {
            if self.plugin_config().server_url_configured {
                self.send_stats("blocked_by_server_url", Some(current.version_name()), None, None);
            }
            self.host.info("Auto update is disabled");
            self.send_ready_to_js(&current, "disabled");
        }
        self.check_app_ready(self.app_ready_check_timeout());
    }

    /// Runs on the caller's thread (the host's background notification) so the
    /// splash screen is up before the OS snapshots the app.
    pub(crate) fn background_splash(&self) {
        self.plugin_state().in_background = true;
        // The page is paused: its readiness is checked again from the next foreground.
        self.invalidate_app_ready_check();
        self.mark_session_foreground(false);
        self.plugin_state().auto_splashscreen_timed_out = false;
        let config = self.plugin_config();
        if config.auto_splashscreen {
            let mut can_show = true;
            if !self.is_auto_update_enabled() {
                self.host.warn("autoSplashscreen is enabled but autoUpdate is disabled. Splashscreen will not be shown. Enable autoUpdate or disable autoSplashscreen.");
                can_show = false;
            }
            if !self.should_use_direct_update() {
                match config.direct_update_mode.as_str() {
                    policy::DIRECT_UPDATE_DISABLED => self.host.warn("autoSplashscreen is enabled but directUpdate is not configured for immediate updates. Set directUpdate to 'always' or disable autoSplashscreen."),
                    mode @ (policy::AUTO_UPDATE_INSTALL | policy::AUTO_UPDATE_LAUNCH) => self.host.info(format!(
                        "autoSplashscreen is enabled but directUpdate is set to \"{mode}\". This is normal. Skipping autoSplashscreen logic."
                    )),
                    _ => {}
                }
                can_show = false;
            }
            if can_show {
                self.host.info("Showing splashscreen for launcher/task switcher");
                self.show_splashscreen();
            }
        }
    }

    /// Background bookkeeping and the pending install, kept alive with a background task.
    pub(crate) fn background_work(&self) {
        let current = self.current_bundle();
        self.hook(
            hooks::BACKGROUND_TASK,
            json!({ "action": "begin", "name": "CapgoInstallNext" }),
        );
        self.send_stats("app_moved_to_background", Some(current.version_name()), None, None);
        self.persist_stats(false);
        self.host.info("Checking for pending update");
        self.set_background_timestamp(super::now_ms());
        self.check_cancel_delay(DelaySource::Background);
        self.install_next();
        self.hook(
            hooks::BACKGROUND_TASK,
            json!({ "action": "end", "name": "CapgoInstallNext" }),
        );
    }

    /// The app process is going away (Android `onDestroy`).
    pub(crate) fn app_terminated(&self) {
        self.mark_session_foreground(false);
        self.check_cancel_delay(DelaySource::Killed);
        self.set_background_timestamp(0);
        self.persist_stats(true);
    }

    /// Installs the bundle queued with `next` / `setNext` (at background).
    pub(crate) fn install_next(&self) {
        if self.block_for_preview() {
            return;
        }
        if self.has_delay_conditions() {
            self.host.info("Update delayed until delay conditions met");
            return;
        }
        let current = self.current_bundle();
        let Some(next) = self.next_bundle() else {
            return;
        };
        if next.is_error() || next.id() == current.id() {
            return;
        }
        self.host.debug(format!("Next bundle is: {}", next.version_name()));
        if self.set_bundle(next.id()) && self.reload_app() {
            self.host.info(format!("Updated to bundle: {}", next.version_name()));
            self.emit_bundle_event("set", &next);
            self.set_next_bundle(None);
        } else {
            self.host
                .error(format!("Update to bundle: {} Failed!", next.version_name()));
        }
    }

    // ---- direct update decisions -------------------------------------------------------------

    /// Whether this cycle installs right away. Stateful: `atInstall` is consumed by the first caller.
    pub(crate) fn should_use_direct_update(&self) -> bool {
        let mut state = self.plugin_state();
        let config = &state.config;
        if !config.auto_update_enabled() || config.auto_update_mode == policy::AUTO_UPDATE_ONLY_DOWNLOAD {
            return false;
        }
        if state.auto_splashscreen_timed_out {
            return false;
        }
        match config.direct_update_mode.as_str() {
            policy::AUTO_UPDATE_ALWAYS => true,
            policy::AUTO_UPDATE_INSTALL => {
                if state.was_recently_installed_or_updated {
                    state.was_recently_installed_or_updated = false;
                    true
                } else {
                    false
                }
            }
            policy::AUTO_UPDATE_LAUNCH => !state.on_launch_direct_update_used,
            _ => false,
        }
    }

    fn direct_update_allowed_now(&self, planned: bool) -> bool {
        planned && !self.plugin_state().auto_splashscreen_timed_out
    }

    pub(crate) fn consume_on_launch_direct_update(&self, planned: bool) {
        let mut state = self.plugin_state();
        if policy::should_consume_on_launch_direct_update(&state.config.direct_update_mode, planned) {
            state.on_launch_direct_update_used = true;
        }
    }

    // ---- update cycle ------------------------------------------------------------------------

    /// A cycle is running and younger than the stuck timeout.
    pub(crate) fn is_update_cycle_running(&self) -> bool {
        let mut state = self.plugin_state();
        match state.download_started_at {
            None => false,
            Some(started) if started.elapsed() > DOWNLOAD_STUCK_TIMEOUT => {
                self.host.warn(format!(
                    "Download has been in progress for {} ms, exceeding timeout of {} ms. Clearing stuck state.",
                    started.elapsed().as_millis(),
                    DOWNLOAD_STUCK_TIMEOUT.as_millis()
                ));
                state.download_started_at = None;
                false
            }
            Some(_) => true,
        }
    }

    fn clear_update_cycle(&self) {
        self.plugin_state().download_started_at = None;
        self.hook(
            hooks::BACKGROUND_TASK,
            json!({ "action": "end", "name": "Finish Download Tasks" }),
        );
    }

    /// Starts an update check (+ download / install) on a worker thread.
    /// Returns `queued`, `already_running` or `unavailable`.
    pub(crate) fn background_download(&self) -> &'static str {
        let _guard = self.plugin.cycle.lock().unwrap();
        if self.block_for_preview() {
            return "unavailable";
        }
        if self.is_update_cycle_running() {
            self.host
                .info("Download already in progress, skipping duplicate download request");
            return "already_running";
        }
        let update_url = self.config().update_url.clone();
        if !is_http_url(&update_url) {
            self.host.error("Error no url or wrong format");
            return "unavailable";
        }
        let planned = self.should_use_direct_update();
        let message_update = if self.direct_update_allowed_now(planned) {
            "Update will occur now."
        } else if self.plugin_config().should_set_next_bundle() {
            "Update will occur next time app moves to background."
        } else {
            "Update will be downloaded and made available."
        };
        self.plugin_state().download_started_at = Some(Instant::now());
        self.hook(
            hooks::BACKGROUND_TASK,
            json!({ "action": "begin", "name": "Finish Download Tasks" }),
        );
        let weak = self.weak_self();
        std::thread::spawn(move || {
            if let Some(engine) = weak.upgrade() {
                engine.run_update_cycle(&update_url, planned, message_update);
            }
        });
        "queued"
    }

    pub(crate) fn end_update_cycle(&self, end: CycleEnd<'_>) {
        self.consume_on_launch_direct_update(end.planned_direct_update);
        if end.error {
            self.host.info(format!(
                "endBackGroundTaskWithNotif error: true current: {} latestVersionName: {}",
                end.current.version_name(),
                end.latest_version
            ));
            if end.send_stats {
                let version = end.stat_version.unwrap_or(end.current.version_name());
                self.send_stats("download_fail", Some(version), None, None);
            }
            self.host
                .emit("downloadFailed", &json!({ "version": end.latest_version }));
        }
        if end.notify_no_need_update {
            self.emit_bundle_event("noNeedUpdate", end.current);
        }
        self.send_ready_to_js(end.current, end.message);
        self.clear_update_cycle();
        self.host.info(format!("endBackGroundTaskWithNotif {}", end.message));
    }

    fn notify_update_check_result(&self, response: &Map<String, Value>, current: &BundleInfo) -> (String, String) {
        let error = text(response, "error").unwrap_or_default();
        let message = text(response, "message").unwrap_or_else(|| "server did not provide a message".into());
        let status_code = response.get("statusCode").and_then(Value::as_i64).unwrap_or(0);
        let kind = policy::normalized_update_response_kind(response.get("kind").and_then(Value::as_str)).to_string();
        let version = text(response, "version")
            .filter(|version| !version.is_empty())
            .unwrap_or_else(|| current.version_name().to_string());
        self.host.emit(
            "updateCheckResult",
            &json!({
                "kind": kind,
                "error": error,
                "message": message,
                "statusCode": status_code,
                "version": version,
                "bundle": current.to_js(),
            }),
        );
        match kind.as_str() {
            "up_to_date" => self.host.info("No new version available"),
            "blocked" => self.host.info(format!("Update check blocked with error: {error}")),
            _ => self.host.error(format!(
                "getLatest failed with error: {error}, message: {message}, statusCode: {status_code}"
            )),
        }
        (kind, message)
    }

    fn run_update_cycle(&self, update_url: &str, planned: bool, message_update: &str) {
        if self.block_for_preview() {
            self.clear_update_cycle();
            return;
        }
        self.host.info(format!("Check for update via {update_url}"));
        let response = self.get_latest(Some(update_url), None, None);
        if self.block_for_preview() {
            self.clear_update_cycle();
            return;
        }
        let current = self.current_bundle();
        if response.contains_key("error") || response.contains_key("kind") {
            let (kind, message) = self.notify_update_check_result(&response, &current);
            let latest = text(&response, "version").unwrap_or_default();
            self.notify_breaking_events_if_needed(&response, &latest);
            let failed = kind == "failed";
            let latest_version = if latest.is_empty() {
                current.version_name().to_string()
            } else {
                latest
            };
            let mut end = CycleEnd::new(&message, &latest_version, &current, failed, planned);
            end.send_stats = failed;
            self.end_update_cycle(end);
            return;
        }
        if let Err(error) = self.wait_for_cleanup() {
            self.host
                .error(format!("Cleanup still running, skipping download: {}", error.message));
            let end = CycleEnd::new("Error in update check", current.version_name(), &current, true, planned);
            self.end_update_cycle(end);
            return;
        }
        let current = self.current_bundle();
        let latest_version = text(&response, "version").unwrap_or_default();

        if latest_version == ID_BUILTIN {
            self.update_to_builtin(&current, planned);
            return;
        }
        let url = text(&response, "url").unwrap_or_default();
        if !is_http_url(&url) {
            self.notify_breaking_events_if_needed(&response, &latest_version);
            self.host.error("Error no url or wrong format");
            let end = CycleEnd::new("Error no url or wrong format", &latest_version, &current, true, planned);
            self.end_update_cycle(end);
            return;
        }
        if latest_version.is_empty() || latest_version == current.version_name() {
            self.host
                .info(format!("No need to update, {} is the latest bundle.", current.id()));
            let end = CycleEnd::new("No need to update", &latest_version, &current, false, planned);
            self.end_update_cycle(end);
            return;
        }
        self.host.info(format!(
            "New bundle: {latest_version} found. Current is: {}. {message_update}",
            current.version_name()
        ));
        let session_key = text(&response, "sessionKey").unwrap_or_default();
        let existing = self.get_bundle_info_by_name(&latest_version);
        let reusable = existing.as_ref().filter(|bundle| {
            bundle.is_downloaded()
                && !bundle.is_downloading()
                && !bundle.is_deleted()
                && !bundle.is_deleting()
                && !bundle.is_error()
        });
        let next = match (reusable, &existing) {
            (Some(bundle), _) if self.require_session_key_quiet(&session_key) => {
                self.host.info(format!(
                    "Latest bundle already exists and download is NOT required. {message_update}"
                ));
                bundle.clone()
            }
            (_, Some(bundle)) if bundle.is_error() => {
                self.host
                    .error("Latest bundle already exists, and is in error state. Aborting update.");
                let end = CycleEnd::new(
                    "Latest bundle already exists, and is in error state. Aborting update.",
                    &latest_version,
                    &current,
                    true,
                    planned,
                );
                self.end_update_cycle(end);
                return;
            }
            _ => {
                if let Some(bundle) = &existing {
                    self.host.info(format!(
                        "Latest bundle already exists in incomplete state ({}) and will be deleted, download will overwrite it.",
                        bundle.status().as_str()
                    ));
                    if self.next_bundle().is_some_and(|next| next.id() == bundle.id()) {
                        self.set_next_bundle(None);
                    }
                    self.delete_bundle(bundle.id(), true, true);
                }
                self.consume_on_launch_direct_update(planned);
                let request = DownloadRequest {
                    url: url.clone(),
                    version: latest_version.clone(),
                    session_key: session_key.clone(),
                    checksum: text(&response, "checksum").unwrap_or_default(),
                    manifest: response.get("manifest").and_then(Value::as_array).cloned(),
                    link: text(&response, "link"),
                    comment: text(&response, "comment"),
                    emit_events: false,
                    ..Default::default()
                };
                let result = if request.manifest.is_some() {
                    self.download_manifest(&request)
                } else {
                    self.download_zip(&request)
                };
                match result {
                    Ok(bundle) => bundle,
                    Err(error) => {
                        self.host.error(format!("Error downloading file {}", error.message));
                        let message = match error.code {
                            "session_key_required" => "Session key required when public key is present",
                            "checksum_required" => "Checksum required",
                            "checksum_fail" => "Error checksum",
                            _ => "Error downloading file",
                        };
                        let current = self.current_bundle();
                        let mut end = CycleEnd::new(message, &latest_version, &current, true, planned);
                        end.stat_version = Some(&latest_version);
                        self.end_update_cycle(end);
                        return;
                    }
                }
            }
        };
        if next.is_error() {
            self.host
                .error("Latest bundle already exists and is in error state. Aborting update.");
            let end = CycleEnd::new(
                "Latest version is in error state. Aborting update.",
                &latest_version,
                &current,
                true,
                planned,
            );
            self.end_update_cycle(end);
            return;
        }
        if self.block_for_preview() {
            self.clear_update_cycle();
            return;
        }
        self.install_downloaded(&next, &current, &latest_version, planned);
    }

    /// Valid session key (or no public key): encrypted bundles cannot be reused otherwise.
    fn require_session_key_quiet(&self, session_key: &str) -> bool {
        self.config().public_key.is_empty() || crate::crypto::is_valid_session_key(Some(session_key))
    }

    fn update_to_builtin(&self, current: &BundleInfo, planned: bool) {
        self.host.info("Latest version is builtin");
        if self.direct_update_allowed_now(planned) {
            self.host.info("Direct update to builtin version");
            self.perform_reset(false, false, false);
            let after = self.current_bundle();
            let end = CycleEnd::new("Updated to builtin version", ID_BUILTIN, &after, false, planned);
            self.end_update_cycle(end);
        } else if self.plugin_config().should_set_next_bundle() {
            if planned {
                self.host
                    .info("Direct update skipped because splashscreen timeout occurred. Update will be applied later.");
            }
            self.host.info("Setting next bundle to builtin");
            self.set_next_bundle(Some(ID_BUILTIN));
            let end = CycleEnd::new(
                "Next update will be to builtin version",
                ID_BUILTIN,
                current,
                false,
                planned,
            );
            self.end_update_cycle(end);
        } else {
            self.host
                .info("autoUpdate is set to onlyDownload, builtin version will not be set as next bundle");
            let available = !current.is_builtin();
            if available {
                let builtin = self.get_bundle_info(Some(ID_BUILTIN));
                self.emit_bundle_event("updateAvailable", &builtin);
            }
            let mut end = CycleEnd::new(
                "Latest version is builtin, autoUpdate onlyDownload",
                ID_BUILTIN,
                current,
                false,
                planned,
            );
            end.notify_no_need_update = !available;
            self.end_update_cycle(end);
        }
    }

    fn install_downloaded(&self, next: &BundleInfo, current: &BundleInfo, latest_version: &str, planned: bool) {
        if self.direct_update_allowed_now(planned) {
            if self.has_delay_conditions() {
                self.host.info("Update delayed until delay conditions met");
                let end = CycleEnd::new(
                    "Update delayed until delay conditions met",
                    latest_version,
                    next,
                    false,
                    planned,
                );
                self.end_update_cycle(end);
                return;
            }
            if self.apply_downloaded_bundle(next) {
                self.emit_bundle_event("set", next);
                let end = CycleEnd::new("update installed", latest_version, next, false, planned);
                self.end_update_cycle(end);
            } else if self.queue_next(next) {
                self.emit_bundle_event("updateAvailable", next);
                let live = self.current_bundle();
                let end = CycleEnd::new(
                    "Direct update reload failed, update will install next background",
                    latest_version,
                    &live,
                    false,
                    planned,
                );
                self.end_update_cycle(end);
            } else {
                let end = CycleEnd::new(
                    "Direct update reload failed, and next bundle could not be queued",
                    latest_version,
                    current,
                    true,
                    planned,
                );
                self.end_update_cycle(end);
            }
        } else if self.plugin_config().should_set_next_bundle() {
            if planned {
                self.host.info(
                    "Direct update skipped because splashscreen timeout occurred. Update will install on next app background.",
                );
            }
            if self.queue_next(next) {
                self.emit_bundle_event("updateAvailable", next);
                let end = CycleEnd::new(
                    "update downloaded, will install next background",
                    latest_version,
                    current,
                    false,
                    planned,
                );
                self.end_update_cycle(end);
            } else {
                let end = CycleEnd::new(
                    "Update downloaded, but next bundle could not be queued",
                    latest_version,
                    current,
                    true,
                    planned,
                );
                self.end_update_cycle(end);
            }
        } else {
            self.host
                .info("autoUpdate is set to onlyDownload, downloaded update will not be set as next bundle");
            self.emit_bundle_event("updateAvailable", next);
            let mut end = CycleEnd::new(
                "update downloaded, autoUpdate onlyDownload",
                latest_version,
                current,
                false,
                planned,
            );
            end.notify_no_need_update = false;
            self.end_update_cycle(end);
        }
    }

    fn queue_next(&self, bundle: &BundleInfo) -> bool {
        if self.set_next_bundle(Some(bundle.id())) {
            return true;
        }
        self.host
            .error(format!("Failed to queue downloaded bundle as next: {}", bundle.id()));
        false
    }

    // ---- triggers ----------------------------------------------------------------------------

    /// `triggerUpdateCheck()`: queues a full update cycle whatever the `autoUpdate`
    /// mode (with auto update off the cycle only downloads, like `onlyDownload`).
    /// Returns `queued`, `already_running`, `preview_session` or `unavailable`.
    pub(crate) fn trigger_update_check(&self) -> &'static str {
        if !is_http_url(&self.config().update_url) {
            self.host.error("Error no url or wrong format");
            return "unavailable";
        }
        if self.block_for_preview() {
            return "preview_session";
        }
        self.background_download()
    }

    /// Periodic update check (`periodCheckDelay`), started once at load.
    fn start_periodic_check(&self) {
        let period = self.plugin_config().period_check_delay_s;
        if period == 0 || !self.is_auto_update_enabled() {
            return;
        }
        if self
            .plugin
            .periodic_started
            .swap(true, std::sync::atomic::Ordering::SeqCst)
        {
            return;
        }
        let weak = self.weak_self();
        std::thread::spawn(move || loop {
            let Some(engine) = Engine::sleep_unless_dropped(&weak, Duration::from_secs(period)) else {
                return;
            };
            engine.periodic_tick();
        });
    }

    pub(crate) fn periodic_tick(&self) {
        if self.block_for_preview() || !self.is_auto_update_enabled() {
            return;
        }
        let response = self.get_latest(None, None, None);
        if self.block_for_preview() {
            return;
        }
        let current = self.current_bundle();
        if response.contains_key("error") || response.contains_key("kind") {
            self.notify_update_check_result(&response, &current);
            return;
        }
        let Some(version) = text(&response, "version").filter(|version| !version.is_empty()) else {
            return;
        };
        if version != current.version_name() {
            self.host.info(format!("New version found: {version}"));
            self.background_download();
        }
    }

    /// `breakingAvailable` + `majorAvailable` for major / store-required updates.
    pub(crate) fn notify_breaking_events_if_needed(&self, response: &Map<String, Value>, version: &str) {
        let breaking = response.get("breaking").and_then(Value::as_bool).unwrap_or(false)
            || response.get("error").and_then(Value::as_str) == Some("disable_auto_update_to_major")
            || response.get("message").and_then(Value::as_str) == Some("store_update_required");
        if !breaking {
            return;
        }
        let version = if version.is_empty() {
            self.current_bundle().version_name().to_string()
        } else {
            version.to_string()
        };
        for event in ["breakingAvailable", "majorAvailable"] {
            self.host.emit(event, &json!({ "version": version }));
        }
    }
}
