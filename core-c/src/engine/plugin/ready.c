/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Reload, `notifyAppReady` and rollback: the part of the update lifecycle that decides
 * whether a bundle stays (Rust engine/plugin/ready.rs). */

#include "engine/plugin/ready.h"

#include <stdlib.h>
#include <string.h>

#include "engine/engine.h"
#include "engine/plugin/plugin.h"
#include "engine/plugin/preview.h"
#include "engine/plugin/telemetry.h"
#include "engine/stats.h"
#include "engine/store.h"

/* Wraps `Capacitor.nativePromise` (not the plugin proxy: registerPlugin's get trap ignores
 * assignments to notifyAppReady) so `notifyAppReady` reports the page's generation. Each
 * document keeps its own generation. */
#define READY_SCRIPT_TAIL                                                                                          \
    ";if(window.__capgoReadyBridge)return;function arm(){var cap=window.Capacitor;if(!cap||typeof "               \
    "cap.nativePromise!=='function'||cap.__capgoNativePromise)return false;var "                                 \
    "orig=cap.nativePromise.bind(cap);cap.nativePromise=function(pluginName,methodName,options){if(pluginName===" \
    "'CapacitorUpdater'&&methodName==='notifyAppReady'){var next={};if(options&&typeof options==='object'){for(" \
    "var k in options){if(Object.prototype.hasOwnProperty.call(options,k))next[k]=options[k];}}next."           \
    "loadGeneration=window.__CAPGO_READY_GEN;options=next;}return "                                               \
    "orig(pluginName,methodName,options);};cap.__capgoNativePromise=true;window.__capgoReadyBridge=true;return "  \
    "true;}if(!arm()){var n=0;var t=setInterval(function(){if(arm()||++n>100)clearInterval(t);},20);}})();"

char *cg_ready_ready_generation_script(int64_t generation) {
    return cg_fmt("(function(){window.__CAPGO_READY_GEN=%lld%s", (long long)generation, READY_SCRIPT_TAIL);
}

/* ---------------------------------------------------------------- notifyAppReady signal */

static uint64_t ready_token(cg_engine *engine) {
    cg_ready_signal *ready = &engine->plugin.ready;
    cg_lock(&ready->lock);
    uint64_t signals = ready->signals;
    cg_unlock(&ready->lock);
    return signals;
}

void cg_ready_arm_pending_ready_wait(cg_engine *engine) {
    cg_ready_signal *ready = &engine->plugin.ready;
    cg_lock(&ready->lock);
    ready->has_pending = true;
    ready->pending = ready->signals;
    cg_unlock(&ready->lock);
}

void cg_ready_clear_pending_ready_wait(cg_engine *engine) {
    cg_ready_signal *ready = &engine->plugin.ready;
    cg_lock(&ready->lock);
    ready->has_pending = false;
    cg_unlock(&ready->lock);
}

static bool take_pending_ready_wait(cg_engine *engine, uint64_t *token) {
    cg_ready_signal *ready = &engine->plugin.ready;
    cg_lock(&ready->lock);
    bool pending = ready->has_pending;
    *token = ready->pending;
    ready->has_pending = false;
    cg_unlock(&ready->lock);
    return pending;
}

bool cg_ready_wait_for_app_ready(cg_engine *engine, uint64_t token, int64_t timeout_ms) {
    /* notifyAppReady comes through the host's method lane. */
    cg_release_method_lane();
    cg_ready_signal *ready = &engine->plugin.ready;
    cg_lock(&ready->lock);
    int64_t deadline = cg_mono_ms() + timeout_ms;
    bool timed_out = false;
    while (ready->signals <= token) {
        int64_t left = deadline - cg_mono_ms();
        if (left <= 0) {
            timed_out = true;
            break;
        }
        cg_cond_wait_ms(&ready->changed, &ready->lock, left);
    }
    cg_unlock(&ready->lock);
    if (timed_out) {
        cg_error_log(&engine->host, "Semaphore wait timed out after %lldms", (long long)timeout_ms);
        return false;
    }
    return true;
}

static void signal_app_ready(cg_engine *engine) {
    cg_ready_signal *ready = &engine->plugin.ready;
    cg_lock(&ready->lock);
    ready->signals++;
    cg_unlock(&ready->lock);
    cg_cond_broadcast(&ready->changed);
}

