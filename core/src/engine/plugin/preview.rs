//! Preview sessions: try other bundles (channels, pull requests) on a device
//! and come back to the live bundle.

use std::time::Duration;

use serde_json::{json, Map, Value};

use super::{hooks, keys, normalized_optional, MethodResult, Rejection};
use crate::bundle::{BundleInfo, ID_BUILTIN};
use crate::engine::Engine;
use crate::error::CoreError;
use crate::host::HostLog;

const PREVIEW_NOTICE_DELAY: Duration = Duration::from_millis(600);
/// Download URL used when a preview payload only carries a manifest.
const NO_ZIP_URL: &str = "https://404.capgo.app/no.zip";

/// `true` for `/preview/channel` and `/preview/bundle` links (`capgo://preview/bundle` too).
pub fn is_preview_deep_link(url: &str) -> bool {
    let Ok(parsed) = url::Url::parse(url) else {
        return false;
    };
    let path = if parsed.scheme() == "capgo" {
        let joined = format!("/{}{}", parsed.host_str().unwrap_or_default(), parsed.path());
        let mut collapsed = String::new();
        for character in joined.chars() {
            if character == '/' && collapsed.ends_with('/') {
                continue;
            }
            collapsed.push(character);
        }
        collapsed
    } else {
        parsed.path().to_string()
    };
    path == "/preview/channel" || path == "/preview/bundle"
}

fn normalized_payload_url(raw: Option<&str>) -> Option<String> {
    let value = normalized_optional(raw)?;
    let url = url::Url::parse(&value).ok()?;
    matches!(url.scheme(), "http" | "https").then(|| url.to_string())
}

impl Engine {
    // ---- registry ----------------------------------------------------------------------------

    fn previews(&self) -> Map<String, Value> {
        let Some(raw) = self
            .kv_text(keys::PREVIEW_SESSIONS)
            .filter(|raw| !raw.trim().is_empty())
        else {
            return Map::new();
        };
        match serde_json::from_str::<Value>(&raw) {
            Ok(Value::Object(map)) => map,
            _ => {
                self.host.warn("Could not parse preview sessions, clearing them");
                self.kv_write(keys::PREVIEW_SESSIONS, None);
                Map::new()
            }
        }
    }

    fn save_previews(&self, previews: &Map<String, Value>) {
        self.kv_write(
            keys::PREVIEW_SESSIONS,
            Some(&Value::Object(previews.clone()).to_string()),
        );
    }

    fn preview_info(
        &self,
        id: &str,
        metadata: &Map<String, Value>,
        available: &[String],
        current_id: &str,
    ) -> Option<Value> {
        let bundle = self.get_bundle_info(Some(id));
        if !bundle.is_builtin() && !available.iter().any(|known| known == id) {
            return None;
        }
        if bundle.is_deleted() || bundle.is_error() {
            return None;
        }
        let now = super::iso_now();
        let field = |key: &str| normalized_optional(metadata.get(key).and_then(Value::as_str));
        let mut info = Map::new();
        info.insert("id".into(), json!(id));
        info.insert("bundle".into(), bundle.to_js());
        info.insert(
            "createdAt".into(),
            json!(field("createdAt").unwrap_or_else(|| now.clone())),
        );
        info.insert(
            "updatedAt".into(),
            json!(field("updatedAt").unwrap_or_else(|| now.clone())),
        );
        info.insert("lastUsedAt".into(), json!(field("lastUsedAt").unwrap_or(now)));
        info.insert(
            "isActive".into(),
            json!(self.plugin_state().preview_session_enabled && id == current_id),
        );
        for key in ["name", "source", "appId", "payloadUrl"] {
            if let Some(value) = field(key) {
                info.insert(key.into(), json!(value));
            }
        }
        Some(Value::Object(info))
    }

    fn available_bundle_ids(&self) -> Vec<String> {
        self.list(false).iter().map(|bundle| bundle.id().to_string()).collect()
    }

    /// Previews sorted by last use; stale entries are dropped when `cleanup`.
    pub(crate) fn list_preview_infos(&self, cleanup: bool) -> Vec<Value> {
        let mut previews = self.previews();
        let available = self.available_bundle_ids();
        let current_id = self.current_bundle().id().to_string();
        let mut infos = Vec::new();
        let mut stale = Vec::new();
        for (id, metadata) in &previews {
            let info = metadata
                .as_object()
                .and_then(|metadata| self.preview_info(id, metadata, &available, &current_id));
            match info {
                Some(info) => infos.push(info),
                None => stale.push(id.clone()),
            }
        }
        infos.sort_by(|first, second| {
            let key = |value: &Value| {
                value
                    .get("lastUsedAt")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string()
            };
            key(second).cmp(&key(first))
        });
        if cleanup && !stale.is_empty() {
            for id in stale {
                previews.remove(&id);
            }
            self.save_previews(&previews);
        }
        infos
    }

