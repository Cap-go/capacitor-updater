/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Engine operation table (Rust engine/ops.rs). */

#include "engine/ops.h"

#include <stdlib.h>
#include <string.h>

#include "engine/backend.h"
#include "engine/download.h"
#include "engine/engine.h"
#include "engine/manifest.h"
#include "engine/plugin/channel.h"
#include "engine/plugin/flow.h"
#include "engine/plugin/methods.h"
#include "engine/plugin/plugin.h"
#include "engine/plugin/preview.h"
#include "engine/plugin/ready.h"
#include "engine/plugin/telemetry.h"
#include "engine/scheduled.h"
#include "engine/stats.h"
#include "engine/store.h"

static const char *opt_str(const cj *input, const char *key) { return cj_get_str(input, key); }

static const char *req_str(const cj *input, const char *key, cg_error *err) {
    const char *value = opt_str(input, key);
    if (!value) cg_err_invalid_input(err, "`%s` is required", key);
    return value;
}

static bool flag(const cj *input, const char *key, bool fallback) { return cj_get_bool(input, key, fallback); }

/* bundle(value): consumes *info. */
static cj *bundle(cg_bundle_info *info) {
    cj *raw = cg_bundle_info_to_raw(info);
    cg_bundle_info_clear(info);
    return raw;
}

static void task_foreground(cg_engine *engine, void *ctx) { cg_flow_app_moved_to_foreground(engine); }
static void task_background(cg_engine *engine, void *ctx) { cg_flow_background_work(engine); }

