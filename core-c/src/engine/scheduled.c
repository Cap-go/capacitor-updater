/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Downloads run as jobs of the host's scheduler (Rust engine/scheduled.rs). */

#include "engine/scheduled.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#include "engine/engine.h"
#include "engine/fsutil.h"
#include "engine/manifest.h"
#include "engine/plugin/flow.h"
#include "engine/plugin/plugin.h"
#include "engine/store.h"

void cg_scheduled_clear(cg_scheduled *scheduled) {
    cg_bundle_info_clear(&scheduled->bundle);
    cg_err_clear(&scheduled->error);
    scheduled->kind = CG_SCHEDULED_SETTLED;
    scheduled->ok = false;
}

/* Rust `error.clone()`. */
static void error_copy(cg_error *out, const cg_error *error) {
    cg_err_set(out, error->code, "%s", cg_or_empty(error->message));
}

/* ---------------------------------------------------------------- job registry */

/* Waiter. */
typedef struct waiter {
    char *id;
    char *version;
    /* Failed attempts the scheduler will retry. */
    uint32_t retries;
    bool has_outcome;
    cg_scheduled outcome;
    struct waiter *next;
} waiter;

/* Attempt running in this process, by job id. */
typedef struct running_job {
    char *id;
    cg_cancel *cancel; /* one reference */
    struct running_job *next;
} running_job;

/* Process-wide: the job may run on another engine of the process (a worker started before the
 * plugin loaded) than the one waiting for it. Leaf lock. */
static cg_mutex jobs_lock = CG_MUTEX_INIT;
static cg_cond jobs_changed = CG_COND_INIT;
static waiter *waiters;
static running_job *running;

static waiter **find_waiter(const char *id) {
    waiter **slot = &waiters;
    while (*slot && strcmp((*slot)->id, id) != 0) slot = &(*slot)->next;
    return slot;
}

static void waiter_free(waiter *entry) {
    free(entry->id);
    free(entry->version);
    cg_scheduled_clear(&entry->outcome);
    free(entry);
}

/* HashMap::remove (call with jobs_lock held). */
static void remove_waiter(const char *id) {
    waiter **slot = find_waiter(id);
    waiter *entry = *slot;
    if (!entry) return;
    *slot = entry->next;
    waiter_free(entry);
}

/* HashMap::insert (call with jobs_lock held): replaces an existing waiter. */
static void insert_waiter(const char *id, const char *version) {
    remove_waiter(id);
    waiter *entry = cg_calloc(1, sizeof(waiter));
    entry->id = cg_strdup(id);
    entry->version = cg_strdup(version);
    entry->next = waiters;
    waiters = entry;
}

static running_job **find_running(const char *id) {
    running_job **slot = &running;
    while (*slot && strcmp((*slot)->id, id) != 0) slot = &(*slot)->next;
    return slot;
}

/* Tells the caller waiting for job `id` (if any) that an attempt failed and is retried. */
static void count_retry(const char *id) {
    cg_lock(&jobs_lock);
    waiter *entry = *find_waiter(id);
    if (entry) entry->retries++;
    cg_unlock(&jobs_lock);
    cg_cond_broadcast(&jobs_changed);
}

/* Hands the final outcome (consumed) to the caller waiting for job `id` (if any). */
static void publish(const char *id, cg_scheduled *outcome) {
    cg_lock(&jobs_lock);
    waiter *entry = *find_waiter(id);
    if (entry) {
        cg_scheduled_clear(&entry->outcome);
        entry->outcome = *outcome;
        entry->has_outcome = true;
        memset(outcome, 0, sizeof *outcome);
    }
    cg_unlock(&jobs_lock);
    cg_scheduled_clear(outcome);
    cg_cond_broadcast(&jobs_changed);
}

/* publish(id, Settled(Err(error.clone()))). */
static void publish_error(const char *id, const cg_error *error) {
    cg_scheduled outcome = {0};
    outcome.kind = CG_SCHEDULED_SETTLED;
    error_copy(&outcome.error, error);
    publish(id, &outcome);
}