    fn stored_preview_info(&self, id: &str) -> Option<Value> {
        let previews = self.previews();
        let metadata = previews.get(id)?.as_object()?.clone();
        let current_id = self.current_bundle().id().to_string();
        self.preview_info(id, &metadata, &self.available_bundle_ids(), &current_id)
    }

    /// Records (or refreshes) `bundle` in the registry; `old_id` is the preview it replaces.
    pub(crate) fn record_preview_bundle(&self, bundle: &BundleInfo, old_id: Option<&str>) -> Value {
        let now = super::iso_now();
        let id = bundle.id().to_string();
        let replacing = old_id.filter(|old| *old != id);
        let mut previews = self.previews();
        let mut metadata = previews
            .get(&id)
            .and_then(Value::as_object)
            .cloned()
            .or_else(|| {
                replacing
                    .and_then(|old| previews.get(old))
                    .and_then(Value::as_object)
                    .cloned()
            })
            .unwrap_or_default();
        metadata.entry("createdAt").or_insert_with(|| json!(now));
        metadata.insert("updatedAt".into(), json!(now));
        let current_id = self.current_bundle().id().to_string();
        if metadata.get("lastUsedAt").map_or(true, Value::is_null) || current_id == id {
            metadata.insert("lastUsedAt".into(), json!(now));
        }
        metadata.insert("version".into(), json!(bundle.version_name()));
        if replacing.is_none() {
            for (field, key) in [
                ("appId", keys::PREVIEW_APP_ID),
                ("payloadUrl", keys::PREVIEW_PAYLOAD_URL),
                ("name", keys::PREVIEW_NAME),
                ("source", keys::PREVIEW_SOURCE),
            ] {
                match normalized_optional(self.kv_text(key).as_deref()) {
                    Some(value) => {
                        metadata.insert(field.into(), json!(value));
                    }
                    None => {
                        metadata.remove(field);
                    }
                }
            }
        }
        if normalized_optional(metadata.get("name").and_then(Value::as_str)).is_none() {
            metadata.insert("name".into(), json!(bundle.version_name()));
        }
        if let Some(old) = replacing {
            previews.remove(old);
        }
        previews.insert(id.clone(), Value::Object(metadata.clone()));
        self.save_previews(&previews);
        self.preview_info(&id, &metadata, &self.available_bundle_ids(), &current_id)
            .unwrap_or_else(|| {
                json!({
                    "id": id,
                    "bundle": bundle.to_js(),
                    "createdAt": now,
                    "updatedAt": now,
                    "lastUsedAt": now,
                    "isActive": self.plugin_state().preview_session_enabled && current_id == id,
                })
            })
    }

    fn update_current_preview_metadata_from(&self, preview: &Value) {
        let field = |key: &str| normalized_optional(preview.get(key).and_then(Value::as_str));
        match field("appId") {
            Some(app_id) => {
                self.set_active_app_id(&app_id);
                self.kv_write(keys::PREVIEW_APP_ID, Some(&app_id));
            }
            None => {
                self.restore_preview_previous_app_id();
                self.kv_write(keys::PREVIEW_APP_ID, None);
            }
        }
        for (field_name, key) in [
            ("payloadUrl", keys::PREVIEW_PAYLOAD_URL),
            ("name", keys::PREVIEW_NAME),
            ("source", keys::PREVIEW_SOURCE),
        ] {
            self.kv_write(key, field(field_name).as_deref());
        }
    }

    pub(crate) fn set_active_app_id(&self, app_id: &str) {
        let _ = self.configure(&json!({ "appId": app_id }));
    }

    fn restore_preview_previous_app_id(&self) {
        if let Some(previous) = self.kv_text(keys::PREVIEW_PREVIOUS_APP_ID).filter(|id| !id.is_empty()) {
            self.set_active_app_id(&previous);
            self.host.info(format!("Restored appId after preview: {previous}"));
        }
    }

    // ---- state transitions -------------------------------------------------------------------

