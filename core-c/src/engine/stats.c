/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Statistics events (Rust engine/stats.rs). */

#include "engine/stats.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "engine/backend.h"
#include "engine/engine.h"
#include "engine/fsutil.h"
#include "engine/store.h"
#include "http.h"

/* ---------------------------------------------------------------- queued events */

/* Takes ownership of event and callback_id. */
static void events_push(cg_queued_events *events, cj *event, char *callback_id) {
    if (events->len == events->cap) {
        events->cap = events->cap ? events->cap * 2 : 8;
        events->items = cg_realloc(events->items, events->cap * sizeof(cg_queued_event));
    }
    events->items[events->len].event = event;
    events->items[events->len].callback_id = callback_id;
    events->len++;
}

/* Vec::remove(0) / drain(..count): drops the first `count` events. */
static void events_drop_front(cg_queued_events *events, size_t count) {
    if (count > events->len) count = events->len;
    for (size_t i = 0; i < count; i++) cg_queued_event_clear(&events->items[i]);
    memmove(events->items, events->items + count, (events->len - count) * sizeof(cg_queued_event));
    events->len -= count;
}

/* Clone of every event. */
static cg_queued_events events_clone(const cg_queued_events *events) {
    cg_queued_events out = {0};
    for (size_t i = 0; i < events->len; i++)
        events_push(&out, cj_clone(events->items[i].event),
                    events->items[i].callback_id ? cg_strdup(events->items[i].callback_id) : NULL);
    return out;
}

/* std::mem::take. */
static cg_queued_events events_take(cg_queued_events *events) {
    cg_queued_events out = *events;
    *events = (cg_queued_events){0};
    return out;
}

void cg_stats_add_ack(cg_engine *engine, const char *callback_id, cg_kv_writes *writes) {
    cg_stats_state *stats = &engine->stats;
    cg_lock(&stats->acks_lock);
    cg_stats_ack *ack = stats->acks;
    while (ack && strcmp(ack->callback_id, callback_id) != 0) ack = ack->next;
    if (ack) {
        cg_kv_writes_clear(&ack->writes);
    } else {
        ack = cg_calloc(1, sizeof(cg_stats_ack));
        ack->callback_id = cg_strdup(callback_id);
        ack->next = stats->acks;
        stats->acks = ack;
    }
    ack->writes = *writes;
    *writes = (cg_kv_writes){0};
    cg_unlock(&stats->acks_lock);
}

/* `acks.lock().remove(callback_id)`: true with *out (owned) when present. */
static bool take_ack(cg_engine *engine, const char *callback_id, cg_kv_writes *out) {
    cg_stats_state *stats = &engine->stats;
    cg_lock(&stats->acks_lock);
    cg_stats_ack **slot = &stats->acks;
    while (*slot && strcmp((*slot)->callback_id, callback_id) != 0) slot = &(*slot)->next;
    cg_stats_ack *ack = *slot;
    if (ack) *slot = ack->next;
    cg_unlock(&stats->acks_lock);
    if (!ack) return false;
    *out = ack->writes;
    free(ack->callback_id);
    free(ack);
    return true;
}

/* ---------------------------------------------------------------- files */

/* Rust `stats_dir.join(PENDING_STATS_FILE)`, NULL when no stats dir is set. */
static char *stats_file(cg_engine *engine) {
    char *dir = CG_CONFIG_DUP(engine, stats_dir);
    char *file = *dir ? cg_fsutil_join(dir, CG_PENDING_STATS_FILE) : NULL;
    free(dir);
    return file;
}

static char *backup_path(const char *file) { return cg_fmt("%s.bak", file); }

/* fs::create_dir_all(parent), fs::write(<file>.tmp), rename; removes the backup on success.
 * false with *err holding the io::Error display. */
static bool write_atomically(const char *file, const char *bytes, size_t len, char **error) {
    char *parent = cg_fsutil_parent(file);
    if (parent && *parent && !cg_fsutil_create_dir_all(parent)) {
        *error = cg_io_message(errno);
        free(parent);
        return false;
    }
    free(parent);
    char *temp = cg_fmt("%s.tmp", file);
    int fd = cg_fsutil_open(temp, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) {
        *error = cg_io_message(errno);
        free(temp);
        return false;
    }
    if (!cg_fsutil_write_all(fd, bytes, len)) {
        *error = cg_io_message(errno);
        close(fd);
        free(temp);
        return false;
    }
    close(fd);
    bool ok = rename(temp, file) == 0;
    if (!ok) {
        *error = cg_io_message(errno);
        unlink(temp);
    } else {
        char *backup = backup_path(file);
        unlink(backup);
        free(backup);
    }
    free(temp);
    return ok;
}