static void publish_cancelled(const char *id) {
    cg_scheduled outcome = {0};
    outcome.kind = CG_SCHEDULED_CANCELLED;
    publish(id, &outcome);
}

size_t cg_scheduled_running_jobs(void) {
    cg_lock(&jobs_lock);
    size_t count = 0;
    for (running_job *job = running; job; job = job->next) count++;
    cg_unlock(&jobs_lock);
    return count;
}

static cj *failure_reply(const cg_error *error) {
    return cj_objv("result", cj_str("failure"), "error",
                   cj_objv("code", cj_str(error->code), "message", cj_str(cg_or_empty(error->message)), NULL), NULL);
}

static cj *retry_reply(const cg_error *error) {
    return cj_objv("result", cj_str("retry"), "error",
                   cj_objv("code", cj_str(error->code), "message", cj_str(cg_or_empty(error->message)), NULL), NULL);
}

/* ---------------------------------------------------------------- job files */

static char *jobs_dir(cg_engine *engine) {
    char *storage = CG_CONFIG_DUP(engine, storage_root);
    char *dir = cg_fsutil_join(storage, CG_JOBS_DIR);
    free(storage);
    return dir;
}

static char *job_path(cg_engine *engine, const char *id) {
    char *dir = jobs_dir(engine);
    char *name = cg_fmt("%s.json", id);
    char *path = cg_fsutil_join(dir, name);
    free(name);
    free(dir);
    return path;
}

/* `fs::read(path).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok())`. */
static cj *read_json(const char *path) {
    int fd = cg_fsutil_open(path, O_RDONLY, 0);
    if (fd < 0) return NULL;
    cg_buf buf = {0};
    uint8_t chunk[16384];
    for (;;) {
        ssize_t read_bytes = read(fd, chunk, sizeof chunk);
        if (read_bytes < 0 && errno == EINTR) continue;
        if (read_bytes < 0) {
            close(fd);
            cg_buf_free(&buf);
            return NULL;
        }
        if (read_bytes == 0) break;
        cg_buf_put(&buf, chunk, (size_t)read_bytes);
    }
    close(fd);
    cj *value = cj_parsen(buf.data ? buf.data : "", buf.len, NULL);
    cg_buf_free(&buf);
    return value;
}

static cj *read_job(cg_engine *engine, const char *id) {
    char *path = job_path(engine, id);
    cj *job = read_json(path);
    free(path);
    return job;
}

cg_strs cg_scheduled_pending_job_ids(cg_engine *engine) {
    cg_strs ids = {0};
    char *dir = jobs_dir(engine);
    size_t count = 0;
    cg_error err = CG_ERROR_INIT;
    char **names = cg_fsutil_read_dir(dir, &count, &err);
    free(dir);
    cg_err_clear(&err);
    if (!names) return ids;
    for (size_t i = 0; i < count; i++) {
        char *name = cg_utf8_lossy((const uint8_t *)names[i], strlen(names[i]));
        if (cg_ends_with(name, ".json")) {
            name[strlen(name) - strlen(".json")] = '\0';
            cg_strs_push(&ids, name);
        } else {
            free(name);
        }
    }
    cg_fsutil_free_names(names, count);
    return ids;
}

/* Settings a job needs when it runs on an engine the plugin did not configure (process
 * started by the scheduler): endpoints, identity, public key, timeouts. */
static cj *job_settings(cg_engine *engine) {
    cg_engine_config *config = cg_engine_config_snapshot(engine);
    cj *settings = cj_objv(                                               //
        "appId", cj_str(config->app_id),                                  //
        "pluginVersion", cj_str(config->plugin_version),                  //
        "versionBuild", cj_str(config->version_build),                    //
        "versionCode", cj_str(config->version_code),                      //
        "versionOs", cj_str(config->version_os),                          //
        "deviceId", cj_str(config->device_id),                            //
        "customId", cj_str(config->custom_id),                            //
        "defaultChannel", cj_str(config->default_channel),                //
        "installSource", cj_str(config->install_source),                  //
        "updateUrl", cj_str(config->update_url),                          //
        "statsUrl", cj_str(config->stats_url),                            //
        "channelUrl", cj_str(config->channel_url),                        //
        "isEmulator", cj_bool(config->is_emulator),                       //
        "isProd", cj_bool(config->is_prod),                               //
        "previewSession", cj_bool(config->preview_session),               //
        "allowHttpsToHttpRedirect", cj_bool(config->allow_https_to_http_redirect), //
        "timeoutMs", cj_u64(config->timeout_ms),                          //
        "publicKey", cj_str(config->public_key),                          //
        NULL);
    cg_config_release(config);
    return settings;
}

