//! Engine operation table: JSON in, JSON out.

use std::collections::BTreeSet;

use serde_json::{json, Value};

use super::Engine;
use crate::bundle::BundleInfo;
use crate::error::{CoreError, CoreResult};

fn opt_str<'a>(input: &'a Value, key: &str) -> Option<&'a str> {
    input.get(key).and_then(Value::as_str)
}

fn req_str<'a>(input: &'a Value, key: &str) -> CoreResult<&'a str> {
    opt_str(input, key).ok_or_else(|| CoreError::invalid_input(format!("`{key}` is required")))
}

fn flag(input: &Value, key: &str, default: bool) -> bool {
    input.get(key).and_then(Value::as_bool).unwrap_or(default)
}

/// The host's own view of a bundle (`bundle` raw JSON) when given, else the stored record for `id`.
fn subject(engine: &Engine, input: &Value) -> CoreResult<BundleInfo> {
    if let Some(bundle) = input
        .get("bundle")
        .filter(|value| value.is_object())
        .and_then(BundleInfo::from_raw)
    {
        return Ok(bundle);
    }
    Ok(engine.get_bundle_info(Some(req_str(input, "id")?)))
}

fn bundle(value: BundleInfo) -> Value {
    value.to_raw()
}

fn optional_bundle(value: Option<BundleInfo>) -> Value {
    value.map_or(Value::Null, bundle)
}