typedef struct {
    cg_bundle_info current;
    char *message;
    uint64_t token;
    int64_t timeout_ms;
} ready_emit;

static void ready_emit_drop(void *ctx) {
    ready_emit *emit = ctx;
    cg_bundle_info_clear(&emit->current);
    free(emit->message);
    free(emit);
}

static void emit_app_ready(cg_engine *engine, const cg_bundle_info *current, const char *message) {
    cj *payload = cj_objv("bundle", cg_bundle_info_to_js(current), "status", cj_str(message), NULL);
    cg_host_emit_retained(&engine->host, "appReady", payload);
    cj_free(payload);
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    bool auto_splashscreen = config.auto_splashscreen;
    cg_plugin_config_clear(&config);
    if (auto_splashscreen) cg_ready_hide_splashscreen(engine);
    cg_plugin_preview_loader(engine, false, "app-ready");
}

static void ready_emit_main(cg_engine_weak *weak, void *ctx) {
    ready_emit *emit = ctx;
    cg_engine *engine = cg_engine_upgrade(weak);
    if (!engine) return;
    cg_ready_wait_for_app_ready(engine, emit->token, emit->timeout_ms);
    emit_app_ready(engine, &emit->current, emit->message);
    cg_engine_release(engine);
}

void cg_ready_send_ready_to_js(cg_engine *engine, const cg_bundle_info *current, const char *message) {
    cg_info(&engine->host, "sendReadyToJs: %s", message);
    uint64_t token;
    if (!take_pending_ready_wait(engine, &token)) {
        emit_app_ready(engine, current, message);
        return;
    }
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    ready_emit *emit = cg_calloc(1, sizeof(ready_emit));
    cg_bundle_info_copy(&emit->current, current);
    emit->message = cg_strdup(message);
    emit->token = token;
    emit->timeout_ms = (int64_t)config.app_ready_timeout_ms;
    cg_plugin_config_clear(&config);
    cg_engine_spawn_weak(engine, "app-ready-timeout", ready_emit_main, emit, ready_emit_drop);
}

/* ---------------------------------------------------------------- rollback timer */

int64_t cg_ready_app_ready_check_timeout(cg_engine *engine) {
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    uint64_t millis = config.app_ready_timeout_ms;
    if (cg_bundle_info_status(&current) != CG_BUNDLE_SUCCESS && config.pending_bundle_min_timeout_ms > millis)
        millis = config.pending_bundle_min_timeout_ms;
    cg_bundle_info_clear(&current);
    cg_plugin_config_clear(&config);
    return (int64_t)millis;
}

typedef struct {
    uint64_t generation;
    int64_t wait_ms;
} app_ready_check;

static void app_ready_check_main(cg_engine_weak *weak, void *ctx) {
    app_ready_check *check = ctx;
    cg_engine *engine = cg_engine_sleep_unless_dropped(weak, check->wait_ms);
    if (!engine) return;
    if (atomic_load(&engine->plugin.app_ready_check) != check->generation) {
        cg_engine_release(engine);
        return;
    }
    /* A backgrounded (or frozen, then thawed) app cannot confirm its page: the next
     * foreground arms a fresh check. */
    bool in_background = cg_plugin_lock_state(engine)->in_background;
    cg_plugin_unlock_state(engine);
    if (in_background) {
        cg_info(&engine->host, "App is in background, notifyAppReady check deferred to the next foreground");
        cg_engine_release(engine);
        return;
    }
    cg_ready_check_revert(engine);
    cg_engine_release(engine);
}

void cg_ready_check_app_ready(cg_engine *engine, int64_t wait_ms) {
    uint64_t generation = atomic_fetch_add(&engine->plugin.app_ready_check, 1) + 1;
    cg_info(&engine->host, "Wait for %lld ms, then check for notifyAppReady", (long long)wait_ms);
    app_ready_check *check = cg_malloc(sizeof(app_ready_check));
    check->generation = generation;
    check->wait_ms = wait_ms;
    cg_engine_spawn_weak(engine, "delay", app_ready_check_main, check, free);
}

