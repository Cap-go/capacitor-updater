/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Zip bundle downloads and the shared download lifecycle (Rust engine/download.rs): gates,
 * progress, cancellation, status transitions, post-install actions. Also the cancellation
 * tokens and the in-flight downloads map the engine owns.
 *
 * Rust CoreResult<BundleInfo> results are `bool f(..., cg_bundle_info *out, cg_error *err)`:
 * true with *out initialized (the caller clears it), false with *err set (*out untouched).
 */
#ifndef CG_ENGINE_DOWNLOAD_H
#define CG_ENGINE_DOWNLOAD_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "bundle.h"
#include "engine/engine_api.h"
#include "net.h"
#include "rt/err.h"
#include "rt/json.h"
#include "rt/str.h"
#include "rt/sync.h"

/* ---- Cancel: cancellation token of one in-flight download (Rust Arc<AtomicBool>) */

typedef struct {
    atomic_int refs;
    atomic_bool cancelled;
} cg_cancel;

/* A new token (one reference). */
static inline cg_cancel *cg_cancel_new(void) {
    cg_cancel *token = (cg_cancel *)cg_malloc(sizeof(cg_cancel));
    atomic_init(&token->refs, 1);
    atomic_init(&token->cancelled, false);
    return token;
}

static inline cg_cancel *cg_cancel_retain(cg_cancel *token) {
    if (token) atomic_fetch_add(&token->refs, 1);
    return token;
}

/* NULL-safe. */
static inline void cg_cancel_release(cg_cancel *token) {
    if (token && atomic_fetch_sub(&token->refs, 1) == 1) free(token);
}

static inline void cg_cancel_set(cg_cancel *token) { atomic_store(&token->cancelled, true); }

/* Cancel::is_cancelled. NULL never cancels. */
static inline bool cg_cancel_is_cancelled(const cg_cancel *token) {
    return token && atomic_load(&((cg_cancel *)token)->cancelled);
}

/* ---- in-flight downloads: Mutex<HashMap<String, Vec<Cancel>>> (engine->downloads) */

typedef struct {
    char *version;
    cg_cancel **tokens; /* each holds one reference */
    size_t len, cap;
} cg_download_entry;

typedef struct {
    cg_mutex lock; /* leaf lock */
    cg_download_entry *items;
    size_t len, cap;
} cg_download_map;

static inline void cg_download_map_init(cg_download_map *map) {
    cg_mutex_init(&map->lock);
    map->items = NULL;
    map->len = map->cap = 0;
}

static inline void cg_download_map_destroy(cg_download_map *map) {
    for (size_t i = 0; i < map->len; i++) {
        for (size_t j = 0; j < map->items[i].len; j++) cg_cancel_release(map->items[i].tokens[j]);
        free(map->items[i].tokens);
        free(map->items[i].version);
    }
    free(map->items);
    map->items = NULL;
    map->len = map->cap = 0;
    cg_mutex_destroy(&map->lock);
}

/* The entry of `version` (call with map->lock held), NULL when absent. */
static inline cg_download_entry *cg_download_map_find(cg_download_map *map, const char *version) {
    for (size_t i = 0; i < map->len; i++)
        if (strcmp(map->items[i].version, version) == 0) return &map->items[i];
    return NULL;
}

/* ---- DownloadRequest: what to do with the bundle once it is installed (PENDING) */

typedef struct {
    /* Existing DOWNLOADING record to fill (hosts that schedule downloads themselves create
     * it up front); a new id is generated otherwise. NULL = None. */
    char *id;
    char *url;         /* never NULL */
    char *version;     /* never NULL, non-empty after from_json */
    char *session_key; /* never NULL */
    char *checksum;    /* never NULL */
    cj *manifest;      /* JSON array, NULL = None */
    char *link;        /* NULL = None */
    char *comment;     /* NULL = None */
    /* Schedule the bundle (`setNextBundle`) or, with direct_update, hand it to the host for
     * an immediate install (`directUpdateFinish` event). */
    bool set_next;
    bool direct_update;
    /* Emit `updateAvailable` / `downloadFailed` (hosts whose plugin layer reports those
     * events itself pass false). */
    bool emit_events;
} cg_download_request;