    fn prepare_preview_fallback_if_needed(&self) -> bool {
        if self.plugin_state().preview_session_enabled {
            return true;
        }
        let current = self.current_bundle();
        if !self.set_preview_fallback_bundle(Some(current.id())) {
            self.host.error("Could not save current bundle as preview fallback");
            return false;
        }
        match self.next_bundle().filter(|next| !next.is_deleted() && !next.is_error()) {
            Some(next) => self.kv_write(keys::PREVIEW_PREVIOUS_NEXT_BUNDLE, Some(next.id())),
            None => self.kv_write(keys::PREVIEW_PREVIOUS_NEXT_BUNDLE, None),
        }
        let app_id = self.config().app_id.clone();
        self.kv_write(keys::PREVIEW_PREVIOUS_APP_ID, Some(&app_id));
        if !self.snapshot_default_channel_for_preview() {
            // No session starts: nothing may stay behind (a stale liveBundle, a protected fallback).
            self.set_preview_fallback_bundle(None);
            self.kv_write(keys::PREVIEW_PREVIOUS_NEXT_BUNDLE, None);
            self.kv_write(keys::PREVIEW_PREVIOUS_APP_ID, None);
            return false;
        }
        let (menu, selector) = {
            let state = self.plugin_state();
            (state.shake_menu_enabled, state.shake_channel_selector_enabled)
        };
        self.kv_write_flag(keys::PREVIEW_PREVIOUS_SHAKE_MENU, menu);
        self.kv_write_flag(keys::PREVIEW_PREVIOUS_SHAKE_CHANNEL_SELECTOR, selector);
        self.host.info(format!(
            "Preview session started with fallback bundle: {}",
            current.id()
        ));
        true
    }

    fn activate_preview_session_state(&self) {
        self.clear_incoming_preview_transition();
        self.preview_loader(false, "preview-session-started");
        {
            let mut state = self.plugin_state();
            state.preview_session_enabled = true;
            state.preview_alert_pending = true;
            state.shake_menu_enabled = true;
        }
        self.set_engine_preview_session(true);
        self.kv_write_flag(keys::PREVIEW_SESSION, true);
        self.kv_write_flag(keys::PREVIEW_ALERT_PENDING, true);
        self.sync_shake_menu();
    }

    /// Clears the "leaving preview" guard (called when the new page is ready).
    pub(crate) fn clear_incoming_preview_transition(&self) {
        let enabled = {
            let mut state = self.plugin_state();
            state.leaving_preview_for_link = false;
            state.preview_session_enabled
        };
        if !enabled {
            self.set_engine_preview_session(false);
        }
    }

    fn restore_preview_previous_next_bundle(&self) {
        match self
            .kv_text(keys::PREVIEW_PREVIOUS_NEXT_BUNDLE)
            .filter(|id| !id.is_empty())
        {
            None => {
                self.set_next_bundle(None);
            }
            Some(id) => {
                if !self.set_next_bundle(Some(&id)) {
                    self.host
                        .warn(format!("Could not restore pre-preview next bundle: {id}"));
                    self.set_next_bundle(None);
                }
            }
        }
    }

    fn clear_preview_session_preferences(&self) {
        self.set_preview_fallback_bundle(None);
        let snapshot_pending = matches!(
            self.channel_snapshot(),
            super::channel::ChannelSnapshot::Snapshot(_) | super::channel::ChannelSnapshot::Unreadable
        );
        for key in [
            keys::PREVIEW_SESSION,
            keys::PREVIEW_PREVIOUS_SHAKE_MENU,
            keys::PREVIEW_PREVIOUS_SHAKE_CHANNEL_SELECTOR,
            keys::PREVIEW_PREVIOUS_NEXT_BUNDLE,
            keys::PREVIEW_PREVIOUS_APP_ID,
            keys::PREVIEW_APP_ID,
            keys::PREVIEW_PAYLOAD_URL,
            keys::PREVIEW_NAME,
            keys::PREVIEW_SOURCE,
            keys::PREVIEW_ALERT_PENDING,
        ] {
            self.kv_write(key, None);
        }
        if !snapshot_pending {
            self.kv_write(keys::PREVIEW_PREVIOUS_DEFAULT_CHANNEL, None);
            self.kv_write(keys::PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET, None);
        }
    }

