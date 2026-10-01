//! The Capacitor plugin layer: update cycle, direct updates, rollback,
//! delay conditions, preview sessions, channels and launch telemetry.
//!
//! Hosts keep only what needs the platform: the bridge (method registration,
//! resolve / reject, listener dispatch), the WebView (applying a bundle,
//! JavaScript injection), lifecycle observers and UI (splash screen, loaders,
//! alerts, shake menu). They reach that code through [`Host::hook`] with the
//! names in [`hooks`].
//!
//! Every public JavaScript method is one engine operation (`pluginMethod`),
//! which answers `{ "resolve": value }` or `{ "reject": { message, code?, data? } }`.

mod channel;
mod delay;
mod flow;
mod methods;
mod preview;
mod ready;
mod telemetry;

use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};

use super::Engine;
use crate::bundle::BundleInfo;
use crate::error::{CoreError, CoreResult};
use crate::host::HostLog;
use crate::policy;

use delay::DelaySource;
pub use methods::ENGINE_METHODS;

pub const DEFAULT_UPDATE_URL: &str = "https://plugin.capgo.app/updates";
pub const DEFAULT_STATS_URL: &str = "https://plugin.capgo.app/stats";
pub const DEFAULT_CHANNEL_URL: &str = "https://plugin.capgo.app/channel_self";
/// A download that runs longer than this no longer blocks new update checks.
pub const DOWNLOAD_STUCK_TIMEOUT: Duration = Duration::from_secs(600);
/// Pacing between obsolete bundle deletes after a native update.
const OBSOLETE_DELETE_PACING: Duration = Duration::from_millis(75);

/// Hook names the plugin layer calls on the host ([`crate::host::Host::hook`]).
pub mod hooks {
    /// `{ path, isBuiltin, readyGeneration, readyScript }` -> `{ ok, guard? }`: inject `readyScript`
    /// at document start, point the WebView at the bundle and reload it. `guard: false` means
    /// the page cannot report its generation.
    pub const APPLY_BUNDLE: &str = "applyBundle";
    /// `{ action: "show" | "hide" }`
    pub const SPLASH: &str = "splash";
    /// `{ action: "show" | "hide", reason }`
    pub const PREVIEW_LOADER: &str = "previewLoader";
    /// `{ gesture }` -> `{ shown }`: "Preview started" alert.
    pub const PREVIEW_NOTICE: &str = "previewNotice";
    /// `{ enabled, channelSelector, gesture }`
    pub const SHAKE_MENU: &str = "shakeMenu";
    /// `{ message }`: progress text of the shake-menu channel switch (`shakeMenuSwitchChannel`).
    pub const SHAKE_MENU_PROGRESS: &str = "shakeMenuProgress";
    /// `{ enabled }`: `keepUrlPathAfterReload` flag for the page.
    pub const KEEP_URL_PATH: &str = "keepUrlPath";
    /// `{ action: "begin" | "end", name }`: keep the app alive while an update runs.
    pub const BACKGROUND_TASK: &str = "backgroundTask";
    /// `{ path }`: exclude a file from device backups.
    pub const EXCLUDE_FROM_BACKUP: &str = "excludeFromBackup";
    /// `{ host }` -> `{ permitted }`: plain HTTP allowed by the app's policy. No answer = refused.
    pub const CLEARTEXT_PERMITTED: &str = "cleartextPermitted";
}