void cg_ready_invalidate_app_ready_check(cg_engine *engine) { atomic_fetch_add(&engine->plugin.app_ready_check, 1); }

typedef struct {
    char *failed_id;
    char *version;
} failed_delete;

static void failed_delete_drop(void *ctx) {
    failed_delete *job = ctx;
    free(job->failed_id);
    free(job->version);
    free(job);
}

static void failed_delete_main(cg_engine_weak *weak, void *ctx) {
    failed_delete *job = ctx;
    cg_engine *engine = cg_engine_upgrade(weak);
    if (!engine) return;
    if (cg_store_delete_bundle(engine, job->failed_id, false, false))
        cg_info(&engine->host, "Failed bundle deleted: %s", job->version);
    else
        cg_error_log(&engine->host, "Failed to delete failed bundle: %s", job->version);
    cg_engine_release(engine);
}

void cg_ready_check_revert(cg_engine *engine) {
    cg_host *host = &engine->host;
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    if (cg_bundle_info_is_builtin(&current)) {
        cg_info(host, "Built-in bundle is active. We skip the check for notifyAppReady.");
        cg_bundle_info_clear(&current);
        return;
    }
    if (cg_plugin_is_preview_state_active(engine)) {
        cg_info(host, "Preview session is active. We skip the check for notifyAppReady.");
        cg_bundle_info_clear(&current);
        return;
    }
    cg_debug(host, "Current bundle is: %s", current.id);
    if (cg_bundle_info_status(&current) == CG_BUNDLE_SUCCESS) {
        cg_info(host, "notifyAppReady was called. This is fine: %s", current.id);
        cg_bundle_info_clear(&current);
        return;
    }
    cg_error_log(host, "notifyAppReady was not called, roll back current bundle: %s", current.id);
    {
        cg_lock(&engine->plugin.confirmation);
        /* notifyAppReady may have confirmed the bundle since the check above. */
        cg_bundle_info latest;
        cg_store_current_bundle(engine, &latest);
        bool confirmed = strcmp(latest.id, current.id) != 0 || cg_bundle_info_status(&latest) == CG_BUNDLE_SUCCESS;
        cg_bundle_info_clear(&latest);
        if (confirmed) {
            cg_info(host, "notifyAppReady was called meanwhile, keeping: %s", current.id);
            cg_unlock(&engine->plugin.confirmation);
            cg_bundle_info_clear(&current);
            return;
        }
        cg_info(host, "Did you forget to call 'notifyAppReady()' in your Capacitor App code?");
        char *stored = cg_bundle_info_to_stored_json(&current);
        cg_plugin_kv_write(engine, CG_KEY_LAST_FAILED_BUNDLE, stored);
        free(stored);
        cg_plugin_emit_bundle_event(engine, "updateFailed", &current);
        cg_telemetry_report_app_launch_timeout(engine, &current);
        cg_stats_send_stats(engine, "update_fail", cg_bundle_info_version_name(&current), NULL, NULL);
        cg_store_set_error(engine, current.id);
        cg_unlock(&engine->plugin.confirmation);
    }
    cg_ready_perform_reset(engine, true, false, true);
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    bool auto_delete_failed = config.auto_delete_failed;
    cg_plugin_config_clear(&config);
    if (auto_delete_failed && !cg_bundle_info_is_builtin(&current)) {
        char *failed_id = cg_strdup(current.id);
        cg_bundle_info latest;
        cg_store_get_bundle_info(engine, failed_id, &latest);
        cg_bundle_info now;
        cg_store_current_bundle(engine, &now);
        bool still_current = strcmp(now.id, failed_id) == 0;
        cg_bundle_info_clear(&now);
        /* Resetting onto this same bundle writes SUCCESS: that bundle must survive. */
        if (cg_bundle_info_status(&latest) != CG_BUNDLE_ERROR || still_current) {
            cg_info(host, "Skip deleting bundle %s after reset", failed_id);
            free(failed_id);
            cg_bundle_info_clear(&latest);
            cg_bundle_info_clear(&current);
            return;
        }
        char *version = cg_strdup(cg_bundle_info_version_name(&latest));
        cg_info(host, "Deleting failing bundle: %s", version);
        /* Marked before the async delete so a kill still resumes it (drainPendingDeletes). */
        cg_bundle_info *deleting = cg_bundle_info_with_status(&latest, CG_BUNDLE_DELETING);
        cg_store_save_bundle_info(engine, failed_id, deleting);
        cg_bundle_info_free(deleting);
        cg_bundle_info_clear(&latest);
        failed_delete *job = cg_malloc(sizeof(failed_delete));
        job->failed_id = failed_id;
        job->version = version;
        cg_engine_spawn_weak(engine, "delete", failed_delete_main, job, failed_delete_drop);
    }
    cg_bundle_info_clear(&current);
}