    fn end_preview_session(&self, keep_preview_guard: bool) {
        let config = self.plugin_config();
        let previous_menu = self
            .kv_flag(keys::PREVIEW_PREVIOUS_SHAKE_MENU)
            .unwrap_or(config.shake_menu);
        let previous_selector = self
            .kv_flag(keys::PREVIEW_PREVIOUS_SHAKE_CHANNEL_SELECTOR)
            .unwrap_or(config.allow_shake_channel_selector);
        self.restore_preview_previous_next_bundle();
        self.restore_preview_previous_app_id();
        self.restore_preview_previous_default_channel();
        {
            let mut state = self.plugin_state();
            state.preview_session_enabled = false;
            state.preview_alert_pending = false;
            state.shake_menu_enabled = previous_menu;
            state.shake_channel_selector_enabled = previous_selector;
        }
        if keep_preview_guard {
            // The fallback's first launch must not be rolled back or auto-updated.
            self.set_engine_preview_session(true);
        } else {
            self.clear_incoming_preview_transition();
        }
        self.sync_shake_menu();
        self.clear_preview_session_preferences();
        self.host.info("Preview session ended");
    }

    fn resolve_preview_fallback(&self, reason: &str) -> Option<BundleInfo> {
        let fallback = self.preview_fallback_bundle();
        if let Some(fallback) = fallback
            .as_ref()
            .filter(|fallback| !fallback.is_error() && self.can_set(fallback))
        {
            return Some(fallback.clone());
        }
        match &fallback {
            None => self.host.warn(format!(
                "No preview fallback bundle available for {reason}. Falling back to builtin bundle."
            )),
            Some(fallback) if fallback.is_error() => self.host.warn(format!(
                "Preview fallback bundle is in error state for {reason}. Falling back to builtin bundle."
            )),
            Some(_) => self.host.warn(format!(
                "Preview fallback bundle is not installable for {reason}. Falling back to builtin bundle."
            )),
        }
        let builtin = self.get_bundle_info(Some(ID_BUILTIN));
        if !builtin.is_error() && self.can_set(&builtin) {
            return Some(builtin);
        }
        self.host
            .error(format!("Builtin bundle is not available to leave preview for {reason}"));
        None
    }

    fn reset_to_preview_fallback(&self) -> bool {
        let Some(fallback) = self.resolve_preview_fallback("leave preview") else {
            return false;
        };
        let previous_state = self.capture_reset_state();
        let previous_name = self.current_bundle().version_name().to_string();
        self.host.info(format!(
            "Resetting to preview fallback bundle: {}",
            fallback.version_name()
        ));
        if self.stage_preview_fallback_reload(&fallback) && self.reload_without_waiting() {
            self.finalize_reset_transition(&previous_name, false);
            self.emit_set_event(&fallback);
            return true;
        }
        self.restore_reset_state(&previous_state);
        self.restore_live_bundle();
        false
    }

    /// `resetPreview()` and the shake menu "leave preview" action.
    pub(crate) fn leave_preview_session(&self) -> bool {
        self.preview_loader(true, "leave-preview-session");
        if !self.reset_to_preview_fallback() {
            self.preview_loader(false, "leave-preview-session-failed");
            return false;
        }
        self.end_preview_session(true);
        true
    }

    fn leave_preview_without_reload(&self, keep_guard: bool) -> bool {
        let Some(fallback) = self.resolve_preview_fallback("preview deeplink launch") else {
            return false;
        };
        if !self.stage_preview_fallback_reload(&fallback) {
            self.host.error("Could not stage preview fallback bundle");
            return false;
        }
        self.end_preview_session(keep_guard);
        true
    }

    /// A preview deep link opened the app: restore the live bundle before the first load.
    pub(crate) fn leave_preview_for_launch_url(&self, url: &str) {
        let (enabled, leaving) = {
            let state = self.plugin_state();
            (state.preview_session_enabled, state.leaving_preview_for_link)
        };
        if !enabled || leaving || !is_preview_deep_link(url) {
            return;
        }
        self.plugin_state().leaving_preview_for_link = true;
        self.preview_loader(true, "preview-launch-deeplink");
        self.host.info(
            "Preview deeplink launch detected while preview session is active; restoring fallback before initial load",
        );
        if !self.leave_preview_without_reload(false) {
            self.host
                .error("Could not leave preview session before initial preview deeplink routing");
            self.plugin_state().leaving_preview_for_link = false;
            self.preview_loader(false, "preview-launch-deeplink-failed");
        }
    }