/// Persisted keys owned by the plugin layer (names kept from every previous version).
pub mod keys {
    pub const CUSTOM_ID: &str = "CapacitorUpdater.customId";
    pub const UPDATE_URL: &str = "CapacitorUpdater.updateUrl";
    pub const STATS_URL: &str = "CapacitorUpdater.statsUrl";
    pub const CHANNEL_URL: &str = "CapacitorUpdater.channelUrl";
    pub const DEFAULT_CHANNEL: &str = "CapacitorUpdater.defaultChannel";
    pub const PREVIEW_SESSION: &str = "CapacitorUpdater.previewSession";
    pub const PREVIEW_ALERT_PENDING: &str = "CapacitorUpdater.previewSessionAlertPending";
    pub const PREVIEW_SESSIONS: &str = "CapacitorUpdater.previewSessions";
    pub const PREVIEW_APP_ID: &str = "CapacitorUpdater.previewAppId";
    pub const PREVIEW_PAYLOAD_URL: &str = "CapacitorUpdater.previewPayloadUrl";
    pub const PREVIEW_NAME: &str = "CapacitorUpdater.previewName";
    pub const PREVIEW_SOURCE: &str = "CapacitorUpdater.previewSource";
    pub const PREVIEW_PREVIOUS_SHAKE_MENU: &str = "CapacitorUpdater.previewPreviousShakeMenu";
    pub const PREVIEW_PREVIOUS_SHAKE_CHANNEL_SELECTOR: &str = "CapacitorUpdater.previewPreviousShakeChannelSelector";
    pub const PREVIEW_PREVIOUS_NEXT_BUNDLE: &str = "CapacitorUpdater.previewPreviousNextBundle";
    pub const PREVIEW_PREVIOUS_APP_ID: &str = "CapacitorUpdater.previewPreviousAppId";
    pub const PREVIEW_PREVIOUS_DEFAULT_CHANNEL: &str = "CapacitorUpdater.previewPreviousDefaultChannel";
    pub const PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET: &str = "CapacitorUpdater.previewPreviousDefaultChannelWasSet";
    pub const INSTALL_MARKER_CREATED: &str = "CapacitorUpdater.defaultChannelInstallMarkerCreated";
    pub const LAST_FAILED_BUNDLE: &str = "CapacitorUpdater.lastFailedBundle";
    pub const LAST_VERSION_OS: &str = "CapacitorUpdater.lastVersionOs";
    pub const LAST_VERSION_BUILD: &str = "CapacitorUpdater.lastVersionBuild";
    pub const LAST_VERSION_CODE: &str = "CapacitorUpdater.lastVersionCode";
    pub const DELAY_CONDITIONS: &str = "DELAY_CONDITION_PREFERENCES_CAPGO";
    pub const BACKGROUND_TIMESTAMP: &str = "BACKGROUND_TIMESTAMP_KEY_CAPGO";
    /// Files in the host's no-backup directory.
    pub const INSTALL_MARKER_FILE: &str = "CapacitorUpdater.defaultChannelInstallMarker";
    pub const DEFAULT_CHANNEL_STATE_FILE: &str = "CapacitorUpdater.defaultChannelState";
    pub const DEFAULT_CHANNEL_SNAPSHOT_FILE: &str = "CapacitorUpdater.defaultChannelPreviewSnapshot";
}

/// Plugin configuration (`plugins.CapacitorUpdater` in capacitor.config) plus
/// the native facts the host reads at load.
#[derive(Debug, Clone)]
pub struct PluginConfig {
    pub app_ready_timeout_ms: u64,
    pub auto_delete_failed: bool,
    pub auto_delete_previous: bool,
    pub auto_update_mode: String,
    pub direct_update_mode: String,
    pub reset_when_update: bool,
    pub auto_splashscreen: bool,
    pub auto_splashscreen_timeout_ms: u64,
    pub period_check_delay_s: u64,
    pub allow_modify_url: bool,
    pub allow_modify_app_id: bool,
    pub allow_manual_bundle_error: bool,
    pub allow_preview: bool,
    pub persist_custom_id: bool,
    pub persist_modify_url: bool,
    pub allow_set_default_channel: bool,
    pub persist_default_channel_on_reinstall: bool,
    pub default_channel: String,
    pub keep_url_path_after_reload: bool,
    pub shake_menu: bool,
    pub shake_menu_gesture: String,
    pub allow_shake_channel_selector: bool,
    /// Capacitor `server.url` is set (live reload): auto update is unavailable.
    pub server_url_configured: bool,
    /// App marketing version (`version` config or native version name).
    pub native_version: String,
    /// Native build number (versionCode / CFBundleVersion).
    pub native_build: String,
    /// Directory excluded from backups (default channel reinstall files).
    pub no_backup_dir: std::path::PathBuf,
    /// `_reload` waits for `notifyAppReady` (Android) or returns once the path is applied (iOS).
    pub reload_waits_for_app_ready: bool,
    /// Minimum rollback delay while the current bundle is not yet confirmed (Android: 30 s).
    pub pending_bundle_min_timeout_ms: u64,
    /// Report crashes from session markers (iOS; Android reports ApplicationExitInfo instead).
    pub track_unclean_exits: bool,
}