bool cg_scheduled_job_has_manifest(cg_engine *engine, const char *id) {
    cj *job = read_job(engine, id);
    bool has = cj_is_arr(cj_path(job, "request", "manifest", NULL));
    cj_free(job);
    return has;
}

static void remove_job(cg_engine *engine, const char *id) {
    char *path = job_path(engine, id);
    unlink(path);
    free(path);
}

/* Removes a job and its partial download files. */
static void discard_job(cg_engine *engine, const char *id) {
    remove_job(engine, id);
    char *storage = CG_CONFIG_DUP(engine, storage_root);
    char *names[] = {cg_fmt("temp_%s.tmp", id), cg_fmt("temp_%s.plain", id), cg_fmt("update_%s.dat", id)};
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        char *path = cg_fsutil_join(storage, names[i]);
        unlink(path);
        free(path);
        free(names[i]);
    }
    free(storage);
}

/* ---------------------------------------------------------------- scheduling */

/* Registers the caller of job `id` and asks the host to run it (idempotent for a job it
 * already has). false: the host does not schedule downloads. */
static bool hand_to_scheduler(cg_engine *engine, const char *id, const char *version) {
    cg_lock(&jobs_lock);
    insert_waiter(id, version);
    cg_unlock(&jobs_lock);
    cj *reply = cg_plugin_hook(engine, CG_HOOK_SCHEDULE_DOWNLOAD,
                               cj_objv("id", cj_str(id), "version", cj_str(version), NULL));
    bool scheduled = false;
    if (reply) cj_as_bool(cj_get(reply, "scheduled"), &scheduled);
    cj_free(reply);
    if (!scheduled) {
        cg_lock(&jobs_lock);
        remove_waiter(id);
        cg_unlock(&jobs_lock);
    }
    return scheduled;
}

/* Blocks until job `id` ends, is cancelled, or the engine is released. Without a network the
 * job waits for it, so this can take as long as the device stays offline. */
static void await_scheduled(cg_engine *engine, const char *id, const char *version, const cg_cancel *cancel,
                            cg_scheduled *out) {
    cg_release_method_lane();
    cg_flow_scheduled_download_waiting(engine, version, true);
    uint32_t seen_retries = 0;
    memset(out, 0, sizeof *out);
    cg_lock(&jobs_lock);
    for (;;) {
        waiter *entry = *find_waiter(id);
        if (!entry) {
            out->kind = CG_SCHEDULED_CANCELLED;
            break;
        }
        if (entry->has_outcome) {
            *out = entry->outcome;
            memset(&entry->outcome, 0, sizeof entry->outcome);
            entry->has_outcome = false;
            break;
        }
        if (atomic_load(&engine->downloads_detached)) {
            out->kind = CG_SCHEDULED_DETACHED;
            break;
        }
        if (cg_cancel_is_cancelled(cancel)) {
            out->kind = CG_SCHEDULED_CANCELLED;
            break;
        }
        if (entry->retries > seen_retries) {
            seen_retries = entry->retries;
            cg_unlock(&jobs_lock);
            cg_flow_scheduled_download_retrying(engine, version);
            cg_lock(&jobs_lock);
            continue;
        }
        cg_cond_wait_ms(&jobs_changed, &jobs_lock, CG_SCHEDULED_WAIT_TICK_MS);
    }
    remove_waiter(id);
    cg_unlock(&jobs_lock);
    cg_flow_scheduled_download_waiting(engine, version, false);
}

