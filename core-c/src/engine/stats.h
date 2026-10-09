/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Statistics events (Rust engine/stats.rs): queued, batched (one POST per second at most),
 * persisted across launches (`capgo_pending_stats.json`, written by the same 1 s timer, at
 * background and at exit) and retried on transient failures.
 *
 * Lock order: queue_lock before in_flight_lock (requeue / persist take both in that order);
 * persist_lock before both. acks_lock is a leaf. None is held across a host callback or the
 * network.
 */
#ifndef CG_ENGINE_STATS_H
#define CG_ENGINE_STATS_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>

#include "engine/engine_api.h"
#include "rt/json.h"
#include "rt/str.h"
#include "rt/sync.h"

#define CG_PENDING_STATS_FILE "capgo_pending_stats.json"
#define CG_MAX_PENDING_STATS 200
#define CG_STATS_FLUSH_INTERVAL_MS 1000

/* QueuedEvent. */
typedef struct {
    cj *event;         /* owned JSON object */
    char *callback_id; /* NULL = None; emitted as `statsSent` once the event reached the server */
} cg_queued_event;

typedef struct {
    cg_queued_event *items;
    size_t len, cap;
} cg_queued_events;

/* One key/value write (value NULL removes the key). */
typedef struct {
    char *key;
    char *value;
} cg_kv_write;

/* KvWrites. */
typedef struct {
    cg_kv_write *items;
    size_t len, cap;
} cg_kv_writes;

/* Entry of the acks map (callback id -> writes). */
typedef struct cg_stats_ack {
    char *callback_id;
    cg_kv_writes writes;
    struct cg_stats_ack *next;
} cg_stats_ack;

/* StatsState. */
typedef struct {
    cg_mutex queue_lock;
    cg_queued_events queue;
    cg_mutex in_flight_lock;
    cg_queued_events in_flight;
    cg_mutex persist_lock;
    atomic_bool flush_in_flight;
    atomic_bool stopped;
    atomic_bool timer_started;
    /* Events queued since the last write of the stats file. */
    atomic_bool unsaved;
    /* Engine-owned acknowledgements: persisted key/value writes applied once the event
     * reached the server (snapshots that must retry until delivered). */
    cg_mutex acks_lock;
    cg_stats_ack *acks;
} cg_stats_state;

static inline void cg_queued_event_clear(cg_queued_event *event) {
    cj_free(event->event);
    free(event->callback_id);
    event->event = NULL;
    event->callback_id = NULL;
}

static inline void cg_queued_events_clear(cg_queued_events *events) {
    for (size_t i = 0; i < events->len; i++) cg_queued_event_clear(&events->items[i]);
    free(events->items);
    events->items = NULL;
    events->len = events->cap = 0;
}

/* Takes ownership of key and value. */
static inline void cg_kv_writes_push(cg_kv_writes *writes, char *key, char *value) {
    if (writes->len == writes->cap) {
        writes->cap = writes->cap ? writes->cap * 2 : 4;
        writes->items = (cg_kv_write *)cg_realloc(writes->items, writes->cap * sizeof(cg_kv_write));
    }
    writes->items[writes->len].key = key;
    writes->items[writes->len].value = value;
    writes->len++;
}

static inline void cg_kv_writes_clear(cg_kv_writes *writes) {
    for (size_t i = 0; i < writes->len; i++) {
        free(writes->items[i].key);
        free(writes->items[i].value);
    }
    free(writes->items);
    writes->items = NULL;
    writes->len = writes->cap = 0;
}

static inline void cg_stats_state_init(cg_stats_state *state) {
    cg_mutex_init(&state->queue_lock);
    cg_mutex_init(&state->in_flight_lock);
    cg_mutex_init(&state->persist_lock);
    cg_mutex_init(&state->acks_lock);
    state->queue = (cg_queued_events){0};
    state->in_flight = (cg_queued_events){0};
    atomic_init(&state->flush_in_flight, false);
    atomic_init(&state->stopped, false);
    atomic_init(&state->timer_started, false);
    atomic_init(&state->unsaved, false);
    state->acks = NULL;
}

/* Frees what is left (after the engine drop ran cg_stats_shutdown_stats). */
static inline void cg_stats_state_destroy(cg_stats_state *state) {
    cg_queued_events_clear(&state->queue);
    cg_queued_events_clear(&state->in_flight);
    while (state->acks) {
        cg_stats_ack *ack = state->acks;
        state->acks = ack->next;
        free(ack->callback_id);
        cg_kv_writes_clear(&ack->writes);
        free(ack);
    }
    cg_mutex_destroy(&state->queue_lock);
    cg_mutex_destroy(&state->in_flight_lock);
    cg_mutex_destroy(&state->persist_lock);
    cg_mutex_destroy(&state->acks_lock);
}

/* Rust `self.stats.acks.lock().insert(callback_id, writes)` (telemetry.rs): takes ownership of
 * *writes (zeroed), replacing an existing entry for callback_id. */
void cg_stats_add_ack(cg_engine *engine, const char *callback_id, cg_kv_writes *writes);

/* send_stats: emits a statistics event from engine logic. Without metadata the host may
 * route it (`sendStats` hook); otherwise it is queued. version_name / old_version_name NULL =
 * None. metadata: a JSON object or NULL (borrowed). */
void cg_stats_send_stats(cg_engine *engine, const char *action, const char *version_name,
                         const char *old_version_name, const cj *metadata);
/* send_stats_with_callback: callback_id NULL = None (copied). */
void cg_stats_send_stats_with_callback(cg_engine *engine, const char *action, const char *version_name,
                                       const char *old_version_name, const cj *metadata, const char *callback_id);
size_t cg_stats_pending_stats_count(cg_engine *engine);
/* Sends queued events now (also called by the 1 s timer thread, which holds a weak reference). */
void cg_stats_flush_stats(cg_engine *engine);
/* Writes in-flight + queued events (newest 200) so a kill does not lose them. */
void cg_stats_persist_stats(cg_engine *engine, bool force);
/* Restores events persisted by a previous launch. */
void cg_stats_restore_pending_stats(cg_engine *engine);
/* Stops the stats timer and persists what is left (also the engine's drop). */
void cg_stats_shutdown_stats(cg_engine *engine);

#endif
