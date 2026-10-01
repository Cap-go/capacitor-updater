//! JavaScript plugin methods. Hosts forward the call arguments and settle the
//! call with the result (`resolve` / `reject`); app store methods stay native.

use serde_json::{json, Value};

use super::{keys, MethodResult, Rejection};
use crate::bundle::BundleInfo;
use crate::engine::download::DownloadRequest;
use crate::engine::Engine;
use crate::error::{CoreError, CoreResult};
use crate::host::HostLog;

/// Methods implemented by the engine (everything but listeners and app store APIs).
pub const ENGINE_METHODS: &[&str] = &[
    "notifyAppReady",
    "setUpdateUrl",
    "setStatsUrl",
    "setChannelUrl",
    "download",
    "next",
    "set",
    "startPreviewSession",
    "listPreviews",
    "setPreview",
    "resetPreview",
    "deletePreview",
    "checkPreviewUpdate",
    "updatePreview",
    "delete",
    "setBundleError",
    "list",
    "reset",
    "current",
    "reload",
    "setMultiDelay",
    "cancelDelay",
    "triggerUpdateCheck",
    "getLatest",
    "getMissingBundleFiles",
    "getBundleDownloadSize",
    "setChannel",
    "unsetChannel",
    "getChannel",
    "listChannels",
    "setCustomId",
    "getBuiltinVersion",
    "getDeviceId",
    "getPluginVersion",
    "isAutoUpdateEnabled",
    "isAutoUpdateAvailable",
    "getNextBundle",
    "getFailedUpdate",
    "setShakeMenu",
    "isShakeMenuEnabled",
    "setShakeChannelSelector",
    "isShakeChannelSelectorEnabled",
    "getAppId",
    "setAppId",
    "reportWebViewError",
];

/// Engine methods hosts must not run on their serial method lane.
///
/// Hosts run every engine method one at a time, in call order, so calls that
/// JavaScript does not await (`next()` then `reload()`) behave like every
/// previous version, where Capacitor ran them in order on one plugin thread
/// (Android) or the bridge queue (iOS). These methods are network bound or wait
/// for `notifyAppReady` from the new page (`set`, `reload`, `reset`): hosts start
/// them in call order, then run them off the lane, like both previous plugins ran
/// them on their own threads, so they never block the calls that come after.
pub const DETACHED_METHODS: &[&str] = &[
    "download",
    "set",
    "reload",
    "reset",
    "setPreview",
    "resetPreview",
    "checkPreviewUpdate",
    "updatePreview",
    "getLatest",
    "getMissingBundleFiles",
    "getBundleDownloadSize",
    "setChannel",
    "unsetChannel",
    "getChannel",
    "listChannels",
];

fn string_arg<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key).and_then(Value::as_str)
}

fn bool_arg(args: &Value, key: &str) -> Option<bool> {
    args.get(key).and_then(Value::as_bool)
}

impl Engine {
    /// Downloads a bundle for `download()` / previews (session key and checksum rules apply).
    pub(crate) fn download_bundle(
        &self,
        url: &str,
        version: &str,
        session_key: &str,
        checksum: &str,
        manifest: Option<Vec<Value>>,
    ) -> CoreResult<BundleInfo> {
        self.wait_for_cleanup()?;
        let request = DownloadRequest {
            url: url.to_string(),
            version: version.to_string(),
            session_key: session_key.to_string(),
            checksum: checksum.to_string(),
            manifest,
            emit_events: false,
            ..Default::default()
        };
        let bundle = if request.manifest.is_some() {
            self.download_manifest(&request)?
        } else {
            self.download_zip(&request)?
        };
        if bundle.is_error() {
            return Err(CoreError::new(
                "download_failed",
                format!("Download failed: {}", bundle.status().as_str()),
            ));
        }
        Ok(bundle)
    }

    fn set_url(&self, args: &Value, method: &str, key: &str, field: &str) -> MethodResult {
        if !self.plugin_config().allow_modify_url {
            self.host.error(format!(
                "{method} not allowed set allowModifyUrl in your config to true to allow it"
            ));
            return Err(Rejection::new(format!(
                "{method} called without allowModifyUrl set allowModifyUrl in your config to true to allow it"
            )));
        }
        let Some(url) = string_arg(args, "url") else {
            return Err(Rejection::new(format!("{method} called without url")));
        };
        if self.plugin_config().persist_modify_url {
            self.kv_write(key, Some(url));
        }
        self.configure(&json!({ field: url }))?;
        Ok(Value::Null)
    }

