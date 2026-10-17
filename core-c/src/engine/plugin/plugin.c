/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* The Capacitor plugin layer: configuration, state and shared helpers (Rust
 * engine/plugin/mod.rs). */

#include "engine/plugin/plugin.h"

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "engine/engine.h"
#include "engine/plugin/flow.h"
#include "engine/plugin/methods.h"
#include "policy.h"
#include "text.h"

/* ---------------------------------------------------------------- config parsing helpers */

bool cg_plugin_object_bool(const cj *object, const char *key, bool fallback) {
    const cj *value = cj_get(object, key);
    bool flag;
    if (cj_as_bool(value, &flag)) return flag;
    const char *text = cj_as_str(value);
    if (cg_eq(text, "true")) return true;
    if (cg_eq(text, "false")) return false;
    return fallback;
}

int64_t cg_plugin_object_i64(const cj *object, const char *key, int64_t fallback) {
    const cj *value = cj_get(object, key);
    if (cj_is_number(value)) {
        int64_t number;
        if (cj_as_i64(value, &number)) return number;
        double real;
        if (cj_as_f64(value, &real)) return cg_text_f64_to_i64_saturating(real);
        return fallback;
    }
    const char *text = cj_as_str(value);
    if (text) {
        char *trimmed = cg_trim(text);
        int64_t number;
        bool parsed = cg_parse_i64(trimmed, &number);
        free(trimmed);
        return parsed ? number : fallback;
    }
    return fallback;
}

char *cg_plugin_object_str(const cj *object, const char *key) { return cg_strdup(cj_get_str(object, key)); }

/* ---------------------------------------------------------------- PluginConfig */

