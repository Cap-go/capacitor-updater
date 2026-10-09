/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Plugin load, app lifecycle and the auto-update cycle (Rust engine/plugin/flow.rs). */

#include "engine/plugin/flow.h"

#include <stdlib.h>
#include <string.h>

#include "crypto/crypto.h"
#include "engine/backend.h"
#include "engine/download.h"
#include "engine/engine.h"
#include "engine/manifest.h"
#include "engine/plugin/channel.h"
#include "engine/plugin/delay.h"
#include "engine/plugin/plugin.h"
#include "engine/plugin/preview.h"
#include "engine/plugin/ready.h"
#include "engine/plugin/telemetry.h"
#include "engine/scheduled.h"
#include "engine/stats.h"
#include "engine/store.h"
#include "net_url.h"
#include "policy.h"

cg_cycle_end cg_flow_cycle_end(const char *message, const char *latest_version, const cg_bundle_info *current,
                               bool error, bool planned) {
    cg_cycle_end end;
    end.message = message;
    end.latest_version = latest_version;
    end.current = current;
    end.error = error;
    end.planned_direct_update = planned;
    end.send_stats = true;
    end.notify_no_need_update = true;
    end.stat_version = NULL;
    return end;
}

/* url::Url::parse(value) is an http(s) URL with a host. */
static bool is_http_url(const char *value) {
    cg_url url;
    if (cg_url_parse(value, NULL, &url) != CG_URL_OK) return false;
    bool ok = (cg_url_scheme_is(&url, "http") || cg_url_scheme_is(&url, "https")) && url.host != CG_URL_HOST_NONE;
    cg_url_clear(&url);
    return ok;
}

/* `text(object, key)`: non-null values as text (strings as is, others as JSON). malloc'd,
 * NULL = None. */
static char *text(const cj *object, const char *key) {
    const cj *value = cj_get(object, key);
    if (cj_is_null(value)) return NULL;
    if (cj_is_str(value)) return cg_strdup(cj_as_str(value));
    return cj_print(value);
}

static char *text_or_empty(const cj *object, const char *key) {
    char *value = text(object, key);
    return value ? value : cg_strdup("");
}

static void background_task(cg_engine *engine, const char *action, const char *name) {
    cj_free(cg_plugin_hook(engine, CG_HOOK_BACKGROUND_TASK,
                           cj_objv("action", cj_str(action), "name", cj_str(name), NULL)));
}

static void current_bundle(cg_engine *engine, cg_bundle_info *out) { cg_store_current_bundle(engine, out); }

/* ---------------------------------------------------------------- load */

static void cleanup_obsolete_versions(cg_engine *engine, bool reset_when_update, bool native_build_changed);
static void start_periodic_check(cg_engine *engine);

/* `persisted(key)`: the stored URL override when persistModifyUrl, else None. */
static char *persisted(cg_engine *engine, const cg_plugin_config *config, const char *key) {
    return config->persist_modify_url ? cg_plugin_kv_text(engine, key) : NULL;
}

static cj *url_setting(cg_engine *engine, const cg_plugin_config *config, const cj *object, const char *key,
                       const char *field, const char *fallback) {
    char *value = persisted(engine, config, key);
    if (!value) value = text(object, field);
    if (!value) value = cg_strdup(fallback);
    return cj_str_own(value);
}

