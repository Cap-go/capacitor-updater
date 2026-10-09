/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Bundle store (Rust engine/store.rs): the registry of downloaded bundles (`<id>_info`
 * records), the current / next / fallback pointers, and the bundle directories.
 *
 * Keys, value formats and directory layout match every previous plugin version so existing
 * installs keep working after upgrade (and downgrade).
 *
 * Rust Option<BundleInfo> results are `bool f(..., cg_bundle_info *out)`: true (Some) with
 * *out initialized (the caller clears it), false (None) with *out untouched. Plain
 * BundleInfo results always initialize *out.
 */
#ifndef CG_ENGINE_STORE_H
#define CG_ENGINE_STORE_H

#include <stdbool.h>
#include <stddef.h>

#include "bundle.h"
#include "engine/engine_api.h"
#include "rt/err.h"
#include "rt/str.h"

#define CG_TEMP_UNZIP_PREFIX "capgo_unzip_"

/* `&dyn Fn() -> bool` cancellation probe. A NULL function never cancels. */
typedef struct {
    bool (*cancelled)(void *ctx);
    void *ctx;
} cg_cancelled_fn;

static inline bool cg_cancelled_fn_check(const cg_cancelled_fn *probe) {
    return probe && probe->cancelled && probe->cancelled(probe->ctx);
}

/* Vec<BundleInfo>. */
typedef struct {
    cg_bundle_info *items;
    size_t len, cap;
} cg_bundle_list;

/* Takes ownership of *info's members (*info is zeroed). */
void cg_bundle_list_push(cg_bundle_list *list, cg_bundle_info *info);
void cg_bundle_list_clear(cg_bundle_list *list);

/* Snapshot of the pointers a reset rewrites, restorable if the reload fails (ResetState). */
typedef struct {
    char *current_bundle_path; /* never NULL */
    char *fallback_bundle_id;  /* never NULL */
    char *next_bundle_id;      /* NULL = None */
} cg_reset_state;

void cg_reset_state_clear(cg_reset_state *state);

/* random_id: 10 random `[0-9A-Za-z]` characters (bundle ids, temp folder names). malloc'd. */
char *cg_store_random_id(void);
/* resolve_inside: resolves `relative` inside `root`, rejecting traversal and (when it exists)
 * symlinks that point outside `root` ("escapes_base"). malloc'd, NULL with *err. */
char *cg_store_resolve_inside(const char *root, const char *relative, cg_error *err);
/* remove_path: a file is unlinked, a directory removed with its content (iteratively,
 * symlinks never followed), a missing path is fine. *err holds the io::Error (see fsutil.h). */
bool cg_store_remove_path(const char *path, cg_error *err);

bool cg_store_has_stored_bundle_info(cg_engine *engine, const char *id);
/* get_bundle_info(Option<&str>): id NULL means "unknown". Always initializes *out. */
void cg_store_get_bundle_info(cg_engine *engine, const char *id, cg_bundle_info *out);
/* save_bundle_info: info NULL removes the record. */
bool cg_store_save_bundle_info(cg_engine *engine, const char *id, const cg_bundle_info *info);
void cg_store_set_bundle_status(cg_engine *engine, const char *id, cg_bundle_status status);
/* Bundles on disk (raw false) or every stored record (raw true), sorted by id. *out is
 * initialized (zeroed first). */
void cg_store_list(cg_engine *engine, bool raw, cg_bundle_list *out);
bool cg_store_get_bundle_info_by_name(cg_engine *engine, const char *version, cg_bundle_info *out);
/* malloc'd, NULL with *err (invalid id). */
char *cg_store_bundle_directory(cg_engine *engine, const char *id, cg_error *err);
bool cg_store_bundle_exists(cg_engine *engine, const char *id);

/* ---- current / fallback / next */
char *cg_store_current_bundle_path(cg_engine *engine);
bool cg_store_is_using_builtin(cg_engine *engine);
char *cg_store_current_bundle_id(cg_engine *engine);
void cg_store_current_bundle(cg_engine *engine, cg_bundle_info *out);
void cg_store_fallback_bundle(cg_engine *engine, cg_bundle_info *out);
bool cg_store_next_bundle(cg_engine *engine, cg_bundle_info *out);
bool cg_store_preview_fallback_bundle(cg_engine *engine, cg_bundle_info *out);
/* fallback NULL clears it. */
bool cg_store_set_preview_fallback_bundle(cg_engine *engine, const char *fallback);
/* next NULL clears it. */
bool cg_store_set_next_bundle(cg_engine *engine, const char *next);

/* ---- delete */
void cg_store_enqueue_pending_delete(cg_engine *engine, const char *id);
/* Deletes a bundle folder under engine->delete_lock (held across host callbacks, as Rust). */
bool cg_store_delete_bundle(cg_engine *engine, const char *id, bool remove_info, bool cancel_active_download);
/* Resumes deletes interrupted by a kill, one by one (75 ms apart). */
void cg_store_drain_pending_deletes(cg_engine *engine);

/* ---- set / reset */
bool cg_store_set_bundle(cg_engine *engine, const char *id);
bool cg_store_can_set(cg_engine *engine, const cg_bundle_info *bundle);
bool cg_store_stage_pending_reload(cg_engine *engine, const cg_bundle_info *bundle);
bool cg_store_stage_preview_fallback_reload(cg_engine *engine, const cg_bundle_info *bundle);
void cg_store_finalize_pending_reload(cg_engine *engine, const cg_bundle_info *bundle,
                                      const char *previous_bundle_name);
/* *out initialized. */
void cg_store_capture_reset_state(cg_engine *engine, cg_reset_state *out);
void cg_store_restore_reset_state(cg_engine *engine, const cg_reset_state *state);
void cg_store_prepare_reset_state_for_transition(cg_engine *engine);
void cg_store_finalize_reset_transition(cg_engine *engine, const char *previous_bundle_name, bool internal);
void cg_store_reset(cg_engine *engine, bool internal);
/* Resets to builtin when the current bundle is gone, foreign, or the native app changed. */
void cg_store_auto_reset(cg_engine *engine, const char *current_native_build_version,
                         bool reset_when_native_version_changed);
/* Marks `id` successful and makes it the fallback; optionally deletes the previous fallback
 * on a "delete" thread holding a strong engine reference (Rust `self: &Arc<Self>`). */
void cg_store_set_success(cg_engine *engine, const char *id, bool auto_delete_previous);
void cg_store_set_error(cg_engine *engine, const char *id);

/* ---- cleanup */
/* BTreeSet<String>: sorted, unique. */
cg_strs cg_store_allowed_bundle_ids_for_cleanup(cg_engine *engine);
/* Deletes bundle folders that no record protects (`allowed` need not be sorted). */
void cg_store_cleanup_download_directories(cg_engine *engine, const cg_strs *allowed, const cg_cancelled_fn *cancelled);
/* Deletes leftover `capgo_unzip_*` folders from interrupted installs. */
void cg_store_cleanup_orphaned_temp_folders(cg_engine *engine, const cg_cancelled_fn *cancelled);
void cg_store_cleanup_delta_cache(cg_engine *engine);
/* A DOWNLOADING record with a new random id, saved. *out initialized. */
void cg_store_new_download_record(cg_engine *engine, const char *version, cg_bundle_info *out);

#endif