    fn method_download(&self, args: &Value) -> MethodResult {
        let Some(url) = string_arg(args, "url") else {
            return Err(Rejection::new("Download called without url"));
        };
        let Some(version) = string_arg(args, "version") else {
            return Err(Rejection::new("Download called without version"));
        };
        self.host.info(format!("Downloading {url}"));
        let manifest = args.get("manifest").and_then(Value::as_array).cloned();
        let result = self.download_bundle(
            url,
            version,
            string_arg(args, "sessionKey").unwrap_or_default(),
            string_arg(args, "checksum").unwrap_or_default(),
            manifest,
        );
        match result {
            Ok(bundle) => {
                self.emit_bundle_event("updateAvailable", &bundle);
                Ok(bundle.to_js())
            }
            Err(error) => {
                self.host
                    .error(format!("Failed to download from: {url} {}", error.message));
                self.host.emit("downloadFailed", &json!({ "version": version }));
                self.send_stats("download_fail", Some(version), None, None);
                Err(Rejection::new(format!(
                    "Failed to download from: {url} - {}",
                    error.message
                )))
            }
        }
    }

    fn method_set_bundle_error(&self, args: &Value) -> MethodResult {
        if !self.plugin_config().allow_manual_bundle_error {
            return Err(Rejection::new(
                "setBundleError not allowed. Set allowManualBundleError to true in your config to enable it.",
            ));
        }
        let Some(id) = string_arg(args, "id") else {
            return Err(Rejection::new("setBundleError called without id"));
        };
        let bundle = self.get_bundle_info(Some(id));
        if bundle.is_unknown() || (!bundle.is_builtin() && !self.has_stored_bundle_info(id)) {
            return Err(Rejection::new(format!("Bundle {id} does not exist")));
        }
        if bundle.is_builtin() {
            return Err(Rejection::new("Cannot set builtin bundle to error state"));
        }
        if self.is_auto_update_enabled() {
            self.host
                .warn("setBundleError used while autoUpdate is enabled; this method is intended for manual mode");
        }
        self.set_error(id);
        Ok(json!({ "bundle": self.get_bundle_info(Some(id)).to_js() }))
    }

