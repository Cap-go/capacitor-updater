/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* JavaScript plugin methods (Rust engine/plugin/methods.rs). Hosts forward the call
 * arguments and settle the call with the result (`resolve` / `reject`); app store methods
 * stay native. */

#include "engine/plugin/methods.h"

#include <stdlib.h>
#include <string.h>

#include "engine/backend.h"
#include "engine/download.h"
#include "engine/engine.h"
#include "engine/manifest.h"
#include "engine/plugin/channel.h"
#include "engine/plugin/delay.h"
#include "engine/plugin/flow.h"
#include "engine/plugin/preview.h"
#include "engine/plugin/ready.h"
#include "engine/plugin/telemetry.h"
#include "engine/stats.h"
#include "engine/store.h"

/* Methods implemented by the engine (everything but listeners and app store APIs). */
static const char *const ENGINE_METHODS[] = {
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
};

/* Engine methods hosts must not run on their serial method lane (see methods.rs: network
 * bound, or waiting for `notifyAppReady` from the new page). */
static const char *const DETACHED_METHODS[] = {
    "download",
    "set",
    "reload",
    "reset",
    "checkPreviewUpdate",
    "updatePreview",
    "getLatest",
    "getMissingBundleFiles",
    "getBundleDownloadSize",
    "setChannel",
    "unsetChannel",
    "getChannel",
    "listChannels",
};

#define COUNT(array) (sizeof(array) / sizeof((array)[0]))

static cj *string_array(const char *const *items, size_t count) {
    cj *array = cj_arr();
    for (size_t i = 0; i < count; i++) cj_push(array, cj_str(items[i]));
    return array;
}

cj *cg_methods_engine_methods(void) { return string_array(ENGINE_METHODS, COUNT(ENGINE_METHODS)); }

cj *cg_methods_detached_methods(void) { return string_array(DETACHED_METHODS, COUNT(DETACHED_METHODS)); }

bool cg_methods_is_detached(const char *name) {
    if (!name) return false;
    for (size_t i = 0; i < COUNT(DETACHED_METHODS); i++)
        if (strcmp(DETACHED_METHODS[i], name) == 0) return true;
    return false;
}

static const char *string_arg(const cj *args, const char *key) { return cj_as_str(cj_get(args, key)); }

/* Option<bool>: false when absent / not a boolean. */
static bool bool_arg(const cj *args, const char *key, bool *out) { return cj_as_bool(cj_get(args, key), out); }

static bool bool_arg_or(const cj *args, const char *key, bool fallback) {
    bool value;
    return bool_arg(args, key, &value) ? value : fallback;
}

/* A string argument holding a NUL byte: the C view would stop at it and name another
 * bundle. Rust fails these ids in the store (path guards); reject without touching it. */
static bool has_nul_arg(const cj *args, const char *key) { return cj_str_has_nul(cj_get(args, key)); }

bool cg_methods_download_bundle(cg_engine *engine, const char *url, const char *version, const char *session_key,
                                const char *checksum, const cj *manifest, cg_bundle_info *out, cg_error *err) {
    if (!cg_plugin_wait_for_cleanup(engine, err)) return false;
    cg_download_request request;
    cg_download_request_init(&request);
    cg_replace(&request.url, cg_strdup(cg_or_empty(url)));
    cg_replace(&request.version, cg_strdup(cg_or_empty(version)));
    cg_replace(&request.session_key, cg_strdup(cg_or_empty(session_key)));
    cg_replace(&request.checksum, cg_strdup(cg_or_empty(checksum)));
    request.manifest = manifest ? cj_clone(manifest) : NULL;
    request.emit_events = false;
    cg_bundle_info bundle;
    bool ok = request.manifest ? cg_manifest_download_manifest(engine, &request, &bundle, err)
                               : cg_download_download_zip(engine, &request, &bundle, err);
    cg_download_request_clear(&request);
    if (!ok) return false;
    if (cg_bundle_info_is_error(&bundle)) {
        cg_err_set(err, "download_failed", "Download failed: %s",
                   cg_bundle_status_str(cg_bundle_info_status(&bundle)));
        cg_bundle_info_clear(&bundle);
        return false;
    }
    *out = bundle;
    return true;
}

