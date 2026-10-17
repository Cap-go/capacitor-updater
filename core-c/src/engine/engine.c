/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* The updater engine (Rust engine/mod.rs). */

#include "engine/engine.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#ifdef __ANDROID__
#include <fcntl.h>
#include <sys/resource.h>
#include <unistd.h>
#endif

#include "api.h"
#include "engine/ops.h"
#include "http.h"
#include "policy.h"
#ifdef CAPGO_TEST_SUPPORT
#include "testing.h"
#endif

/* ---------------------------------------------------------------- creation / drop */

static void http_settings(const cg_engine_config *config, char **user_agent) {
    *user_agent = cg_http_user_agent(config->app_id, config->plugin_version, config->version_os, config->platform);
}

#ifdef __ANDROID__
/*
 * C-only (no Rust counterpart, nothing observable by the host). Linux grows a process's
 * descriptor table by powers of two, and each growth waits for an RCU grace period
 * (synchronize_rcu, 15-20 ms on the emulator) during which every thread that needs a
 * descriptor past the old table sleeps. A WebView app settles at about 250 descriptors, so
 * the first parallel manifest download crossed 256 with all its workers opening sockets and
 * partial files at once, and each of them waited for the grace period (Rust pays the same
 * wait in whichever download first crosses 256: in the bench app, the first zip, whose
 * extraction workers each open the archive while C shares one descriptor). This grows the table
 * once per process, on its own thread right after the first engine is created (the app is
 * still starting, so it is usually below 256 then), to at least 512 slots and to fit one
 * manifest download at full concurrency (a socket and a partial file per worker) above the
 * descriptors already open. A thread that needs a slot past the old table meanwhile waits
 * for this growth instead of starting its own.
 */
static void reserve_descriptors(void *arg) {
    (void)arg;
    int probe = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (probe < 0) return;
    /* The lowest free descriptor: about the number already open. */
    int64_t target = probe + 2 * cg_policy_manifest_max_concurrent_files(cg_cpu_count()) + 16;
    if (target < 511) target = 511;
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY &&
        (uint64_t)target >= (uint64_t)limit.rlim_cur)
        target = (int64_t)limit.rlim_cur - 1;
    if (target > probe) {
        int high = fcntl(probe, F_DUPFD_CLOEXEC, (int)target);
        if (high >= 0) close(high);
    }
    close(probe);
}

static atomic_bool descriptors_reserved;
#endif

cg_engine *cg_engine_create(const char *config_json, const CapgoHostCallbacks *callbacks, cg_error *err) {
    size_t start, len;
    cg_trim_range(config_json, &start, &len);
    cj *value;
    if (len == 0) {
        value = cj_null();
    } else {
        char *parse_error = NULL;
        value = cj_parse(config_json, &parse_error);
        if (!value) {
            cg_err_invalid_input(err, "Invalid engine config: %s", cg_or_empty(parse_error));
            free(parse_error);
            return NULL;
        }
    }
    cg_engine_config *config = cg_config_from_json(value, err);
    cj_free(value);
    if (!config) return NULL;

    cg_engine *engine = cg_calloc(1, sizeof(cg_engine));
    atomic_init(&engine->strong, 1);
    atomic_init(&engine->weak, 1);
    engine->host.cb = *callbacks;
    char *user_agent;
    http_settings(config, &user_agent);
    engine->http = cg_http_new(&engine->host, user_agent, config->timeout_ms);
    free(user_agent);
    cg_http_set_allow_https_to_http_redirect(engine->http, config->allow_https_to_http_redirect);
    cg_http_set_http3(engine->http, config->http3, config->http3_connections);
    cg_mutex_init(&engine->config_lock);
    cg_mutex_init(&engine->config_write);
    engine->config = config;
    cg_stats_state_init(&engine->stats);
    cg_mutex_init(&engine->delete_lock);
    cg_download_map_init(&engine->downloads);
    cg_plugin_init(&engine->plugin);
    atomic_init(&engine->downloads_detached, false);
#ifdef __ANDROID__
    if (!atomic_exchange(&descriptors_reserved, true)) cg_spawn("fdtable", reserve_descriptors, NULL);
#endif
    return engine;
}