    pub(crate) fn run_plugin_method(&self, name: &str, args: &Value) -> MethodResult {
        let empty = Value::Object(Default::default());
        let args = if args.is_object() { args } else { &empty };
        match name {
            "notifyAppReady" => Ok(self.notify_app_ready(args.get("loadGeneration").and_then(Value::as_i64))),
            "setUpdateUrl" => self.set_url(args, "setUpdateUrl", keys::UPDATE_URL, "updateUrl"),
            "setStatsUrl" => self.set_url(args, "setStatsUrl", keys::STATS_URL, "statsUrl"),
            "setChannelUrl" => self.set_url(args, "setChannelUrl", keys::CHANNEL_URL, "channelUrl"),
            "download" => self.method_download(args),
            "next" => {
                let Some(id) = string_arg(args, "id") else {
                    return Err(Rejection::new("Next called without id"));
                };
                self.host.info(format!("Setting next active id {id}"));
                if !self.set_next_bundle(Some(id)) {
                    return Err(Rejection::new(format!(
                        "Set next id failed. Bundle {id} does not exist."
                    )));
                }
                Ok(self.get_bundle_info(Some(id)).to_js())
            }
            "set" => {
                let Some(id) = string_arg(args, "id") else {
                    return Err(Rejection::new("Set called without id"));
                };
                self.set_and_reload(id).map(|_| Value::Null).map_err(Rejection::new)
            }
            "startPreviewSession" => self.method_start_preview_session(args),
            "listPreviews" => self.method_list_previews(),
            "setPreview" => self.method_set_preview(args),
            "resetPreview" => self.method_reset_preview(),
            "deletePreview" => self.method_delete_preview(args),
            "checkPreviewUpdate" => self.method_preview_update(args, false),
            "updatePreview" => self.method_preview_update(args, true),
            "delete" => {
                let Some(id) = string_arg(args, "id") else {
                    return Err(Rejection::new("Delete called without id"));
                };
                if self.delete_bundle(id, true, true) {
                    Ok(Value::Null)
                } else {
                    Err(Rejection::new(format!(
                        "Delete failed, id {id} does not exist or it cannot be deleted (perhaps it is the 'next' bundle)"
                    )))
                }
            }
            "setBundleError" => self.method_set_bundle_error(args),
            "list" => {
                let bundles: Vec<Value> = self
                    .list(bool_arg(args, "raw").unwrap_or(false))
                    .iter()
                    .map(BundleInfo::to_js)
                    .collect();
                Ok(json!({ "bundles": bundles }))
            }
            "reset" => {
                let to_last_successful = bool_arg(args, "toLastSuccessful").unwrap_or(false);
                let use_pending = bool_arg(args, "usePendingBundle").unwrap_or(false);
                if self.perform_reset(to_last_successful, use_pending, false) {
                    Ok(Value::Null)
                } else {
                    Err(Rejection::new("Reset failed"))
                }
            }
            "current" => Ok(json!({
                "bundle": self.current_bundle().to_js(),
                "native": self.plugin_config().native_version,
            })),
            "reload" => self.reload_with_pending().map(|()| Value::Null).map_err(Rejection::new),
            "setMultiDelay" => {
                let Some(conditions) = args.get("delayConditions").and_then(Value::as_array) else {
                    return Err(Rejection::new("setMultiDelay called without delayCondition"));
                };
                if self.set_multi_delay(conditions) {
                    Ok(Value::Null)
                } else {
                    Err(Rejection::new("Failed to delay update"))
                }
            }
            "cancelDelay" => {
                if self.cancel_delay("JS") {
                    Ok(Value::Null)
                } else {
                    Err(Rejection::new("Failed to cancel delay"))
                }
            }
            "triggerUpdateCheck" => {
                let status = self.trigger_update_check();
                Ok(json!({ "status": status, "queued": status == "queued" }))
            }
            "getLatest" => self.method_get_latest(args),
            "getMissingBundleFiles" => {
                let Some(manifest) = args.get("manifest").and_then(Value::as_array) else {
                    return Err(Rejection::new("getMissingBundleFiles called without manifest"));
                };
                Ok(self.missing_bundle_files(manifest, string_arg(args, "sessionKey").unwrap_or_default()))
            }
            "getBundleDownloadSize" => {
                let Some(manifest) = args.get("manifest").and_then(Value::as_array) else {
                    return Err(Rejection::new("getBundleDownloadSize called without manifest"));
                };
                let update_url = self.config().update_url.clone();
                Ok(Value::Object(self.bundle_download_size(
                    &update_url,
                    string_arg(args, "version"),
                    manifest,
                )))
            }
            "setChannel" => self.method_set_channel(args),
            "unsetChannel" => self.method_unset_channel(args),
            "getChannel" => self.method_get_channel(),
            "listChannels" => self.method_list_channels(),
            "setCustomId" => {
                let Some(custom_id) = string_arg(args, "customId") else {
                    return Err(Rejection::new("setCustomId called without customId"));
                };
                self.configure(&json!({ "customId": custom_id }))?;
                if self.plugin_config().persist_custom_id {
                    self.kv_write(keys::CUSTOM_ID, (!custom_id.is_empty()).then_some(custom_id));
                }
                Ok(Value::Null)
            }
            "getBuiltinVersion" => Ok(json!({ "version": self.config().version_build })),
            "getDeviceId" => Ok(json!({ "deviceId": self.config().device_id })),
            "getPluginVersion" => Ok(json!({ "version": self.config().plugin_version })),
            "isAutoUpdateEnabled" => Ok(json!({ "enabled": self.is_auto_update_enabled() })),
            "isAutoUpdateAvailable" => Ok(json!({ "available": !self.plugin_config().server_url_configured })),
            "getNextBundle" => Ok(self.next_bundle().map_or(Value::Null, |bundle| bundle.to_js())),
            "getFailedUpdate" => Ok(self.take_failed_update()),
            "setShakeMenu" => {
                let Some(enabled) = bool_arg(args, "enabled") else {
                    return Err(Rejection::new("setShakeMenu called without enabled parameter"));
                };
                self.plugin_state().shake_menu_enabled = enabled;
                self.sync_shake_menu();
                Ok(Value::Null)
            }
            "isShakeMenuEnabled" => {
                let state = self.plugin_state();
                Ok(json!({ "enabled": state.shake_menu_enabled, "gesture": state.shake_menu_gesture }))
            }
            "setShakeChannelSelector" => {
                let Some(enabled) = bool_arg(args, "enabled") else {
                    return Err(Rejection::new(
                        "setShakeChannelSelector called without enabled parameter",
                    ));
                };
                self.plugin_state().shake_channel_selector_enabled = enabled;
                self.sync_shake_menu();
                Ok(Value::Null)
            }
            "isShakeChannelSelectorEnabled" => {
                Ok(json!({ "enabled": self.plugin_state().shake_channel_selector_enabled }))
            }
            "getAppId" => Ok(json!({ "appId": self.config().app_id })),
            "setAppId" => {
                if !self.plugin_config().allow_modify_app_id {
                    return Err(Rejection::new(
                        "setAppId called without allowModifyAppId set allowModifyAppId in your config to true to allow it",
                    ));
                }
                let Some(app_id) = string_arg(args, "appId") else {
                    return Err(Rejection::new("setAppId called without appId"));
                };
                self.set_active_app_id(app_id);
                Ok(Value::Null)
            }
            "reportWebViewError" => {
                self.report_webview_error(args);
                Ok(Value::Null)
            }
            _ => Err(Rejection::new(format!("Unknown plugin method: {name}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detached_methods_are_engine_methods() {
        for method in DETACHED_METHODS {
            assert!(ENGINE_METHODS.contains(method), "{method}");
        }
        // Quick state methods stay ordered on the lane.
        for method in [
            "notifyAppReady",
            "next",
            "getNextBundle",
            "current",
            "delete",
            "triggerUpdateCheck",
        ] {
            assert!(!DETACHED_METHODS.contains(&method), "{method}");
        }
    }
}