static bool plugin_flag(cg_engine *engine, size_t offset) {
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    bool flag = *(bool *)((char *)&config + offset);
    cg_plugin_config_clear(&config);
    return flag;
}
#define PLUGIN_FLAG(engine, field) plugin_flag((engine), offsetof(cg_plugin_config, field))

static cj *set_url(cg_engine *engine, const cj *args, const char *method, const char *key, const char *field,
                   cg_rejection *rejection) {
    if (!PLUGIN_FLAG(engine, allow_modify_url)) {
        cg_error_log(&engine->host, "%s not allowed set allowModifyUrl in your config to true to allow it", method);
        return cg_rejection_newf(rejection,
                                 "%s called without allowModifyUrl set allowModifyUrl in your config to true to "
                                 "allow it",
                                 method);
    }
    const char *url = string_arg(args, "url");
    if (!url) return cg_rejection_newf(rejection, "%s called without url", method);
    if (PLUGIN_FLAG(engine, persist_modify_url)) cg_plugin_kv_write(engine, key, url);
    cj *settings = cj_objv(field, cj_clone(cj_get(args, "url")), NULL);
    cg_error err = CG_ERROR_INIT;
    bool ok = cg_engine_configure(engine, settings, &err);
    cj_free(settings);
    if (!ok) {
        cg_rejection_from_error(rejection, &err);
        cg_err_clear(&err);
        return NULL;
    }
    return cj_null();
}

static cj *method_download(cg_engine *engine, const cj *args, cg_rejection *rejection) {
    const char *url = string_arg(args, "url");
    if (!url) return cg_rejection_new(rejection, "Download called without url");
    const char *version = string_arg(args, "version");
    if (!version) return cg_rejection_new(rejection, "Download called without version");
    cg_info(&engine->host, "Downloading %s", url);
    const cj *manifest = cj_get(args, "manifest");
    cg_bundle_info bundle;
    cg_error err = CG_ERROR_INIT;
    bool ok = cg_methods_download_bundle(engine, url, version, cg_or_empty(string_arg(args, "sessionKey")),
                                         cg_or_empty(string_arg(args, "checksum")),
                                         cj_is_arr(manifest) ? manifest : NULL, &bundle, &err);
    if (ok) {
        cg_plugin_emit_bundle_event(engine, "updateAvailable", &bundle);
        cj *value = cg_bundle_info_to_js(&bundle);
        cg_bundle_info_clear(&bundle);
        return value;
    }
    if (cg_err_is(&err, "download_detached")) {
        /* Plugin released while the scheduled job waits: nobody listens anymore. */
        cg_rejection_from_error(rejection, &err);
        cg_err_clear(&err);
        return NULL;
    }
    cg_error_log(&engine->host, "Failed to download from: %s %s", url, cg_or_empty(err.message));
    cj *payload = cj_objv("version", cj_str(version), NULL);
    cg_host_emit(&engine->host, "downloadFailed", payload);
    cj_free(payload);
    cg_stats_send_stats(engine, "download_fail", version, NULL, NULL);
    cg_rejection_newf(rejection, "Failed to download from: %s - %s", url, cg_or_empty(err.message));
    cg_err_clear(&err);
    return NULL;
}

static cj *method_set_bundle_error(cg_engine *engine, const cj *args, cg_rejection *rejection) {
    if (!PLUGIN_FLAG(engine, allow_manual_bundle_error))
        return cg_rejection_new(
            rejection, "setBundleError not allowed. Set allowManualBundleError to true in your config to enable it.");
    const char *id = string_arg(args, "id");
    if (!id) return cg_rejection_new(rejection, "setBundleError called without id");
    cg_bundle_info bundle;
    cg_store_get_bundle_info(engine, id, &bundle);
    bool builtin = cg_bundle_info_is_builtin(&bundle);
    bool missing = has_nul_arg(args, "id") || cg_bundle_info_is_unknown(&bundle) ||
                   (!builtin && !cg_store_has_stored_bundle_info(engine, id));
    cg_bundle_info_clear(&bundle);
    if (missing) return cg_rejection_newf(rejection, "Bundle %s does not exist", id);
    if (builtin) return cg_rejection_new(rejection, "Cannot set builtin bundle to error state");
    if (cg_plugin_is_auto_update_enabled(engine))
        cg_warn(&engine->host,
                "setBundleError used while autoUpdate is enabled; this method is intended for manual mode");
    cg_store_set_error(engine, id);
    cg_store_get_bundle_info(engine, id, &bundle);
    cj *value = cj_objv("bundle", cg_bundle_info_to_js(&bundle), NULL);
    cg_bundle_info_clear(&bundle);
    return value;
}

