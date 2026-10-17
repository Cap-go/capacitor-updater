/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Port of core/src/engine/crash_guard.rs (see the header). */

#include "engine/crash_guard.h"

#include <inttypes.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "engine/engine.h"
#include "engine/plugin/plugin.h"
#include "engine/stats.h"
#include "engine/store.h"
#include "host.h"
#include "rt/str.h"
#include "rt/sync.h"

/* Deaths in a row that mark a version failed. */
#define DEATHS_TO_FAIL 2

/* Serializes the read-modify-write of the records (every engine of the process shares the
 * storage). A leaf: only key-value calls run under it. */
static cg_mutex guard_lock = CG_MUTEX_INIT;

static pthread_once_t token_once = PTHREAD_ONCE_INIT;
static char *token;

static void token_init(void) { token = cg_store_random_id(); }

/* Identifies this process in the records (a pid can be reused by the next process). */
static const char *process_token(void) {
    pthread_once(&token_once, token_init);
    return token;
}

/* Android ApplicationExitInfo reasons that are crashes: CRASH, CRASH_NATIVE, ANR. */
static bool is_crash_reason(int64_t reason) { return reason == 4 || reason == 5 || reason == 6; }

typedef struct {
    char *version;
    char *step;
    char *id;
    uint64_t attempts;
    uint64_t active;
    char *process;
    uint64_t pid;
    bool background;
    bool failed;
} step_record;

typedef struct {
    step_record *items;
    size_t len, cap;
} records;

static void record_clear(step_record *record) {
    free(record->version);
    free(record->step);
    free(record->id);
    free(record->process);
    memset(record, 0, sizeof *record);
}

static void records_free(records *list) {
    for (size_t i = 0; i < list->len; i++) record_clear(&list->items[i]);
    free(list->items);
    memset(list, 0, sizeof *list);
}

static void set_text(char **field, const char *value) {
    free(*field);
    *field = cg_strdup(value ? value : "");
}

static step_record *records_push(records *list, const char *version) {
    if (list->len == list->cap) {
        list->cap = list->cap ? list->cap * 2 : 4;
        list->items = cg_realloc(list->items, list->cap * sizeof *list->items);
    }
    step_record *record = &list->items[list->len++];
    memset(record, 0, sizeof *record);
    record->version = cg_strdup(version);
    record->step = cg_strdup("");
    record->id = cg_strdup("");
    record->process = cg_strdup("");
    return record;
}

static step_record *records_find(records *list, const char *version) {
    for (size_t i = 0; i < list->len; i++)
        if (strcmp(list->items[i].version, version) == 0) return &list->items[i];
    return NULL;
}

static void records_remove(records *list, step_record *record) {
    size_t index = (size_t)(record - list->items);
    record_clear(record);
    memmove(&list->items[index], &list->items[index + 1], (list->len - index - 1) * sizeof *list->items);
    list->len--;
}

/* A step of this process is running. */
static bool running_here(const step_record *record) {
    return record->active > 0 && strcmp(record->process, process_token()) == 0;
}

static uint64_t number(const cj *value, const char *key) {
    uint64_t out = 0;
    return cj_as_u64(cj_get(value, key), &out) ? out : 0;
}

static bool flag(const cj *value, const char *key) {
    bool out = false;
    return cj_as_bool(cj_get(value, key), &out) ? out : false;
}

static records load(cg_engine *engine) {
    records list = {0};
    char *stored = cg_host_kv_get(&engine->host, CG_KEY_CRASH_GUARD, NULL);
    cj *map = stored ? cj_parse(stored, NULL) : NULL;
    free(stored);
    if (cj_is_obj(map)) {
        for (size_t i = 0; i < cj_len(map); i++) {
            const cj *value = cj_value_at(map, i);
            if (!cj_is_obj(value)) continue;
            step_record *record = records_push(&list, cj_key_at(map, i));
            set_text(&record->step, cj_get_str(value, "step"));
            set_text(&record->id, cj_get_str(value, "id"));
            record->attempts = number(value, "attempts");
            record->active = number(value, "active");
            set_text(&record->process, cj_get_str(value, "process"));
            record->pid = number(value, "pid");
            record->background = flag(value, "background");
            record->failed = flag(value, "failed");
        }
    }
    cj_free(map);
    return list;
}