void cg_plugin_config_from_json(const cj *config, const cj *native, cg_strs *warnings, cg_plugin_config *out) {
    cj empty = {.type = CJ_OBJECT};
    const cj *object = cj_is_obj(config) ? config : &empty;
    if (!cj_is_obj(native)) native = &empty;
    memset(out, 0, sizeof *out);

    /* autoUpdate: boolean (legacy, combined with directUpdate) or a mode string. */
    const cj *auto_update = cj_get(object, "autoUpdate");
    const char *configured = NULL;
    bool flag;
    if (cj_is_str(auto_update)) configured = cj_as_str(auto_update);
    else if (cj_as_bool(auto_update, &flag)) configured = flag ? "true" : "false";
    if (configured && *configured && strcmp(configured, "true") != 0 && strcmp(configured, "false") != 0) {
        const char *mode = cg_policy_normalized_auto_update_mode(configured);
        if (strcmp(mode, configured) != 0 && warnings)
            cg_strs_push(warnings,
                         cg_fmt("Invalid autoUpdate value: \"%s\". Supported values are: true, false, \"off\", "
                                "\"atBackground\", \"atInstall\", \"onLaunch\", \"always\", \"onlyDownload\". "
                                "Defaulting to \"atBackground\".",
                                configured));
        out->auto_update_mode = cg_strdup(mode);
    } else {
        bool enabled = !configured || strcmp(configured, "true") == 0;
        if (enabled) {
            const cj *direct_value = cj_get(object, "directUpdate");
            const char *direct = CG_DIRECT_UPDATE_DISABLED;
            const char *text = cj_as_str(direct_value);
            if (text) {
                if (strcmp(text, "true") == 0) {
                    direct = CG_AUTO_UPDATE_ALWAYS;
                } else if (strcmp(text, "false") == 0 || strcmp(text, "atInstall") == 0 ||
                           strcmp(text, "onLaunch") == 0 || strcmp(text, "always") == 0) {
                    direct = text;
                } else {
                    if (warnings)
                        cg_strs_push(warnings,
                                     cg_fmt("Invalid directUpdate value: \"%s\". Supported values are: false, true, "
                                            "\"always\", \"atInstall\", \"onLaunch\". Defaulting to \"false\".",
                                            text));
                    direct = CG_DIRECT_UPDATE_DISABLED;
                }
            } else if (cj_as_bool(direct_value, &flag) && flag) {
                direct = CG_AUTO_UPDATE_ALWAYS;
            }
            out->auto_update_mode = cg_strdup(cg_policy_auto_update_mode_for_legacy_direct_update_mode(direct));
        } else {
            out->auto_update_mode = cg_strdup(CG_AUTO_UPDATE_OFF);
        }
    }
    out->direct_update_mode = cg_strdup(cg_policy_direct_update_mode_for_auto_update_mode(out->auto_update_mode));

    int64_t value = cg_plugin_object_i64(object, "appReadyTimeout", 10000);
    out->app_ready_timeout_ms = (uint64_t)(value < 1000 ? 1000 : value);
    out->auto_delete_failed = cg_plugin_object_bool(object, "autoDeleteFailed", true);
    out->auto_delete_previous = cg_plugin_object_bool(object, "autoDeletePrevious", true);
    out->reset_when_update = cg_plugin_object_bool(object, "resetWhenUpdate", true);
    out->auto_splashscreen = cg_plugin_object_bool(object, "autoSplashscreen", false);
    value = cg_plugin_object_i64(object, "autoSplashscreenTimeout", 10000);
    out->auto_splashscreen_timeout_ms = (uint64_t)(value < 0 ? 0 : value);
    value = cg_policy_normalized_period_check_delay_seconds(cg_plugin_object_i64(object, "periodCheckDelay", 0));
    out->period_check_delay_s = (uint64_t)(value < 0 ? 0 : value);
    out->allow_modify_url = cg_plugin_object_bool(object, "allowModifyUrl", false);
    out->allow_modify_app_id = cg_plugin_object_bool(object, "allowModifyAppId", false);
    out->allow_manual_bundle_error = cg_plugin_object_bool(object, "allowManualBundleError", false);
    out->allow_preview = cg_plugin_object_bool(object, "allowPreview", false);
    out->persist_custom_id = cg_plugin_object_bool(object, "persistCustomId", false);
    out->persist_modify_url = cg_plugin_object_bool(object, "persistModifyUrl", false);
    out->allow_set_default_channel = cg_plugin_object_bool(object, "allowSetDefaultChannel", true);
    out->persist_default_channel_on_reinstall =
        cg_plugin_object_bool(object, "persistDefaultChannelOnReinstall", true);
    out->default_channel = cg_strdup(cg_or_empty(cj_get_str(object, "defaultChannel")));
    out->keep_url_path_after_reload = cg_plugin_object_bool(object, "keepUrlPathAfterReload", false);
    out->shake_menu = cg_plugin_object_bool(object, "shakeMenu", false);
    out->shake_menu_gesture =
        cg_strdup(cg_policy_normalized_shake_menu_gesture(cj_get_str(object, "shakeMenuGesture")));
    out->allow_shake_channel_selector = cg_plugin_object_bool(object, "allowShakeChannelSelector", false);
    out->server_url_configured = cj_get_bool(native, "serverUrlConfigured", false);
    const char *version = cj_get_str(object, "version");
    const char *native_version = cj_get_str(native, "versionName");
    if (version && *version) out->native_version = cg_strdup(version);
    else if (native_version && *native_version) out->native_version = cg_strdup(native_version);
    else out->native_version = cg_strdup("");
    out->native_build = cg_strdup(cg_or_empty(cj_get_str(native, "versionCode")));
    out->no_backup_dir = cg_strdup(cg_or_empty(cj_get_str(native, "noBackupDir")));
    out->reload_waits_for_app_ready = cj_get_bool(native, "reloadWaitsForAppReady", false);
    uint64_t min_timeout;
    out->pending_bundle_min_timeout_ms = cj_as_u64(cj_get(native, "pendingBundleMinAppReadyTimeoutMs"), &min_timeout)
                                             ? min_timeout
                                             : CG_PENDING_BUNDLE_MIN_APP_READY_TIMEOUT_MS;
    out->track_unclean_exits = cj_get_bool(native, "trackUncleanExits", false);
}

void cg_plugin_config_copy(cg_plugin_config *out, const cg_plugin_config *config) {
    *out = *config;
    out->auto_update_mode = cg_strdup(config->auto_update_mode);
    out->direct_update_mode = cg_strdup(config->direct_update_mode);
    out->default_channel = cg_strdup(config->default_channel);
    out->shake_menu_gesture = cg_strdup(config->shake_menu_gesture);
    out->native_version = cg_strdup(config->native_version);
    out->native_build = cg_strdup(config->native_build);
    out->no_backup_dir = cg_strdup(config->no_backup_dir);
}

void cg_plugin_config_clear(cg_plugin_config *config) {
    free(config->auto_update_mode);
    free(config->direct_update_mode);
    free(config->default_channel);
    free(config->shake_menu_gesture);
    free(config->native_version);
    free(config->native_build);
    free(config->no_backup_dir);
    memset(config, 0, sizeof *config);
}