bool cg_scheduled_schedule_download(cg_engine *engine, const cg_download_request *request,
                                    const cg_bundle_info *record, const cg_cancel *cancel, cg_scheduled *out) {
    char *id = cg_strdup(cg_bundle_info_id(record));
    cg_download_request job_request;
    cg_download_request_copy(&job_request, request);
    cg_replace(&job_request.id, cg_strdup(id));
    cj *job = cj_objv("request", cg_download_request_to_json(&job_request), "settings", job_settings(engine), NULL);
    cg_download_request_clear(&job_request);
    char *text = cj_print(job);
    cj_free(job);
    /* Written before the hook: the scheduler may start the job right away. */
    char *dir = jobs_dir(engine);
    bool written = cg_fsutil_create_dir_all(dir);
    free(dir);
    if (written) {
        char *path = job_path(engine, id);
        cg_error err = CG_ERROR_INIT;
        written = cg_fsutil_write_atomically(path, text, strlen(text), &err);
        cg_err_clear(&err);
        free(path);
    }
    free(text);
    if (!written) {
        free(id);
        return false;
    }
    if (!hand_to_scheduler(engine, id, request->version)) {
        remove_job(engine, id);
        free(id);
        return false;
    }
    cg_info(&engine->host, "Download of %s scheduled (job %s), waiting for it", request->version, id);
    await_scheduled(engine, id, request->version, cancel, out);
    free(id);
    return true;
}

int cg_scheduled_adopt_scheduled_download(cg_engine *engine, const char *version, cg_bundle_info *out,
                                          cg_error *err) {
    static const cj null_value = {.type = CJ_NULL};
    cg_bundle_info record = {0};
    cg_download_request request;
    bool found = false;
    cg_strs ids = cg_scheduled_pending_job_ids(engine);
    for (size_t i = 0; i < ids.len && !found; i++) {
        const char *id = ids.items[i];
        cj *job = read_job(engine, id);
        if (!job) continue;
        const cj *raw = cj_is_obj(job) ? cj_get(job, "request") : NULL;
        cg_error parse_error = CG_ERROR_INIT;
        bool parsed = cg_download_request_from_json(raw ? raw : &null_value, &request, &parse_error);
        cg_err_clear(&parse_error);
        cj_free(job);
        if (!parsed) continue;
        if (strcmp(request.version, version) != 0) {
            cg_download_request_clear(&request);
            continue;
        }
        cg_store_get_bundle_info(engine, id, &record);
        if (cg_bundle_info_is_downloading(&record) && strcmp(cg_bundle_info_version_name(&record), version) == 0) {
            found = true;
        } else {
            cg_bundle_info_clear(&record);
            cg_download_request_clear(&request);
        }
    }
    cg_strs_free(&ids);
    if (!found) return -1;
    const char *id = cg_bundle_info_id(&record);
    cg_lock(&jobs_lock);
    bool waiting = *find_waiter(id) != NULL;
    cg_unlock(&jobs_lock);
    if (waiting || !hand_to_scheduler(engine, id, request.version)) {
        cg_bundle_info_clear(&record);
        cg_download_request_clear(&request);
        return -1;
    }
    cg_info(&engine->host, "Resuming the scheduled download of %s started before the app restarted",
            request.version);
    cg_cancel *cancel = cg_manifest_register_download_token(engine, request.version);
    cg_scheduled outcome;
    await_scheduled(engine, id, request.version, cancel, &outcome);
    cg_manifest_unregister_download_token(engine, request.version, cancel);
    cg_cancel_release(cancel);
    bool ok = cg_scheduled_scheduled_result(engine, &request, &record, &outcome, out, err);
    cg_bundle_info_clear(&record);
    cg_download_request_clear(&request);
    return ok ? 1 : 0;
}