static void save(cg_engine *engine, const records *list) {
    if (list->len == 0) {
        cg_host_kv_set(&engine->host, CG_KEY_CRASH_GUARD, NULL);
        return;
    }
    cj *map = cj_obj();
    for (size_t i = 0; i < list->len; i++) {
        const step_record *record = &list->items[i];
        cj *value = cj_obj();
        cj_set(value, "step", cj_str(record->step));
        cj_set(value, "id", cj_str(record->id));
        cj_set(value, "attempts", cj_u64(record->attempts));
        cj_set(value, "active", cj_u64(record->active));
        cj_set(value, "process", cj_str(record->process));
        cj_set(value, "pid", cj_u64(record->pid));
        cj_set(value, "background", cj_bool(record->background));
        cj_set(value, "failed", cj_bool(record->failed));
        cj_set(map, record->version, value);
    }
    char *text = cj_print(map);
    cg_host_kv_set(&engine->host, CG_KEY_CRASH_GUARD, text);
    free(text);
    cj_free(map);
}

const char *cg_crash_guard_step_version(const cg_bundle_info *bundle) {
    return bundle->version && *bundle->version ? bundle->version : cg_bundle_info_id(bundle);
}

/* The app is in the background, or no plugin runs in this process (a download job). */
static bool in_background(cg_engine *engine) {
    cg_plugin_state *state = cg_plugin_lock_state(engine);
    bool background = !state->loaded || state->in_background;
    cg_plugin_unlock_state(engine);
    return background;
}

void cg_crash_guard_begin_native_step(cg_engine *engine, const char *step, const char *version, const char *id) {
    bool background = in_background(engine);
    if (!version || !*version) return;
    cg_lock(&guard_lock);
    records list = load(engine);
    step_record *record = records_find(&list, version);
    if (!record) record = records_push(&list, version);
    /* A record left by another process is replaced (its death is counted at plugin load). */
    if (!running_here(record)) {
        record->active = 0;
        set_text(&record->process, process_token());
    }
    record->active++;
    set_text(&record->step, step);
    if (id && *id) set_text(&record->id, id);
    record->pid = (uint64_t)getpid();
    record->background = background;
    save(engine, &list);
    records_free(&list);
    cg_unlock(&guard_lock);
}

void cg_crash_guard_end_native_step(cg_engine *engine, const char *version) {
    if (!version || !*version) return;
    cg_lock(&guard_lock);
    records list = load(engine);
    step_record *record = records_find(&list, version);
    if (record && running_here(record)) {
        record->active--;
        if (record->active == 0) {
            if (record->failed) {
                set_text(&record->process, "");
                record->pid = 0;
                record->background = false;
            } else {
                records_remove(&list, record);
            }
        }
        save(engine, &list);
    }
    records_free(&list);
    cg_unlock(&guard_lock);
}

void cg_crash_guard_mark_native_steps_background(cg_engine *engine, bool background) {
    cg_lock(&guard_lock);
    records list = load(engine);
    bool changed = false;
    for (size_t i = 0; i < list.len; i++) {
        step_record *record = &list.items[i];
        if (running_here(record) && record->background != background) {
            record->background = background;
            changed = true;
        }
    }
    if (changed) save(engine, &list);
    records_free(&list);
    cg_unlock(&guard_lock);
}