bool cg_plugin_config_auto_update_enabled(const cg_plugin_config *config) {
    return cg_policy_is_auto_update_mode_enabled(config->auto_update_mode);
}

bool cg_plugin_config_track_unclean_exits(const cg_plugin_config *config) { return config->track_unclean_exits; }

bool cg_plugin_config_should_set_next_bundle(const cg_plugin_config *config) {
    return cg_policy_should_auto_update_mode_set_next_bundle(config->auto_update_mode);
}

/* ---------------------------------------------------------------- PluginState */

bool cg_plugin_state_stat_percent(const cg_plugin_state *state, const char *id, int64_t *out) {
    for (size_t i = 0; i < state->last_notified_stat_percent.len; i++) {
        if (strcmp(state->last_notified_stat_percent.items[i].id, id) == 0) {
            *out = state->last_notified_stat_percent.items[i].percent;
            return true;
        }
    }
    return false;
}

void cg_plugin_state_set_stat_percent(cg_plugin_state *state, const char *id, int64_t percent) {
    for (size_t i = 0; i < state->last_notified_stat_percent.len; i++) {
        if (strcmp(state->last_notified_stat_percent.items[i].id, id) == 0) {
            state->last_notified_stat_percent.items[i].percent = percent;
            return;
        }
    }
    if (state->last_notified_stat_percent.len == state->last_notified_stat_percent.cap) {
        size_t cap = state->last_notified_stat_percent.cap ? state->last_notified_stat_percent.cap * 2 : 4;
        state->last_notified_stat_percent.items =
            cg_realloc(state->last_notified_stat_percent.items, cap * sizeof(cg_stat_percent));
        state->last_notified_stat_percent.cap = cap;
    }
    state->last_notified_stat_percent.items[state->last_notified_stat_percent.len++] =
        (cg_stat_percent){cg_strdup(id), percent};
}

void cg_plugin_state_remove_stat_percent(cg_plugin_state *state, const char *id) {
    for (size_t i = 0; i < state->last_notified_stat_percent.len; i++) {
        if (strcmp(state->last_notified_stat_percent.items[i].id, id) == 0) {
            free(state->last_notified_stat_percent.items[i].id);
            state->last_notified_stat_percent.items[i] =
                state->last_notified_stat_percent.items[--state->last_notified_stat_percent.len];
            return;
        }
    }
}

void cg_plugin_state_set_cycle_download(cg_plugin_state *state, const cg_cycle_download *download) {
    free(state->cycle_download.version);
    memset(&state->cycle_download, 0, sizeof state->cycle_download);
    state->has_cycle_download = download != NULL;
    if (download) {
        state->cycle_download = *download;
        state->cycle_download.version = cg_strdup(cg_or_empty(download->version));
    }
}

static void state_init(cg_plugin_state *state) {
    memset(state, 0, sizeof *state);
    cg_plugin_config_from_json(NULL, NULL, NULL, &state->config);
    state->shake_menu_gesture = cg_strdup("");
}

static void state_clear(cg_plugin_state *state) {
    cg_plugin_config_clear(&state->config);
    free(state->shake_menu_gesture);
    for (size_t i = 0; i < state->last_notified_stat_percent.len; i++)
        free(state->last_notified_stat_percent.items[i].id);
    free(state->last_notified_stat_percent.items);
    free(state->cycle_download.version);
    memset(state, 0, sizeof *state);
}

/* ---------------------------------------------------------------- Plugin */

void cg_plugin_init(cg_plugin *plugin) {
    cg_mutex_init(&plugin->state_lock);
    state_init(&plugin->state);
    cg_mutex_init(&plugin->ready.lock);
    cg_cond_init(&plugin->ready.changed);
    plugin->ready.signals = 0;
    plugin->ready.has_pending = false;
    plugin->ready.pending = 0;
    cg_mutex_init(&plugin->cleanup.lock);
    cg_cond_init(&plugin->cleanup.changed);
    plugin->cleanup.complete = false;
    atomic_init(&plugin->app_ready_check, 0);
    atomic_init(&plugin->splash_timer, 0);
    atomic_init(&plugin->periodic_started, false);
    cg_mutex_init(&plugin->cycle);
    cg_mutex_init(&plugin->confirmation);
    cg_mutex_init(&plugin->lifecycle_lock);
    plugin->lifecycle_head = plugin->lifecycle_tail = NULL;
    plugin->lifecycle_draining = false;
}