/* ---------------------------------------------------------------- readiness guard */

static int64_t arm_ready_guard(cg_engine *engine) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    state->ready_generation++;
    state->ready_guard_armed = true;
    int64_t generation = state->ready_generation;
    cg_plugin_unlock_state(engine);
    return generation;
}

void cg_ready_disarm_ready_guard(cg_engine *engine, int64_t generation) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    if (state->ready_generation == generation && state->ready_guard_armed) {
        state->ready_guard_armed = false;
        cg_plugin_unlock_state(engine);
        cg_warn(&engine->host,
                "Could not stamp notifyAppReady for the next page. Readiness guard disabled for this reload.");
        return;
    }
    cg_plugin_unlock_state(engine);
}

bool cg_ready_accepts_ready_call(cg_engine *engine, const int64_t *reported) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    bool accepts = !state->ready_guard_armed || (reported && *reported == state->ready_generation);
    cg_plugin_unlock_state(engine);
    return accepts;
}

/* ---------------------------------------------------------------- reload primitives */

bool cg_ready_apply_current_bundle(cg_engine *engine) {
    int64_t generation = arm_ready_guard(engine);
    char *path = cg_store_current_bundle_path(engine);
    bool is_builtin = cg_store_is_using_builtin(engine);
    cg_info(&engine->host, "Reloading: %s", path);
    cj *reply = cg_plugin_hook(engine, CG_HOOK_APPLY_BUNDLE,
                               cj_objv("path", cj_str_own(path), "isBuiltin", cj_bool(is_builtin), "readyGeneration",
                                       cj_i64(generation), "readyScript",
                                       cj_str_own(cg_ready_ready_generation_script(generation)), NULL));
    bool ok = false, guarded = true;
    if (!cj_as_bool(cj_get(reply, "ok"), &ok)) ok = false;
    if (!cj_as_bool(cj_get(reply, "guard"), &guarded)) guarded = true;
    cj_free(reply);
    if (!ok || !guarded) cg_ready_disarm_ready_guard(engine, generation);
    return ok;
}

void cg_ready_restore_live_bundle(cg_engine *engine) {
    if (!cg_ready_apply_current_bundle(engine)) cg_warn(&engine->host, "Failed to restore live bundle after rejected reload");
}

static void emit_app_reloaded(cg_engine *engine) {
    cj *payload = cj_obj();
    cg_host_emit(&engine->host, "appReloaded", payload);
    cj_free(payload);
}

bool cg_ready_reload_app(cg_engine *engine) {
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    bool waits = config.reload_waits_for_app_ready;
    cg_plugin_config_clear(&config);
    /* A backgrounded page cannot confirm itself: do not wait (the next foreground checks it). */
    if (waits) {
        bool in_background = cg_plugin_lock_state(engine)->in_background;
        cg_plugin_unlock_state(engine);
        waits = !in_background;
    }
    if (waits) {
        /* This reload owns notifyAppReady synchronization. */
        cg_ready_clear_pending_ready_wait(engine);
        uint64_t token = ready_token(engine);
        if (!cg_ready_apply_current_bundle(engine)) return false;
        int64_t wait = cg_ready_app_ready_check_timeout(engine);
        cg_ready_check_app_ready(engine, wait);
        emit_app_reloaded(engine);
        return cg_ready_wait_for_app_ready(engine, token, wait);
    }
    cg_ready_arm_pending_ready_wait(engine);
    if (!cg_ready_apply_current_bundle(engine)) {
        cg_ready_clear_pending_ready_wait(engine);
        return false;
    }
    cg_ready_check_app_ready(engine, cg_ready_app_ready_check_timeout(engine));
    emit_app_reloaded(engine);
    return true;
}