fn object_bool(object: &Map<String, Value>, key: &str, default: bool) -> bool {
    match object.get(key) {
        Some(Value::Bool(value)) => *value,
        Some(Value::String(value)) if value == "true" => true,
        Some(Value::String(value)) if value == "false" => false,
        _ => default,
    }
}

fn object_i64(object: &Map<String, Value>, key: &str, default: i64) -> i64 {
    match object.get(key) {
        Some(Value::Number(number)) => number
            .as_i64()
            .or_else(|| number.as_f64().map(|v| v as i64))
            .unwrap_or(default),
        Some(Value::String(text)) => text.trim().parse().unwrap_or(default),
        _ => default,
    }
}

fn object_str(object: &Map<String, Value>, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_string)
}

impl PluginConfig {
    /// Parses the plugin config; returns the warnings to log.
    pub fn from_json(config: &Value, native: &Value) -> (Self, Vec<String>) {
        let empty = Map::new();
        let object = config.as_object().unwrap_or(&empty);
        let native = native.as_object().unwrap_or(&empty);
        let mut warnings = Vec::new();

        // autoUpdate: boolean (legacy, combined with directUpdate) or a mode string.
        let configured = match object.get("autoUpdate") {
            Some(Value::String(value)) => Some(value.clone()),
            Some(Value::Bool(value)) => Some(value.to_string()),
            _ => None,
        };
        let auto_update_mode = match configured.as_deref() {
            Some(value) if !value.is_empty() && value != "true" && value != "false" => {
                let mode = policy::normalized_auto_update_mode(Some(value));
                if mode != value {
                    warnings.push(format!(
                        "Invalid autoUpdate value: \"{value}\". Supported values are: true, false, \"off\", \"atBackground\", \"atInstall\", \"onLaunch\", \"always\", \"onlyDownload\". Defaulting to \"atBackground\"."
                    ));
                }
                mode.to_string()
            }
            other => {
                let enabled = other.map_or(true, |value| value == "true");
                if enabled {
                    let direct = match object.get("directUpdate") {
                        Some(Value::String(value)) => match value.as_str() {
                            "true" => policy::AUTO_UPDATE_ALWAYS.to_string(),
                            "false" | "atInstall" | "onLaunch" | "always" => value.clone(),
                            other => {
                                warnings.push(format!(
                                    "Invalid directUpdate value: \"{other}\". Supported values are: false, true, \"always\", \"atInstall\", \"onLaunch\". Defaulting to \"false\"."
                                ));
                                policy::DIRECT_UPDATE_DISABLED.to_string()
                            }
                        },
                        Some(Value::Bool(true)) => policy::AUTO_UPDATE_ALWAYS.to_string(),
                        _ => policy::DIRECT_UPDATE_DISABLED.to_string(),
                    };
                    policy::auto_update_mode_for_legacy_direct_update_mode(&direct).to_string()
                } else {
                    policy::AUTO_UPDATE_OFF.to_string()
                }
            }
        };
        let direct_update_mode = policy::direct_update_mode_for_auto_update_mode(&auto_update_mode).to_string();
        let native_version = native
            .get("versionName")
            .and_then(Value::as_str)
            .map(str::to_string)
            .filter(|value| !value.is_empty());
        let config = Self {
            app_ready_timeout_ms: object_i64(object, "appReadyTimeout", 10_000).max(1000) as u64,
            auto_delete_failed: object_bool(object, "autoDeleteFailed", true),
            auto_delete_previous: object_bool(object, "autoDeletePrevious", true),
            auto_update_mode,
            direct_update_mode,
            reset_when_update: object_bool(object, "resetWhenUpdate", true),
            auto_splashscreen: object_bool(object, "autoSplashscreen", false),
            auto_splashscreen_timeout_ms: object_i64(object, "autoSplashscreenTimeout", 10_000).max(0) as u64,
            period_check_delay_s: policy::normalized_period_check_delay_seconds(object_i64(
                object,
                "periodCheckDelay",
                0,
            ))
            .max(0) as u64,
            allow_modify_url: object_bool(object, "allowModifyUrl", false),
            allow_modify_app_id: object_bool(object, "allowModifyAppId", false),
            allow_manual_bundle_error: object_bool(object, "allowManualBundleError", false),
            allow_preview: object_bool(object, "allowPreview", false),
            persist_custom_id: object_bool(object, "persistCustomId", false),
            persist_modify_url: object_bool(object, "persistModifyUrl", false),
            allow_set_default_channel: object_bool(object, "allowSetDefaultChannel", true),
            persist_default_channel_on_reinstall: object_bool(object, "persistDefaultChannelOnReinstall", true),
            default_channel: object_str(object, "defaultChannel").unwrap_or_default(),
            keep_url_path_after_reload: object_bool(object, "keepUrlPathAfterReload", false),
            shake_menu: object_bool(object, "shakeMenu", false),
            shake_menu_gesture: policy::normalized_shake_menu_gesture(
                object.get("shakeMenuGesture").and_then(Value::as_str),
            )
            .to_string(),
            allow_shake_channel_selector: object_bool(object, "allowShakeChannelSelector", false),
            server_url_configured: native
                .get("serverUrlConfigured")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            native_version: object_str(object, "version")
                .filter(|value| !value.is_empty())
                .or(native_version)
                .unwrap_or_default(),
            native_build: native
                .get("versionCode")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            no_backup_dir: native
                .get("noBackupDir")
                .and_then(Value::as_str)
                .map(std::path::PathBuf::from)
                .unwrap_or_default(),
            reload_waits_for_app_ready: native
                .get("reloadWaitsForAppReady")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            pending_bundle_min_timeout_ms: native
                .get("pendingBundleMinAppReadyTimeoutMs")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            track_unclean_exits: native
                .get("trackUncleanExits")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        };
        (config, warnings)
    }