bool cg_scheduled_scheduled_result(cg_engine *engine, const cg_download_request *request,
                                   const cg_bundle_info *record, cg_scheduled *scheduled, cg_bundle_info *out,
                                   cg_error *err) {
    bool ok = false;
    switch (scheduled->kind) {
    case CG_SCHEDULED_SETTLED:
        if (scheduled->ok) {
            *out = scheduled->bundle;
            memset(&scheduled->bundle, 0, sizeof scheduled->bundle);
            ok = true;
        } else {
            if (err) cg_err_move(err, &scheduled->error);
        }
        break;
    case CG_SCHEDULED_CANCELLED: {
        cg_error error = CG_ERROR_INIT;
        cg_err_set(&error, "download_stopped", "Download cancelled");
        /* A deleted bundle keeps its delete: only a live record becomes ERROR. */
        cg_bundle_info current;
        cg_store_get_bundle_info(engine, cg_bundle_info_id(record), &current);
        bool downloading = cg_bundle_info_is_downloading(&current);
        cg_bundle_info_clear(&current);
        if (downloading) {
            cg_bundle_info unused = {0};
            cg_download_settle_download(engine, request, record, false, &unused, &error);
            cg_bundle_info_clear(&unused);
        }
        if (err)
            cg_err_move(err, &error);
        else
            cg_err_clear(&error);
        break;
    }
    case CG_SCHEDULED_DETACHED:
        cg_err_set(err, "download_detached",
                   "The updater was released; the scheduled download continues in the background");
        break;
    }
    cg_scheduled_clear(scheduled);
    return ok;
}

cj *cg_scheduled_run_scheduled_download(cg_engine *engine, const char *id) {
    static const cj null_value = {.type = CJ_NULL};
    cj *job = read_job(engine, id);
    const cj *raw = cj_is_obj(job) ? cj_get(job, "request") : NULL;
    cg_download_request request;
    bool parsed = false;
    if (raw) {
        cg_error parse_error = CG_ERROR_INIT;
        parsed = cg_download_request_from_json(raw, &request, &parse_error);
        cg_err_clear(&parse_error);
    }
    if (!job || !parsed) {
        /* Cancelled (or never written): nothing to run. */
        cj_free(job);
        cg_error error = CG_ERROR_INIT;
        cg_err_set(&error, "download_obsolete", "Scheduled download no longer exists");
        publish_error(id, &error);
        cj *reply = failure_reply(&error);
        cg_err_clear(&error);
        return reply;
    }
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    bool loaded = state->loaded;
    cg_plugin_unlock_state(engine);
    if (!loaded) {
        /* Engine created for the job alone (no plugin in this process yet). */
        const cj *settings = cj_is_obj(job) ? cj_get(job, "settings") : NULL;
        cg_error error = CG_ERROR_INIT;
        if (!cg_engine_configure(engine, settings ? settings : &null_value, &error))
            cg_warn(&engine->host, "Scheduled download settings rejected: %s", cg_or_empty(error.message));
        cg_err_clear(&error);
    }
    cj_free(job);
    cg_bundle_info record;
    cg_store_get_bundle_info(engine, id, &record);
    if (!cg_bundle_info_is_downloading(&record) || strcmp(cg_bundle_info_version_name(&record), request.version) != 0) {
        cg_info(&engine->host, "Scheduled download %s is obsolete (bundle deleted or settled)", id);
        discard_job(engine, id);
        cg_error error = CG_ERROR_INIT;
        cg_err_set(&error, "download_obsolete", "Scheduled download no longer exists");
        publish_error(id, &error);
        cj *reply = failure_reply(&error);
        cg_err_clear(&error);
        cg_bundle_info_clear(&record);
        cg_download_request_clear(&request);
        return reply;
    }
    cg_cancel *cancel = cg_manifest_register_download_token(engine, request.version);
    cg_lock(&jobs_lock);
    running_job **slot = find_running(id);
    if (*slot) {
        cg_cancel_release((*slot)->cancel);
        (*slot)->cancel = cg_cancel_retain(cancel);
    } else {
        running_job *entry = cg_calloc(1, sizeof(running_job));
        entry->id = cg_strdup(id);
        entry->cancel = cg_cancel_retain(cancel);
        entry->next = running;
        running = entry;
    }
    cg_unlock(&jobs_lock);
    cg_bundle_info installed;
    cg_error error = CG_ERROR_INIT;
    bool ok = cg_download_transfer_and_install(engine, &request, &record, cancel, true, &installed, &error);
    cg_lock(&jobs_lock);
    slot = find_running(id);
    if (*slot) {
        running_job *entry = *slot;
        *slot = entry->next;
        cg_cancel_release(entry->cancel);
        free(entry->id);
        free(entry);
    }
    cg_unlock(&jobs_lock);
    cg_manifest_unregister_download_token(engine, request.version, cancel);
    cg_cancel_release(cancel);
    cj *reply;
    if (ok) {
        remove_job(engine, id);
        reply = cj_objv("result", cj_str("success"), "bundle", cg_bundle_info_to_raw(&installed), NULL);
        cg_scheduled outcome = {0};
        outcome.kind = CG_SCHEDULED_SETTLED;
        outcome.ok = true;
        outcome.bundle = installed;
        publish(id, &outcome);
    } else if (cg_err_is(&error, "download_stopped")) {
        /* Stopped by the scheduler (constraints lost, time limit): it runs the job again. A
         * cancel also lands here; the scheduler then drops the job. */
        cg_info(&engine->host, "Scheduled download %s stopped", id);
        /* Waiting for the constraints again is a retry for the caller too (a direct update
         * stops holding the launch). A cancelled job is gone: nothing to retry. */
        char *path = job_path(engine, id);
        if (cg_fsutil_exists(path)) count_retry(id);
        free(path);
        reply = retry_reply(&error);
    } else if (cg_download_is_retryable_download_error(&error)) {
        cg_warn(&engine->host, "Scheduled download %s failed (%s), the scheduler retries it", id,
                cg_or_empty(error.message));
        count_retry(id);
        reply = retry_reply(&error);
    } else {
        reply = failure_reply(&error);
        cg_scheduled outcome = {0};
        outcome.kind = CG_SCHEDULED_SETTLED;
        outcome.ok = cg_download_settle_download(engine, &request, &record, false, &outcome.bundle, &error);
        if (!outcome.ok) cg_err_move(&outcome.error, &error);
        discard_job(engine, id);
        publish(id, &outcome);
    }
    cg_err_clear(&error);
    cg_bundle_info_clear(&record);
    cg_download_request_clear(&request);
    return reply;
}