static cj *method_next(cg_engine *engine, const cj *args, cg_rejection *rejection) {
    const char *id = string_arg(args, "id");
    if (!id) return cg_rejection_new(rejection, "Next called without id");
    cg_info(&engine->host, "Setting next active id %s", id);
    if (has_nul_arg(args, "id") || !cg_store_set_next_bundle(engine, id))
        return cg_rejection_newf(rejection, "Set next id failed. Bundle %s does not exist.", id);
    cg_bundle_info bundle;
    cg_store_get_bundle_info(engine, id, &bundle);
    cj *value = cg_bundle_info_to_js(&bundle);
    cg_bundle_info_clear(&bundle);
    return value;
}

static cj *method_set(cg_engine *engine, const cj *args, cg_rejection *rejection) {
    const char *id = string_arg(args, "id");
    if (!id) return cg_rejection_new(rejection, "Set called without id");
    if (has_nul_arg(args, "id")) {
        cg_info(&engine->host, "Setting active bundle %s", id);
        cg_error_log(&engine->host, "Invalid bundle id");
        return cg_rejection_newf(rejection, "Update failed, id %s does not exist.", id);
    }
    cg_bundle_info bundle;
    char *error = NULL;
    if (!cg_ready_set_and_reload(engine, id, &bundle, &error)) {
        cg_rejection_new(rejection, error);
        free(error);
        return NULL;
    }
    cg_bundle_info_clear(&bundle);
    return cj_null();
}

static cj *method_delete(cg_engine *engine, const cj *args, cg_rejection *rejection) {
    const char *id = string_arg(args, "id");
    if (!id) return cg_rejection_new(rejection, "Delete called without id");
    if (!has_nul_arg(args, "id") && cg_store_delete_bundle(engine, id, true, true)) return cj_null();
    return cg_rejection_newf(rejection,
                             "Delete failed, id %s does not exist or it cannot be deleted (perhaps it is the 'next' "
                             "bundle)",
                             id);
}

static cj *method_list(cg_engine *engine, const cj *args) {
    cg_bundle_list list;
    cg_store_list(engine, bool_arg_or(args, "raw", false), &list);
    cj *bundles = cj_arr();
    for (size_t i = 0; i < list.len; i++) cj_push(bundles, cg_bundle_info_to_js(&list.items[i]));
    cg_bundle_list_clear(&list);
    return cj_objv("bundles", bundles, NULL);
}

static cj *method_current(cg_engine *engine) {
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    cj *value = cj_objv("bundle", cg_bundle_info_to_js(&current), "native", cj_str(config.native_version), NULL);
    cg_plugin_config_clear(&config);
    cg_bundle_info_clear(&current);
    return value;
}

static cj *method_set_custom_id(cg_engine *engine, const cj *args, cg_rejection *rejection) {
    const char *custom_id = string_arg(args, "customId");
    if (!custom_id) return cg_rejection_new(rejection, "setCustomId called without customId");
    cj *settings = cj_objv("customId", cj_clone(cj_get(args, "customId")), NULL);
    cg_error err = CG_ERROR_INIT;
    bool ok = cg_engine_configure(engine, settings, &err);
    cj_free(settings);
    if (!ok) {
        cg_rejection_from_error(rejection, &err);
        cg_err_clear(&err);
        return NULL;
    }
    if (PLUGIN_FLAG(engine, persist_custom_id)) cg_plugin_kv_write(engine, CG_KEY_CUSTOM_ID, *custom_id ? custom_id : NULL);
    return cj_null();
}