    pub fn auto_update_enabled(&self) -> bool {
        policy::is_auto_update_mode_enabled(&self.auto_update_mode)
    }

    pub fn track_unclean_exits(&self) -> bool {
        self.track_unclean_exits
    }

    pub fn should_set_next_bundle(&self) -> bool {
        policy::should_auto_update_mode_set_next_bundle(&self.auto_update_mode)
    }
}

impl Default for PluginConfig {
    fn default() -> Self {
        Self::from_json(&Value::Null, &Value::Null).0
    }
}

/// Mutable plugin state (one per engine).
#[derive(Debug, Default)]
pub struct PluginState {
    pub loaded: bool,
    pub config: PluginConfig,
    pub was_recently_installed_or_updated: bool,
    pub on_launch_direct_update_used: bool,
    pub auto_splashscreen_timed_out: bool,
    pub preview_session_enabled: bool,
    pub preview_alert_pending: bool,
    pub leaving_preview_for_link: bool,
    pub shake_menu_enabled: bool,
    pub shake_channel_selector_enabled: bool,
    pub shake_menu_gesture: String,
    pub launch_started_at_ms: i64,
    pub launch_start_reported: bool,
    pub launch_ready_reported: bool,
    pub launch_timeout_reported: bool,
    pub last_notified_stat_percent: i64,
    pub download_started_at: Option<Instant>,
    pub default_channel_cleanup_must_retry: bool,
    pub ready_generation: i64,
    pub ready_guard_armed: bool,
    /// Between `appBackground` and `appForeground`: rollback checks wait for the next foreground.
    pub in_background: bool,
}

/// `notifyAppReady` signal: waiters record the count they saw and wake when it grows.
#[derive(Default)]
struct ReadySignal {
    inner: Mutex<ReadyInner>,
    changed: Condvar,
}

#[derive(Default)]
struct ReadyInner {
    signals: u64,
    /// Token armed at load / reload; consumed by the next `appReady` emission.
    pending: Option<u64>,
}

/// Launch cleanup gate: downloads wait until obsolete bundles are removed.
#[derive(Default)]
struct CleanupGate {
    complete: Mutex<bool>,
    changed: Condvar,
}