cj *cg_flow_load_plugin(cg_engine *engine, const cj *input, cg_error *err) {
    cg_host *host = &engine->host;
    const cj *config_json = cj_get(input, "config");
    const cj *native = cj_get(input, "native");
    cg_plugin_config config;
    cg_strs warnings = {0};
    cg_plugin_config_from_json(config_json, native, &warnings, &config);
    for (size_t i = 0; i < warnings.len; i++) cg_host_log(host, CG_ERROR, warnings.items[i]);
    cg_strs_free(&warnings);
    cj empty = {.type = CJ_OBJECT};
    const cj *object = cj_is_obj(config_json) ? config_json : &empty;
    {
        cg_plugin_state *state = cg_plugin_lock_state(engine);
        cg_plugin_config_clear(&state->config);
        cg_plugin_config_copy(&state->config, &config);
        state->shake_menu_enabled = config.shake_menu;
        state->shake_channel_selector_enabled = config.allow_shake_channel_selector;
        cg_replace(&state->shake_menu_gesture, cg_strdup(config.shake_menu_gesture));
        state->launch_started_at_ms = cg_plugin_now_ms();
        state->loaded = true;
        cg_plugin_unlock_state(engine);
    }
    cg_plugin_mark_cleanup(engine, false);

    /* Endpoints, keys and HTTP settings (persisted URL overrides when allowed). */
    cj *runtime = cj_obj();
    char *app_id = text(object, "appId");
    if (app_id && *app_id) cj_set(runtime, "appId", cj_str(app_id));
    free(app_id);
    char *configured_app_id = CG_CONFIG_DUP(engine, app_id);
    bool missing = !*configured_app_id && !cj_has(runtime, "appId");
    free(configured_app_id);
    if (missing) {
        /* Its own code: hosts stop the app only on this and an invalid public key. */
        cj_free(runtime);
        cg_plugin_config_clear(&config);
        cg_err_set(err, "missing_app_id",
                   "appId is missing in capacitor.config.json or plugin config, and cannot be retrieved from the "
                   "native app, please add it globally or in the plugin config");
        return NULL;
    }
    cj_set(runtime, "updateUrl", url_setting(engine, &config, object, CG_KEY_UPDATE_URL, "updateUrl", CG_DEFAULT_UPDATE_URL));
    cj_set(runtime, "statsUrl", url_setting(engine, &config, object, CG_KEY_STATS_URL, "statsUrl", CG_DEFAULT_STATS_URL));
    cj_set(runtime, "channelUrl",
           url_setting(engine, &config, object, CG_KEY_CHANNEL_URL, "channelUrl", CG_DEFAULT_CHANNEL_URL));
    cj_set(runtime, "publicKey", cj_str_own(text_or_empty(object, "publicKey")));
    int64_t response_timeout = cg_plugin_object_i64(object, "responseTimeout", 20);
    uint64_t timeout_ms = 20000;
    if (response_timeout > 0) {
        uint64_t seconds = (uint64_t)response_timeout;
        timeout_ms = seconds > UINT64_MAX / 1000 ? UINT64_MAX : seconds * 1000;
    }
    cj_set(runtime, "timeoutMs", cj_u64(timeout_ms));
    cj_set(runtime, "allowHttpsToHttpRedirect",
           cj_bool(cg_plugin_object_bool(object, "allowHttpsToHttpRedirect", false)));
    char *version_build = CG_CONFIG_DUP(engine, version_build);
    if (*config.native_version && !*version_build) cj_set(runtime, "versionBuild", cj_str(config.native_version));
    free(version_build);
    cg_error configure_error = CG_ERROR_INIT;
    bool configured = cg_engine_configure(engine, runtime, &configure_error);
    cj_free(runtime);
    if (!configured) {
        /* An invalid public key fails the load and the hosts crash, like every previous
         * version: the updater never runs without the encryption the app asked for. */
        cg_host_log(host, CG_ERROR, cg_or_empty(configure_error.message));
        cg_err_move(err, &configure_error);
        cg_plugin_config_clear(&config);
        return NULL;
    }
    char *key_id = CG_CONFIG_DUP(engine, key_id);
    if (*key_id) cg_info(host, "Public key prefix: %s", key_id);
    free(key_id);

    const char *native_build = config.native_build;
    char *stored_build = cg_flow_stored_native_build(engine);
    bool native_build_changed = *stored_build && strcmp(stored_build, native_build) != 0;

    cg_channel_prepare_default_channel(engine, native_build_changed);
    cg_stats_restore_pending_stats(engine);
    if (config.persist_custom_id) {
        char *custom_id = cg_plugin_kv_text(engine, CG_KEY_CUSTOM_ID);
        if (custom_id && *custom_id) {
            cg_engine_config *writer = cg_engine_config_begin(engine);
            cg_replace(&writer->custom_id, custom_id);
            cg_engine_config_commit(engine, writer);
            custom_id = NULL;
            cg_info(host, "Loaded persisted customId");
        }
        free(custom_id);
    }
    char *device_id = CG_CONFIG_DUP(engine, device_id);
    cg_info(host, "init for device %s", device_id);
    free(device_id);
    cg_info(host, "version native %s", config.native_version);

    cg_preview_restore_preview_state_at_load(engine);
    cg_plugin_lock_state(engine)->was_recently_installed_or_updated =
        !*stored_build || strcmp(stored_build, native_build) != 0;
    cg_plugin_unlock_state(engine);
    cg_store_auto_reset(engine, native_build, config.reset_when_update);
    if (native_build_changed) cg_preview_clear_preview_session_for_native_build_change(engine);
    const char *launch_url = cj_as_str(cj_get(native, "launchUrl"));
    if (launch_url) cg_preview_leave_preview_for_launch_url(engine, launch_url);
    /* After the startup reset: the stat names the bundle this launch really loads (builtin
     * after a native build reset), not the one stored before it. */
    cg_telemetry_report_app_launch_start(engine);
    cg_telemetry_report_native_version_stats_if_changed(engine);
    const cj *previous_exits = cj_get(native, "previousExits");
    if (cj_is_arr(previous_exits)) cg_telemetry_report_previous_exits(engine, previous_exits);
    cg_telemetry_report_previous_render_process_gone(engine);
    if (config.track_unclean_exits) cg_telemetry_report_previous_unclean_exit_and_start_session(engine);
    if (!config.reset_when_update) cg_flow_persist_native_build_version(engine);
    cleanup_obsolete_versions(engine, config.reset_when_update, native_build_changed);
    cg_delay_check_cancel_delay(engine, CG_DELAY_KILLED);
    start_periodic_check(engine);
    cg_preview_show_preview_notice_if_needed(engine);
    cg_plugin_sync_shake_menu(engine);
    cj_free(cg_plugin_hook(engine, CG_HOOK_KEEP_URL_PATH,
                           cj_objv("enabled", cj_bool(config.keep_url_path_after_reload), NULL)));
    /* The first appReady waits for notifyAppReady from the initial page. */
    cg_ready_arm_pending_ready_wait(engine);
    cg_bundle_info current;
    current_bundle(engine, &current);
    char *result_app_id = CG_CONFIG_DUP(engine, app_id);
    char *path = cg_store_current_bundle_path(engine);
    bool is_builtin = cg_store_is_using_builtin(engine);
    bool preview_session = cg_plugin_lock_state(engine)->preview_session_enabled;
    cg_plugin_unlock_state(engine);
    cj *result = cj_objv("appId", cj_str_own(result_app_id), "bundle", cg_bundle_info_to_js(&current), "path",
                         cj_str_own(path), "isBuiltin", cj_bool(is_builtin), "autoUpdate",
                         cj_str(config.auto_update_mode), "previewSession", cj_bool(preview_session), NULL);
    cg_bundle_info_clear(&current);
    free(stored_build);
    cg_plugin_config_clear(&config);
    return result;
}

char *cg_flow_stored_native_build(cg_engine *engine) {
    cg_engine_config *config = cg_engine_config_snapshot(engine);
    char *key = cg_strdup(config->keys.native_build_version);
    char *legacy_key = cg_strdup(config->keys.legacy_native_build_version);
    cg_config_release(config);
    char *current = cg_host_kv_get(&engine->host, key, NULL);
    if (!current) current = cg_strdup("");
    if (!*current) {
        free(current);
        current = cg_host_kv_get(&engine->host, legacy_key, NULL);
        if (!current) current = cg_strdup("");
    }
    free(key);
    free(legacy_key);
    return current;
}

void cg_flow_persist_native_build_version(cg_engine *engine) {
    bool must_retry = cg_plugin_lock_state(engine)->default_channel_cleanup_must_retry;
    cg_plugin_unlock_state(engine);
    if (must_retry) {
        cg_warn(&engine->host, "Keeping the previous native build version so default channel cleanup retries");
        return;
    }
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    char *key = CG_CONFIG_DUP(engine, keys.native_build_version);
    cg_plugin_kv_write(engine, key, config.native_build);
    free(key);
    cg_plugin_config_clear(&config);
}