bool cg_ready_reload_without_waiting(cg_engine *engine) {
    if (!cg_ready_apply_current_bundle(engine)) return false;
    cg_ready_check_app_ready(engine, cg_ready_app_ready_check_timeout(engine));
    emit_app_reloaded(engine);
    return true;
}

static char *current_version_name(cg_engine *engine) {
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    char *name = cg_strdup(cg_bundle_info_version_name(&current));
    cg_bundle_info_clear(&current);
    return name;
}

bool cg_ready_apply_downloaded_bundle(cg_engine *engine, const cg_bundle_info *bundle) {
    cg_reset_state previous_state;
    cg_store_capture_reset_state(engine, &previous_state);
    char *previous_name = current_version_name(engine);
    bool ok = false;
    if (!cg_store_stage_pending_reload(engine, bundle)) {
        cg_store_restore_reset_state(engine, &previous_state);
        cg_error_log(&engine->host, "Direct update failed to stage downloaded bundle: %s", bundle->id);
    } else if (cg_ready_reload_app(engine)) {
        cg_store_finalize_pending_reload(engine, bundle, previous_name);
        cg_store_set_next_bundle(engine, NULL);
        ok = true;
    } else {
        cg_store_restore_reset_state(engine, &previous_state);
        cg_ready_restore_live_bundle(engine);
        cg_error_log(&engine->host, "Direct update reload failed after staging bundle: %s", bundle->id);
    }
    free(previous_name);
    cg_reset_state_clear(&previous_state);
    return ok;
}

bool cg_ready_set_and_reload(cg_engine *engine, const char *id, cg_bundle_info *out, char **error) {
    cg_info(&engine->host, "Setting active bundle %s", id);
    if (!cg_store_set_bundle(engine, id)) {
        *error = cg_fmt("Update failed, id %s does not exist.", id);
        return false;
    }
    cg_bundle_info bundle;
    cg_store_get_bundle_info(engine, id, &bundle);
    bool preview = cg_plugin_lock_state(engine)->preview_session_enabled;
    cg_plugin_unlock_state(engine);
    if (preview) {
        cj_free(cg_preview_record_preview_bundle(engine, &bundle, NULL));
        if (!cg_ready_reload_without_waiting(engine)) {
            *error = cg_fmt("Reload failed after setting preview bundle %s", id);
            cg_bundle_info_clear(&bundle);
            return false;
        }
    } else if (!cg_ready_reload_app(engine)) {
        *error = cg_fmt("Reload failed after setting bundle %s", id);
        cg_bundle_info_clear(&bundle);
        return false;
    }
    cg_plugin_emit_set_event(engine, &bundle);
    cg_preview_show_preview_notice_if_needed(engine);
    *out = bundle;
    return true;
}

bool cg_ready_reload_with_pending(cg_engine *engine, char **error) {
    cg_bundle_info current, next;
    cg_store_current_bundle(engine, &current);
    bool has_next = cg_store_next_bundle(engine, &next);
    if (has_next && !cg_plugin_is_preview_state_active(engine) && !cg_bundle_info_is_error(&next) &&
        strcmp(next.id, current.id) != 0) {
        cg_reset_state previous_state;
        cg_store_capture_reset_state(engine, &previous_state);
        char *previous_name = cg_strdup(cg_bundle_info_version_name(&current));
        cg_info(&engine->host, "Applying pending bundle before reload: %s", cg_bundle_info_version_name(&next));
        bool staged;
        if (cg_bundle_info_is_builtin(&next)) {
            cg_store_prepare_reset_state_for_transition(engine);
            staged = true;
        } else {
            staged = cg_store_stage_pending_reload(engine, &next);
        }
        bool ok = false;
        if (staged && cg_ready_reload_app(engine)) {
            if (cg_bundle_info_is_builtin(&next)) cg_store_finalize_reset_transition(engine, previous_name, false);
            else cg_store_finalize_pending_reload(engine, &next, previous_name);
            cg_plugin_emit_set_event(engine, &next);
            cg_store_set_next_bundle(engine, NULL);
            cg_preview_show_preview_notice_if_needed(engine);
            ok = true;
        } else {
            cg_store_restore_reset_state(engine, &previous_state);
            cg_ready_restore_live_bundle(engine);
            *error = cg_fmt("Reload failed after applying pending bundle: %s", cg_bundle_info_version_name(&next));
        }
        free(previous_name);
        cg_reset_state_clear(&previous_state);
        cg_bundle_info_clear(&next);
        cg_bundle_info_clear(&current);
        return ok;
    }
    if (has_next) cg_bundle_info_clear(&next);
    cg_bundle_info_clear(&current);
    if (cg_ready_reload_app(engine)) {
        cg_preview_show_preview_notice_if_needed(engine);
        return true;
    }
    *error = cg_strdup("Reload failed");
    return false;
}