    /// A preview deep link arrived while the app runs. Returns whether the link
    /// starts leaving the preview (the host then routes it after the reload).
    pub(crate) fn handle_open_url(&self, url: &str) -> bool {
        let (enabled, leaving) = {
            let state = self.plugin_state();
            (state.preview_session_enabled, state.leaving_preview_for_link)
        };
        if !enabled || leaving || !is_preview_deep_link(url) {
            return false;
        }
        self.plugin_state().leaving_preview_for_link = true;
        self.preview_loader(true, "incoming-preview-deeplink");
        let weak = self.weak_self();
        std::thread::spawn(move || {
            if let Some(engine) = weak.upgrade() {
                if !engine.leave_preview_for_incoming_link() {
                    engine
                        .host
                        .error("Could not leave preview session before routing incoming preview deeplink");
                }
            }
        });
        true
    }

    fn leave_preview_for_incoming_link(&self) -> bool {
        let Some(fallback) = self.resolve_preview_fallback("incoming preview deeplink") else {
            self.clear_incoming_preview_transition();
            self.preview_loader(false, "incoming-preview-deeplink-failed");
            return false;
        };
        let previous_state = self.capture_reset_state();
        if !self.stage_preview_fallback_reload(&fallback) {
            self.host.error("Could not stage preview fallback bundle");
            self.clear_incoming_preview_transition();
            self.preview_loader(false, "incoming-preview-deeplink-failed");
            return false;
        }
        if !self.reload_without_waiting() {
            self.restore_reset_state(&previous_state);
            self.restore_live_bundle();
            self.clear_incoming_preview_transition();
            self.preview_loader(false, "incoming-preview-deeplink-reload-failed");
            return false;
        }
        self.end_preview_session(true);
        // Keep the guard until the fallback had a chance to confirm itself.
        let delay = Duration::from_millis(self.plugin_config().app_ready_timeout_ms);
        let weak = self.weak_self();
        std::thread::spawn(move || {
            if let Some(engine) = Engine::sleep_unless_dropped(&weak, delay) {
                engine.clear_incoming_preview_transition();
            }
        });
        true
    }

    /// Shake menu "reload": refresh from the preview payload URL when there is one.
    pub(crate) fn reload_preview_session(&self) -> bool {
        self.preview_loader(true, "reload-preview-session");
        let payload_url = normalized_payload_url(self.kv_text(keys::PREVIEW_PAYLOAD_URL).as_deref());
        let reloaded = match payload_url {
            Some(url) => match self.refresh_preview_from_payload(&url) {
                Ok(reloaded) => reloaded,
                Err(error) => {
                    self.host
                        .error(format!("Could not refresh preview session: {}", error.message));
                    false
                }
            },
            None => self.reload_without_waiting(),
        };
        if !reloaded {
            self.preview_loader(false, "reload-preview-session-failed");
        }
        reloaded
    }

    fn refresh_preview_from_payload(&self, url: &str) -> Result<bool, CoreError> {
        let payload = self.fetch_json(url)?;
        let version = payload
            .get("version")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string();
        if version.is_empty() {
            return Err(CoreError::new(
                "invalid_payload",
                "Preview payload is missing a version",
            ));
        }
        let current = self.current_bundle();
        if version == current.version_name() {
            self.host.info("Preview payload unchanged, reloading current bundle");
            return Ok(self.reload_without_waiting());
        }
        let next = self.download_preview_payload(&payload)?;
        if !self.set_bundle(next.id()) {
            return Err(CoreError::new(
                "set_failed",
                "Downloaded preview bundle cannot be applied",
            ));
        }
        self.record_preview_bundle(&next, Some(current.id()));
        self.emit_set_event(&next);
        Ok(self.reload_without_waiting())
    }

    fn download_preview_payload(&self, payload: &Value) -> Result<BundleInfo, CoreError> {
        let text = |key: &str| payload.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
        let version = text("version").trim().to_string();
        if version.is_empty() {
            return Err(CoreError::new(
                "invalid_payload",
                "Preview payload is missing a version",
            ));
        }
        let manifest = payload
            .get("manifest")
            .and_then(Value::as_array)
            .filter(|manifest| !manifest.is_empty())
            .cloned();
        let url = text("url");
        if url.is_empty() && manifest.is_none() {
            return Err(CoreError::new(
                "invalid_payload",
                "Preview payload is missing download information",
            ));
        }
        let url = if url.is_empty() { NO_ZIP_URL.to_string() } else { url };
        let bundle = self.download_bundle(&url, &version, &text("sessionKey"), &text("checksum"), manifest)?;
        if bundle.is_error() {
            return Err(CoreError::new(
                "download_failed",
                format!("Download failed: {}", bundle.status().as_str()),
            ));
        }
        Ok(bundle)
    }