#[derive(Default)]
pub struct Plugin {
    state: Mutex<PluginState>,
    ready: ReadySignal,
    cleanup: CleanupGate,
    /// Bumped on every `checkAppReady`; a deferred rollback check only runs if still current.
    app_ready_check: AtomicU64,
    splash_timer: AtomicU64,
    periodic_started: AtomicBool,
    /// Serializes starting the update cycle.
    cycle: Mutex<()>,
}

pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default()
}

pub(crate) fn iso_now() -> String {
    crate::bundle::iso8601_now()
}

/// Trims and drops JavaScript `undefined` / `null` spellings.
pub(crate) fn normalized_optional(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    if value.is_empty() || value.eq_ignore_ascii_case("undefined") || value.eq_ignore_ascii_case("null") {
        return None;
    }
    Some(value.to_string())
}

impl Engine {
    pub(crate) fn plugin_state(&self) -> MutexGuard<'_, PluginState> {
        self.plugin.state.lock().unwrap_or_else(|poison| poison.into_inner())
    }

    pub(crate) fn plugin_config(&self) -> PluginConfig {
        self.plugin_state().config.clone()
    }

    pub(crate) fn hook(&self, name: &str, payload: Value) -> Option<Value> {
        self.host.hook(name, &payload)
    }

    pub(crate) fn emit_bundle_event(&self, event: &str, bundle: &BundleInfo) {
        self.host.emit(event, &json!({ "bundle": bundle.to_js() }));
    }

    /// `set`: kept for listeners registered after the reload.
    pub(crate) fn emit_set_event(&self, bundle: &BundleInfo) {
        self.host.emit_retained("set", &json!({ "bundle": bundle.to_js() }));
    }

    /// `updateAvailable` of an `onlyDownload` (or auto update off) check: nothing installs
    /// the bundle, so the event is kept for listeners registered later.
    pub(crate) fn emit_only_download_update_available(&self, bundle: &BundleInfo) {
        self.host
            .emit_retained("updateAvailable", &json!({ "bundle": bundle.to_js() }));
    }

    pub(crate) fn kv_flag(&self, key: &str) -> Option<bool> {
        self.host.kv_get(key, None).map(|value| value == "true" || value == "1")
    }

    pub(crate) fn kv_text(&self, key: &str) -> Option<String> {
        self.host.kv_get(key, None)
    }

    pub(crate) fn kv_write(&self, key: &str, value: Option<&str>) {
        self.host.kv_set(key, value);
    }

    pub(crate) fn kv_write_flag(&self, key: &str, value: bool) {
        self.host.kv_set(key, Some(if value { "true" } else { "false" }));
    }

    /// Preview state blocks auto-update work, rollback and pending installs.
    pub(crate) fn is_preview_state_active(&self) -> bool {
        let (enabled, leaving) = {
            let state = self.plugin_state();
            (state.preview_session_enabled, state.leaving_preview_for_link)
        };
        enabled || leaving || self.config().preview_session
    }

    pub(crate) fn block_for_preview(&self) -> bool {
        if !self.is_preview_state_active() {
            return false;
        }
        self.host
            .info("Preview session is active. Skipping normal auto-update work.");
        true
    }

    pub(crate) fn set_engine_preview_session(&self, active: bool) {
        self.config_mut().preview_session = active;
    }

    /// `autoUpdate` on, an update URL, no live-reload server URL, no preview session.
    pub(crate) fn is_auto_update_enabled(&self) -> bool {
        if self.is_preview_state_active() {
            return false;
        }
        let config = self.plugin_config();
        if config.server_url_configured {
            self.host
                .warn("AutoUpdate is automatic disabled when serverUrl is set.");
        }
        config.auto_update_enabled() && !self.config().update_url.is_empty() && !config.server_url_configured
    }

    pub(crate) fn sync_shake_menu(&self) {
        let (enabled, selector, gesture) = {
            let state = self.plugin_state();
            (
                state.shake_menu_enabled,
                state.shake_channel_selector_enabled,
                state.shake_menu_gesture.clone(),
            )
        };
        self.hook(
            hooks::SHAKE_MENU,
            json!({ "enabled": enabled, "channelSelector": selector, "gesture": gesture }),
        );
    }

    pub(crate) fn preview_loader(&self, show: bool, reason: &str) {
        self.hook(
            hooks::PREVIEW_LOADER,
            json!({ "action": if show { "show" } else { "hide" }, "reason": reason }),
        );
    }

    fn mark_cleanup(&self, complete: bool) {
        *self.plugin.cleanup.complete.lock().unwrap() = complete;
        self.plugin.cleanup.changed.notify_all();
    }

    /// Download gate: blocks until the launch cleanup finished (bounded).
    pub(crate) fn wait_for_cleanup(&self) -> CoreResult<()> {
        let gate = &self.plugin.cleanup;
        let complete = gate.complete.lock().unwrap();
        if *complete || !self.plugin_state().loaded {
            return Ok(());
        }
        self.host
            .info("Waiting for cleanup to complete before starting download...");
        let (complete, timeout) = gate
            .changed
            .wait_timeout_while(complete, Duration::from_secs(120), |complete| !*complete)
            .unwrap();
        if timeout.timed_out() && !*complete {
            return Err(CoreError::new(
                "cleanup_timeout",
                "Cleanup did not finish before download",
            ));
        }
        self.host.info("Cleanup finished, proceeding with download");
        Ok(())
    }

    /// Initializes the plugin layer (Capacitor `load()`); see `load` in `flow.rs`.
    pub fn plugin_load(&self, input: &Value) -> CoreResult<Value> {
        self.load_plugin(input)
    }

    /// Runs one JavaScript plugin method: `{ name, args }`.
    pub fn plugin_method(&self, name: &str, args: &Value) -> Value {
        match self.run_plugin_method(name, args) {
            Ok(value) => json!({ "resolve": value }),
            Err(rejection) => json!({ "reject": rejection.to_json() }),
        }
    }

    /// Synchronous foreground handling (tests; hosts use the `appForeground` operation).
    #[cfg(any(test, feature = "test-support"))]
    pub fn plugin_foreground_for_tests(&self) {
        self.app_moved_to_foreground();
    }

    #[cfg(any(test, feature = "test-support"))]
    pub fn wait_for_cleanup_for_tests(&self) {
        let _ = self.wait_for_cleanup();
    }

    #[cfg(any(test, feature = "test-support"))]
    pub fn plugin_terminate_for_tests(&self) {
        self.app_terminated();
    }

    /// Runs lifecycle work off the caller's thread (hosts call from the UI thread).
    pub(crate) fn spawn_plugin_task(&self, task: impl FnOnce(&Engine) + Send + 'static) {
        let weak = self.weak_self();
        std::thread::spawn(move || {
            if let Some(engine) = weak.upgrade() {
                task(&engine);
            }
        });
    }

    pub(crate) fn sleep_unless_dropped(
        weak: &std::sync::Weak<Engine>,
        duration: Duration,
    ) -> Option<std::sync::Arc<Engine>> {
        std::thread::sleep(duration);
        weak.upgrade()
    }
}

/// A rejected plugin call.
#[derive(Debug, Clone)]
pub struct Rejection {
    pub message: String,
    pub code: Option<String>,
    pub data: Option<Value>,
}

impl Rejection {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            code: None,
            data: None,
        }
    }

    pub fn coded(message: impl Into<String>, code: &str, error: &str) -> Self {
        let message = message.into();
        Self {
            data: Some(json!({ "message": message, "error": error })),
            message,
            code: Some(code.to_string()),
        }
    }

    fn to_json(&self) -> Value {
        let mut object = Map::new();
        object.insert("message".into(), json!(self.message));
        if let Some(code) = &self.code {
            object.insert("code".into(), json!(code));
        }
        if let Some(data) = &self.data {
            object.insert("data".into(), data.clone());
        }
        Value::Object(object)
    }
}

impl From<CoreError> for Rejection {
    fn from(error: CoreError) -> Self {
        Rejection::new(error.message)
    }
}

pub(crate) type MethodResult = Result<Value, Rejection>;