/* Rust `impl Drop for Engine` followed by the drop of every field. */
static void engine_drop(cg_engine *engine) {
    cg_stats_shutdown_stats(engine);
    cg_plugin_destroy(&engine->plugin);
    cg_download_map_destroy(&engine->downloads);
    cg_mutex_destroy(&engine->delete_lock);
    cg_stats_state_destroy(&engine->stats);
    cg_config_release(engine->config);
    engine->config = NULL;
    cg_mutex_destroy(&engine->config_write);
    cg_mutex_destroy(&engine->config_lock);
    cg_http_free(engine->http);
    engine->http = NULL;
    /* Last: the host context (Rust drops the last Arc<dyn Host> with the fields). */
    cg_host_release(&engine->host);
}

/* ---------------------------------------------------------------- references */

cg_engine *cg_engine_retain(cg_engine *engine) {
    if (engine) atomic_fetch_add(&engine->strong, 1);
    return engine;
}

static void weak_drop(cg_engine *engine) {
    if (atomic_fetch_sub(&engine->weak, 1) == 1) free(engine);
}

void cg_engine_release(cg_engine *engine) {
    if (!engine) return;
    if (atomic_fetch_sub(&engine->strong, 1) == 1) {
        engine_drop(engine);
        /* The weak reference shared by the strong ones. */
        weak_drop(engine);
    }
}

cg_engine_weak *cg_engine_downgrade(cg_engine *engine) {
    atomic_fetch_add(&engine->weak, 1);
    return (cg_engine_weak *)engine;
}

cg_engine *cg_engine_upgrade(cg_engine_weak *weak) {
    if (!weak) return NULL;
    cg_engine *engine = (cg_engine *)weak;
    size_t strong = atomic_load(&engine->strong);
    while (strong > 0) {
        if (atomic_compare_exchange_weak(&engine->strong, &strong, strong + 1)) return engine;
    }
    return NULL;
}

void cg_engine_weak_release(cg_engine_weak *weak) {
    if (weak) weak_drop((cg_engine *)weak);
}

cg_engine *cg_engine_sleep_unless_dropped(cg_engine_weak *weak, int64_t ms) {
    cg_sleep_ms(ms);
    return cg_engine_upgrade(weak);
}

void cg_engine_free_handle(cg_engine *engine) { cg_engine_release(engine); }

/* ---------------------------------------------------------------- configuration */

cg_engine_config *cg_engine_config_snapshot(cg_engine *engine) {
    cg_lock(&engine->config_lock);
    cg_engine_config *config = cg_config_retain(engine->config);
    cg_unlock(&engine->config_lock);
    return config;
}

char *cg_engine_config_dup(cg_engine *engine, size_t offset) {
    cg_engine_config *config = cg_engine_config_snapshot(engine);
    char *value = cg_strdup(*(char **)((char *)config + offset));
    cg_config_release(config);
    return value;
}

bool cg_engine_config_flag(cg_engine *engine, size_t offset) {
    cg_engine_config *config = cg_engine_config_snapshot(engine);
    bool value = *(bool *)((char *)config + offset);
    cg_config_release(config);
    return value;
}

cg_engine_config *cg_engine_config_begin(cg_engine *engine) {
    cg_lock(&engine->config_write);
    cg_lock(&engine->config_lock);
    cg_engine_config *copy = cg_config_clone(engine->config);
    cg_unlock(&engine->config_lock);
    return copy;
}

void cg_engine_config_commit(cg_engine *engine, cg_engine_config *config) {
    cg_lock(&engine->config_lock);
    cg_engine_config *old = engine->config;
    engine->config = config;
    cg_unlock(&engine->config_lock);
    cg_unlock(&engine->config_write);
    /* Snapshots taken earlier keep the old values. */
    cg_config_release(old);
}

void cg_engine_config_abort(cg_engine *engine, cg_engine_config *config) {
    cg_unlock(&engine->config_write);
    cg_config_release(config);
}

bool cg_engine_configure(cg_engine *engine, const cj *value, cg_error *err) {
    cg_engine_config *config = cg_engine_config_begin(engine);
    /* All or nothing: an invalid public key must not leave half the settings applied. */
    if (!cg_config_apply(config, value, err)) {
        cg_engine_config_abort(engine, config);
        return false;
    }
    bool allow_downgrade = config->allow_https_to_http_redirect;
    uint64_t timeout_ms = config->timeout_ms;
    bool http3 = config->http3;
    uint64_t http3_connections = config->http3_connections;
    char *user_agent;
    http_settings(config, &user_agent);
    cg_engine_config_commit(engine, config);
    cg_http_set_user_agent(engine->http, user_agent);
    cg_http_set_timeout(engine->http, timeout_ms);
    cg_http_set_allow_https_to_http_redirect(engine->http, allow_downgrade);
    cg_http_set_http3(engine->http, http3, http3_connections);
    free(user_agent);
    return true;
}