    /// Native build changed: previews point at bundles of the previous build.
    pub(crate) fn clear_preview_session_for_native_build_change(&self) {
        let enabled = self.plugin_state().preview_session_enabled;
        if !enabled && self.preview_fallback_bundle().is_none() && self.previews().is_empty() {
            return;
        }
        self.host.info("Native build changed; clearing preview session state");
        let config = self.plugin_config();
        {
            let mut state = self.plugin_state();
            state.preview_session_enabled = false;
            state.preview_alert_pending = false;
            state.leaving_preview_for_link = false;
            state.shake_menu_enabled = config.shake_menu;
            state.shake_channel_selector_enabled = config.allow_shake_channel_selector;
            state.shake_menu_gesture = config.shake_menu_gesture.clone();
        }
        self.set_engine_preview_session(false);
        self.sync_shake_menu();
        self.restore_preview_previous_app_id();
        self.restore_preview_previous_default_channel();
        self.set_preview_fallback_bundle(None);
        self.set_next_bundle(None);
        self.clear_preview_session_preferences();
        self.kv_write(keys::PREVIEW_SESSIONS, None);
    }

    fn clear_preview_session_because_disabled(&self) {
        self.host
            .info("Preview session disabled by config; restoring preview fallback");
        match self.resolve_preview_fallback("preview disabled") {
            Some(bundle) => {
                self.stage_preview_fallback_reload(&bundle);
            }
            None => self
                .host
                .warn("Could not restore preview fallback while disabling preview"),
        }
        self.restore_preview_previous_next_bundle();
        self.restore_preview_previous_app_id();
        self.restore_preview_previous_default_channel();
        let config = self.plugin_config();
        {
            let mut state = self.plugin_state();
            state.preview_session_enabled = false;
            state.preview_alert_pending = false;
            state.leaving_preview_for_link = false;
            state.shake_menu_enabled = config.shake_menu;
            state.shake_channel_selector_enabled = config.allow_shake_channel_selector;
            state.shake_menu_gesture = config.shake_menu_gesture.clone();
        }
        self.set_engine_preview_session(false);
        self.preview_loader(false, "preview-session-disabled");
        self.sync_shake_menu();
        self.clear_preview_session_preferences();
    }

    /// Load: resume (or drop, when `allowPreview` is off) a stored preview session.
    pub(crate) fn restore_preview_state_at_load(&self) {
        let config = self.plugin_config();
        let stored = self.kv_flag(keys::PREVIEW_SESSION).unwrap_or(false);
        if stored && !config.allow_preview {
            self.clear_preview_session_because_disabled();
            return;
        }
        let enabled = stored && config.allow_preview;
        self.plugin_state().preview_session_enabled = enabled;
        self.set_engine_preview_session(enabled);
        if !enabled {
            return;
        }
        let alert_pending = self.kv_flag(keys::PREVIEW_ALERT_PENDING).unwrap_or(true);
        let selector = self
            .kv_flag(keys::PREVIEW_PREVIOUS_SHAKE_CHANNEL_SELECTOR)
            .unwrap_or(config.allow_shake_channel_selector);
        {
            let mut state = self.plugin_state();
            state.preview_alert_pending = alert_pending;
            state.shake_menu_enabled = true;
            state.shake_channel_selector_enabled = selector;
        }
        if let Some(app_id) = self.kv_text(keys::PREVIEW_APP_ID).filter(|id| !id.is_empty()) {
            self.set_active_app_id(&app_id);
            self.host.info(format!("Using preview appId {app_id}"));
        }
    }

    /// Shows "Preview started" once per session (re-armed when the host could not show it).
    pub(crate) fn show_preview_notice_if_needed(&self) {
        {
            let mut state = self.plugin_state();
            if !state.preview_session_enabled || !state.preview_alert_pending {
                return;
            }
            state.preview_alert_pending = false;
        }
        self.kv_write_flag(keys::PREVIEW_ALERT_PENDING, false);
        let weak = self.weak_self();
        std::thread::spawn(move || {
            let Some(engine) = Engine::sleep_unless_dropped(&weak, PREVIEW_NOTICE_DELAY) else {
                return;
            };
            let (enabled, gesture) = {
                let state = engine.plugin_state();
                (state.preview_session_enabled, state.shake_menu_gesture.clone())
            };
            if !enabled {
                return;
            }
            let shown = engine
                .hook(hooks::PREVIEW_NOTICE, json!({ "gesture": gesture }))
                .and_then(|reply| reply.get("shown").and_then(Value::as_bool))
                .unwrap_or(false);
            if !shown {
                engine.plugin_state().preview_alert_pending = true;
                engine.kv_write_flag(keys::PREVIEW_ALERT_PENDING, true);
            }
        });
    }