typedef struct {
    bool reset_when_update;
    bool native_build_changed;
} cleanup_job;

static void cleanup_main(cg_engine_weak *weak, void *ctx) {
    cleanup_job *job = ctx;
    cg_engine *engine = cg_engine_upgrade(weak);
    if (!engine) return;
    cg_host *host = &engine->host;
    if (job->reset_when_update && job->native_build_changed) {
        cg_plugin_config config;
        cg_plugin_plugin_config(engine, &config);
        cg_info(host, "New native build version detected: %s", config.native_build);
        cg_plugin_config_clear(&config);
        cg_bundle_list bundles;
        cg_store_list(engine, false, &bundles);
        for (size_t i = 0; i < bundles.len; i++) {
            const char *id = cg_bundle_info_id(&bundles.items[i]);
            cg_info(host, "Deleting obsolete bundle: %s", id);
            if (!cg_store_delete_bundle(engine, id, true, true)) cg_error_log(host, "Failed to delete: %s", id);
            cg_sleep_ms(CG_OBSOLETE_DELETE_PACING_MS);
        }
        cg_bundle_list_clear(&bundles);
        cg_store_cleanup_delta_cache(engine);
    }
    cg_store_drain_pending_deletes(engine);
    cg_strs allowed = cg_store_allowed_bundle_ids_for_cleanup(engine);
    cg_store_cleanup_download_directories(engine, &allowed, NULL);
    cg_strs_free(&allowed);
    cg_store_cleanup_orphaned_temp_folders(engine, NULL);
    cg_download_cleanup_download_temp_files(engine);
    cg_flow_persist_native_build_version(engine);
    cg_plugin_mark_cleanup(engine, true);
    cg_info(host, "Cleanup complete");
    background_task(engine, "end", "CapgoBundleCleanup");
    cg_engine_release(engine);
}

/* Deletes obsolete bundles after a native update and sweeps leftovers; downloads wait on it
 * (cg_plugin_wait_for_cleanup). */
static void cleanup_obsolete_versions(cg_engine *engine, bool reset_when_update, bool native_build_changed) {
    cg_plugin_mark_cleanup(engine, false);
    background_task(engine, "begin", "CapgoBundleCleanup");
    cleanup_job *job = cg_malloc(sizeof(cleanup_job));
    job->reset_when_update = reset_when_update;
    job->native_build_changed = native_build_changed;
    if (!cg_engine_spawn_weak(engine, "cleanup", cleanup_main, job, free)) {
        /* Downloads wait for the cleanup, and an unended background task gets the app killed. */
        cg_plugin_mark_cleanup(engine, true);
        background_task(engine, "end", "CapgoBundleCleanup");
    }
}

/* ---------------------------------------------------------------- lifecycle */

void cg_flow_app_moved_to_foreground(cg_engine *engine) {
    /* A check armed before or during the background must not fire on thaw: this foreground
     * arms a fresh one below. */
    cg_ready_invalidate_app_ready_check(engine);
    cg_plugin_lock_state(engine)->in_background = false;
    cg_plugin_unlock_state(engine);
    cg_telemetry_mark_session_foreground(engine, true);
    cg_bundle_info current;
    current_bundle(engine, &current);
    cg_stats_send_stats(engine, "app_moved_to_foreground", cg_bundle_info_version_name(&current), NULL, NULL);
    cg_delay_check_cancel_delay(engine, CG_DELAY_FOREGROUND);
    cg_delay_unset_background_timestamp(engine);
    if (cg_plugin_is_auto_update_enabled(engine)) {
        if (cg_flow_is_update_cycle_running(engine))
            cg_info(&engine->host, "Download already in progress, skipping duplicate download request");
        else
            cg_flow_background_download(engine);
    } else {
        cg_plugin_config config;
        cg_plugin_plugin_config(engine, &config);
        bool server_url = config.server_url_configured;
        cg_plugin_config_clear(&config);
        if (server_url)
            cg_stats_send_stats(engine, "blocked_by_server_url", cg_bundle_info_version_name(&current), NULL, NULL);
        cg_info(&engine->host, "Auto update is disabled");
        cg_ready_send_ready_to_js(engine, &current, "disabled");
    }
    cg_bundle_info_clear(&current);
    cg_ready_check_app_ready(engine, cg_ready_app_ready_check_timeout(engine));
}

void cg_flow_background_splash(cg_engine *engine) {
    {
        cg_plugin_state *state = cg_plugin_lock_state(engine);
        state->in_background = true;
        state->foreground_handled = false;
        cg_plugin_unlock_state(engine);
    }
    /* The page is paused: its readiness is checked again from the next foreground. */
    cg_ready_invalidate_app_ready_check(engine);
    cg_telemetry_mark_session_foreground(engine, false);
    cg_plugin_lock_state(engine)->auto_splashscreen_timed_out = false;
    cg_plugin_unlock_state(engine);
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    if (config.auto_splashscreen) {
        bool can_show = true;
        if (!cg_plugin_is_auto_update_enabled(engine)) {
            cg_warn(&engine->host,
                    "autoSplashscreen is enabled but autoUpdate is disabled. Splashscreen will not be shown. Enable "
                    "autoUpdate or disable autoSplashscreen.");
            can_show = false;
        }
        if (!cg_flow_should_use_direct_update(engine)) {
            const char *mode = config.direct_update_mode;
            if (strcmp(mode, CG_DIRECT_UPDATE_DISABLED) == 0)
                cg_warn(&engine->host,
                        "autoSplashscreen is enabled but directUpdate is not configured for immediate updates. Set "
                        "directUpdate to 'always' or disable autoSplashscreen.");
            else if (strcmp(mode, CG_AUTO_UPDATE_INSTALL) == 0 || strcmp(mode, CG_AUTO_UPDATE_LAUNCH) == 0)
                cg_info(&engine->host,
                        "autoSplashscreen is enabled but directUpdate is set to \"%s\". This is normal. Skipping "
                        "autoSplashscreen logic.",
                        mode);
            can_show = false;
        }
        if (can_show) {
            cg_info(&engine->host, "Showing splashscreen for launcher/task switcher");
            cg_ready_show_splashscreen(engine);
        }
    }
    cg_plugin_config_clear(&config);
}