static void task_free(cg_lifecycle_task *task) {
    if (task->drop_ctx) task->drop_ctx(task->ctx);
    free(task);
}

void cg_plugin_destroy(cg_plugin *plugin) {
    while (plugin->lifecycle_head) {
        cg_lifecycle_task *task = plugin->lifecycle_head;
        plugin->lifecycle_head = task->next;
        task_free(task);
    }
    plugin->lifecycle_tail = NULL;
    state_clear(&plugin->state);
    cg_mutex_destroy(&plugin->state_lock);
    cg_mutex_destroy(&plugin->ready.lock);
    cg_cond_destroy(&plugin->ready.changed);
    cg_mutex_destroy(&plugin->cleanup.lock);
    cg_cond_destroy(&plugin->cleanup.changed);
    cg_mutex_destroy(&plugin->cycle);
    cg_mutex_destroy(&plugin->confirmation);
    cg_mutex_destroy(&plugin->lifecycle_lock);
}

/* ---------------------------------------------------------------- Rejection */

cj *cg_rejection_new(cg_rejection *rejection, const char *message) {
    cg_rejection_clear(rejection);
    rejection->message = cg_strdup(cg_or_empty(message));
    return NULL;
}

cj *cg_rejection_newf(cg_rejection *rejection, const char *format, ...) {
    va_list args;
    va_start(args, format);
    char *message = cg_vfmt(format, args);
    va_end(args);
    cg_rejection_clear(rejection);
    rejection->message = message;
    return NULL;
}

cj *cg_rejection_coded(cg_rejection *rejection, const char *message, const char *code, const char *error) {
    cg_rejection_clear(rejection);
    rejection->message = cg_strdup(cg_or_empty(message));
    rejection->code = cg_strdup(cg_or_empty(code));
    rejection->data = cj_objv("message", cj_str(rejection->message), "error", cj_str(cg_or_empty(error)), NULL);
    return NULL;
}

cj *cg_rejection_from_error(cg_rejection *rejection, const cg_error *error) {
    return cg_rejection_new(rejection, error ? error->message : "");
}

cj *cg_rejection_to_json(const cg_rejection *rejection) {
    cj *object = cj_objv("message", cj_str(cg_or_empty(rejection->message)), NULL);
    if (rejection->code) cj_set(object, "code", cj_str(rejection->code));
    if (rejection->data) cj_set(object, "data", cj_clone(rejection->data));
    return object;
}

bool cg_rejection_is_set(const cg_rejection *rejection) { return rejection->message != NULL; }

void cg_rejection_clear(cg_rejection *rejection) {
    free(rejection->message);
    free(rejection->code);
    cj_free(rejection->data);
    memset(rejection, 0, sizeof *rejection);
}

/* ---------------------------------------------------------------- helpers */

int64_t cg_plugin_now_ms(void) { return cg_now_ms(); }

char *cg_plugin_iso_now(void) { return cg_bundle_iso8601_now(); }

char *cg_plugin_normalized_optional(const char *value) {
    if (!value) return NULL;
    char *trimmed = cg_trim(value);
    if (!*trimmed || cg_eq_nocase(trimmed, "undefined") || cg_eq_nocase(trimmed, "null")) {
        free(trimmed);
        return NULL;
    }
    return trimmed;
}

cg_plugin_state *cg_plugin_lock_state(cg_engine *engine) {
    cg_lock(&engine->plugin.state_lock);
    return &engine->plugin.state;
}

void cg_plugin_unlock_state(cg_engine *engine) { cg_unlock(&engine->plugin.state_lock); }

void cg_plugin_plugin_config(cg_engine *engine, cg_plugin_config *out) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    cg_plugin_config_copy(out, &state->config);
    cg_plugin_unlock_state(engine);
}

cj *cg_plugin_hook(cg_engine *engine, const char *name, cj *payload) {
    cj *reply = cg_host_hook(&engine->host, name, payload);
    cj_free(payload);
    return reply;
}

void cg_plugin_emit_bundle_event(cg_engine *engine, const char *event, const cg_bundle_info *bundle) {
    cj *payload = cj_objv("bundle", cg_bundle_info_to_js(bundle), NULL);
    cg_host_emit(&engine->host, event, payload);
    cj_free(payload);
}