    // ---- methods -----------------------------------------------------------------------------

    fn require_preview_allowed(&self, method: &str) -> Result<(), Rejection> {
        if self.plugin_config().allow_preview {
            Ok(())
        } else {
            Err(Rejection::new(format!(
                "{method} not allowed. Set allowPreview to true in your config to enable it."
            )))
        }
    }

    pub(crate) fn method_start_preview_session(&self, args: &Value) -> MethodResult {
        if let Err(rejection) = self.require_preview_allowed("startPreviewSession") {
            self.preview_loader(false, "preview-session-not-allowed");
            return Err(rejection);
        }
        let app_id = normalized_optional(args.get("appId").and_then(Value::as_str));
        let raw_payload_url = args.get("payloadUrl").and_then(Value::as_str);
        let payload_url = normalized_payload_url(raw_payload_url);
        if normalized_optional(raw_payload_url).is_some() && payload_url.is_none() {
            self.preview_loader(false, "preview-session-invalid-payload");
            return Err(Rejection::new("Invalid preview payloadUrl"));
        }
        if !self.prepare_preview_fallback_if_needed() {
            self.preview_loader(false, "preview-session-fallback-failed");
            return Err(Rejection::new("Could not save current bundle as preview fallback"));
        }
        if let Some(app_id) = &app_id {
            self.set_active_app_id(app_id);
            self.kv_write(keys::PREVIEW_APP_ID, Some(app_id));
            self.host.info(format!("Preview session using appId: {app_id}"));
        }
        self.kv_write(keys::PREVIEW_PAYLOAD_URL, payload_url.as_deref());
        self.kv_write(
            keys::PREVIEW_NAME,
            normalized_optional(args.get("name").and_then(Value::as_str)).as_deref(),
        );
        self.kv_write(
            keys::PREVIEW_SOURCE,
            normalized_optional(args.get("source").and_then(Value::as_str)).as_deref(),
        );
        self.activate_preview_session_state();
        Ok(Value::Null)
    }

    pub(crate) fn method_list_previews(&self) -> MethodResult {
        self.require_preview_allowed("listPreviews")?;
        let previews = self.list_preview_infos(true);
        let mut result = Map::new();
        if let Some(current) = previews
            .iter()
            .find(|preview| preview.get("isActive").and_then(Value::as_bool) == Some(true))
        {
            result.insert("current".into(), current.clone());
        }
        result.insert("previews".into(), Value::Array(previews));
        result.insert("currentBundle".into(), self.current_bundle().to_js());
        if let Some(live) = self.preview_fallback_bundle() {
            result.insert("liveBundle".into(), live.to_js());
        }
        Ok(Value::Object(result))
    }

    /// `setPreview` / shake menu: switch to a stored preview.
    pub(crate) fn set_preview(&self, id: &str, reason: &str) -> Result<(), Rejection> {
        let Some(preview) = self.stored_preview_info(id) else {
            return Err(Rejection::new(format!("Preview {id} is not available locally")));
        };
        self.preview_loader(true, reason);
        if !self.prepare_preview_fallback_if_needed() {
            self.preview_loader(false, &format!("{reason}-fallback-failed"));
            return Err(Rejection::new("Could not save current bundle as preview fallback"));
        }
        if !self.set_bundle(id) {
            self.preview_loader(false, &format!("{reason}-failed"));
            return Err(Rejection::new(format!("Preview {id} cannot be applied")));
        }
        let bundle = self.get_bundle_info(Some(id));
        self.update_current_preview_metadata_from(&preview);
        self.activate_preview_session_state();
        self.record_preview_bundle(&bundle, None);
        if !self.reload_without_waiting() {
            self.preview_loader(false, &format!("{reason}-reload-failed"));
            return Err(Rejection::new(format!("Reload failed after setting preview {id}")));
        }
        self.emit_set_event(&bundle);
        self.show_preview_notice_if_needed();
        Ok(())
    }

    pub(crate) fn method_set_preview(&self, args: &Value) -> MethodResult {
        self.require_preview_allowed("setPreview")?;
        let id = args.get("id").and_then(Value::as_str).filter(|id| !id.is_empty());
        let Some(id) = id else {
            return Err(Rejection::new("setPreview called without id"));
        };
        self.set_preview(id, "set-preview").map(|()| Value::Null)
    }