bool cg_ready_perform_reset(cg_engine *engine, bool to_last_successful, bool use_pending_bundle, bool internal) {
    cg_host *host = &engine->host;
    cg_bundle_info fallback, pending;
    cg_store_fallback_bundle(engine, &fallback);
    bool has_pending = cg_store_next_bundle(engine, &pending);
    cg_reset_state previous_state;
    cg_store_capture_reset_state(engine, &previous_state);
    char *previous_name = current_version_name(engine);
    bool result = false;

    if (use_pending_bundle) {
        if (!has_pending || cg_bundle_info_is_error(&pending)) {
            cg_error_log(host, "No pending bundle available to reset to");
        } else if (!cg_store_can_set(engine, &pending)) {
            cg_error_log(host, "Pending bundle is not installable");
        } else {
            cg_store_prepare_reset_state_for_transition(engine);
            cg_info(host, "Resetting to pending bundle: %s", cg_bundle_info_version_name(&pending));
            bool applied = cg_bundle_info_is_builtin(&pending) || cg_store_set_bundle(engine, pending.id);
            if (applied && cg_ready_reload_app(engine)) {
                cg_store_finalize_reset_transition(engine, previous_name, internal);
                cg_plugin_emit_set_event(engine, &pending);
                cg_store_set_next_bundle(engine, NULL);
                result = true;
            } else {
                cg_store_restore_reset_state(engine, &previous_state);
                cg_ready_restore_live_bundle(engine);
            }
        }
        goto done;
    }

    if (to_last_successful && !cg_bundle_info_is_builtin(&fallback)) {
        if (cg_store_can_set(engine, &fallback)) {
            cg_store_prepare_reset_state_for_transition(engine);
            cg_info(host, "Resetting to: %s", cg_bundle_info_version_name(&fallback));
            if (cg_store_set_bundle(engine, fallback.id) && cg_ready_reload_app(engine)) {
                cg_store_finalize_reset_transition(engine, previous_name, internal);
                cg_plugin_emit_set_event(engine, &fallback);
                result = true;
                goto done;
            }
            if (!internal) {
                cg_store_restore_reset_state(engine, &previous_state);
                cg_ready_restore_live_bundle(engine);
                goto done;
            }
            cg_warn(host, "Fallback reload failed during internal reset, resetting to builtin instead");
        } else {
            cg_warn(host, "Fallback bundle is not installable, resetting to builtin instead");
        }
    }

    cg_store_prepare_reset_state_for_transition(engine);
    cg_info(host, "Resetting to builtin version");
    if (cg_ready_reload_app(engine)) {
        cg_store_finalize_reset_transition(engine, previous_name, internal);
        result = true;
    } else if (!internal) {
        cg_store_restore_reset_state(engine, &previous_state);
        cg_ready_restore_live_bundle(engine);
    }

done:
    free(previous_name);
    cg_reset_state_clear(&previous_state);
    if (has_pending) cg_bundle_info_clear(&pending);
    cg_bundle_info_clear(&fallback);
    return result;
}