/* fs::read_to_string: NULL when unreadable or not UTF-8. */
static char *read_to_string(const char *path, size_t *len) {
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
    *len = buf.len;
    if (buf.data && !cg_utf8_valid(buf.data, *len)) {
        cg_buf_free(&buf);
        return NULL;
    }
    return cg_buf_take(&buf);
}

/* ---------------------------------------------------------------- sending */

void cg_stats_send_stats(cg_engine *engine, const char *action, const char *version_name,
                         const char *old_version_name, const cj *metadata) {
    if (!metadata) {
        char *version;
        if (version_name) {
            version = cg_strdup(version_name);
        } else {
            cg_bundle_info current;
            cg_store_current_bundle(engine, &current);
            version = cg_strdup(cg_bundle_info_version_name(&current));
            cg_bundle_info_clear(&current);
        }
        if (cg_host_send_stats(&engine->host, action, version, cg_or_empty(old_version_name))) {
            free(version);
            return;
        }
        cg_stats_send_stats_with_callback(engine, action, version, old_version_name, NULL, NULL);
        free(version);
        return;
    }
    cg_stats_send_stats_with_callback(engine, action, version_name, old_version_name, metadata, NULL);
}

static void ensure_stats_timer(cg_engine *engine);

void cg_stats_send_stats_with_callback(cg_engine *engine, const char *action, const char *version_name,
                                       const char *old_version_name, const cj *metadata, const char *callback_id) {
    cg_stats_state *stats = &engine->stats;
    if (atomic_load(&stats->stopped)) return;
    if (CG_CONFIG_FLAG(engine, preview_session)) {
        cg_host_log(&engine->host, CG_DEBUG, "Skipping sendStats during preview session.");
        return;
    }
    char *stats_url = CG_CONFIG_DUP(engine, stats_url);
    bool no_url = !*stats_url;
    free(stats_url);
    if (no_url) return;
    char *version;
    if (version_name) {
        version = cg_strdup(version_name);
    } else {
        cg_bundle_info current;
        cg_store_current_bundle(engine, &current);
        version = cg_strdup(cg_bundle_info_version_name(&current));
        cg_bundle_info_clear(&current);
    }
    cj *event = cg_backend_info_object(engine, NULL);
    cj_set(event, "version_name", cj_str_own(version));
    cj_set(event, "old_version_name", cj_str(cg_or_empty(old_version_name)));
    cj_set(event, "action", cj_str(action));
    cj_set(event, "timestamp", cj_i64(cg_now_ms()));
    if (metadata && cj_len(metadata) > 0) cj_set(event, "metadata", cj_clone(metadata));
    cg_lock(&stats->queue_lock);
    if (atomic_load(&stats->stopped)) {
        cg_unlock(&stats->queue_lock);
        cj_free(event);
        return;
    }
    if (stats->queue.len >= CG_MAX_PENDING_STATS)
        events_drop_front(&stats->queue, stats->queue.len - CG_MAX_PENDING_STATS + 1);
    events_push(&stats->queue, event, callback_id ? cg_strdup(callback_id) : NULL);
    cg_unlock(&stats->queue_lock);
    /* Written by the next timer tick (at most one write a second), sent or not. */
    atomic_store(&stats->unsaved, true);
    ensure_stats_timer(engine);
}

size_t cg_stats_pending_stats_count(cg_engine *engine) {
    cg_lock(&engine->stats.queue_lock);
    size_t count = engine->stats.queue.len;
    cg_unlock(&engine->stats.queue_lock);
    return count;
}

static void stats_timer(void *arg) {
    cg_engine_weak *weak = arg;
    for (;;) {
        cg_engine *engine = cg_engine_sleep_unless_dropped(weak, CG_STATS_FLUSH_INTERVAL_MS);
        if (!engine) break;
        if (atomic_load(&engine->stats.stopped)) {
            cg_engine_release(engine);
            break;
        }
        cg_stats_flush_stats(engine);
        cg_engine_release(engine);
    }
    cg_engine_weak_release(weak);
}

static void ensure_stats_timer(cg_engine *engine) {
    if (atomic_load(&engine->stats.stopped) || atomic_exchange(&engine->stats.timer_started, true)) return;
    /* Rust spawns this thread directly (no log when the OS refuses). */
    cg_engine_weak *weak = cg_engine_downgrade(engine);
    if (!cg_spawn("stats", stats_timer, weak)) cg_engine_weak_release(weak);
}

static void requeue_stats(cg_engine *engine, cg_queued_events *events);