    pub(crate) fn method_reset_preview(&self) -> MethodResult {
        if !self.plugin_state().preview_session_enabled {
            return Ok(Value::Null);
        }
        if self.leave_preview_session() {
            Ok(Value::Null)
        } else {
            Err(Rejection::new("Could not leave preview session"))
        }
    }

    pub(crate) fn method_delete_preview(&self, args: &Value) -> MethodResult {
        self.require_preview_allowed("deletePreview")?;
        let Some(id) = args.get("id").and_then(Value::as_str).filter(|id| !id.is_empty()) else {
            return Err(Rejection::new("deletePreview called without id"));
        };
        if self.plugin_state().preview_session_enabled && self.current_bundle().id() == id {
            return Err(Rejection::new("Cannot delete the active preview"));
        }
        let mut previews = self.previews();
        let removed = previews.remove(id).is_some();
        self.save_previews(&previews);
        let fallback = self.preview_fallback_bundle();
        let next = self.next_bundle();
        let deleted = removed
            && id != ID_BUILTIN
            && fallback.as_ref().map_or(true, |fallback| fallback.id() != id)
            && next.as_ref().map_or(true, |next| next.id() != id)
            && self.delete_bundle(id, false, true);
        Ok(json!({ "removed": removed, "deleted": deleted }))
    }

    pub(crate) fn method_preview_update(&self, args: &Value, download: bool) -> MethodResult {
        if !self.plugin_config().allow_preview {
            return Err(Rejection::new(
                "Preview updates not allowed. Set allowPreview to true in your config to enable it.",
            ));
        }
        let Some(id) = args.get("id").and_then(Value::as_str).filter(|id| !id.is_empty()) else {
            return Err(Rejection::new("Preview update called without id"));
        };
        let preview = self.stored_preview_info(id);
        let payload_url = preview
            .as_ref()
            .and_then(|preview| normalized_payload_url(preview.get("payloadUrl").and_then(Value::as_str)));
        let (Some(preview), Some(payload_url)) = (preview, payload_url) else {
            return Err(Rejection::new(format!("Preview {id} has no payloadUrl to update from")));
        };
        self.preview_update(id, &preview, &payload_url, download)
            .map_err(|error| Rejection::new(format!("Could not update preview: {}", error.message)))
    }

    fn preview_update(&self, id: &str, preview: &Value, payload_url: &str, download: bool) -> Result<Value, CoreError> {
        let payload = self.fetch_json(payload_url)?;
        let version = payload
            .get("version")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string();
        if version.is_empty() {
            return Err(CoreError::new(
                "invalid_payload",
                "Preview payload is missing a version",
            ));
        }
        let current_preview = self.get_bundle_info(Some(id));
        let up_to_date = version == current_preview.version_name();
        if up_to_date || !download {
            return Ok(json!({
                "preview": preview,
                "latestVersion": version,
                "upToDate": up_to_date,
                "updated": false,
                "bundle": current_preview.to_js(),
            }));
        }
        let next = self.download_preview_payload(&payload)?;
        let was_active = self.plugin_state().preview_session_enabled && self.current_bundle().id() == id;
        if was_active && !self.set_bundle(next.id()) {
            return Err(CoreError::new(
                "set_failed",
                "Downloaded preview bundle cannot be applied",
            ));
        }
        let saved = self.record_preview_bundle(&next, Some(id));
        if was_active {
            if !self.reload_without_waiting() {
                return Err(CoreError::new("reload_failed", "Reload failed after updating preview"));
            }
            self.emit_set_event(&next);
            self.show_preview_notice_if_needed();
        }
        Ok(json!({
            "preview": saved,
            "latestVersion": version,
            "upToDate": false,
            "updated": true,
            "bundle": next.to_js(),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_links() {
        assert!(is_preview_deep_link("https://app.example.com/preview/bundle?id=1"));
        assert!(is_preview_deep_link("capgo://preview/channel"));
        assert!(is_preview_deep_link("capgo://preview//bundle"));
        assert!(!is_preview_deep_link("https://app.example.com/preview"));
        assert!(!is_preview_deep_link("not a url"));
    }

    #[test]
    fn payload_urls() {
        assert_eq!(
            normalized_payload_url(Some(" https://x.dev/p.json ")).as_deref(),
            Some("https://x.dev/p.json")
        );
        assert_eq!(normalized_payload_url(Some("undefined")), None);
        assert_eq!(normalized_payload_url(Some("ftp://x.dev/p")), None);
    }
}