/* `version` died twice in a row: ERROR record, back to the previous bundle, statistic. */
static void trip(cg_engine *engine, const step_record *record) {
    cg_error_log(&engine->host,
                 "Bundle %s crashed the app %" PRIu64
                 " times in a row during its %s step: marked failed, the update cycle skips it until the "
                 "server offers another version",
                 record->version, record->attempts, record->step);
    if (*record->id && strcmp(record->id, CG_BUNDLE_ID_BUILTIN) != 0 &&
        cg_store_has_stored_bundle_info(engine, record->id)) {
        char *current = cg_store_current_bundle_id(engine);
        if (strcmp(current, record->id) == 0) cg_store_leave_failed_current_bundle(engine, record->id);
        free(current);
        cg_bundle_info next;
        if (cg_store_next_bundle(engine, &next)) {
            if (strcmp(cg_bundle_info_id(&next), record->id) == 0) cg_store_set_next_bundle(engine, NULL);
            cg_bundle_info_clear(&next);
        }
        cg_store_set_bundle_status(engine, record->id, CG_BUNDLE_ERROR);
    }
    const char *action = strcmp(record->step, CG_STEP_SET) == 0 ? "set_fail" : "download_fail";
    cj *metadata = cj_obj();
    cj_set(metadata, "message",
           cj_str_own(cg_fmt("native crash during %s (%" PRIu64 " in a row)", record->step, record->attempts)));
    cj_set(metadata, "step", cj_str(record->step));
    cj_set(metadata, "attempts", cj_str_own(cg_fmt("%" PRIu64, record->attempts)));
    cg_stats_send_stats(engine, action, record->version, NULL, metadata);
    cj_free(metadata);
}

typedef struct {
    bool warning;
    char *message;
} log_line;

void cg_crash_guard_account_native_deaths(cg_engine *engine, const cj *exits) {
    records failed = {0};
    log_line *logs = NULL;
    size_t log_count = 0;
    cg_lock(&guard_lock);
    records list = load(engine);
    bool changed = false;
    for (size_t i = 0; i < list.len; i++) {
        step_record *record = &list.items[i];
        if (record->active == 0 || strcmp(record->process, process_token()) == 0) continue;
        bool reported = false;
        int64_t reason = 0;
        if (cj_is_arr(exits)) {
            for (size_t e = 0; e < cj_len(exits); e++) {
                const cj *exit = cj_at(exits, e);
                uint64_t pid;
                if (cj_as_u64(cj_get(exit, "pid"), &pid) && pid == record->pid) {
                    reported = true;
                    if (!cj_as_i64(cj_get(exit, "reason"), &reason)) reason = 0;
                    break;
                }
            }
        }
        bool crashed = reported ? is_crash_reason(reason) : !record->background;
        record->active = 0;
        set_text(&record->process, "");
        record->pid = 0;
        record->background = false;
        changed = true;
        logs = cg_realloc(logs, (log_count + 1) * sizeof *logs);
        if (!crashed) {
            logs[log_count].warning = false;
            logs[log_count++].message =
                cg_fmt("The previous process ended during the %s step of %s, not as a crash: not counted", record->step,
                       record->version);
            continue;
        }
        record->attempts++;
        logs[log_count].warning = true;
        logs[log_count++].message = cg_fmt("The previous process died during the %s step of %s (%" PRIu64 " in a row)",
                                           record->step, record->version, record->attempts);
        if (record->attempts >= DEATHS_TO_FAIL && !record->failed) {
            record->failed = true;
            step_record *copy = records_push(&failed, record->version);
            set_text(&copy->step, record->step);
            set_text(&copy->id, record->id);
            copy->attempts = record->attempts;
            copy->failed = true;
        }
    }
    if (changed) save(engine, &list);
    records_free(&list);
    cg_unlock(&guard_lock);
    /* Logged without the lock: a host may call the engine from its log callback. */
    for (size_t i = 0; i < log_count; i++) {
        cg_host_log(&engine->host, logs[i].warning ? CG_WARN : CG_INFO, logs[i].message);
        free(logs[i].message);
    }
    free(logs);
    for (size_t i = 0; i < failed.len; i++) trip(engine, &failed.items[i]);
    records_free(&failed);
}

bool cg_crash_guard_native_step_failed(cg_engine *engine, const char *version) {
    cg_lock(&guard_lock);
    records list = load(engine);
    step_record *record = records_find(&list, version);
    bool failed = record && record->failed;
    records_free(&list);
    cg_unlock(&guard_lock);
    return failed;
}

void cg_crash_guard_forget_native_steps_except(cg_engine *engine, const char *version) {
    cg_lock(&guard_lock);
    records list = load(engine);
    size_t before = list.len;
    for (size_t i = list.len; i > 0; i--) {
        step_record *record = &list.items[i - 1];
        if (strcmp(record->version, version) != 0 && !running_here(record)) records_remove(&list, record);
    }
    if (list.len != before) save(engine, &list);
    records_free(&list);
    cg_unlock(&guard_lock);
}