void cg_scheduled_stop_scheduled_download(cg_engine *engine, const char *id) {
    (void)engine;
    cg_lock(&jobs_lock);
    running_job *entry = *find_running(id);
    if (entry) cg_cancel_set(entry->cancel);
    cg_unlock(&jobs_lock);
}

void cg_scheduled_cancel_scheduled_downloads(cg_engine *engine, const char *version) {
    cg_strs pending = cg_scheduled_pending_job_ids(engine);
    cg_strs ids = {0};
    for (size_t i = 0; i < pending.len; i++) {
        const char *id = pending.items[i];
        bool matches = version == NULL;
        if (!matches) {
            cj *job = read_job(engine, id);
            const cj *job_version = cj_path(job, "request", "version", NULL);
            bool job_matches = cj_is_str(job_version) && !cj_str_has_nul(job_version) &&
                               strcmp(cj_as_str(job_version), version) == 0;
            cj_free(job);
            cg_lock(&jobs_lock);
            waiter *entry = *find_waiter(id);
            bool waiting_matches = entry && strcmp(entry->version, version) == 0;
            cg_unlock(&jobs_lock);
            matches = job_matches || waiting_matches;
        }
        if (matches) cg_strs_push_copy(&ids, id);
    }
    cg_strs_free(&pending);
    for (size_t i = 0; i < ids.len; i++) {
        const char *id = ids.items[i];
        cg_info(&engine->host, "Cancelling scheduled download %s", id);
        discard_job(engine, id);
        cg_scheduled_stop_scheduled_download(engine, id);
        publish_cancelled(id);
    }
    cg_strs_free(&ids);
}

bool cg_scheduled_cancel_version_download(cg_engine *engine, const char *version) {
    if (!cg_host_cancel_version_download(&engine->host, version)) return false;
    cg_scheduled_cancel_scheduled_downloads(engine, version);
    return true;
}

void cg_scheduled_detach_scheduled_downloads(cg_engine *engine) {
    atomic_store(&engine->downloads_detached, true);
    cg_cond_broadcast(&jobs_changed);
}