void cg_flow_background_work(cg_engine *engine) {
    cg_bundle_info current;
    current_bundle(engine, &current);
    background_task(engine, "begin", "CapgoInstallNext");
    cg_stats_send_stats(engine, "app_moved_to_background", cg_bundle_info_version_name(&current), NULL, NULL);
    cg_stats_persist_stats(engine, false);
    cg_info(&engine->host, "Checking for pending update");
    cg_delay_set_background_timestamp(engine, cg_plugin_now_ms());
    cg_delay_check_cancel_delay(engine, CG_DELAY_BACKGROUND);
    cg_flow_install_next(engine);
    background_task(engine, "end", "CapgoInstallNext");
    cg_bundle_info_clear(&current);
}

void cg_flow_app_terminated(cg_engine *engine) {
    cg_telemetry_mark_session_foreground(engine, false);
    cg_delay_check_cancel_delay(engine, CG_DELAY_KILLED);
    cg_delay_set_background_timestamp(engine, 0);
    cg_stats_persist_stats(engine, true);
}

void cg_flow_install_next(cg_engine *engine) {
    if (cg_plugin_block_for_preview(engine)) return;
    if (cg_delay_has_delay_conditions(engine)) {
        cg_info(&engine->host, "Update delayed until delay conditions met");
        return;
    }
    cg_bundle_info current, next;
    current_bundle(engine, &current);
    if (!cg_store_next_bundle(engine, &next)) {
        cg_bundle_info_clear(&current);
        return;
    }
    if (cg_bundle_info_is_error(&next) || strcmp(next.id, current.id) == 0) {
        cg_bundle_info_clear(&next);
        cg_bundle_info_clear(&current);
        return;
    }
    cg_debug(&engine->host, "Next bundle is: %s", cg_bundle_info_version_name(&next));
    if (cg_store_set_bundle(engine, next.id) && cg_ready_reload_app(engine)) {
        cg_info(&engine->host, "Updated to bundle: %s", cg_bundle_info_version_name(&next));
        cg_plugin_emit_set_event(engine, &next);
        cg_store_set_next_bundle(engine, NULL);
    } else {
        cg_error_log(&engine->host, "Update to bundle: %s Failed!", cg_bundle_info_version_name(&next));
    }
    cg_bundle_info_clear(&next);
    cg_bundle_info_clear(&current);
}

/* ---------------------------------------------------------------- direct update decisions */

bool cg_flow_should_use_direct_update(cg_engine *engine) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    const cg_plugin_config *config = &state->config;
    bool result = false;
    if (!cg_plugin_config_auto_update_enabled(config) ||
        strcmp(config->auto_update_mode, CG_AUTO_UPDATE_ONLY_DOWNLOAD) == 0) {
        result = false;
    } else if (state->auto_splashscreen_timed_out) {
        result = false;
    } else if (strcmp(config->direct_update_mode, CG_AUTO_UPDATE_ALWAYS) == 0) {
        result = true;
    } else if (strcmp(config->direct_update_mode, CG_AUTO_UPDATE_INSTALL) == 0) {
        if (state->was_recently_installed_or_updated) {
            state->was_recently_installed_or_updated = false;
            result = true;
        }
    } else if (strcmp(config->direct_update_mode, CG_AUTO_UPDATE_LAUNCH) == 0) {
        result = !state->on_launch_direct_update_used;
    }
    cg_plugin_unlock_state(engine);
    return result;
}

static bool direct_update_allowed_now(cg_engine *engine, bool planned) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    bool allowed = planned && !state->auto_splashscreen_timed_out &&
                   !(state->has_cycle_download && state->cycle_download.launch_released);
    cg_plugin_unlock_state(engine);
    return allowed;
}

void cg_flow_consume_on_launch_direct_update(cg_engine *engine, bool planned) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    if (cg_policy_should_consume_on_launch_direct_update(state->config.direct_update_mode, planned))
        state->on_launch_direct_update_used = true;
    cg_plugin_unlock_state(engine);
}

static bool should_set_next_bundle(cg_engine *engine) {
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    bool set_next = cg_plugin_config_should_set_next_bundle(&config);
    cg_plugin_config_clear(&config);
    return set_next;
}

/* ---------------------------------------------------------------- update cycle */

bool cg_flow_is_update_cycle_running(cg_engine *engine) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    bool waiting_scheduled = state->has_cycle_download && state->cycle_download.waiting_scheduled;
    bool running;
    if (!state->has_download_started_at) {
        running = false;
    } else if (waiting_scheduled) {
        /* A scheduled download waits for the network as long as it needs: not stuck. */
        running = true;
    } else {
        int64_t elapsed = cg_mono_ms() - state->download_started_at_ms;
        if (elapsed > CG_DOWNLOAD_STUCK_TIMEOUT_MS) {
            cg_warn(&engine->host,
                    "Download has been in progress for %lld ms, exceeding timeout of %lld ms. Clearing stuck state.",
                    (long long)elapsed, (long long)CG_DOWNLOAD_STUCK_TIMEOUT_MS);
            state->has_download_started_at = false;
            running = false;
        } else {
            running = true;
        }
    }
    cg_plugin_unlock_state(engine);
    return running;
}

static void clear_update_cycle(cg_engine *engine) {
    {
        cg_plugin_state *state = cg_plugin_lock_state(engine);
        state->has_download_started_at = false;
        cg_plugin_state_set_cycle_download(state, NULL);
        cg_plugin_unlock_state(engine);
    }
    background_task(engine, "end", "Finish Download Tasks");
}

static void run_update_cycle(cg_engine *engine, const char *update_url, bool planned, const char *message_update);

typedef struct {
    char *update_url;
    bool planned;
    const char *message_update; /* static */
} update_job;

static void update_job_drop(void *ctx) {
    update_job *job = ctx;
    free(job->update_url);
    free(job);
}

static void update_main(cg_engine_weak *weak, void *ctx) {
    update_job *job = ctx;
    cg_engine *engine = cg_engine_upgrade(weak);
    if (!engine) return;
    run_update_cycle(engine, job->update_url, job->planned, job->message_update);
    cg_engine_release(engine);
}