/* Returns the result (NULL with *err on error). Unknown operations set *handled = false. */
static cj *dispatch(cg_engine *engine, const char *op, const cj *input, bool *handled, cg_error *err) {
#define IS(name) (strcmp(op, name) == 0)
    if (IS("configure")) {
        if (!cg_engine_configure(engine, input, err)) return NULL;
        return cj_obj();
    }
    if (IS("config")) {
        cg_engine_config *config = cg_engine_config_snapshot(engine);
        cj *out = cj_objv("defaultChannel", cj_str(config->default_channel), "customId", cj_str(config->custom_id),
                          "statsUrl", cj_str(config->stats_url), "channelUrl", cj_str(config->channel_url),
                          "updateUrl", cj_str(config->update_url), "keyId", cj_str(config->key_id),
                          "previewSession", cj_bool(config->preview_session), "userAgent",
                          cj_str_own(cg_engine_user_agent(engine)), NULL);
        cg_config_release(config);
        return out;
    }

    /* ---- plugin layer (Capacitor glue calls these) */
    if (IS("pluginLoad")) return cg_plugin_plugin_load(engine, input, err);
    if (IS("pluginMethod")) {
        const char *name = req_str(input, "name", err);
        if (!name) return NULL;
        return cg_plugin_plugin_method(engine, name, cj_get(input, "args"));
    }
    if (IS("appForeground")) {
        cg_plugin_state *state = cg_plugin_lock_state(engine);
        if (state->foreground_handled) {
            cg_plugin_unlock_state(engine);
            cg_debug(&engine->host, "Already in foreground, ignoring a repeated foreground event");
            return cj_objv("duplicate", cj_bool(true), NULL);
        }
        state->foreground_handled = true;
        cg_plugin_unlock_state(engine);
        cg_ready_invalidate_app_ready_check(engine);
        cg_plugin_lock_state(engine)->in_background = false;
        cg_plugin_unlock_state(engine);
        cg_plugin_spawn_plugin_task(engine, task_foreground, NULL, NULL);
        return cj_obj();
    }
    if (IS("appBackground")) {
        cg_flow_background_splash(engine);
        cg_plugin_spawn_plugin_task(engine, task_background, NULL, NULL);
        return cj_obj();
    }
    if (IS("appTerminate")) {
        cg_flow_app_terminated(engine);
        return cj_obj();
    }
    if (IS("openUrl")) {
        const char *url = req_str(input, "url", err);
        if (!url) return NULL;
        return cj_objv("leavingPreview", cj_bool(cg_preview_handle_open_url(engine, url)), NULL);
    }
    if (IS("readyGuardDisarm")) {
        int64_t generation;
        if (!cj_as_i64(cj_get(input, "generation"), &generation)) generation = -1;
        cg_ready_disarm_ready_guard(engine, generation);
        return cj_obj();
    }
    if (IS("reportMemoryWarning")) {
        cg_telemetry_report_memory_warning(engine);
        return cj_obj();
    }
    if (IS("reportRenderProcessGone")) {
        cg_telemetry_persist_render_process_gone(engine, cj_get(input, "metadata"));
        return cj_obj();
    }
    if (IS("reportWebViewStats")) {
        const cj *metadata = cj_get(input, "metadata");
        cj *object = cj_is_obj(metadata) ? cj_clone(metadata) : cj_obj();
        const char *action = req_str(input, "action", err);
        if (action) cg_telemetry_report_webview_stats(engine, action, object);
        cj_free(object);
        return action ? cj_obj() : NULL;
    }
    if (IS("previewMenuPreviews")) return cg_preview_list_preview_infos(engine, true);
    if (IS("previewMenuSet")) {
        const char *id = req_str(input, "id", err);
        if (!id) return NULL;
        cg_rejection rejection = CG_REJECTION_INIT;
        bool ok = cg_preview_set_preview(engine, id, "set-preview-menu", &rejection);
        cg_rejection_clear(&rejection);
        return cj_objv("ok", cj_bool(ok), NULL);
    }
    if (IS("previewMenuLeave")) return cj_objv("ok", cj_bool(cg_preview_leave_preview_session(engine)), NULL);
    if (IS("previewMenuReload")) return cj_objv("ok", cj_bool(cg_preview_reload_preview_session(engine)), NULL);
    if (IS("previewSessionActive")) {
        bool active = cg_plugin_lock_state(engine)->preview_session_enabled;
        cg_plugin_unlock_state(engine);
        return cj_objv("active", cj_bool(active), NULL);
    }
    if (IS("shakeMenuSwitchChannel")) {
        const char *channel = req_str(input, "channel", err);
        if (!channel) return NULL;
        return cg_channel_shake_menu_switch_channel(engine, channel);
    }
    if (IS("pluginMethods")) return cg_methods_engine_methods();
    if (IS("detachedPluginMethods")) return cg_methods_detached_methods();

    /* ---- store */
    if (IS("bundleGet")) {
        cg_bundle_info info;
        cg_store_get_bundle_info(engine, opt_str(input, "id"), &info);
        return bundle(&info);
    }
    if (IS("bundleGetByName")) {
        const char *version = req_str(input, "version", err);
        if (!version) return NULL;
        cg_bundle_info info;
        return cg_store_get_bundle_info_by_name(engine, version, &info) ? bundle(&info) : cj_null();
    }
    if (IS("bundleSave")) {
        const char *id = req_str(input, "id", err);
        if (!id) return NULL;
        const cj *raw = cj_get(input, "bundle");
        if (cj_is_null(raw)) return cj_objv("saved", cj_bool(cg_store_save_bundle_info(engine, id, NULL)), NULL);
        cg_bundle_info info;
        if (!cg_bundle_info_from_raw(raw, &info)) {
            cg_err_invalid_input(err, "invalid bundle");
            return NULL;
        }
        bool saved = cg_store_save_bundle_info(engine, id, &info);
        cg_bundle_info_clear(&info);
        return cj_objv("saved", cj_bool(saved), NULL);
    }
    if (IS("bundleList")) {
        cg_bundle_list list;
        cg_store_list(engine, flag(input, "raw", false), &list);
        cj *out = cj_arr();
        for (size_t i = 0; i < list.len; i++) cj_push(out, cg_bundle_info_to_raw(&list.items[i]));
        cg_bundle_list_clear(&list);
        return out;
    }
    if (IS("bundleDelete")) {
        const char *id = req_str(input, "id", err);
        if (!id) return NULL;
        bool deleted = cg_store_delete_bundle(engine, id, flag(input, "removeInfo", true),
                                              flag(input, "cancelActiveDownload", true));
        return cj_objv("deleted", cj_bool(deleted), NULL);
    }
    if (IS("bundleSet")) {
        const char *id = req_str(input, "id", err);
        if (!id) return NULL;
        return cj_objv("set", cj_bool(cg_store_set_bundle(engine, id)), NULL);
    }
    if (IS("bundleCurrent")) {
        cg_bundle_info current;
        cg_store_current_bundle(engine, &current);
        cj *out = cj_objv("bundle", bundle(&current), "id", cj_str_own(cg_store_current_bundle_id(engine)), "path",
                          cj_str_own(cg_store_current_bundle_path(engine)), "isBuiltin",
                          cj_bool(cg_store_is_using_builtin(engine)), NULL);
        return out;
    }
    if (IS("bundleNext")) {
        cg_bundle_info next;
        return cg_store_next_bundle(engine, &next) ? bundle(&next) : cj_null();
    }
    if (IS("bundleSetNext"))
        return cj_objv("set", cj_bool(cg_store_set_next_bundle(engine, opt_str(input, "id"))), NULL);
    if (IS("bundleSetSuccess")) {
        cg_engine_weak *weak = cg_engine_downgrade(engine);
        cg_engine *strong = cg_engine_upgrade(weak);
        cg_engine_weak_release(weak);
        if (!strong) {
            cg_err_set(err, "internal", "engine dropped");
            return NULL;
        }
        const char *id = req_str(input, "id", err);
        if (id) cg_store_set_success(strong, id, flag(input, "autoDeletePrevious", false));
        cg_engine_release(strong);
        return id ? cj_obj() : NULL;
    }
    if (IS("bundleReset")) {
        cg_store_reset(engine, flag(input, "internal", false));
        return cj_obj();
    }
    if (IS("bundleAutoReset")) {
        cg_store_auto_reset(engine, cg_or_empty(opt_str(input, "nativeBuildVersion")),
                            flag(input, "resetWhenNativeVersionChanged", true));
        return cj_obj();
    }
    if (IS("bundleCaptureResetState")) {
        cg_reset_state state;
        cg_store_capture_reset_state(engine, &state);
        cj *out = cj_objv("currentBundlePath", cj_str(state.current_bundle_path), "fallbackBundleId",
                          cj_str(state.fallback_bundle_id), "nextBundleId", cj_str(state.next_bundle_id), NULL);
        cg_reset_state_clear(&state);
        return out;
    }
    if (IS("bundleRestoreResetState")) {
        cg_reset_state state = {
            .current_bundle_path = (char *)cg_or_empty(opt_str(input, "currentBundlePath")),
            .fallback_bundle_id = (char *)cg_or_empty(opt_str(input, "fallbackBundleId")),
            .next_bundle_id = (char *)opt_str(input, "nextBundleId"),
        };
        cg_store_restore_reset_state(engine, &state);
        return cj_obj();
    }
    if (IS("bundlePrepareResetTransition")) {
        cg_store_prepare_reset_state_for_transition(engine);
        return cj_obj();
    }
    if (IS("bundleDrainPendingDeletes")) {
        cg_store_drain_pending_deletes(engine);
        return cj_obj();
    }
    if (IS("bundleCleanupDownloadDirectories")) {
        const cj *ids = cj_get(input, "allowedIds");
        cg_strs allowed = {0};
        if (cj_is_arr(ids)) {
            for (size_t i = 0; i < cj_len(ids); i++) {
                const char *id = cj_as_str(cj_at(ids, i));
                if (id && !cg_strs_contains(&allowed, id)) cg_strs_push_copy(&allowed, id);
            }
        } else {
            allowed = cg_store_allowed_bundle_ids_for_cleanup(engine);
        }
        cg_store_cleanup_download_directories(engine, &allowed, NULL);
        cg_strs_free(&allowed);
        return cj_obj();
    }
    if (IS("bundleCleanupOrphanedTempFolders")) {
        cg_store_cleanup_orphaned_temp_folders(engine, NULL);
        return cj_obj();
    }

    /* ---- stats */
    if (IS("statsSend")) {
        const cj *metadata = cj_get(input, "metadata");
        const char *action = req_str(input, "action", err);
        if (!action) return NULL;
        cg_stats_send_stats_with_callback(engine, action, opt_str(input, "versionName"),
                                          opt_str(input, "oldVersionName"), cj_is_obj(metadata) ? metadata : NULL,
                                          opt_str(input, "callbackId"));
        return cj_obj();
    }
    if (IS("statsFlush")) {
        cg_stats_flush_stats(engine);
        return cj_obj();
    }
    if (IS("statsRestore")) {
        cg_stats_restore_pending_stats(engine);
        return cj_obj();
    }
    if (IS("statsPersist")) {
        cg_stats_persist_stats(engine, false);
        return cj_obj();
    }
    if (IS("statsPendingCount")) return cj_objv("count", cj_u64(cg_stats_pending_stats_count(engine)), NULL);
    if (IS("statsShutdown")) {
        cg_stats_shutdown_stats(engine);
        return cj_obj();
    }

    /* ---- backend */
    if (IS("getLatest"))
        return cg_backend_get_latest(engine, opt_str(input, "updateUrl"), opt_str(input, "channel"),
                                     opt_str(input, "appId"));
    if (IS("setChannel")) {
        const char *channel = req_str(input, "channel", err);
        if (!channel) return NULL;
        return cg_backend_set_channel(engine, channel, opt_str(input, "persistKey"),
                                      flag(input, "allowSetDefaultChannel", true),
                                      cg_or_empty(opt_str(input, "configDefaultChannel")));
    }
    if (IS("unsetChannel"))
        return cg_backend_unset_channel(engine, opt_str(input, "persistKey"),
                                        cg_or_empty(opt_str(input, "configDefaultChannel")),
                                        flag(input, "allowSetDefaultChannel", true));
    if (IS("getChannel")) return cg_backend_get_channel(engine, opt_str(input, "persistKey"));
    if (IS("listChannels")) return cg_backend_list_channels(engine);
    if (IS("bundleDownloadSize")) {
        const cj *manifest = cj_get(input, "manifest");
        cj *entries = cj_is_arr(manifest) ? cj_clone(manifest) : cj_arr();
        const char *update_url = opt_str(input, "updateUrl");
        char *url = update_url ? cg_strdup(update_url) : CG_CONFIG_DUP(engine, update_url);
        cj *out = cg_backend_bundle_download_size(engine, url, opt_str(input, "version"), entries);
        free(url);
        cj_free(entries);
        return out;
    }
    if (IS("isRemoteBlocked")) return cj_objv("blocked", cj_bool(cg_backend_is_remote_blocked(engine)), NULL);

    /* ---- downloads */
    if (IS("download")) {
        cg_download_request request;
        if (!cg_download_request_from_json(input, &request, err)) return NULL;
        cj *out = NULL;
        if (!request.manifest && !*request.url) {
            cg_err_invalid_input(err, "Download called without url");
        } else if (cg_plugin_wait_for_cleanup(engine, err)) {
            /* Like every other download path: never write while the launch cleanup sweeps. */
            cg_bundle_info installed;
            bool ok = request.manifest ? cg_manifest_download_manifest(engine, &request, &installed, err)
                                       : cg_download_download_zip(engine, &request, &installed, err);
            if (ok) out = bundle(&installed);
        }
        cg_download_request_clear(&request);
        return out;
    }
    if (IS("missingBundleFiles")) {
        const cj *manifest = cj_get(input, "manifest");
        cj *entries = cj_is_arr(manifest) ? cj_clone(manifest) : cj_arr();
        cj *out = cg_manifest_missing_bundle_files(engine, entries, cg_or_empty(opt_str(input, "sessionKey")));
        cj_free(entries);
        return out;
    }
    if (IS("runScheduledDownload")) {
        const char *id = req_str(input, "id", err);
        if (!id) return NULL;
        return cg_scheduled_run_scheduled_download(engine, id);
    }
    if (IS("stopScheduledDownload")) {
        const char *id = req_str(input, "id", err);
        if (!id) return NULL;
        cg_scheduled_stop_scheduled_download(engine, id);
        return cj_obj();
    }
    if (IS("detachScheduledDownloads")) {
        cg_scheduled_detach_scheduled_downloads(engine);
        return cj_obj();
    }
    if (IS("populateDeltaCache")) {
        const char *id = req_str(input, "id", err);
        if (!id) return NULL;
        cg_download_populate_delta_cache(engine, id);
        return cj_obj();
    }
#undef IS
    *handled = false;
    return NULL;
}

bool cg_ops_call_engine(cg_engine *engine, const char *operation, const cj *input, cj **result, cg_error *err) {
    bool handled = true;
    cj *value = dispatch(engine, operation, input, &handled, err);
    if (!handled) return false;
    *result = value;
    return true;
}