static void emit_retained_bundle(cg_engine *engine, const char *event, const cg_bundle_info *bundle) {
    cj *payload = cj_objv("bundle", cg_bundle_info_to_js(bundle), NULL);
    cg_host_emit_retained(&engine->host, event, payload);
    cj_free(payload);
}

void cg_plugin_emit_set_event(cg_engine *engine, const cg_bundle_info *bundle) {
    emit_retained_bundle(engine, "set", bundle);
}

void cg_plugin_emit_only_download_update_available(cg_engine *engine, const cg_bundle_info *bundle) {
    emit_retained_bundle(engine, "updateAvailable", bundle);
}

bool cg_plugin_kv_flag(cg_engine *engine, const char *key, bool *out) {
    char *value = cg_host_kv_get(&engine->host, key, NULL);
    if (!value) return false;
    *out = strcmp(value, "true") == 0 || strcmp(value, "1") == 0;
    free(value);
    return true;
}

char *cg_plugin_kv_text(cg_engine *engine, const char *key) { return cg_host_kv_get(&engine->host, key, NULL); }

void cg_plugin_kv_write(cg_engine *engine, const char *key, const char *value) {
    cg_host_kv_set(&engine->host, key, value);
}

void cg_plugin_kv_write_flag(cg_engine *engine, const char *key, bool value) {
    cg_host_kv_set(&engine->host, key, value ? "true" : "false");
}

bool cg_plugin_is_preview_state_active(cg_engine *engine) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    bool enabled = state->preview_session_enabled, leaving = state->leaving_preview_for_link;
    cg_plugin_unlock_state(engine);
    return enabled || leaving || CG_CONFIG_FLAG(engine, preview_session);
}

bool cg_plugin_block_for_preview(cg_engine *engine) {
    if (!cg_plugin_is_preview_state_active(engine)) return false;
    cg_info(&engine->host, "Preview session is active. Skipping normal auto-update work.");
    return true;
}

void cg_plugin_set_engine_preview_session(cg_engine *engine, bool active) {
    cg_engine_config *config = cg_engine_config_begin(engine);
    config->preview_session = active;
    cg_engine_config_commit(engine, config);
}

bool cg_plugin_is_auto_update_enabled(cg_engine *engine) {
    if (cg_plugin_is_preview_state_active(engine)) return false;
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    if (config.server_url_configured)
        cg_warn(&engine->host, "AutoUpdate is automatic disabled when serverUrl is set.");
    char *update_url = CG_CONFIG_DUP(engine, update_url);
    bool enabled = cg_plugin_config_auto_update_enabled(&config) && *update_url && !config.server_url_configured;
    free(update_url);
    cg_plugin_config_clear(&config);
    return enabled;
}

void cg_plugin_sync_shake_menu(cg_engine *engine) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    bool enabled = state->shake_menu_enabled, selector = state->shake_channel_selector_enabled;
    char *gesture = cg_strdup(state->shake_menu_gesture);
    cg_plugin_unlock_state(engine);
    cj_free(cg_plugin_hook(engine, CG_HOOK_SHAKE_MENU,
                           cj_objv("enabled", cj_bool(enabled), "channelSelector", cj_bool(selector), "gesture",
                                   cj_str_own(gesture), NULL)));
}

void cg_plugin_preview_loader(cg_engine *engine, bool show, const char *reason) {
    cj_free(cg_plugin_hook(engine, CG_HOOK_PREVIEW_LOADER,
                           cj_objv("action", cj_str(show ? "show" : "hide"), "reason", cj_str(reason), NULL)));
}

void cg_plugin_mark_cleanup(cg_engine *engine, bool complete) {
    cg_lock(&engine->plugin.cleanup.lock);
    engine->plugin.cleanup.complete = complete;
    cg_unlock(&engine->plugin.cleanup.lock);
    cg_cond_broadcast(&engine->plugin.cleanup.changed);
}

#define CLEANUP_WAIT_MS 120000