const char *cg_flow_background_download(cg_engine *engine) {
    cg_lock(&engine->plugin.cycle);
    const char *status = "queued";
    char *update_url = NULL;
    if (cg_plugin_block_for_preview(engine)) {
        status = "unavailable";
        goto done;
    }
    if (cg_flow_is_update_cycle_running(engine)) {
        cg_info(&engine->host, "Download already in progress, skipping duplicate download request");
        status = "already_running";
        goto done;
    }
    update_url = CG_CONFIG_DUP(engine, update_url);
    if (!is_http_url(update_url)) {
        cg_error_log(&engine->host, "Error no url or wrong format");
        status = "unavailable";
        goto done;
    }
    bool planned = cg_flow_should_use_direct_update(engine);
    const char *message_update;
    if (direct_update_allowed_now(engine, planned)) message_update = "Update will occur now.";
    else if (should_set_next_bundle(engine)) message_update = "Update will occur next time app moves to background.";
    else message_update = "Update will be downloaded and made available.";
    {
        cg_plugin_state *state = cg_plugin_lock_state(engine);
        state->has_download_started_at = true;
        state->download_started_at_ms = cg_mono_ms();
        cg_plugin_unlock_state(engine);
    }
    background_task(engine, "begin", "Finish Download Tasks");
    update_job *job = cg_malloc(sizeof(update_job));
    job->update_url = update_url;
    update_url = NULL;
    job->planned = planned;
    job->message_update = message_update;
    if (!cg_engine_spawn_weak(engine, "update", update_main, job, update_job_drop)) {
        cg_plugin_lock_state(engine)->has_download_started_at = false;
        cg_plugin_unlock_state(engine);
        background_task(engine, "end", "Finish Download Tasks");
        status = "unavailable";
    }
done:
    free(update_url);
    cg_unlock(&engine->plugin.cycle);
    return status;
}

void cg_flow_end_update_cycle(cg_engine *engine, const cg_cycle_end *end) {
    cg_host *host = &engine->host;
    cg_flow_consume_on_launch_direct_update(engine, end->planned_direct_update);
    if (end->error) {
        cg_info(host, "endBackGroundTaskWithNotif error: true current: %s latestVersionName: %s",
                cg_bundle_info_version_name(end->current), end->latest_version);
        if (end->send_stats) {
            const char *version = end->stat_version ? end->stat_version : cg_bundle_info_version_name(end->current);
            cg_stats_send_stats(engine, "download_fail", version, NULL, NULL);
        }
        cj *payload = cj_objv("version", cj_str(end->latest_version), NULL);
        cg_host_emit(host, "downloadFailed", payload);
        cj_free(payload);
    }
    if (end->notify_no_need_update) cg_plugin_emit_bundle_event(engine, "noNeedUpdate", end->current);
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    bool launch_released = state->has_cycle_download && state->cycle_download.launch_released;
    cg_plugin_unlock_state(engine);
    /* Already sent when a retrying scheduled download released the launch. */
    if (!launch_released) cg_ready_send_ready_to_js(engine, end->current, end->message);
    clear_update_cycle(engine);
    cg_info(host, "endBackGroundTaskWithNotif %s", end->message);
}

/* Emits `updateCheckResult` and logs it; *kind (static) and *message (malloc'd) out. */
static void notify_update_check_result(cg_engine *engine, const cj *response, const cg_bundle_info *current,
                                       const char **kind_out, char **message_out) {
    char *error = text_or_empty(response, "error");
    char *message = text(response, "message");
    if (!message) message = cg_strdup("server did not provide a message");
    int64_t status_code = 0;
    if (!cj_as_i64(cj_get(response, "statusCode"), &status_code)) status_code = 0;
    const char *kind = cg_policy_normalized_update_response_kind(cj_as_str(cj_get(response, "kind")));
    char *version = text(response, "version");
    if (!version || !*version) cg_replace(&version, cg_strdup(cg_bundle_info_version_name(current)));
    cj *payload = cj_objv("kind", cj_str(kind), "error", cj_str(error), "message", cj_str(message), "statusCode",
                          cj_i64(status_code), "version", cj_str_own(version), "bundle", cg_bundle_info_to_js(current),
                          NULL);
    cg_host_emit(&engine->host, "updateCheckResult", payload);
    cj_free(payload);
    if (strcmp(kind, "up_to_date") == 0)
        cg_info(&engine->host, "No new version available");
    else if (strcmp(kind, "blocked") == 0)
        cg_info(&engine->host, "Update check blocked with error: %s", error);
    else
        cg_error_log(&engine->host, "getLatest failed with error: %s, message: %s, statusCode: %lld", error, message,
                     (long long)status_code);
    free(error);
    if (kind_out) *kind_out = kind;
    if (message_out) *message_out = message;
    else free(message);
}

/* Valid session key (or no public key): encrypted bundles cannot be reused otherwise. */
static bool require_session_key_quiet(cg_engine *engine, const char *session_key) {
    char *public_key = CG_CONFIG_DUP(engine, public_key);
    bool ok = !*public_key || cg_crypto_is_valid_session_key(session_key);
    free(public_key);
    return ok;
}

static bool is_reusable(const cg_bundle_info *bundle) {
    return cg_bundle_info_is_downloaded(bundle) && !cg_bundle_info_is_downloading(bundle) &&
           !cg_bundle_info_is_deleted(bundle) && !cg_bundle_info_is_deleting(bundle) &&
           !cg_bundle_info_is_error(bundle);
}

static void update_to_builtin(cg_engine *engine, const cg_bundle_info *current, bool planned);
static void install_downloaded(cg_engine *engine, const cg_bundle_info *next, const cg_bundle_info *current,
                               const char *latest_version, bool planned);

/* The download step of run_update_cycle (the `_ =>` arm). true with *next set; false when the
 * cycle already ended. */
