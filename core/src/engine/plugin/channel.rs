//! Default channel persistence (reinstall handling, backup-excluded state
//! files) and the channel / latest-version plugin methods.

use std::fs;
use std::path::PathBuf;

use serde_json::{json, Map, Value};

use super::{hooks, keys, MethodResult, Rejection};
use crate::engine::Engine;
use crate::host::HostLog;
use crate::policy;

/// What the preview snapshot file says about the channel to restore after a preview.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ChannelSnapshot {
    Missing,
    Invalidated,
    Snapshot(Option<String>),
    Unreadable,
}

/// Authoritative default channel state (excluded from backups, so a restored
/// backup cannot resurrect a channel the user cleared).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ChannelState {
    pub exists: bool,
    pub channel: Option<String>,
    pub readable: bool,
}

impl Engine {
    fn no_backup_file(&self, name: &str) -> Option<PathBuf> {
        let dir = self.plugin_config().no_backup_dir;
        (!dir.as_os_str().is_empty()).then(|| dir.join(name))
    }

    fn write_no_backup_file(&self, path: &std::path::Path, data: &[u8]) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        crate::engine::fsutil::write_atomically(path, data)?;
        self.hook(hooks::EXCLUDE_FROM_BACKUP, json!({ "path": path.to_string_lossy() }));
        Ok(())
    }

    pub(crate) fn default_channel_state(&self) -> ChannelState {
        let Some(path) = self.no_backup_file(keys::DEFAULT_CHANNEL_STATE_FILE) else {
            return ChannelState {
                exists: false,
                channel: None,
                readable: true,
            };
        };
        if !path.exists() {
            return ChannelState {
                exists: false,
                channel: None,
                readable: true,
            };
        }
        match fs::read(&path) {
            Ok(data) if data.is_empty() => ChannelState {
                exists: true,
                channel: None,
                readable: true,
            },
            Ok(data) => match String::from_utf8(data) {
                Ok(channel) => ChannelState {
                    exists: true,
                    channel: Some(channel),
                    readable: true,
                },
                Err(_) => {
                    self.host.warn("Cannot decode persisted default channel state");
                    ChannelState {
                        exists: true,
                        channel: None,
                        readable: false,
                    }
                }
            },
            Err(error) => {
                self.host
                    .warn(format!("Cannot read persisted default channel state: {error}"));
                ChannelState {
                    exists: true,
                    channel: None,
                    readable: false,
                }
            }
        }
    }

    fn write_default_channel_state(&self, channel: Option<&str>) -> std::io::Result<()> {
        match self.no_backup_file(keys::DEFAULT_CHANNEL_STATE_FILE) {
            Some(path) => self.write_no_backup_file(&path, channel.unwrap_or_default().as_bytes()),
            None => Ok(()),
        }
    }

    pub(crate) fn channel_snapshot(&self) -> ChannelSnapshot {
        let Some(path) = self.no_backup_file(keys::DEFAULT_CHANNEL_SNAPSHOT_FILE) else {
            return ChannelSnapshot::Missing;
        };
        if !path.exists() {
            return ChannelSnapshot::Missing;
        }
        match fs::read(&path) {
            Ok(data) => match (data.first(), data.len()) {
                (Some(0), 1) => ChannelSnapshot::Invalidated,
                (Some(1), 1) => ChannelSnapshot::Snapshot(None),
                (Some(2), _) => String::from_utf8(data[1..].to_vec())
                    .map(|channel| ChannelSnapshot::Snapshot(Some(channel)))
                    .unwrap_or(ChannelSnapshot::Unreadable),
                _ => ChannelSnapshot::Unreadable,
            },
            Err(_) => ChannelSnapshot::Unreadable,
        }
    }

    pub(crate) fn write_channel_snapshot(&self, snapshot: &ChannelSnapshot) -> std::io::Result<()> {
        let Some(path) = self.no_backup_file(keys::DEFAULT_CHANNEL_SNAPSHOT_FILE) else {
            return Ok(());
        };
        let data = match snapshot {
            ChannelSnapshot::Snapshot(Some(channel)) => {
                let mut data = vec![2u8];
                data.extend_from_slice(channel.as_bytes());
                data
            }
            ChannelSnapshot::Snapshot(None) => vec![1u8],
            _ => vec![0u8],
        };
        self.write_no_backup_file(&path, &data)
    }

    fn has_pending_channel_snapshot(&self) -> bool {
        matches!(
            self.channel_snapshot(),
            ChannelSnapshot::Snapshot(_) | ChannelSnapshot::Unreadable
        )
    }

    /// The channel that `setChannel` persisted (state file first, then the key/value store).
    pub(crate) fn persisted_default_channel(&self) -> Option<String> {
        let state = self.default_channel_state();
        if state.exists {
            if state.readable {
                return state.channel;
            }
            if !self.plugin_config().persist_default_channel_on_reinstall {
                return None;
            }
        }
        self.kv_text(keys::DEFAULT_CHANNEL)
    }

    /// Mirrors the key/value channel into the state file (falls back to the store when it cannot be written).
    pub(crate) fn persist_default_channel_state_from_store(&self) -> bool {
        let channel = self.kv_text(keys::DEFAULT_CHANNEL);
        match self.write_default_channel_state(channel.as_deref()) {
            Ok(()) => true,
            Err(error) => {
                if let Some(path) = self.no_backup_file(keys::DEFAULT_CHANNEL_STATE_FILE) {
                    if path.exists() && fs::remove_file(&path).is_err() {
                        self.host
                            .warn(format!("Cannot persist or invalidate default channel state: {error}"));
                        return false;
                    }
                }
                self.host.warn(format!(
                    "Cannot persist default channel state; falling back to stored preferences: {error}"
                ));
                true
            }
        }
    }

    fn clear_persisted_default_channel(&self) -> bool {
        if let Err(error) = self
            .write_default_channel_state(None)
            .and_then(|_| self.write_channel_snapshot(&ChannelSnapshot::Invalidated))
        {
            self.host
                .warn(format!("Cannot persist cleared default channel state: {error}"));
            return false;
        }
        self.kv_write(keys::DEFAULT_CHANNEL, None);
        self.kv_write(keys::PREVIEW_PREVIOUS_DEFAULT_CHANNEL, None);
        self.kv_write(keys::PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET, None);
        true
    }

    fn install_marker(&self) -> Option<PathBuf> {
        self.no_backup_file(keys::INSTALL_MARKER_FILE)
    }

    fn prepare_install_marker(&self) {
        let Some(marker) = self.install_marker() else {
            return;
        };
        let created = self.kv_flag(keys::INSTALL_MARKER_CREATED).unwrap_or(false);
        let result = if marker.exists() {
            self.hook(hooks::EXCLUDE_FROM_BACKUP, json!({ "path": marker.to_string_lossy() }));
            Ok(())
        } else {
            self.write_no_backup_file(&marker, b"")
        };
        match result {
            Ok(()) if !created => self.kv_write_flag(keys::INSTALL_MARKER_CREATED, true),
            Ok(()) => {}
            Err(error) => {
                let _ = fs::remove_file(&marker);
                self.kv_write_flag(keys::INSTALL_MARKER_CREATED, false);
                self.host
                    .warn(format!("Cannot prepare default channel install marker: {error}"));
            }
        }
    }

    /// Reinstall handling and default channel resolution at load.
    pub(crate) fn prepare_default_channel(&self, native_build_changed: bool) {
        let config = self.plugin_config();
        let disabled = !config.persist_default_channel_on_reinstall;
        let restored_reinstall = disabled
            && self.kv_flag(keys::INSTALL_MARKER_CREATED).unwrap_or(false)
            && self.install_marker().is_some_and(|marker| !marker.exists());
        let mut marker_can_be_prepared = true;
        if policy::should_clear_persisted_default_channel(
            config.persist_default_channel_on_reinstall,
            config.reset_when_update,
            native_build_changed,
            restored_reinstall,
        ) {
            if self.clear_persisted_default_channel() {
                self.host
                    .info("Cleared persisted defaultChannel because reinstall persistence is disabled");
            } else {
                self.host.warn("Cannot durably clear persisted defaultChannel");
                self.plugin_state().default_channel_cleanup_must_retry = true;
                marker_can_be_prepared = false;
                if let Some(marker) = self.install_marker().filter(|marker| marker.exists()) {
                    if let Err(error) = fs::remove_file(marker) {
                        self.host.warn(format!(
                            "Cannot invalidate default channel install marker for cleanup retry: {error}"
                        ));
                    }
                }
            }
        }
        if disabled && marker_can_be_prepared {
            self.prepare_install_marker();
        }
        let retry = self.plugin_state().default_channel_cleanup_must_retry;
        let in_preview = config.allow_preview && self.kv_flag(keys::PREVIEW_SESSION).unwrap_or(false);
        if !in_preview && !retry && self.has_pending_channel_snapshot() {
            self.restore_preview_previous_default_channel();
        }

        let state = self.default_channel_state();
        let channel = if retry {
            self.host
                .info("Using configured defaultChannel until persisted cleanup can retry");
            config.default_channel.clone()
        } else if state.exists && state.readable {
            match &state.channel {
                Some(channel) => self.kv_write(keys::DEFAULT_CHANNEL, Some(channel)),
                None => self.kv_write(keys::DEFAULT_CHANNEL, None),
            }
            state
                .channel
                .clone()
                .filter(|channel| !channel.is_empty())
                .unwrap_or_else(|| config.default_channel.clone())
        } else if disabled && state.exists {
            self.host
                .warn("Ignoring unreadable persisted defaultChannel while reinstall persistence is disabled");
            config.default_channel.clone()
        } else {
            match self
                .kv_text(keys::DEFAULT_CHANNEL)
                .filter(|channel| !channel.is_empty())
            {
                Some(channel) => {
                    self.host.info("Loaded persisted defaultChannel from setChannel()");
                    channel
                }
                None => config.default_channel.clone(),
            }
        };
        if !retry && (!state.exists || (!disabled && !state.readable)) {
            self.persist_default_channel_state_from_store();
        }
        self.config_mut().default_channel = channel;
    }

    /// Restores the channel saved when the preview session started.
    pub(crate) fn restore_preview_previous_default_channel(&self) {
        if self.plugin_state().default_channel_cleanup_must_retry {
            return;
        }
        let config_channel = self.plugin_config().default_channel;
        let snapshot = self.channel_snapshot();
        let previous = match snapshot {
            ChannelSnapshot::Snapshot(channel) => Some(channel),
            ChannelSnapshot::Invalidated => Some(None),
            ChannelSnapshot::Unreadable => {
                self.host
                    .warn("Default channel preview restore will retry on next launch");
                return;
            }
            // Without a snapshot file, the key/value copy decides.
            ChannelSnapshot::Missing => {
                if self
                    .kv_flag(keys::PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET)
                    .unwrap_or(false)
                {
                    Some(Some(
                        self.kv_text(keys::PREVIEW_PREVIOUS_DEFAULT_CHANNEL).unwrap_or_default(),
                    ))
                } else if self.kv_text(keys::PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET).is_some() {
                    Some(None)
                } else {
                    None
                }
            }
        };
        let Some(previous) = previous else {
            return;
        };
        match &previous {
            Some(channel) => self.kv_write(keys::DEFAULT_CHANNEL, Some(channel)),
            None => self.kv_write(keys::DEFAULT_CHANNEL, None),
        }
        if !self.persist_default_channel_state_from_store() {
            self.host
                .warn("Default channel preview restore will retry on next launch");
            return;
        }
        let _ = self.write_channel_snapshot(&ChannelSnapshot::Invalidated);
        self.kv_write(keys::PREVIEW_PREVIOUS_DEFAULT_CHANNEL, None);
        self.kv_write(keys::PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET, None);
        self.config_mut().default_channel = previous.filter(|channel| !channel.is_empty()).unwrap_or(config_channel);
        self.host.info("Restored defaultChannel after preview");
    }

    /// Saves the channel to restore when the preview ends.
    pub(crate) fn snapshot_default_channel_for_preview(&self) -> bool {
        let channel = self.persisted_default_channel();
        if let Err(error) = self.write_channel_snapshot(&ChannelSnapshot::Snapshot(channel.clone())) {
            self.host.error(format!(
                "Could not durably save the default channel preview snapshot: {error}"
            ));
            return false;
        }
        match channel {
            Some(channel) => {
                self.kv_write(keys::PREVIEW_PREVIOUS_DEFAULT_CHANNEL, Some(&channel));
                self.kv_write_flag(keys::PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET, true);
            }
            None => {
                self.kv_write(keys::PREVIEW_PREVIOUS_DEFAULT_CHANNEL, None);
                self.kv_write_flag(keys::PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET, false);
            }
        }
        true
    }

    // ---- channel methods ---------------------------------------------------------------------

    fn channel_error(&self, result: &Map<String, Value>, code: &str) -> Rejection {
        let error = result
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("request_failed")
            .to_string();
        let message = result
            .get("message")
            .and_then(Value::as_str)
            .filter(|message| !message.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| error.clone());
        Rejection::coded(message, code, &error)
    }

    fn trigger_after_channel_change(&self, trigger: bool) {
        if trigger && self.is_auto_update_enabled() {
            self.host.info("Calling autoupdater after channel change!");
            self.background_download();
        }
    }

    pub(crate) fn method_set_channel(&self, args: &Value) -> MethodResult {
        let Some(channel) = args.get("channel").and_then(Value::as_str) else {
            self.host.error("setChannel called without channel");
            return Err(Rejection::coded(
                "setChannel called without channel",
                "SETCHANNEL_INVALID_PARAMS",
                "missing_parameter",
            ));
        };
        let config = self.plugin_config();
        let result = self.set_channel(
            channel,
            Some(keys::DEFAULT_CHANNEL),
            config.allow_set_default_channel,
            &config.default_channel,
        );
        if result.contains_key("error") {
            let rejection = self.channel_error(&result, "SETCHANNEL_FAILED");
            let error = result.get("error").and_then(Value::as_str).unwrap_or_default();
            if error.contains("cannot_update_via_private_channel") || error.contains("channel_self_set_not_allowed") {
                self.host.emit(
                    "channelPrivate",
                    &json!({ "channel": channel, "message": rejection.message }),
                );
            }
            return Err(rejection);
        }
        if !self.persist_default_channel_state_from_store() {
            return Err(Rejection::coded(
                "Channel changed but local persistence failed",
                "SETCHANNEL_PERSISTENCE_FAILED",
                "persistence_failed",
            ));
        }
        self.trigger_after_channel_change(args.get("triggerAutoUpdate").and_then(Value::as_bool).unwrap_or(false));
        Ok(Value::Object(result))
    }

    pub(crate) fn method_unset_channel(&self, args: &Value) -> MethodResult {
        let config = self.plugin_config();
        let result = self.unset_channel(
            Some(keys::DEFAULT_CHANNEL),
            &config.default_channel,
            config.allow_set_default_channel,
        );
        if result.contains_key("error") {
            return Err(self.channel_error(&result, "UNSETCHANNEL_FAILED"));
        }
        if !self.persist_default_channel_state_from_store() {
            return Err(Rejection::coded(
                "Channel override removed but local persistence failed",
                "UNSETCHANNEL_PERSISTENCE_FAILED",
                "persistence_failed",
            ));
        }
        self.trigger_after_channel_change(args.get("triggerAutoUpdate").and_then(Value::as_bool).unwrap_or(false));
        Ok(Value::Object(result))
    }

    pub(crate) fn method_get_channel(&self) -> MethodResult {
        let result = self.get_channel(Some(keys::DEFAULT_CHANNEL));
        if result.contains_key("error") {
            return Err(self.channel_error(&result, "GETCHANNEL_FAILED"));
        }
        if !self.persist_default_channel_state_from_store() {
            return Err(Rejection::coded(
                "Channel synchronized but local persistence failed",
                "GETCHANNEL_PERSISTENCE_FAILED",
                "persistence_failed",
            ));
        }
        Ok(Value::Object(result))
    }

    pub(crate) fn method_list_channels(&self) -> MethodResult {
        let result = self.list_channels();
        if result.contains_key("error") {
            return Err(self.channel_error(&result, "LISTCHANNELS_FAILED"));
        }
        Ok(Value::Object(result))
    }

    // ---- getLatest ---------------------------------------------------------------------------

    pub(crate) fn method_get_latest(&self, args: &Value) -> MethodResult {
        let channel = args.get("channel").and_then(Value::as_str);
        let include_size = args.get("includeBundleSize").and_then(Value::as_bool).unwrap_or(false);
        let app_id = super::normalized_optional(args.get("appId").and_then(Value::as_str));
        if app_id.is_some() && !self.plugin_config().allow_preview {
            return Err(Rejection::new(
                "getLatest preview override not allowed. Set allowPreview to true in your config to enable it.",
            ));
        }
        let mut result = self.get_latest(None, channel, app_id.as_deref());
        let version = result
            .get("version")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        if result.contains_key("error") || result.contains_key("kind") {
            let kind = policy::normalized_update_response_kind(result.get("kind").and_then(Value::as_str));
            result.insert("kind".into(), json!(kind));
            self.notify_breaking_events_if_needed(&result, &version);
            let error = result
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let message = result
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("server did not provide a message")
                .to_string();
            if kind == "failed" {
                self.host
                    .error(format!("getLatest failed with error: {error}, message: {message}"));
                return Err(Rejection::new(if error.is_empty() { message } else { error }));
            }
            if version.is_empty() {
                result.insert("version".into(), json!(self.current_bundle().version_name()));
            }
            if include_size {
                self.attach_bundle_size(&mut result);
            }
            self.host.info(format!("getLatest returned {kind}: {message}"));
            return Ok(Value::Object(result));
        }
        if let Some(message) = result.get("message").and_then(Value::as_str).map(str::to_string) {
            self.notify_breaking_events_if_needed(&result, &version);
            return Err(Rejection::new(message));
        }
        if include_size {
            self.attach_bundle_size(&mut result);
        }
        Ok(Value::Object(result))
    }

    fn attach_bundle_size(&self, latest: &mut Map<String, Value>) {
        let Some(manifest) = latest
            .get("manifest")
            .and_then(Value::as_array)
            .filter(|manifest| !manifest.is_empty())
        else {
            return;
        };
        let session_key = latest.get("sessionKey").and_then(Value::as_str).unwrap_or_default();
        let missing = self.missing_bundle_files(manifest, session_key);
        let missing_manifest = missing
            .get("missing")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let version = latest.get("version").and_then(Value::as_str).map(str::to_string);
        let update_url = self.config().update_url.clone();
        let size = self.bundle_download_size(&update_url, version.as_deref(), &missing_manifest);
        latest.insert("missing".into(), missing);
        latest.insert("downloadSize".into(), Value::Object(size));
    }

    // ---- shake menu ----------------------------------------------------------------------------

    /// Shake-menu channel switch: `setChannel`, `getLatest`, `download`, then `next`.
    /// Reports progress through the `shakeMenuProgress` hook and answers what the menu
    /// shows: `{ status: "error" | "success" | "updateReady", message, bundleId?, version? }`.
    /// The host applies the bundle (`set`) only when the user chooses to reload.
    pub(crate) fn shake_menu_switch_channel(&self, channel: &str) -> Value {
        let error = |message: String| json!({ "status": "error", "message": message });
        let success = |message: String| json!({ "status": "success", "message": message });
        let progress = |message: String| {
            self.hook(hooks::SHAKE_MENU_PROGRESS, json!({ "message": message }));
        };

        if let Err(rejection) =
            self.run_plugin_method("setChannel", &json!({ "channel": channel, "triggerAutoUpdate": false }))
        {
            return error(format!("Failed to set channel: {}", rejection.message));
        }
        progress("Checking for updates...".to_string());

        let latest = match self.run_plugin_method("getLatest", &json!({ "channel": channel })) {
            Err(rejection) => {
                return error(format!(
                    "Channel set to {channel}. Update check failed: {}",
                    rejection.message
                ))
            }
            Ok(Value::Object(latest)) => latest,
            Ok(_) => return success(format!("Channel set to {channel}. Could not check for updates.")),
        };
        let field = |key: &str| latest.get(key).and_then(Value::as_str).unwrap_or_default();
        let (latest_error, kind) = (field("error"), field("kind"));
        let detail = [field("message"), latest_error, kind]
            .into_iter()
            .find(|value| !value.is_empty())
            .unwrap_or("server did not provide a message");
        if !latest_error.is_empty() && kind != "up_to_date" && kind != "blocked" {
            return error(format!("Channel set to {channel}. Update check failed: {detail}"));
        }
        if kind == "blocked" {
            return error(format!("Channel set to {channel}. Update check blocked: {detail}"));
        }

        let url = field("url");
        let manifest = latest
            .get("manifest")
            .and_then(Value::as_array)
            .filter(|manifest| !manifest.is_empty());
        // A manifest-only response legitimately has no URL (the files come from the manifest).
        if kind == "up_to_date" || (url.is_empty() && manifest.is_none()) {
            return success(format!("Channel set to {channel}. Already on latest version."));
        }
        let version = field("version");
        if version.is_empty() {
            return error(format!(
                "Channel set to {channel}. Update check failed: missing version."
            ));
        }
        progress(format!("Downloading update {version}..."));

        let mut request = json!({
            // Manifest-only responses have no zip URL; the download tolerates this placeholder.
            "url": if url.is_empty() { "https://404.capgo.app/no.zip" } else { url },
            "version": version,
            "sessionKey": field("sessionKey"),
            "checksum": field("checksum"),
        });
        if let Some(manifest) = manifest {
            request["manifest"] = Value::Array(manifest.clone());
        }
        let bundle_id = match self.run_plugin_method("download", &request) {
            Err(rejection) => return error(format!("Failed to download update: {}", rejection.message)),
            Ok(bundle) => bundle.get("id").and_then(Value::as_str).unwrap_or_default().to_string(),
        };
        if bundle_id.is_empty() {
            return error("Failed to download update: missing bundle".to_string());
        }
        if let Err(rejection) = self.run_plugin_method("next", &json!({ "id": bundle_id })) {
            self.host
                .warn(format!("Could not queue downloaded bundle: {}", rejection.message));
        }
        json!({
            "status": "updateReady",
            "message": format!("Update downloaded! Reload to apply version {version}?"),
            "bundleId": bundle_id,
            "version": version,
        })
    }
}