void cg_stats_flush_stats(cg_engine *engine) {
    cg_stats_state *stats = &engine->stats;
    if (atomic_load(&stats->stopped)) return;
    cg_lock(&stats->queue_lock);
    bool empty = stats->queue.len == 0;
    cg_unlock(&stats->queue_lock);
    if (empty) return;
    /* While Retry-After is active, keep stats queued (on disk too) and skip the network call. */
    if (cg_backend_is_remote_blocked(engine)) {
        cg_host_log(&engine->host, CG_DEBUG, "Deferring stats flush until Retry-After expires.");
        if (atomic_load(&stats->unsaved)) cg_stats_persist_stats(engine, false);
        return;
    }
    char *stats_url = CG_CONFIG_DUP(engine, stats_url);
    if (!*stats_url) {
        free(stats_url);
        cg_lock(&stats->queue_lock);
        cg_queued_events_clear(&stats->queue);
        cg_unlock(&stats->queue_lock);
        cg_lock(&stats->in_flight_lock);
        cg_queued_events_clear(&stats->in_flight);
        cg_unlock(&stats->in_flight_lock);
        cg_stats_persist_stats(engine, false);
        return;
    }
    if (atomic_exchange(&stats->flush_in_flight, true)) {
        free(stats_url);
        return;
    }
    cg_lock(&stats->queue_lock);
    cg_queued_events events = events_take(&stats->queue);
    cg_lock(&stats->in_flight_lock);
    cg_queued_events_clear(&stats->in_flight);
    stats->in_flight = events_clone(&events);
    cg_unlock(&stats->in_flight_lock);
    cg_unlock(&stats->queue_lock);
    if (events.len == 0) {
        atomic_store(&stats->flush_in_flight, false);
        free(stats_url);
        return;
    }
    cg_stats_persist_stats(engine, false);
    cj *body = cj_arr();
    for (size_t i = 0; i < events.len; i++) cj_push(body, cj_clone(events.items[i].event));
    cg_net_response response = {0};
    cg_net_error error = CG_NET_ERROR_INIT;
    bool sent = cg_http_post_json(engine->http, stats_url, body, &response, &error);
    cj_free(body);
    free(stats_url);
    if (atomic_load(&stats->stopped)) {
        atomic_store(&stats->flush_in_flight, false);
        if (sent) cg_net_response_clear(&response);
        cg_net_error_clear(&error);
        cg_queued_events_clear(&events);
        return;
    }
    if (!sent) {
        requeue_stats(engine, &events);
        cg_host_log(&engine->host, CG_ERROR, "Failed to send stats batch");
        cg_debug(&engine->host, "Error: %s", cg_or_empty(error.message));
        cg_net_error_clear(&error);
    } else {
        cg_remote_block block;
        cg_backend_handle_rate_limit(engine, &response, &block);
        if (block.blocked) {
            requeue_stats(engine, &events);
        } else if (cg_net_response_is_success(&response)) {
            cg_lock(&stats->in_flight_lock);
            cg_queued_events_clear(&stats->in_flight);
            cg_unlock(&stats->in_flight_lock);
            cg_stats_persist_stats(engine, false);
            cg_host_log(&engine->host, CG_INFO, "Stats batch sent successfully");
            cg_debug(&engine->host, "Sent %zu events", events.len);
            for (size_t i = 0; i < events.len; i++) {
                const char *callback_id = events.items[i].callback_id;
                if (!callback_id) continue;
                cg_kv_writes writes = {0};
                if (take_ack(engine, callback_id, &writes)) {
                    for (size_t w = 0; w < writes.len; w++)
                        cg_host_kv_set(&engine->host, writes.items[w].key, writes.items[w].value);
                    cg_kv_writes_clear(&writes);
                    continue;
                }
                cj *payload = cj_objv("callbackId", cj_str(callback_id), NULL);
                cg_host_emit(&engine->host, "statsSent", payload);
                cj_free(payload);
            }
        } else if (cg_http_is_retryable_http_status(response.status)) {
            requeue_stats(engine, &events);
            cg_host_log(&engine->host, CG_ERROR, "Error sending stats batch");
            cg_debug(&engine->host, "Retrying later, response code: %u", (unsigned)response.status);
        } else {
            cg_lock(&stats->in_flight_lock);
            cg_queued_events_clear(&stats->in_flight);
            cg_unlock(&stats->in_flight_lock);
            cg_stats_persist_stats(engine, false);
            cg_host_log(&engine->host, CG_ERROR, "Dropping stats batch after permanent error");
            cg_debug(&engine->host, "Response code: %u", (unsigned)response.status);
        }
        cg_remote_block_clear(&block);
        cg_net_response_clear(&response);
    }
    cg_queued_events_clear(&events);
    atomic_store(&stats->flush_in_flight, false);
}