bool cg_plugin_wait_for_cleanup(cg_engine *engine, cg_error *err) {
    cg_release_method_lane();
    cg_cleanup_gate *gate = &engine->plugin.cleanup;
    cg_lock(&gate->lock);
    if (gate->complete) {
        cg_unlock(&gate->lock);
        return true;
    }
    bool loaded = cg_plugin_lock_state(engine)->loaded;
    cg_plugin_unlock_state(engine);
    if (!loaded) {
        cg_unlock(&gate->lock);
        return true;
    }
    cg_info(&engine->host, "Waiting for cleanup to complete before starting download...");
    int64_t deadline = cg_mono_ms() + CLEANUP_WAIT_MS;
    while (!gate->complete) {
        int64_t left = deadline - cg_mono_ms();
        if (left <= 0) break;
        cg_cond_wait_ms(&gate->changed, &gate->lock, left);
    }
    if (!gate->complete) {
        cg_unlock(&gate->lock);
        return cg_err_set(err, "cleanup_timeout", "Cleanup did not finish before download");
    }
    cg_info(&engine->host, "Cleanup finished, proceeding with download");
    cg_unlock(&gate->lock);
    return true;
}

cj *cg_plugin_plugin_load(cg_engine *engine, const cj *input, cg_error *err) {
    return cg_flow_load_plugin(engine, input, err);
}

cj *cg_plugin_plugin_method(cg_engine *engine, const char *name, const cj *args) {
    bool lane = cg_methods_is_detached(name);
    if (lane) cg_method_lane_hold(&engine->host);
    cg_rejection rejection = CG_REJECTION_INIT;
    cj *value = cg_methods_run_plugin_method(engine, name, args, &rejection);
    cj *out;
    if (value) {
        out = cj_objv("resolve", value, NULL);
    } else {
        out = cj_objv("reject", cg_rejection_to_json(&rejection), NULL);
    }
    cg_rejection_clear(&rejection);
    if (lane) cg_method_lane_drop();
    return out;
}

void cg_plugin_plugin_foreground_for_tests(cg_engine *engine) { cg_flow_app_moved_to_foreground(engine); }

void cg_plugin_plugin_periodic_tick_for_tests(cg_engine *engine) { cg_flow_periodic_tick(engine); }

void cg_plugin_wait_for_cleanup_for_tests(cg_engine *engine) {
    cg_error err = CG_ERROR_INIT;
    cg_plugin_wait_for_cleanup(engine, &err);
    cg_err_clear(&err);
}

void cg_plugin_plugin_terminate_for_tests(cg_engine *engine) { cg_flow_app_terminated(engine); }

/* ---------------------------------------------------------------- lifecycle queue */

static void lifecycle_main(cg_engine_weak *weak, void *ctx) {
    while (true) {
        cg_engine *engine = cg_engine_upgrade(weak);
        if (!engine) return;
        cg_lock(&engine->plugin.lifecycle_lock);
        cg_lifecycle_task *next = engine->plugin.lifecycle_head;
        if (next) {
            engine->plugin.lifecycle_head = next->next;
            if (!engine->plugin.lifecycle_head) engine->plugin.lifecycle_tail = NULL;
        }
        engine->plugin.lifecycle_draining = next != NULL;
        cg_unlock(&engine->plugin.lifecycle_lock);
        if (next) {
            next->run(engine, next->ctx);
            task_free(next);
        }
        cg_engine_release(engine);
        if (!next) return;
    }
}

void cg_plugin_spawn_plugin_task(cg_engine *engine, void (*task)(cg_engine *engine, void *ctx), void *ctx,
                                 void (*drop_ctx)(void *ctx)) {
    cg_lifecycle_task *item = cg_calloc(1, sizeof(cg_lifecycle_task));
    item->run = task;
    item->ctx = ctx;
    item->drop_ctx = drop_ctx;
    cg_plugin *plugin = &engine->plugin;
    cg_lock(&plugin->lifecycle_lock);
    if (plugin->lifecycle_tail) plugin->lifecycle_tail->next = item;
    else plugin->lifecycle_head = item;
    plugin->lifecycle_tail = item;
    if (plugin->lifecycle_draining) {
        cg_unlock(&plugin->lifecycle_lock);
        return;
    }
    plugin->lifecycle_draining = true;
    cg_unlock(&plugin->lifecycle_lock);
    if (cg_engine_spawn_weak(engine, "lifecycle", lifecycle_main, NULL, NULL)) return;
    cg_lock(&plugin->lifecycle_lock);
    cg_lifecycle_task *pending = plugin->lifecycle_head;
    plugin->lifecycle_head = plugin->lifecycle_tail = NULL;
    plugin->lifecycle_draining = false;
    cg_unlock(&plugin->lifecycle_lock);
    while (pending) {
        cg_lifecycle_task *next = pending->next;
        task_free(pending);
        pending = next;
    }
}