char *cg_engine_user_agent(cg_engine *engine) { return cg_http_get_user_agent(engine->http); }

/* ---------------------------------------------------------------- threads */

bool cg_engine_spawn(cg_engine *engine, const char *name, void (*run)(void *arg), void *arg) {
    if (cg_spawn(name, run, arg)) return true;
    char *error = cg_io_message(EAGAIN);
    cg_error_log(&engine->host, "Could not start the %s thread: %s", name, error);
    free(error);
    return false;
}

typedef struct {
    cg_engine *engine;     /* spawn_strong */
    cg_engine_weak *weak;  /* spawn_weak */
    void (*run_strong)(cg_engine *engine, void *ctx);
    void (*run_weak)(cg_engine_weak *weak, void *ctx);
    void *ctx;
    void (*drop_ctx)(void *ctx);
} closure;

static void closure_drop(closure *job) {
    if (job->drop_ctx) job->drop_ctx(job->ctx);
    cg_engine_release(job->engine);
    cg_engine_weak_release(job->weak);
    free(job);
}

static void closure_main(void *arg) {
    closure *job = arg;
    if (job->run_strong) job->run_strong(job->engine, job->ctx);
    else job->run_weak(job->weak, job->ctx);
    closure_drop(job);
}

bool cg_engine_spawn_strong(cg_engine *engine, const char *name, void (*run)(cg_engine *engine, void *ctx),
                            void *ctx, void (*drop_ctx)(void *ctx)) {
    closure *job = cg_calloc(1, sizeof(closure));
    job->engine = cg_engine_retain(engine);
    job->run_strong = run;
    job->ctx = ctx;
    job->drop_ctx = drop_ctx;
    if (cg_engine_spawn(engine, name, closure_main, job)) return true;
    closure_drop(job);
    return false;
}

bool cg_engine_spawn_weak(cg_engine *engine, const char *name, void (*run)(cg_engine_weak *weak, void *ctx),
                          void *ctx, void (*drop_ctx)(void *ctx)) {
    closure *job = cg_calloc(1, sizeof(closure));
    job->weak = cg_engine_downgrade(engine);
    job->run_weak = run;
    job->ctx = ctx;
    job->drop_ctx = drop_ctx;
    if (cg_engine_spawn(engine, name, closure_main, job)) return true;
    closure_drop(job);
    return false;
}

/* ---------------------------------------------------------------- calls */

cj *cg_engine_call(cg_engine *engine, const char *operation, const cj *input, cg_error *err) {
    cj empty = {.type = CJ_OBJECT};
    if (cj_is_null(input)) input = &empty;
    if (!cj_is_obj(input)) {
        cg_err_invalid_input(err, "input must be a JSON object");
        return NULL;
    }
    cj *result = NULL;
#ifdef CAPGO_TEST_SUPPORT
    if (strncmp(operation, CG_TEST_PREFIX, strlen(CG_TEST_PREFIX)) == 0 &&
        cg_testing_engine_call(engine, operation + strlen(CG_TEST_PREFIX), input, &result, err))
        return result;
#endif
    if (cg_ops_call_engine(engine, operation, input, &result, err)) return result;
    result = cg_api_call(operation, input, err);
    if (cg_err_is(err, "unknown_operation"))
        cg_err_set(err, "unknown_operation", "Unknown engine operation: %s", operation);
    return result;
}

char *cg_engine_call_json(cg_engine *engine, const char *operation, const char *input_json) {
    cg_error err = CG_ERROR_INIT;
    cj *value = NULL;
    size_t start, len;
    cg_trim_range(input_json, &start, &len);
    if (len == 0) {
        value = cg_engine_call(engine, operation, NULL, &err);
    } else {
        char *parse_error = NULL;
        cj *input = cj_parse(input_json, &parse_error);
        if (!input) {
            cg_err_invalid_input(&err, "Invalid JSON input: %s", cg_or_empty(parse_error));
        } else {
            value = cg_engine_call(engine, operation, input, &err);
            cj_free(input);
        }
        free(parse_error);
    }
    char *out = cg_api_envelope(value, &err);
    cg_err_clear(&err);
    return out;
}