/* Takes the events (*events is left empty). */
static void requeue_stats(cg_engine *engine, cg_queued_events *events) {
    cg_stats_state *stats = &engine->stats;
    if (atomic_load(&stats->stopped) || events->len == 0) {
        cg_queued_events_clear(events);
        return;
    }
    cg_lock(&stats->queue_lock);
    cg_lock(&stats->in_flight_lock);
    cg_queued_events_clear(&stats->in_flight);
    cg_unlock(&stats->in_flight_lock);
    cg_queued_events combined = events_take(events);
    for (size_t i = 0; i < stats->queue.len; i++)
        events_push(&combined, stats->queue.items[i].event, stats->queue.items[i].callback_id);
    free(stats->queue.items);
    stats->queue = (cg_queued_events){0};
    if (combined.len > CG_MAX_PENDING_STATS) events_drop_front(&combined, combined.len - CG_MAX_PENDING_STATS);
    stats->queue = combined;
    cg_unlock(&stats->queue_lock);
    cg_stats_persist_stats(engine, false);
    ensure_stats_timer(engine);
}

/* ---------------------------------------------------------------- persistence */

void cg_stats_persist_stats(cg_engine *engine, bool force) {
    cg_stats_state *stats = &engine->stats;
    char *file = stats_file(engine);
    if (!file) return;
    cg_lock(&stats->persist_lock);
    if (atomic_load(&stats->stopped) && !force) {
        cg_unlock(&stats->persist_lock);
        free(file);
        return;
    }
    atomic_store(&stats->unsaved, false);
    cg_lock(&stats->queue_lock);
    cg_lock(&stats->in_flight_lock);
    size_t total = stats->in_flight.len + stats->queue.len;
    size_t start = total > CG_MAX_PENDING_STATS ? total - CG_MAX_PENDING_STATS : 0;
    cg_buf bytes = {0};
    cg_buf_putc(&bytes, '[');
    bool first = true;
    for (size_t index = start; index < total; index++) {
        const cg_queued_event *queued = index < stats->in_flight.len
                                            ? &stats->in_flight.items[index]
                                            : &stats->queue.items[index - stats->in_flight.len];
        char *text = cj_print(queued->event);
        if (!first) cg_buf_putc(&bytes, ',');
        cg_buf_puts(&bytes, text);
        free(text);
        first = false;
    }
    cg_buf_putc(&bytes, ']');
    cg_unlock(&stats->in_flight_lock);
    cg_unlock(&stats->queue_lock);
    char *error = NULL;
    if (!write_atomically(file, bytes.data, bytes.len, &error)) {
        /* Not on disk yet: the next timer tick tries again. */
        atomic_store(&stats->unsaved, true);
        cg_host_log(&engine->host, CG_ERROR, "Failed to persist stats queue");
        cg_debug(&engine->host, "Error: %s", error);
        free(error);
    }
    cg_buf_free(&bytes);
    cg_unlock(&stats->persist_lock);
    free(file);
}

void cg_stats_restore_pending_stats(cg_engine *engine) {
    cg_stats_state *stats = &engine->stats;
    char *file = stats_file(engine);
    if (!file) return;
    char *backup = backup_path(file);
    if (!cg_fsutil_exists(file) && cg_fsutil_exists(backup) && rename(backup, file) != 0) {
        cg_host_log(&engine->host, CG_ERROR, "Failed to restore stats backup");
        free(backup);
        free(file);
        return;
    }
    size_t len = 0;
    char *raw = read_to_string(file, &len);
    free(file);
    if (!raw) {
        free(backup);
        return;
    }
    cj *events = cj_parsen(raw, len, NULL);
    free(raw);
    if (!cj_is_arr(events)) {
        cj_free(events);
        cg_host_log(&engine->host, CG_ERROR, "Failed to restore pending stats");
        free(backup);
        return;
    }
    cg_lock(&stats->queue_lock);
    for (size_t i = 0; i < cj_len(events); i++) {
        cj *event = cj_at(events, i);
        if (!cj_is_obj(event)) continue;
        if (stats->queue.len >= CG_MAX_PENDING_STATS) break;
        events_push(&stats->queue, cj_clone(event), NULL);
    }
    size_t restored = stats->queue.len;
    cg_unlock(&stats->queue_lock);
    cj_free(events);
    unlink(backup);
    free(backup);
    if (restored > 0) {
        cg_info(&engine->host, "Restored %zu pending stats events", restored);
        ensure_stats_timer(engine);
    }
}

void cg_stats_shutdown_stats(cg_engine *engine) {
    atomic_store(&engine->stats.stopped, true);
    cg_stats_persist_stats(engine, true);
}