static bool download_latest(cg_engine *engine, const cj *response, const char *url, const char *latest_version,
                            const char *session_key, bool planned, const cg_bundle_info *existing_in,
                            bool has_existing_in, cg_bundle_info *next) {
    cg_host *host = &engine->host;
    cg_flow_consume_on_launch_direct_update(engine, planned);
    {
        cg_cycle_download download = {.version = (char *)latest_version, .planned = planned};
        cg_plugin_state *state = cg_plugin_lock_state(engine);
        cg_plugin_state_set_cycle_download(state, &download);
        cg_plugin_unlock_state(engine);
    }
    /* A scheduled download an earlier process started (killed mid-download) goes on where it
     * stopped instead of starting over. */
    cg_error error = CG_ERROR_INIT;
    cg_bundle_info result;
    int adopted = cg_scheduled_adopt_scheduled_download(engine, latest_version, &result, &error);
    bool ok;
    if (adopted >= 0) {
        ok = adopted == 1;
    } else {
        /* A job of this version may have finished since `existing` was read: stop any job
         * left, then decide from the record as it is now. */
        if (has_existing_in && cg_bundle_info_is_downloading(existing_in))
            cg_scheduled_cancel_version_download(engine, latest_version);
        cg_bundle_info existing;
        bool has_existing = cg_store_get_bundle_info_by_name(engine, latest_version, &existing);
        if (has_existing && is_reusable(&existing) && require_session_key_quiet(engine, session_key)) {
            cg_info(host, "Latest bundle %s was downloaded by its scheduled download", existing.id);
            cg_bundle_info_copy(&result, &existing);
            ok = true;
        } else {
            if (has_existing) {
                cg_info(host,
                        "Latest bundle already exists in incomplete state (%s) and will be deleted, download will "
                        "overwrite it.",
                        cg_bundle_status_str(cg_bundle_info_status(&existing)));
                cg_bundle_info queued;
                if (cg_store_next_bundle(engine, &queued)) {
                    if (strcmp(queued.id, existing.id) == 0) cg_store_set_next_bundle(engine, NULL);
                    cg_bundle_info_clear(&queued);
                }
                cg_store_delete_bundle(engine, existing.id, true, true);
            }
            cg_download_request request;
            cg_download_request_init(&request);
            cg_replace(&request.url, cg_strdup(url));
            cg_replace(&request.version, cg_strdup(latest_version));
            cg_replace(&request.session_key, cg_strdup(session_key));
            cg_replace(&request.checksum, text_or_empty(response, "checksum"));
            const cj *manifest = cj_get(response, "manifest");
            request.manifest = cj_is_arr(manifest) ? cj_clone(manifest) : NULL;
            request.link = text(response, "link");
            request.comment = text(response, "comment");
            request.emit_events = false;
            if (request.manifest) ok = cg_manifest_download_manifest(engine, &request, &result, &error);
            else ok = cg_download_download_zip(engine, &request, &result, &error);
            cg_download_request_clear(&request);
        }
        if (has_existing) cg_bundle_info_clear(&existing);
    }
    if (ok) {
        *next = result;
        return true;
    }
    if (cg_err_is(&error, "download_detached")) {
        /* Plugin released: the scheduled job records the bundle; the next update check installs
         * it. */
        cg_info(host, "%s", cg_or_empty(error.message));
        clear_update_cycle(engine);
        cg_err_clear(&error);
        return false;
    }
    cg_error_log(host, "Error downloading file %s", cg_or_empty(error.message));
    const char *message = "Error downloading file";
    if (cg_err_is(&error, "session_key_required")) message = "Session key required when public key is present";
    else if (cg_err_is(&error, "checksum_required")) message = "Checksum required";
    else if (cg_err_is(&error, "checksum_fail")) message = "Error checksum";
    cg_err_clear(&error);
    cg_bundle_info current;
    current_bundle(engine, &current);
    cg_cycle_end end = cg_flow_cycle_end(message, latest_version, &current, true, planned);
    end.stat_version = latest_version;
    cg_flow_end_update_cycle(engine, &end);
    cg_bundle_info_clear(&current);
    return false;
}