/* DownloadRequest::default(): empty strings, no manifest, every flag false. */
void cg_download_request_init(cg_download_request *request);
/* DownloadRequest::from_json: invalid_input "Download called without version". *out
 * initialized only on success. */
bool cg_download_request_from_json(const cj *input, cg_download_request *out, cg_error *err);
/* Inverse of from_json (scheduled download jobs persist it). Owned. */
cj *cg_download_request_to_json(const cg_download_request *request);
/* Deep copy into *out (Rust clone). */
void cg_download_request_copy(cg_download_request *out, const cg_download_request *request);
void cg_download_request_clear(cg_download_request *request);

/* Transfer failures a later attempt can fix (network_error, timeout, incomplete_download,
 * retryable http_error). */
bool cg_download_is_retryable_download_error(const cg_error *error);
/* Whether a transfer failure can succeed on a later attempt. */
bool cg_download_net_error_retryable(const cg_net_error *error);
/* Error code of a transfer failure (static string). */
const char *cg_download_net_error_code(const cg_net_error *error);

/* progress: `notify_download(id, clamp(percent, 0, 100))` (telemetry). */
void cg_download_progress(cg_engine *engine, const char *id, int64_t percent);
/* Cancels in-flight downloads of `version` (returns whether one was running). */
bool cg_download_cancel_download(cg_engine *engine, const char *version);
bool cg_download_is_downloading(cg_engine *engine, const char *version);
/* Refuses unencrypted delivery when a public key is configured (session_key_required). */
bool cg_download_require_session_key(cg_engine *engine, const char *session_key, const char *version,
                                     cg_error *err);
bool cg_download_require_checksum(cg_engine *engine, const char *checksum, const char *version, cg_error *err);
bool cg_download_check_disk_space(cg_engine *engine, uint64_t needed, const char *version, cg_error *err);
/* A DOWNLOADING record for the request (its id or a new one), saved. *out initialized. */
void cg_download_start_record(cg_engine *engine, const cg_download_request *request, cg_bundle_info *out);
/* Marks a download failed: ERROR record, `downloadFailed` event and `download_fail` stat. */
void cg_download_fail_download(cg_engine *engine, const cg_bundle_info *record, const cg_error *error,
                               bool emit_events);
/* Final step shared by zip and manifest downloads. *out initialized. */
void cg_download_finish_install(cg_engine *engine, const cg_bundle_info *record, const char *checksum,
                                const cg_download_request *request, cg_bundle_info *out);
/* Downloads, verifies and installs a zip bundle. Blocking. */
bool cg_download_download_zip(cg_engine *engine, const cg_download_request *request, cg_bundle_info *out,
                              cg_error *err);
/* Transfers and installs a started download (`record` is DOWNLOADING): through the host's
 * job scheduler when it takes the job, else in-process. */
bool cg_download_run_download(cg_engine *engine, const cg_download_request *request, const cg_bundle_info *record,
                              cg_bundle_info *out, cg_error *err);
/* One transfer + install attempt of a started download (`resumable`: scheduled jobs). */
bool cg_download_transfer_and_install(cg_engine *engine, const cg_download_request *request,
                                      const cg_bundle_info *record, const cg_cancel *cancel, bool resumable,
                                      cg_bundle_info *out, cg_error *err);
/* settle_download(result): `ok` true passes *result through (returns true); `ok` false: *err
 * holds the error on input, the failure is recorded (ERROR record, events, partial manifest
 * folder removed) and false is returned with *err still set. */
bool cg_download_settle_download(cg_engine *engine, const cg_download_request *request, const cg_bundle_info *record,
                                 bool ok, cg_bundle_info *result, cg_error *err);
/* Copies the files of an installed bundle into the delta cache (`<hash>_<name>`). */
void cg_download_populate_delta_cache(cg_engine *engine, const char *id);
/* Sweeps download leftovers older than one hour (also `test.cleanupDownloadTempFiles`). */
void cg_download_cleanup_download_temp_files(cg_engine *engine);
/* Every file under `dir` (heap work list, no symlinked directories), appended to *out. */
void cg_download_collect_files(const char *dir, cg_strs *out);

#endif