static cj *config_string(cg_engine *engine, const char *key, size_t offset) {
    char *value = cg_engine_config_dup(engine, offset);
    return cj_objv(key, cj_str_own(value), NULL);
}

static cj *method_set_shake(cg_engine *engine, const cj *args, bool channel_selector, cg_rejection *rejection) {
    bool enabled;
    if (!bool_arg(args, "enabled", &enabled))
        return cg_rejection_new(rejection, channel_selector ? "setShakeChannelSelector called without enabled parameter"
                                                            : "setShakeMenu called without enabled parameter");
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    if (channel_selector) state->shake_channel_selector_enabled = enabled;
    else state->shake_menu_enabled = enabled;
    cg_plugin_unlock_state(engine);
    cg_plugin_sync_shake_menu(engine);
    return cj_null();
}

cj *cg_methods_run_plugin_method(cg_engine *engine, const char *name, const cj *args_in, cg_rejection *rejection) {
    cj empty = {.type = CJ_OBJECT};
    const cj *args = cj_is_obj(args_in) ? args_in : &empty;
    name = cg_or_empty(name);
#define IS(method) (strcmp(name, method) == 0)
    if (IS("notifyAppReady")) {
        int64_t generation;
        bool reported = cj_as_i64(cj_get(args, "loadGeneration"), &generation);
        return cg_ready_notify_app_ready(engine, reported ? &generation : NULL);
    }
    if (IS("setUpdateUrl")) return set_url(engine, args, "setUpdateUrl", CG_KEY_UPDATE_URL, "updateUrl", rejection);
    if (IS("setStatsUrl")) return set_url(engine, args, "setStatsUrl", CG_KEY_STATS_URL, "statsUrl", rejection);
    if (IS("setChannelUrl"))
        return set_url(engine, args, "setChannelUrl", CG_KEY_CHANNEL_URL, "channelUrl", rejection);
    if (IS("download")) return method_download(engine, args, rejection);
    if (IS("next")) return method_next(engine, args, rejection);
    if (IS("set")) return method_set(engine, args, rejection);
    if (IS("startPreviewSession")) return cg_preview_method_start_preview_session(engine, args, rejection);
    if (IS("listPreviews")) return cg_preview_method_list_previews(engine, rejection);
    if (IS("setPreview")) return cg_preview_method_set_preview(engine, args, rejection);
    if (IS("resetPreview")) return cg_preview_method_reset_preview(engine, rejection);
    if (IS("deletePreview")) return cg_preview_method_delete_preview(engine, args, rejection);
    if (IS("checkPreviewUpdate")) return cg_preview_method_preview_update(engine, args, false, rejection);
    if (IS("updatePreview")) return cg_preview_method_preview_update(engine, args, true, rejection);
    if (IS("delete")) return method_delete(engine, args, rejection);
    if (IS("setBundleError")) return method_set_bundle_error(engine, args, rejection);
    if (IS("list")) return method_list(engine, args);
    if (IS("reset")) {
        bool to_last_successful = bool_arg_or(args, "toLastSuccessful", false);
        bool use_pending = bool_arg_or(args, "usePendingBundle", false);
        if (cg_ready_perform_reset(engine, to_last_successful, use_pending, false)) return cj_null();
        return cg_rejection_new(rejection, "Reset failed");
    }
    if (IS("current")) return method_current(engine);
    if (IS("reload")) {
        char *error = NULL;
        if (cg_ready_reload_with_pending(engine, &error)) return cj_null();
        cg_rejection_new(rejection, error);
        free(error);
        return NULL;
    }
    if (IS("setMultiDelay")) {
        const cj *conditions = cj_get(args, "delayConditions");
        if (!cj_is_arr(conditions)) return cg_rejection_new(rejection, "setMultiDelay called without delayCondition");
        if (cg_delay_set_multi_delay(engine, conditions)) return cj_null();
        return cg_rejection_new(rejection, "Failed to delay update");
    }
    if (IS("cancelDelay")) {
        if (cg_delay_cancel_delay(engine, "JS")) return cj_null();
        return cg_rejection_new(rejection, "Failed to cancel delay");
    }
    if (IS("triggerUpdateCheck")) {
        const char *status = cg_flow_trigger_update_check(engine);
        return cj_objv("status", cj_str(status), "queued", cj_bool(strcmp(status, "queued") == 0), NULL);
    }
    if (IS("getLatest")) return cg_channel_method_get_latest(engine, args, rejection);
    if (IS("getMissingBundleFiles")) {
        const cj *manifest = cj_get(args, "manifest");
        if (!cj_is_arr(manifest)) return cg_rejection_new(rejection, "getMissingBundleFiles called without manifest");
        return cg_manifest_missing_bundle_files(engine, manifest, cg_or_empty(string_arg(args, "sessionKey")));
    }
    if (IS("getBundleDownloadSize")) {
        const cj *manifest = cj_get(args, "manifest");
        if (!cj_is_arr(manifest)) return cg_rejection_new(rejection, "getBundleDownloadSize called without manifest");
        char *update_url = CG_CONFIG_DUP(engine, update_url);
        cj *value = cg_backend_bundle_download_size(engine, update_url, string_arg(args, "version"), manifest);
        free(update_url);
        return value;
    }
    if (IS("setChannel")) return cg_channel_method_set_channel(engine, args, rejection);
    if (IS("unsetChannel")) return cg_channel_method_unset_channel(engine, args, rejection);
    if (IS("getChannel")) return cg_channel_method_get_channel(engine, rejection);
    if (IS("listChannels")) return cg_channel_method_list_channels(engine, rejection);
    if (IS("setCustomId")) return method_set_custom_id(engine, args, rejection);
    if (IS("getBuiltinVersion")) return config_string(engine, "version", offsetof(cg_engine_config, version_build));
    if (IS("getDeviceId")) return config_string(engine, "deviceId", offsetof(cg_engine_config, device_id));
    if (IS("getPluginVersion")) return config_string(engine, "version", offsetof(cg_engine_config, plugin_version));
    if (IS("isAutoUpdateEnabled")) return cj_objv("enabled", cj_bool(cg_plugin_is_auto_update_enabled(engine)), NULL);
    if (IS("isAutoUpdateAvailable"))
        return cj_objv("available", cj_bool(!PLUGIN_FLAG(engine, server_url_configured)), NULL);
    if (IS("getNextBundle")) {
        cg_bundle_info next;
        if (!cg_store_next_bundle(engine, &next)) return cj_null();
        cj *value = cg_bundle_info_to_js(&next);
        cg_bundle_info_clear(&next);
        return value;
    }
    if (IS("getFailedUpdate")) return cg_ready_take_failed_update(engine);
    if (IS("setShakeMenu")) return method_set_shake(engine, args, false, rejection);
    if (IS("isShakeMenuEnabled")) {
        cg_plugin_state *state = cg_plugin_lock_state(engine);
        cj *value = cj_objv("enabled", cj_bool(state->shake_menu_enabled), "gesture", cj_str(state->shake_menu_gesture),
                            NULL);
        cg_plugin_unlock_state(engine);
        return value;
    }
    if (IS("setShakeChannelSelector")) return method_set_shake(engine, args, true, rejection);
    if (IS("isShakeChannelSelectorEnabled")) {
        bool enabled = cg_plugin_lock_state(engine)->shake_channel_selector_enabled;
        cg_plugin_unlock_state(engine);
        return cj_objv("enabled", cj_bool(enabled), NULL);
    }
    if (IS("getAppId")) return config_string(engine, "appId", offsetof(cg_engine_config, app_id));
    if (IS("setAppId")) {
        if (!PLUGIN_FLAG(engine, allow_modify_app_id))
            return cg_rejection_new(
                rejection,
                "setAppId called without allowModifyAppId set allowModifyAppId in your config to true to allow it");
        const char *app_id = string_arg(args, "appId");
        if (!app_id) return cg_rejection_new(rejection, "setAppId called without appId");
        cg_preview_set_active_app_id(engine, app_id);
        return cj_null();
    }
    if (IS("reportWebViewError")) {
        cg_telemetry_report_webview_error(engine, args);
        return cj_null();
    }
#undef IS
    return cg_rejection_newf(rejection, "Unknown plugin method: %s", name);
}