static void run_update_cycle(cg_engine *engine, const char *update_url, bool planned, const char *message_update) {
    cg_host *host = &engine->host;
    if (cg_plugin_block_for_preview(engine)) {
        clear_update_cycle(engine);
        return;
    }
    cg_info(host, "Check for update via %s", update_url);
    cj *response = cg_backend_get_latest(engine, update_url, NULL, NULL);
    if (cg_plugin_block_for_preview(engine)) {
        clear_update_cycle(engine);
        cj_free(response);
        return;
    }
    cg_bundle_info current;
    current_bundle(engine, &current);
    if (cj_has(response, "error") || cj_has(response, "kind")) {
        const char *kind;
        char *message;
        notify_update_check_result(engine, response, &current, &kind, &message);
        char *latest = text_or_empty(response, "version");
        cg_flow_notify_breaking_events_if_needed(engine, response, latest);
        bool failed = strcmp(kind, "failed") == 0;
        const char *latest_version = *latest ? latest : cg_bundle_info_version_name(&current);
        cg_cycle_end end = cg_flow_cycle_end(message, latest_version, &current, failed, planned);
        end.send_stats = failed;
        cg_flow_end_update_cycle(engine, &end);
        free(latest);
        free(message);
        cg_bundle_info_clear(&current);
        cj_free(response);
        return;
    }
    cg_error cleanup_error = CG_ERROR_INIT;
    if (!cg_plugin_wait_for_cleanup(engine, &cleanup_error)) {
        cg_error_log(host, "Cleanup still running, skipping download: %s", cg_or_empty(cleanup_error.message));
        cg_err_clear(&cleanup_error);
        cg_cycle_end end =
            cg_flow_cycle_end("Error in update check", cg_bundle_info_version_name(&current), &current, true, planned);
        cg_flow_end_update_cycle(engine, &end);
        cg_bundle_info_clear(&current);
        cj_free(response);
        return;
    }
    cg_bundle_info_clear(&current);
    current_bundle(engine, &current);
    char *latest_version = text_or_empty(response, "version");
    char *url = NULL, *session_key = NULL;
    cg_bundle_info existing;
    bool has_existing = false;

    if (strcmp(latest_version, CG_BUNDLE_ID_BUILTIN) == 0) {
        update_to_builtin(engine, &current, planned);
        goto done;
    }
    url = text_or_empty(response, "url");
    if (!is_http_url(url)) {
        cg_flow_notify_breaking_events_if_needed(engine, response, latest_version);
        cg_error_log(host, "Error no url or wrong format");
        cg_cycle_end end = cg_flow_cycle_end("Error no url or wrong format", latest_version, &current, true, planned);
        cg_flow_end_update_cycle(engine, &end);
        goto done;
    }
    if (!*latest_version || strcmp(latest_version, cg_bundle_info_version_name(&current)) == 0) {
        cg_info(host, "No need to update, %s is the latest bundle.", current.id);
        cg_cycle_end end = cg_flow_cycle_end("No need to update", latest_version, &current, false, planned);
        cg_flow_end_update_cycle(engine, &end);
        goto done;
    }
    cg_info(host, "New bundle: %s found. Current is: %s. %s", latest_version, cg_bundle_info_version_name(&current),
            message_update);
    session_key = text_or_empty(response, "sessionKey");
    has_existing = cg_store_get_bundle_info_by_name(engine, latest_version, &existing);
    cg_bundle_info next;
    if (has_existing && is_reusable(&existing) && require_session_key_quiet(engine, session_key)) {
        cg_info(host, "Latest bundle already exists and download is NOT required. %s", message_update);
        cg_bundle_info_copy(&next, &existing);
    } else if (has_existing && cg_bundle_info_is_error(&existing)) {
        cg_error_log(host, "Latest bundle already exists, and is in error state. Aborting update.");
        cg_cycle_end end = cg_flow_cycle_end("Latest bundle already exists, and is in error state. Aborting update.",
                                             latest_version, &current, true, planned);
        cg_flow_end_update_cycle(engine, &end);
        goto done;
    } else if (!download_latest(engine, response, url, latest_version, session_key, planned, &existing, has_existing,
                                &next)) {
        goto done;
    }
    if (cg_bundle_info_is_error(&next)) {
        cg_error_log(host, "Latest bundle already exists and is in error state. Aborting update.");
        cg_cycle_end end = cg_flow_cycle_end("Latest version is in error state. Aborting update.", latest_version,
                                             &current, true, planned);
        cg_flow_end_update_cycle(engine, &end);
    } else if (cg_plugin_block_for_preview(engine)) {
        clear_update_cycle(engine);
    } else {
        install_downloaded(engine, &next, &current, latest_version, planned);
    }
    cg_bundle_info_clear(&next);

done:
    if (has_existing) cg_bundle_info_clear(&existing);
    free(session_key);
    free(url);
    free(latest_version);
    cg_bundle_info_clear(&current);
    cj_free(response);
}

void cg_flow_scheduled_download_waiting(cg_engine *engine, const char *version, bool waiting) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    if (state->has_cycle_download && strcmp(state->cycle_download.version, version) == 0)
        state->cycle_download.waiting_scheduled = waiting;
    cg_plugin_unlock_state(engine);
}

void cg_flow_scheduled_download_retrying(cg_engine *engine, const char *version) {
    bool release = false;
    {
        cg_plugin_state *state = cg_plugin_lock_state(engine);
        bool timed_out = state->auto_splashscreen_timed_out;
        cg_cycle_download *download = state->has_cycle_download ? &state->cycle_download : NULL;
        if (download && strcmp(download->version, version) == 0 && download->planned && !download->launch_released &&
            !timed_out) {
            download->launch_released = true;
            release = true;
        }
        cg_plugin_unlock_state(engine);
    }
    if (release) {
        const char *message = "Direct update download is retrying, continuing launch on the current bundle";
        cg_warn(&engine->host, "%s", message);
        cg_bundle_info current;
        current_bundle(engine, &current);
        cg_ready_send_ready_to_js(engine, &current, message);
        cg_bundle_info_clear(&current);
    }
}

static void update_to_builtin(cg_engine *engine, const cg_bundle_info *current, bool planned) {
    cg_host *host = &engine->host;
    cg_info(host, "Latest version is builtin");
    if (direct_update_allowed_now(engine, planned)) {
        cg_info(host, "Direct update to builtin version");
        cg_ready_perform_reset(engine, false, false, false);
        cg_bundle_info after;
        current_bundle(engine, &after);
        cg_cycle_end end = cg_flow_cycle_end("Updated to builtin version", CG_BUNDLE_ID_BUILTIN, &after, false, planned);
        cg_flow_end_update_cycle(engine, &end);
        cg_bundle_info_clear(&after);
    } else if (should_set_next_bundle(engine)) {
        if (planned)
            cg_info(host,
                    "Direct update skipped because splashscreen timeout occurred. Update will be applied later.");
        cg_info(host, "Setting next bundle to builtin");
        cg_store_set_next_bundle(engine, CG_BUNDLE_ID_BUILTIN);
        cg_cycle_end end =
            cg_flow_cycle_end("Next update will be to builtin version", CG_BUNDLE_ID_BUILTIN, current, false, planned);
        cg_flow_end_update_cycle(engine, &end);
    } else {
        cg_info(host, "autoUpdate is set to onlyDownload, builtin version will not be set as next bundle");
        bool available = !cg_bundle_info_is_builtin(current);
        if (available) {
            cg_bundle_info builtin;
            cg_store_get_bundle_info(engine, CG_BUNDLE_ID_BUILTIN, &builtin);
            cg_plugin_emit_only_download_update_available(engine, &builtin);
            cg_bundle_info_clear(&builtin);
        }
        cg_cycle_end end = cg_flow_cycle_end("Latest version is builtin, autoUpdate onlyDownload",
                                             CG_BUNDLE_ID_BUILTIN, current, false, planned);
        end.notify_no_need_update = !available;
        cg_flow_end_update_cycle(engine, &end);
    }
}

static bool queue_next(cg_engine *engine, const cg_bundle_info *bundle) {
    if (cg_store_set_next_bundle(engine, bundle->id)) return true;
    cg_error_log(&engine->host, "Failed to queue downloaded bundle as next: %s", bundle->id);
    return false;
}