cj *cg_ready_notify_app_ready(cg_engine *engine, const int64_t *reported_generation) {
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    if (!cg_ready_accepts_ready_call(engine, reported_generation)) {
        cg_info(&engine->host, "Ignoring notifyAppReady from a page that is no longer current");
        cj *out = cj_objv("bundle", cg_bundle_info_to_js(&current), NULL);
        cg_bundle_info_clear(&current);
        return out;
    }
    /* Rust upgrades weak_self() here (set_success needs an Arc): inside a call the engine is
     * always alive, so the upgrade cannot fail. */
    {
        cg_lock(&engine->plugin.confirmation);
        cg_plugin_config config;
        cg_plugin_plugin_config(engine, &config);
        bool auto_delete_previous = config.auto_delete_previous;
        cg_plugin_config_clear(&config);
        cg_store_set_success(engine, current.id, auto_delete_previous);
        cg_unlock(&engine->plugin.confirmation);
    }
    cg_telemetry_report_app_launch_ready(engine, &current);
    cg_info(&engine->host, "Current bundle loaded successfully. ['notifyAppReady()' was called] %s", current.id);
    signal_app_ready(engine);
    cg_preview_clear_incoming_preview_transition(engine);
    cg_plugin_preview_loader(engine, false, "notify-app-ready");
    cg_bundle_info_clear(&current);
    cg_store_current_bundle(engine, &current);
    cj *out = cj_objv("bundle", cg_bundle_info_to_js(&current), NULL);
    cg_bundle_info_clear(&current);
    return out;
}

cj *cg_ready_take_failed_update(cg_engine *engine) {
    char *raw = cg_plugin_kv_text(engine, CG_KEY_LAST_FAILED_BUNDLE);
    if (raw) {
        size_t start, len;
        cg_trim_range(raw, &start, &len);
        if (len == 0) {
            free(raw);
            raw = NULL;
        }
    }
    if (!raw) return cj_null();
    cg_plugin_kv_write(engine, CG_KEY_LAST_FAILED_BUNDLE, NULL);
    cg_bundle_info bundle;
    cj *out = NULL;
    if (cg_bundle_info_from_stored_json(raw, &bundle)) {
        if (!cg_bundle_info_is_unknown(&bundle)) out = cj_objv("bundle", cg_bundle_info_to_js(&bundle), NULL);
        cg_bundle_info_clear(&bundle);
    }
    free(raw);
    if (!out) {
        cg_error_log(&engine->host, "Failed to parse failed bundle info");
        out = cj_null();
    }
    return out;
}

/* ---------------------------------------------------------------- splash screen */

typedef struct {
    uint64_t generation;
    int64_t timeout_ms;
} splash_timer;

static void splash_timer_main(cg_engine_weak *weak, void *ctx) {
    splash_timer *timer = ctx;
    cg_engine *engine = cg_engine_sleep_unless_dropped(weak, timer->timeout_ms);
    if (!engine) return;
    if (atomic_load(&engine->plugin.splash_timer) != timer->generation) {
        cg_engine_release(engine);
        return;
    }
    cg_info(&engine->host, "autoSplashscreen timeout reached, hiding splashscreen");
    cg_plugin_lock_state(engine)->auto_splashscreen_timed_out = true;
    cg_plugin_unlock_state(engine);
    cj_free(cg_plugin_hook(engine, CG_HOOK_SPLASH, cj_objv("action", cj_str("hide"), NULL)));
    cg_engine_release(engine);
}

void cg_ready_show_splashscreen(cg_engine *engine) {
    uint64_t generation = atomic_fetch_add(&engine->plugin.splash_timer, 1) + 1;
    cg_plugin_lock_state(engine)->auto_splashscreen_timed_out = false;
    cg_plugin_unlock_state(engine);
    cj_free(cg_plugin_hook(engine, CG_HOOK_SPLASH, cj_objv("action", cj_str("show"), NULL)));
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    uint64_t timeout = config.auto_splashscreen_timeout_ms;
    cg_plugin_config_clear(&config);
    if (timeout == 0) return;
    splash_timer *timer = cg_malloc(sizeof(splash_timer));
    timer->generation = generation;
    timer->timeout_ms = (int64_t)timeout;
    cg_engine_spawn_weak(engine, "app-ready-timeout", splash_timer_main, timer, free);
}

void cg_ready_hide_splashscreen(cg_engine *engine) {
    atomic_fetch_add(&engine->plugin.splash_timer, 1);
    cj_free(cg_plugin_hook(engine, CG_HOOK_SPLASH, cj_objv("action", cj_str("hide"), NULL)));
}