impl Engine {
    pub(super) fn call_engine(&self, operation: &str, input: &Value) -> Option<CoreResult<Value>> {
        let result = (|| -> CoreResult<Value> {
            Ok(match operation {
                "engineInfo" => json!({ "version": crate::CORE_VERSION }),
                "configure" => {
                    self.configure(input)?;
                    json!({})
                }
                "config" => {
                    let config = self.config();
                    json!({
                        "defaultChannel": config.default_channel,
                        "customId": config.custom_id,
                        "statsUrl": config.stats_url,
                        "channelUrl": config.channel_url,
                        "updateUrl": config.update_url,
                        "keyId": config.key_id,
                        "previewSession": config.preview_session,
                        "userAgent": self.http.user_agent(),
                    })
                }

                // ---- plugin layer (Capacitor glue calls these)
                "pluginLoad" => self.plugin_load(input)?,
                "pluginMethod" => {
                    self.plugin_method(req_str(input, "name")?, input.get("args").unwrap_or(&Value::Null))
                }
                "appForeground" => {
                    self.invalidate_app_ready_check();
                    self.plugin_state().in_background = false;
                    self.spawn_plugin_task(|engine| engine.app_moved_to_foreground());
                    json!({})
                }
                "appBackground" => {
                    self.background_splash();
                    self.spawn_plugin_task(|engine| engine.background_work());
                    json!({})
                }
                "appTerminate" => {
                    self.app_terminated();
                    json!({})
                }
                "openUrl" => json!({ "leavingPreview": self.handle_open_url(req_str(input, "url")?) }),
                "readyGuardDisarm" => {
                    self.disarm_ready_guard(input.get("generation").and_then(Value::as_i64).unwrap_or(-1));
                    json!({})
                }
                "reportMemoryWarning" => {
                    self.report_memory_warning();
                    json!({})
                }
                "reportRenderProcessGone" => {
                    self.persist_render_process_gone(input.get("metadata").unwrap_or(&Value::Null));
                    json!({})
                }
                "reportWebViewStats" => {
                    let metadata = input
                        .get("metadata")
                        .and_then(Value::as_object)
                        .cloned()
                        .unwrap_or_default();
                    self.report_webview_stats(req_str(input, "action")?, &metadata);
                    json!({})
                }
                "previewMenuPreviews" => Value::Array(self.list_preview_infos(true)),
                "previewMenuSet" => {
                    json!({ "ok": self.set_preview(req_str(input, "id")?, "set-preview-menu").is_ok() })
                }
                "previewMenuLeave" => json!({ "ok": self.leave_preview_session() }),
                "previewMenuReload" => json!({ "ok": self.reload_preview_session() }),
                "previewSessionActive" => json!({ "active": self.plugin_state().preview_session_enabled }),
                "pluginMethods" => json!(super::plugin::ENGINE_METHODS),

                // ---- store
                "bundleGet" => bundle(self.get_bundle_info(opt_str(input, "id"))),
                "bundleGetByName" => optional_bundle(self.get_bundle_info_by_name(req_str(input, "version")?)),
                "bundleSave" => {
                    let id = req_str(input, "id")?;
                    let info = match input.get("bundle") {
                        None | Some(Value::Null) => None,
                        Some(value) => Some(
                            BundleInfo::from_raw(value).ok_or_else(|| CoreError::invalid_input("invalid bundle"))?,
                        ),
                    };
                    json!({ "saved": self.save_bundle_info(id, info.as_ref()) })
                }
                "bundleList" => Value::Array(self.list(flag(input, "raw", false)).into_iter().map(bundle).collect()),
                "bundleHasInfo" => {
                    json!({ "stored": self.has_stored_bundle_info(req_str(input, "id")?) })
                }
                "bundleDirectory" => {
                    json!({ "path": self.bundle_directory(req_str(input, "id")?)?.to_string_lossy() })
                }
                "bundleExists" => json!({ "exists": self.bundle_exists(req_str(input, "id")?) }),
                "bundleDelete" => json!({
                    "deleted": self.delete_bundle(
                        req_str(input, "id")?,
                        flag(input, "removeInfo", true),
                        flag(input, "cancelActiveDownload", true),
                    )
                }),
                "bundleSet" => json!({ "set": self.set_bundle(req_str(input, "id")?) }),
                "bundleCanSet" => {
                    let info = subject(self, input)?;
                    json!({ "canSet": self.can_set(&info) })
                }
                "bundleSetStatus" => {
                    let status = crate::bundle::BundleStatus::parse(opt_str(input, "status"))
                        .ok_or_else(|| CoreError::invalid_input("invalid status"))?;
                    self.set_bundle_status(req_str(input, "id")?, status);
                    json!({})
                }
                "bundleCurrent" => json!({
                    "bundle": bundle(self.current_bundle()),
                    "id": self.current_bundle_id(),
                    "path": self.current_bundle_path(),
                    "isBuiltin": self.is_using_builtin(),
                }),
                "bundleFallback" => bundle(self.fallback_bundle()),
                "bundleNext" => optional_bundle(self.next_bundle()),
                "bundleSetNext" => json!({ "set": self.set_next_bundle(opt_str(input, "id")) }),
                "bundlePreviewFallback" => optional_bundle(self.preview_fallback_bundle()),
                "bundleSetPreviewFallback" => {
                    json!({ "set": self.set_preview_fallback_bundle(opt_str(input, "id")) })
                }
                "bundleSetSuccess" => {
                    let engine = self
                        .weak_self()
                        .upgrade()
                        .ok_or_else(|| CoreError::new("internal", "engine dropped"))?;
                    engine.set_success(req_str(input, "id")?, flag(input, "autoDeletePrevious", false));
                    json!({})
                }
                "bundleSetError" => {
                    self.set_error(req_str(input, "id")?);
                    json!({})
                }
                "bundleReset" => {
                    self.reset(flag(input, "internal", false));
                    json!({})
                }
                "bundleAutoReset" => {
                    self.auto_reset(
                        opt_str(input, "nativeBuildVersion").unwrap_or_default(),
                        flag(input, "resetWhenNativeVersionChanged", true),
                    );
                    json!({})
                }
                "bundleCaptureResetState" => {
                    let state = self.capture_reset_state();
                    json!({
                        "currentBundlePath": state.current_bundle_path,
                        "fallbackBundleId": state.fallback_bundle_id,
                        "nextBundleId": state.next_bundle_id,
                    })
                }
                "bundleRestoreResetState" => {
                    self.restore_reset_state(&super::store::ResetState {
                        current_bundle_path: opt_str(input, "currentBundlePath").unwrap_or_default().to_string(),
                        fallback_bundle_id: opt_str(input, "fallbackBundleId").unwrap_or_default().to_string(),
                        next_bundle_id: opt_str(input, "nextBundleId").map(str::to_string),
                    });
                    json!({})
                }
                "bundlePrepareResetTransition" => {
                    self.prepare_reset_state_for_transition();
                    json!({})
                }
                "bundleFinalizeResetTransition" => {
                    self.finalize_reset_transition(
                        opt_str(input, "previousBundleName").unwrap_or_default(),
                        flag(input, "internal", false),
                    );
                    json!({})
                }
                "bundleStagePendingReload" => {
                    let info = subject(self, input)?;
                    json!({ "staged": self.stage_pending_reload(&info) })
                }
                "bundleStagePreviewFallbackReload" => {
                    let info = subject(self, input)?;
                    json!({ "staged": self.stage_preview_fallback_reload(&info) })
                }
                "bundleFinalizePendingReload" => {
                    let info = subject(self, input)?;
                    self.finalize_pending_reload(&info, opt_str(input, "previousBundleName").unwrap_or_default());
                    json!({})
                }
                "bundleDrainPendingDeletes" => {
                    self.drain_pending_deletes();
                    json!({})
                }
                "bundleAllowedIdsForCleanup" => json!(self.allowed_bundle_ids_for_cleanup()),
                "bundleCleanupDownloadDirectories" => {
                    let allowed: BTreeSet<String> = match input.get("allowedIds") {
                        Some(Value::Array(ids)) => ids.iter().filter_map(Value::as_str).map(str::to_string).collect(),
                        _ => self.allowed_bundle_ids_for_cleanup(),
                    };
                    self.cleanup_download_directories(&allowed, &|| false);
                    json!({})
                }
                "bundleCleanupOrphanedTempFolders" => {
                    self.cleanup_orphaned_temp_folders(&|| false);
                    json!({})
                }
                "bundleCleanupDeltaCache" => {
                    self.cleanup_delta_cache();
                    json!({})
                }
                "bundleNewDownloadRecord" => bundle(self.new_download_record(req_str(input, "version")?)),
                "randomId" => json!({ "id": super::store::random_id() }),

                // ---- stats
                "statsSend" => {
                    let metadata = input.get("metadata").and_then(Value::as_object);
                    self.send_stats_with_callback(
                        req_str(input, "action")?,
                        opt_str(input, "versionName"),
                        opt_str(input, "oldVersionName"),
                        metadata,
                        opt_str(input, "callbackId").map(str::to_string),
                    );
                    json!({})
                }
                "statsFlush" => {
                    self.flush_stats();
                    json!({})
                }
                "statsRestore" => {
                    self.restore_pending_stats();
                    json!({})
                }
                "statsPersist" => {
                    self.persist_stats(false);
                    json!({})
                }
                "statsPendingCount" => json!({ "count": self.pending_stats_count() }),
                "statsShutdown" => {
                    self.shutdown_stats();
                    json!({})
                }

                // ---- backend
                "infoObject" => Value::Object(self.info_object(opt_str(input, "appId"))),
                "getLatest" => Value::Object(self.get_latest(
                    opt_str(input, "updateUrl"),
                    opt_str(input, "channel"),
                    opt_str(input, "appId"),
                )),
                "setChannel" => Value::Object(self.set_channel(
                    req_str(input, "channel")?,
                    opt_str(input, "persistKey"),
                    flag(input, "allowSetDefaultChannel", true),
                    opt_str(input, "configDefaultChannel").unwrap_or_default(),
                )),
                "unsetChannel" => Value::Object(self.unset_channel(
                    opt_str(input, "persistKey"),
                    opt_str(input, "configDefaultChannel").unwrap_or_default(),
                    flag(input, "allowSetDefaultChannel", true),
                )),
                "getChannel" => Value::Object(self.get_channel(opt_str(input, "persistKey"))),
                "listChannels" => Value::Object(self.list_channels()),
                "bundleDownloadSize" => {
                    let manifest = input
                        .get("manifest")
                        .and_then(Value::as_array)
                        .cloned()
                        .unwrap_or_default();
                    let update_url = opt_str(input, "updateUrl")
                        .map(str::to_string)
                        .unwrap_or_else(|| self.config().update_url.clone());
                    Value::Object(self.bundle_download_size(&update_url, opt_str(input, "version"), &manifest))
                }
                "isRemoteBlocked" => json!({ "blocked": self.is_remote_blocked() }),

                // ---- downloads
                "download" => {
                    let request = super::download::DownloadRequest::from_json(input)?;
                    let installed = if request.manifest.is_some() {
                        self.download_manifest(&request)?
                    } else {
                        if request.url.is_empty() {
                            return Err(CoreError::invalid_input("Download called without url"));
                        }
                        self.download_zip(&request)?
                    };
                    bundle(installed)
                }
                "downloadPreflight" => {
                    let version = opt_str(input, "version").unwrap_or_default();
                    self.require_session_key(opt_str(input, "sessionKey").unwrap_or_default(), version)?;
                    if !flag(input, "isManifest", false) {
                        self.require_checksum(opt_str(input, "checksum").unwrap_or_default(), version)?;
                    }
                    json!({})
                }
                "fetchJson" => self.fetch_json(req_str(input, "url")?)?,
                "cancelDownload" => {
                    json!({ "cancelled": self.cancel_download(req_str(input, "version")?) })
                }
                "isDownloading" => {
                    json!({ "downloading": self.is_downloading(req_str(input, "version")?) })
                }
                "missingBundleFiles" => {
                    let manifest = input
                        .get("manifest")
                        .and_then(Value::as_array)
                        .cloned()
                        .unwrap_or_default();
                    self.missing_bundle_files(&manifest, opt_str(input, "sessionKey").unwrap_or_default())
                }
                "populateDeltaCache" => {
                    self.populate_delta_cache(req_str(input, "id")?);
                    json!({})
                }
                "cleanupDownloadTempFiles" => {
                    self.cleanup_download_temp_files();
                    json!({})
                }
                _ => return Err(CoreError::new("__not_engine__", "")),
            })
        })();
        match result {
            Err(error) if error.code == "__not_engine__" => None,
            other => Some(other),
        }
    }
}