static void install_downloaded(cg_engine *engine, const cg_bundle_info *next, const cg_bundle_info *current,
                               const char *latest_version, bool planned) {
    cg_host *host = &engine->host;
    if (direct_update_allowed_now(engine, planned)) {
        if (cg_delay_has_delay_conditions(engine)) {
            cg_info(host, "Update delayed until delay conditions met");
            cg_cycle_end end =
                cg_flow_cycle_end("Update delayed until delay conditions met", latest_version, next, false, planned);
            cg_flow_end_update_cycle(engine, &end);
            return;
        }
        if (cg_ready_apply_downloaded_bundle(engine, next)) {
            cg_plugin_emit_set_event(engine, next);
            cg_cycle_end end = cg_flow_cycle_end("update installed", latest_version, next, false, planned);
            cg_flow_end_update_cycle(engine, &end);
        } else if (queue_next(engine, next)) {
            cg_plugin_emit_bundle_event(engine, "updateAvailable", next);
            cg_bundle_info live;
            current_bundle(engine, &live);
            cg_cycle_end end = cg_flow_cycle_end("Direct update reload failed, update will install next background",
                                                 latest_version, &live, false, planned);
            cg_flow_end_update_cycle(engine, &end);
            cg_bundle_info_clear(&live);
        } else {
            cg_cycle_end end = cg_flow_cycle_end("Direct update reload failed, and next bundle could not be queued",
                                                 latest_version, current, true, planned);
            cg_flow_end_update_cycle(engine, &end);
        }
    } else if (should_set_next_bundle(engine)) {
        if (planned)
            cg_info(host, "Direct update skipped because splashscreen timeout occurred. Update will install on next "
                          "app background.");
        if (queue_next(engine, next)) {
            cg_plugin_emit_bundle_event(engine, "updateAvailable", next);
            cg_cycle_end end = cg_flow_cycle_end("update downloaded, will install next background", latest_version,
                                                 current, false, planned);
            cg_flow_end_update_cycle(engine, &end);
        } else {
            cg_cycle_end end = cg_flow_cycle_end("Update downloaded, but next bundle could not be queued",
                                                 latest_version, current, true, planned);
            cg_flow_end_update_cycle(engine, &end);
        }
    } else {
        cg_info(host, "autoUpdate is set to onlyDownload, downloaded update will not be set as next bundle");
        cg_plugin_emit_only_download_update_available(engine, next);
        cg_cycle_end end =
            cg_flow_cycle_end("update downloaded, autoUpdate onlyDownload", latest_version, current, false, planned);
        end.notify_no_need_update = false;
        cg_flow_end_update_cycle(engine, &end);
    }
}

/* ---------------------------------------------------------------- triggers */

const char *cg_flow_trigger_update_check(cg_engine *engine) {
    char *update_url = CG_CONFIG_DUP(engine, update_url);
    bool valid = is_http_url(update_url);
    free(update_url);
    if (!valid) {
        cg_error_log(&engine->host, "Error no url or wrong format");
        return "unavailable";
    }
    if (cg_plugin_block_for_preview(engine)) return "unavailable";
    if (!cg_plugin_is_auto_update_enabled(engine)) {
        cg_info(&engine->host, "Auto update is disabled, update check not triggered");
        return "unavailable";
    }
    return cg_flow_background_download(engine);
}

static void periodic_main(cg_engine_weak *weak, void *ctx) {
    int64_t period_ms = *(int64_t *)ctx;
    while (true) {
        cg_engine *engine = cg_engine_sleep_unless_dropped(weak, period_ms);
        if (!engine) return;
        cg_flow_periodic_tick(engine);
        cg_engine_release(engine);
    }
}

/* Periodic update check (`periodCheckDelay`), started once at load. */
static void start_periodic_check(cg_engine *engine) {
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    uint64_t period = config.period_check_delay_s;
    cg_plugin_config_clear(&config);
    if (period == 0 || !cg_plugin_is_auto_update_enabled(engine)) return;
    if (atomic_exchange(&engine->plugin.periodic_started, true)) return;
    int64_t *period_ms = cg_malloc(sizeof(int64_t));
    *period_ms = (int64_t)period * 1000;
    cg_engine_spawn_weak(engine, "periodic-check", periodic_main, period_ms, free);
}

void cg_flow_periodic_tick(cg_engine *engine) {
    if (cg_plugin_block_for_preview(engine) || !cg_plugin_is_auto_update_enabled(engine)) return;
    cj *response = cg_backend_get_latest(engine, NULL, NULL, NULL);
    if (cg_plugin_block_for_preview(engine)) {
        cj_free(response);
        return;
    }
    cg_bundle_info current;
    current_bundle(engine, &current);
    if (cj_has(response, "error") || cj_has(response, "kind")) {
        notify_update_check_result(engine, response, &current, NULL, NULL);
    } else {
        char *version = text(response, "version");
        if (version && *version && strcmp(version, cg_bundle_info_version_name(&current)) != 0) {
            cg_info(&engine->host, "New version found: %s", version);
            cg_flow_background_download(engine);
        }
        free(version);
    }
    cg_bundle_info_clear(&current);
    cj_free(response);
}

void cg_flow_notify_breaking_events_if_needed(cg_engine *engine, const cj *response, const char *version) {
    bool breaking = false;
    if (!cj_as_bool(cj_get(response, "breaking"), &breaking)) breaking = false;
    breaking = breaking || cg_eq(cj_as_str(cj_get(response, "error")), "disable_auto_update_to_major") ||
               cg_eq(cj_as_str(cj_get(response, "message")), "store_update_required");
    if (!breaking) return;
    char *name;
    if (!version || !*version) {
        cg_bundle_info current;
        current_bundle(engine, &current);
        name = cg_strdup(cg_bundle_info_version_name(&current));
        cg_bundle_info_clear(&current);
    } else {
        name = cg_strdup(version);
    }
    static const char *const events[] = {"breakingAvailable", "majorAvailable"};
    for (size_t i = 0; i < 2; i++) {
        cj *payload = cj_objv("version", cj_str(name), NULL);
        cg_host_emit(&engine->host, events[i], payload);
        cj_free(payload);
    }
    free(name);
}
