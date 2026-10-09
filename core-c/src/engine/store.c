/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Bundle store (Rust engine/store.rs). */

#include "engine/store.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#include "engine/engine.h"
#include "engine/fsutil.h"
#include "engine/scheduled.h"
#include "engine/stats.h"
#include "paths.h"
#include "policy.h"

#define DELETE_PACE_MS 75

/* ---------------------------------------------------------------- small types */

void cg_bundle_list_push(cg_bundle_list *list, cg_bundle_info *info) {
    if (list->len == list->cap) {
        list->cap = list->cap ? list->cap * 2 : 8;
        list->items = cg_realloc(list->items, list->cap * sizeof(cg_bundle_info));
    }
    list->items[list->len++] = *info;
    memset(info, 0, sizeof *info);
}

void cg_bundle_list_clear(cg_bundle_list *list) {
    for (size_t i = 0; i < list->len; i++) cg_bundle_info_clear(&list->items[i]);
    free(list->items);
    list->items = NULL;
    list->len = list->cap = 0;
}

void cg_reset_state_clear(cg_reset_state *state) {
    free(state->current_bundle_path);
    free(state->fallback_bundle_id);
    free(state->next_bundle_id);
    memset(state, 0, sizeof *state);
}

static int compare_strings(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

/* Sorts and removes duplicates (BTreeSet / sort + dedup). */
static void sort_dedup(cg_strs *list) {
    if (list->len < 2) return;
    qsort(list->items, list->len, sizeof(char *), compare_strings);
    size_t out = 1;
    for (size_t i = 1; i < list->len; i++) {
        if (strcmp(list->items[i], list->items[out - 1]) == 0) {
            free(list->items[i]);
        } else {
            list->items[out++] = list->items[i];
        }
    }
    list->len = out;
}

/* ---------------------------------------------------------------- free functions */

char *cg_store_random_id(void) { return cg_fsutil_random_id(); }

static bool is_stored_bundle_id(const char *key, const char *suffix) {
    if (!cg_ends_with(key, suffix)) return false;
    size_t len = strlen(key) - strlen(suffix);
    if (len != 10) return false;
    for (size_t i = 0; i < len; i++)
        if (!isalnum((unsigned char)key[i])) return false;
    return true;
}

char *cg_store_resolve_inside(const char *root, const char *relative, cg_error *err) {
    char *resolved = cg_paths_resolve_path_inside(root, relative, err);
    if (!resolved) return NULL;
    char *canonical_root = cg_fsutil_canonicalize(root);
    char *canonical_target = canonical_root ? cg_fsutil_canonicalize(resolved) : NULL;
    bool escapes = canonical_root && canonical_target &&
                   (strcmp(canonical_target, canonical_root) == 0 ||
                    !cg_fsutil_path_starts_with(canonical_target, canonical_root));
    free(canonical_root);
    free(canonical_target);
    if (escapes) {
        free(resolved);
        cg_err_set(err, "escapes_base", "Path escapes base directory: %s", relative);
        return NULL;
    }
    return resolved;
}

bool cg_store_remove_path(const char *path, cg_error *err) { return cg_fsutil_remove_path(path, err); }

/* fs::read_dir names as a list; false when the directory cannot be read. */
static bool read_dir(const char *path, cg_strs *out) {
    cg_error err = CG_ERROR_INIT;
    size_t len = 0;
    char **names = cg_fsutil_read_dir(path, &len, &err);
    cg_err_clear(&err);
    if (!names) return false;
    *out = (cg_strs){.items = names, .len = len, .cap = len};
    return true;
}

/* ---------------------------------------------------------------- kv helpers */

static char *kv(cg_engine *engine, const char *key) { return cg_host_kv_get(&engine->host, key, NULL); }

static char *kv_or(cg_engine *engine, const char *key, const char *fallback) {
    return cg_host_kv_get(&engine->host, key, fallback);
}

static void kv_put(cg_engine *engine, const char *key, const char *value) {
    cg_host_kv_set(&engine->host, key, value);
}

/* kv_put on a key of the config (CG_CONFIG_DUP field). */
#define KV_PUT_KEY(engine, field, value)                                                                             \
    do {                                                                                                             \
        char *key_ = CG_CONFIG_DUP(engine, field);                                                                   \
        kv_put(engine, key_, value);                                                                                 \
        free(key_);                                                                                                  \
    } while (0)

static char *info_key(cg_engine *engine, const char *id) {
    char *suffix = CG_CONFIG_DUP(engine, keys.info_suffix);
    char *key = cg_fmt("%s%s", id, suffix);
    free(suffix);
    return key;
}

/* save_bundle_info(id, Some(&info.with_status(status))). */
static bool save_with_status(cg_engine *engine, const char *id, const cg_bundle_info *info, cg_bundle_status status) {
    cg_bundle_info *copy = cg_bundle_info_with_status(info, status);
    bool saved = cg_store_save_bundle_info(engine, id, copy);
    cg_bundle_info_free(copy);
    return saved;
}

/* ---------------------------------------------------------------- records */

bool cg_store_has_stored_bundle_info(cg_engine *engine, const char *id) {
    if (!*id || strcmp(id, CG_BUNDLE_ID_BUILTIN) == 0 || strcmp(id, CG_BUNDLE_VERSION_UNKNOWN) == 0) return false;
    char *key = info_key(engine, id);
    bool found = cg_host_kv_contains(&engine->host, key);
    free(key);
    return found;
}

void cg_store_get_bundle_info(cg_engine *engine, const char *id, cg_bundle_info *out) {
    if (!id) id = CG_BUNDLE_VERSION_UNKNOWN;
    if (strcmp(id, CG_BUNDLE_ID_BUILTIN) == 0) {
        char *version_build = CG_CONFIG_DUP(engine, version_build);
        cg_bundle_info_init(out, CG_BUNDLE_ID_BUILTIN, *version_build ? version_build : NULL, CG_BUNDLE_SUCCESS, "",
                            "");
        free(version_build);
        return;
    }
    if (strcmp(id, CG_BUNDLE_VERSION_UNKNOWN) == 0) {
        cg_bundle_info_init(out, CG_BUNDLE_VERSION_UNKNOWN, NULL, CG_BUNDLE_ERROR, "", "");
        return;
    }
    char *key = info_key(engine, id);
    char *stored = kv_or(engine, key, "");
    if (!*stored) {
        cg_bundle_info_init(out, id, NULL, CG_BUNDLE_PENDING, "", "");
    } else if (!cg_bundle_info_from_stored_json(stored, out)) {
        cg_error_log(&engine->host, "Failed to parse bundle info");
        cg_debug(&engine->host, "Bundle ID: %s", id);
        kv_put(engine, key, NULL);
        cg_bundle_info_init(out, id, NULL, CG_BUNDLE_ERROR, "", "");
    }
    free(stored);
    free(key);
}

bool cg_store_save_bundle_info(cg_engine *engine, const char *id, const cg_bundle_info *info) {
    if (info && (cg_bundle_info_is_builtin(info) || cg_bundle_info_is_unknown(info))) {
        cg_debug(&engine->host, "Not saving info for bundle: [%s]", id);
        return false;
    }
    char *key = info_key(engine, id);
    if (!info) {
        cg_debug(&engine->host, "Removing info for bundle [%s]", id);
        kv_put(engine, key, NULL);
    } else {
        cg_bundle_info *with_id = cg_bundle_info_with_id(info, id);
        char *stored = cg_bundle_info_to_stored_json(with_id);
        cg_bundle_info_free(with_id);
        cg_debug(&engine->host, "Storing info for bundle [%s] %s", id, stored);
        kv_put(engine, key, stored);
        free(stored);
    }
    free(key);
    return true;
}

void cg_store_set_bundle_status(cg_engine *engine, const char *id, cg_bundle_status status) {
    cg_bundle_info info;
    cg_store_get_bundle_info(engine, id, &info);
    cg_debug(&engine->host, "Setting status for bundle [%s] to %s", id, cg_bundle_status_str(status));
    save_with_status(engine, id, &info, status);
    cg_bundle_info_clear(&info);
}

void cg_store_list(cg_engine *engine, bool raw, cg_bundle_list *out) {
    memset(out, 0, sizeof *out);
    cg_strs ids = {0};
    if (raw) {
        char *suffix = CG_CONFIG_DUP(engine, keys.info_suffix);
        cg_strs keys = cg_host_kv_keys(&engine->host);
        for (size_t i = 0; i < keys.len; i++) {
            if (is_stored_bundle_id(keys.items[i], suffix))
                cg_strs_push(&ids, cg_strndup(keys.items[i], strlen(keys.items[i]) - strlen(suffix)));
        }
        cg_strs_free(&keys);
        free(suffix);
        sort_dedup(&ids);
    } else {
        char *root = CG_CONFIG_DUP(engine, bundle_root);
        cg_strs names;
        if (!read_dir(root, &names)) {
            cg_info(&engine->host, "No versions available to list %s", root);
            free(root);
            return;
        }
        free(root);
        for (size_t i = 0; i < names.len; i++) {
            /* Names that are not UTF-8 are skipped (OsStr::to_str), as are hidden ones. */
            const char *name = names.items[i];
            if (cg_utf8_valid(name, strlen(name)) && name[0] != '.') cg_strs_push_copy(&ids, name);
        }
        cg_strs_free(&names);
        if (ids.len > 1) qsort(ids.items, ids.len, sizeof(char *), compare_strings);
    }
    for (size_t i = 0; i < ids.len; i++) {
        cg_bundle_info info;
        cg_store_get_bundle_info(engine, ids.items[i], &info);
        cg_bundle_list_push(out, &info);
    }
    cg_strs_free(&ids);
}

bool cg_store_get_bundle_info_by_name(cg_engine *engine, const char *version, cg_bundle_info *out) {
    cg_bundle_list list;
    cg_store_list(engine, false, &list);
    bool found = false;
    for (size_t i = 0; i < list.len; i++) {
        if (strcmp(cg_bundle_info_version_name(&list.items[i]), version) == 0) {
            *out = list.items[i];
            memset(&list.items[i], 0, sizeof list.items[i]);
            found = true;
            break;
        }
    }
    cg_bundle_list_clear(&list);
    return found;
}

char *cg_store_bundle_directory(cg_engine *engine, const char *id, cg_error *err) {
    char *root = CG_CONFIG_DUP(engine, bundle_root);
    char *dir = cg_store_resolve_inside(root, id, err);
    free(root);
    return dir;
}

bool cg_store_bundle_exists(cg_engine *engine, const char *id) {
    cg_error err = CG_ERROR_INIT;
    char *dir = cg_store_bundle_directory(engine, id, &err);
    cg_err_clear(&err);
    if (!dir) return false;
    cg_bundle_info info;
    cg_store_get_bundle_info(engine, id, &info);
    char *index = cg_fsutil_join(dir, "index.html");
    bool exists = cg_fsutil_is_dir(dir) && cg_fsutil_exists(index) && !cg_bundle_info_is_deleted(&info) &&
                  !cg_bundle_info_is_deleting(&info);
    free(index);
    free(dir);
    cg_bundle_info_clear(&info);
    return exists;
}

/* ---------------------------------------------------------------- current / fallback / next */

static bool trimmed_empty(const char *value) {
    size_t start, len;
    cg_trim_range(value, &start, &len);
    return len == 0;
}

char *cg_store_current_bundle_path(cg_engine *engine) {
    char *builtin = CG_CONFIG_DUP(engine, builtin_server_path);
    char *key = CG_CONFIG_DUP(engine, keys.server_path);
    char *path;
    if (!*builtin) {
        path = kv(engine, key);
        if (!path) path = cg_strdup("");
    } else {
        path = kv_or(engine, key, builtin);
    }
    free(key);
    if (trimmed_empty(path)) {
        free(path);
        return builtin;
    }
    free(builtin);
    return path;
}

bool cg_store_is_using_builtin(cg_engine *engine) {
    char *path = cg_store_current_bundle_path(engine);
    char *builtin = CG_CONFIG_DUP(engine, builtin_server_path);
    bool using_builtin = trimmed_empty(path) || strcmp(path, builtin) == 0 || strcmp(path, "public") == 0;
    free(builtin);
    free(path);
    return using_builtin;
}

char *cg_store_current_bundle_id(cg_engine *engine) {
    if (cg_store_is_using_builtin(engine)) return cg_strdup(CG_BUNDLE_ID_BUILTIN);
    char *path = cg_store_current_bundle_path(engine);
    const char *slash = strrchr(path, '/');
    char *id = cg_strdup(slash ? slash + 1 : path);
    free(path);
    return id;
}

void cg_store_current_bundle(cg_engine *engine, cg_bundle_info *out) {
    char *id = cg_store_current_bundle_id(engine);
    cg_store_get_bundle_info(engine, id, out);
    free(id);
}

static void set_current_bundle_path(cg_engine *engine, const char *path) {
    cg_host_will_switch_bundle(&engine->host, path);
    KV_PUT_KEY(engine, keys.server_path, path);
    cg_info(&engine->host, "Current bundle set to: %s", *path ? path : CG_BUNDLE_ID_BUILTIN);
}

static char *builtin_path(cg_engine *engine) { return CG_CONFIG_DUP(engine, builtin_server_path); }

void cg_store_fallback_bundle(cg_engine *engine, cg_bundle_info *out) {
    char *key = CG_CONFIG_DUP(engine, keys.fallback);
    char *id = kv_or(engine, key, CG_BUNDLE_ID_BUILTIN);
    free(key);
    cg_store_get_bundle_info(engine, id, out);
    free(id);
}

/* fallback NULL: builtin. */
static void set_fallback_bundle(cg_engine *engine, const cg_bundle_info *fallback) {
    KV_PUT_KEY(engine, keys.fallback, fallback ? cg_bundle_info_id(fallback) : CG_BUNDLE_ID_BUILTIN);
}

bool cg_store_next_bundle(cg_engine *engine, cg_bundle_info *out) {
    char *key = CG_CONFIG_DUP(engine, keys.next);
    char *id = kv(engine, key);
    free(key);
    if (!id) return false;
    cg_store_get_bundle_info(engine, id, out);
    free(id);
    return true;
}

/* bundle.is_error() || (!bundle.is_builtin() && !bundle_exists(id)) */
static bool unusable(cg_engine *engine, const cg_bundle_info *bundle, const char *id) {
    return cg_bundle_info_is_error(bundle) ||
           (!cg_bundle_info_is_builtin(bundle) && !cg_store_bundle_exists(engine, id));
}

bool cg_store_preview_fallback_bundle(cg_engine *engine, cg_bundle_info *out) {
    char *key = CG_CONFIG_DUP(engine, keys.preview_fallback);
    char *id = kv(engine, key);
    free(key);
    if (!id) return false;
    cg_bundle_info bundle;
    cg_store_get_bundle_info(engine, id, &bundle);
    bool usable = !unusable(engine, &bundle, id);
    free(id);
    if (!usable) {
        cg_bundle_info_clear(&bundle);
        cg_store_set_preview_fallback_bundle(engine, NULL);
        return false;
    }
    *out = bundle;
    return true;
}

bool cg_store_set_preview_fallback_bundle(cg_engine *engine, const char *fallback) {
    char *key = CG_CONFIG_DUP(engine, keys.preview_fallback);
    bool ok = true;
    if (!fallback) {
        kv_put(engine, key, NULL);
    } else {
        cg_bundle_info bundle;
        cg_store_get_bundle_info(engine, fallback, &bundle);
        if (unusable(engine, &bundle, fallback)) ok = false;
        else kv_put(engine, key, fallback);
        cg_bundle_info_clear(&bundle);
    }
    free(key);
    return ok;
}

bool cg_store_set_next_bundle(cg_engine *engine, const char *next) {
    char *key = CG_CONFIG_DUP(engine, keys.next);
    if (!next) {
        kv_put(engine, key, NULL);
        free(key);
        return true;
    }
    cg_bundle_info bundle;
    cg_store_get_bundle_info(engine, next, &bundle);
    bool result = true;
    if (!cg_bundle_info_is_builtin(&bundle) && !cg_store_bundle_exists(engine, next)) {
        result = false;
        goto done;
    }
    char *current_id = cg_store_current_bundle_id(engine);
    bool is_current = strcmp(next, current_id) == 0;
    free(current_id);
    if (is_current && cg_bundle_info_status(&bundle) == CG_BUNDLE_SUCCESS) {
        cg_info(&engine->host, "Bundle %s is already the current successful bundle. Skip next().", next);
        goto done;
    }
    kv_put(engine, key, next);
    cg_store_set_bundle_status(engine, next, CG_BUNDLE_PENDING);
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    cg_stats_send_stats(engine, "set_next", cg_bundle_info_version_name(&bundle),
                        cg_bundle_info_version_name(&current), NULL);
    cg_bundle_info_clear(&current);
    cj *payload = cj_objv("bundle", cg_bundle_info_to_js(&bundle), NULL);
    cg_host_emit(&engine->host, "setNext", payload);
    cj_free(payload);
done:
    cg_bundle_info_clear(&bundle);
    free(key);
    return result;
}

/* ---------------------------------------------------------------- delete */

static cg_strs pending_delete_ids(cg_engine *engine) {
    char *key = CG_CONFIG_DUP(engine, keys.pending_deletes);
    char *raw = kv_or(engine, key, "");
    free(key);
    cg_strs parts = cg_split(raw, ',');
    free(raw);
    cg_strs ids = {0};
    for (size_t i = 0; i < parts.len; i++)
        if (*parts.items[i] && !cg_strs_contains(&ids, parts.items[i])) cg_strs_push_copy(&ids, parts.items[i]);
    cg_strs_free(&parts);
    return ids;
}

static void write_pending_delete_ids(cg_engine *engine, const cg_strs *ids) {
    if (!ids->len) {
        KV_PUT_KEY(engine, keys.pending_deletes, NULL);
        return;
    }
    cg_buf joined = {0};
    for (size_t i = 0; i < ids->len; i++) {
        if (i) cg_buf_putc(&joined, ',');
        cg_buf_puts(&joined, ids->items[i]);
    }
    char *value = cg_buf_take(&joined);
    KV_PUT_KEY(engine, keys.pending_deletes, value);
    free(value);
}

void cg_store_enqueue_pending_delete(cg_engine *engine, const char *id) {
    cg_strs ids = pending_delete_ids(engine);
    if (*id && !cg_strs_contains(&ids, id)) {
        cg_strs_push_copy(&ids, id);
        write_pending_delete_ids(engine, &ids);
    }
    cg_strs_free(&ids);
}

static void dequeue_pending_delete(cg_engine *engine, const char *id) {
    cg_strs ids = pending_delete_ids(engine);
    size_t out = 0, before = ids.len;
    for (size_t i = 0; i < ids.len; i++) {
        if (strcmp(ids.items[i], id) == 0) free(ids.items[i]);
        else ids.items[out++] = ids.items[i];
    }
    ids.len = out;
    if (ids.len != before) write_pending_delete_ids(engine, &ids);
    cg_strs_free(&ids);
}

/* A live record of `id` (Some, not deleted / error / deleting) protects it from deletion. */
static bool protects(bool present, const cg_bundle_info *bundle, const char *id) {
    return present && !cg_bundle_info_is_deleted(bundle) && !cg_bundle_info_is_error(bundle) &&
           !cg_bundle_info_is_deleting(bundle) && strcmp(cg_bundle_info_id(bundle), id) == 0;
}

static bool delete_locked(cg_engine *engine, const char *id, bool remove_info, bool cancel_active_download) {
    cg_host *host = &engine->host;
    cg_error err = CG_ERROR_INIT;
    char *dir = cg_store_bundle_directory(engine, id, &err);
    if (!dir) {
        cg_error_log(host, "Cannot delete bundle with invalid id");
        cg_debug(host, "Bundle ID: %s, Error: %s", id, cg_or_empty(err.message));
        cg_err_clear(&err);
        return false;
    }
    bool result = false;
    cg_bundle_info deleted;
    cg_store_get_bundle_info(engine, id, &deleted);
    char *current_id = cg_store_current_bundle_id(engine);
    bool is_current = strcmp(current_id, id) == 0;
    free(current_id);
    if (cg_bundle_info_is_builtin(&deleted) || is_current) {
        cg_error_log(host, "Cannot delete current or builtin bundle");
        cg_debug(host, "Bundle ID: %s", id);
        goto done;
    }
    cg_bundle_info other;
    bool present = cg_store_preview_fallback_bundle(engine, &other);
    bool protected = protects(present, &other, id);
    if (present) cg_bundle_info_clear(&other);
    if (protected) {
        cg_error_log(host, "Cannot delete the preview fallback bundle");
        cg_debug(host, "Bundle ID: %s", id);
        goto done;
    }
    present = cg_store_next_bundle(engine, &other);
    protected = protects(present, &other, id);
    if (present) cg_bundle_info_clear(&other);
    if (protected) {
        cg_error_log(host, "Cannot delete the next bundle");
        cg_debug(host, "Bundle ID: %s", id);
        goto done;
    }
    if (!cg_store_has_stored_bundle_info(engine, id) && !cg_fsutil_exists(dir)) {
        cg_error_log(host, "Cannot delete unknown bundle");
        cg_debug(host, "Bundle ID: %s", id);
        goto done;
    }
    if (!cg_bundle_info_is_deleting(&deleted) && !save_with_status(engine, id, &deleted, CG_BUNDLE_DELETING)) {
        cg_error_log(host, "Failed to persist DELETING marker, aborting disk delete");
        goto done;
    }
    if (cancel_active_download &&
        !cg_scheduled_cancel_version_download(engine, cg_bundle_info_version_name(&deleted))) {
        cg_error_log(host, "Failed to cancel active download before delete");
        goto done;
    }
    if (cg_fsutil_exists(dir) && !cg_store_remove_path(dir, &err)) {
        cg_error_log(host, "Failed to delete bundle folder, will retry later");
        cg_debug(host, "Bundle ID: %s, Error: %s", id, cg_or_empty(err.message));
        cg_err_clear(&err);
        goto done;
    }
    if (cg_fsutil_exists(dir)) {
        cg_error_log(host, "Bundle folder still present after delete, will retry later");
        goto done;
    }
    bool finalized = remove_info ? cg_store_save_bundle_info(engine, id, NULL)
                                 : save_with_status(engine, id, &deleted, CG_BUNDLE_DELETED);
    if (!finalized) {
        cg_error_log(host, "Failed to finalize delete registry update, will retry later");
        goto done;
    }
    cg_stats_send_stats(engine, "delete", cg_bundle_info_version_name(&deleted), NULL, NULL);
    dequeue_pending_delete(engine, id);
    cg_info(host, "Bundle deleted and confirmed gone");
    cg_debug(host, "Bundle ID: %s", id);
    result = true;
done:
    cg_bundle_info_clear(&deleted);
    free(dir);
    return result;
}

bool cg_store_delete_bundle(cg_engine *engine, const char *id, bool remove_info, bool cancel_active_download) {
    cg_lock(&engine->delete_lock);
    bool deleted = delete_locked(engine, id, remove_info, cancel_active_download);
    cg_unlock(&engine->delete_lock);
    return deleted;
}

void cg_store_drain_pending_deletes(cg_engine *engine) {
    cg_strs ids = {0};
    cg_bundle_list records;
    cg_store_list(engine, true, &records);
    for (size_t i = 0; i < records.len; i++) {
        const cg_bundle_info *info = &records.items[i];
        if (cg_bundle_info_is_deleting(info) && *cg_bundle_info_id(info))
            cg_strs_push_copy(&ids, cg_bundle_info_id(info));
    }
    cg_bundle_list_clear(&records);
    cg_strs pending = pending_delete_ids(engine);
    for (size_t i = 0; i < pending.len; i++)
        if (!cg_strs_contains(&ids, pending.items[i])) cg_strs_push_copy(&ids, pending.items[i]);
    cg_strs_free(&pending);
    for (size_t i = 0; i < ids.len; i++) {
        cg_info(&engine->host, "Resuming pending delete for bundle: %s", ids.items[i]);
        if (cg_store_delete_bundle(engine, ids.items[i], true, true)) dequeue_pending_delete(engine, ids.items[i]);
        cg_sleep_ms(DELETE_PACE_MS);
    }
    cg_strs_free(&ids);
}

/* ---------------------------------------------------------------- set / reset */

static void set_failed(cg_engine *engine, const char *id, const cg_bundle_info *bundle) {
    cg_store_set_bundle_status(engine, id, CG_BUNDLE_ERROR);
    cg_stats_send_stats(engine, "set_fail", cg_bundle_info_version_name(bundle), NULL, NULL);
}

bool cg_store_set_bundle(cg_engine *engine, const char *id) {
    cg_bundle_info bundle;
    cg_store_get_bundle_info(engine, id, &bundle);
    if (cg_bundle_info_is_builtin(&bundle)) {
        cg_bundle_info_clear(&bundle);
        cg_store_reset(engine, false);
        return true;
    }
    cg_error err = CG_ERROR_INIT;
    char *dir = cg_store_bundle_directory(engine, id, &err);
    if (!dir) {
        cg_error_log(&engine->host, "Invalid bundle id");
        cg_debug(&engine->host, "Bundle ID: %s, Error: %s", id, cg_or_empty(err.message));
        cg_err_clear(&err);
        set_failed(engine, id, &bundle);
        cg_bundle_info_clear(&bundle);
        return false;
    }
    cg_info(&engine->host, "Setting next active bundle: %s", id);
    bool set = cg_store_bundle_exists(engine, id);
    if (set) {
        cg_bundle_info previous;
        cg_store_current_bundle(engine, &previous);
        set_current_bundle_path(engine, dir);
        cg_store_set_bundle_status(engine, id, CG_BUNDLE_PENDING);
        cg_stats_send_stats(engine, "set", cg_bundle_info_version_name(&bundle),
                            cg_bundle_info_version_name(&previous), NULL);
        cg_bundle_info_clear(&previous);
    } else {
        set_failed(engine, id, &bundle);
    }
    free(dir);
    cg_bundle_info_clear(&bundle);
    return set;
}

bool cg_store_can_set(cg_engine *engine, const cg_bundle_info *bundle) {
    return cg_bundle_info_is_builtin(bundle) || cg_store_bundle_exists(engine, cg_bundle_info_id(bundle));
}

bool cg_store_stage_pending_reload(cg_engine *engine, const cg_bundle_info *bundle) {
    if (cg_bundle_info_is_builtin(bundle) || !cg_store_bundle_exists(engine, cg_bundle_info_id(bundle))) return false;
    cg_error err = CG_ERROR_INIT;
    char *dir = cg_store_bundle_directory(engine, cg_bundle_info_id(bundle), &err);
    cg_err_clear(&err);
    if (!dir) return false;
    set_current_bundle_path(engine, dir);
    free(dir);
    return true;
}

bool cg_store_stage_preview_fallback_reload(cg_engine *engine, const cg_bundle_info *bundle) {
    if (cg_bundle_info_is_error(bundle)) return false;
    if (cg_bundle_info_is_builtin(bundle)) {
        char *path = builtin_path(engine);
        set_current_bundle_path(engine, path);
        free(path);
        return true;
    }
    return cg_store_stage_pending_reload(engine, bundle);
}

void cg_store_finalize_pending_reload(cg_engine *engine, const cg_bundle_info *bundle,
                                      const char *previous_bundle_name) {
    if (!cg_bundle_info_is_builtin(bundle))
        cg_stats_send_stats(engine, "set", cg_bundle_info_version_name(bundle), previous_bundle_name, NULL);
}

void cg_store_capture_reset_state(cg_engine *engine, cg_reset_state *out) {
    out->current_bundle_path = cg_store_current_bundle_path(engine);
    char *fallback = CG_CONFIG_DUP(engine, keys.fallback);
    out->fallback_bundle_id = kv_or(engine, fallback, CG_BUNDLE_ID_BUILTIN);
    free(fallback);
    char *next = CG_CONFIG_DUP(engine, keys.next);
    out->next_bundle_id = kv(engine, next);
    free(next);
}

void cg_store_restore_reset_state(cg_engine *engine, const cg_reset_state *state) {
    char *path = trimmed_empty(cg_or_empty(state->current_bundle_path)) ? builtin_path(engine)
                                                                        : cg_strdup(state->current_bundle_path);
    KV_PUT_KEY(engine, keys.server_path, path);
    free(path);
    const char *fallback = cg_or_empty(state->fallback_bundle_id);
    KV_PUT_KEY(engine, keys.fallback, *fallback ? fallback : CG_BUNDLE_ID_BUILTIN);
    const char *next = state->next_bundle_id && *state->next_bundle_id ? state->next_bundle_id : NULL;
    KV_PUT_KEY(engine, keys.next, next);
}

void cg_store_prepare_reset_state_for_transition(cg_engine *engine) {
    char *path = builtin_path(engine);
    set_current_bundle_path(engine, path);
    free(path);
    set_fallback_bundle(engine, NULL);
    KV_PUT_KEY(engine, keys.next, NULL);
}

void cg_store_finalize_reset_transition(cg_engine *engine, const char *previous_bundle_name, bool internal) {
    cg_host_cancel_all_downloads(&engine->host);
    cg_scheduled_cancel_scheduled_downloads(engine, NULL);
    if (!internal) {
        cg_bundle_info current;
        cg_store_current_bundle(engine, &current);
        cg_stats_send_stats(engine, "reset", cg_bundle_info_version_name(&current), previous_bundle_name, NULL);
        cg_bundle_info_clear(&current);
    }
}

void cg_store_reset(cg_engine *engine, bool internal) {
    cg_debug(&engine->host, "reset: %s", internal ? "true" : "false");
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    char *previous = cg_strdup(cg_bundle_info_version_name(&current));
    cg_bundle_info_clear(&current);
    cg_store_prepare_reset_state_for_transition(engine);
    cg_store_finalize_reset_transition(engine, previous, internal);
    free(previous);
}

static char *stored_native_build_version(cg_engine *engine) {
    char *key = CG_CONFIG_DUP(engine, keys.native_build_version);
    char *current = kv_or(engine, key, "");
    free(key);
    if (*current) return current;
    free(current);
    key = CG_CONFIG_DUP(engine, keys.legacy_native_build_version);
    char *legacy = kv_or(engine, key, "");
    free(key);
    return legacy;
}

void cg_store_auto_reset(cg_engine *engine, const char *current_native_build_version,
                         bool reset_when_native_version_changed) {
    cg_bundle_info current;
    cg_store_current_bundle(engine, &current);
    if (!cg_bundle_info_is_builtin(&current) && !cg_store_bundle_exists(engine, cg_bundle_info_id(&current))) {
        cg_info(&engine->host, "Folder at bundle path does not exist. Triggering reset.");
        cg_bundle_info_clear(&current);
        cg_store_reset(engine, false);
        return;
    }
    char *key = CG_CONFIG_DUP(engine, keys.server_path);
    char *bundle_path = kv(engine, key);
    free(key);
    bool has_info = cg_store_has_stored_bundle_info(engine, cg_bundle_info_id(&current));
    char *builtin = builtin_path(engine);
    const char *foreign =
        bundle_path && strcmp(bundle_path, builtin) != 0 && strcmp(bundle_path, "public") != 0 ? bundle_path : NULL;
    bool foreign_reset =
        cg_policy_should_reset_for_foreign_bundle(foreign, cg_bundle_info_is_builtin(&current), has_info);
    free(builtin);
    free(bundle_path);
    cg_bundle_info_clear(&current);
    if (foreign_reset) {
        cg_info(&engine->host,
                "Current bundle id is not one of the bundle ids stored by this plugin. Triggering reset.");
        cg_store_reset(engine, false);
        return;
    }
    char *previous = stored_native_build_version(engine);
    const char *native = cg_or_empty(current_native_build_version);
    if (reset_when_native_version_changed && *previous && *native && strcmp(previous, native) != 0) {
        cg_info(&engine->host,
                "Stored native build version %s does not match current native build version %s. Triggering reset.",
                previous, native);
        cg_store_reset(engine, false);
    }
    free(previous);
}

typedef struct {
    char *previous_id;
    char *previous_version;
} delete_previous_job;

static void delete_previous_drop(void *ctx) {
    delete_previous_job *job = ctx;
    free(job->previous_id);
    free(job->previous_version);
    free(job);
}

static void delete_previous_run(cg_engine *engine, void *ctx) {
    delete_previous_job *job = ctx;
    if (!cg_scheduled_cancel_version_download(engine, job->previous_version)) {
        cg_error_log(&engine->host, "Failed to cancel previous version download before delete");
        return;
    }
    if (cg_store_delete_bundle(engine, job->previous_id, true, false))
        cg_info(&engine->host, "Deleted previous bundle: %s", job->previous_version);
    else
        cg_debug(&engine->host, "Previous bundle delete incomplete, will retry: %s", job->previous_id);
}

void cg_store_set_success(cg_engine *engine, const char *id, bool auto_delete_previous) {
    cg_store_set_bundle_status(engine, id, CG_BUNDLE_SUCCESS);
    cg_bundle_info fallback, preview, bundle, next;
    cg_store_fallback_bundle(engine, &fallback);
    bool has_preview = cg_store_preview_fallback_bundle(engine, &preview);
    bool fallback_is_preview =
        has_preview && strcmp(cg_bundle_info_id(&preview), cg_bundle_info_id(&fallback)) == 0;
    if (has_preview) cg_bundle_info_clear(&preview);
    cg_store_get_bundle_info(engine, id, &bundle);
    cg_info(&engine->host, "Version successfully loaded: %s", cg_bundle_info_version_name(&bundle));
    const char *previous_id = cg_bundle_info_id(&fallback);
    const char *previous_version = cg_bundle_info_version_name(&fallback);
    bool has_next = cg_store_next_bundle(engine, &next);
    bool previous_is_next = has_next && strcmp(cg_bundle_info_id(&next), previous_id) == 0 &&
                            !cg_bundle_info_is_deleted(&next) && !cg_bundle_info_is_error(&next) &&
                            !cg_bundle_info_is_deleting(&next);
    if (has_next) cg_bundle_info_clear(&next);
    bool delete_previous = auto_delete_previous && !cg_bundle_info_is_builtin(&fallback) &&
                           strcmp(previous_id, id) != 0 && !fallback_is_preview && !previous_is_next;
    if (delete_previous && !save_with_status(engine, previous_id, &fallback, CG_BUNDLE_DELETING)) {
        cg_error_log(&engine->host, "Failed to persist DELETING for previous bundle; queueing durable retry");
        cg_store_enqueue_pending_delete(engine, previous_id);
    }
    set_fallback_bundle(engine, &bundle);
    if (delete_previous) {
        delete_previous_job *job = cg_calloc(1, sizeof(delete_previous_job));
        job->previous_id = cg_strdup(previous_id);
        job->previous_version = cg_strdup(previous_version);
        cg_engine_spawn_strong(engine, "delete", delete_previous_run, job, delete_previous_drop);
    }
    cg_bundle_info_clear(&bundle);
    cg_bundle_info_clear(&fallback);
}

void cg_store_set_error(cg_engine *engine, const char *id) { cg_store_set_bundle_status(engine, id, CG_BUNDLE_ERROR); }

/* ---------------------------------------------------------------- cleanup */

cg_strs cg_store_allowed_bundle_ids_for_cleanup(cg_engine *engine) {
    cg_strs allowed = {0};
    cg_bundle_list records;
    cg_store_list(engine, true, &records);
    for (size_t i = 0; i < records.len; i++) {
        const cg_bundle_info *info = &records.items[i];
        /* DELETED tombstones must not protect leftover folders; DELETING stays protected so
         * drain_pending_deletes owns the removal. */
        if (*cg_bundle_info_id(info) && !cg_bundle_info_is_deleted(info))
            cg_strs_push_copy(&allowed, cg_bundle_info_id(info));
    }
    cg_bundle_list_clear(&records);
    cg_strs_push(&allowed, cg_store_current_bundle_id(engine));
    cg_bundle_info bundle;
    cg_store_fallback_bundle(engine, &bundle);
    if (!cg_bundle_info_is_deleting(&bundle)) cg_strs_push_copy(&allowed, cg_bundle_info_id(&bundle));
    cg_bundle_info_clear(&bundle);
    if (cg_store_next_bundle(engine, &bundle)) {
        if (!cg_bundle_info_is_deleting(&bundle)) cg_strs_push_copy(&allowed, cg_bundle_info_id(&bundle));
        cg_bundle_info_clear(&bundle);
    }
    if (cg_store_preview_fallback_bundle(engine, &bundle)) {
        if (!cg_bundle_info_is_deleting(&bundle)) cg_strs_push_copy(&allowed, cg_bundle_info_id(&bundle));
        cg_bundle_info_clear(&bundle);
    }
    sort_dedup(&allowed);
    return allowed;
}

void cg_store_cleanup_download_directories(cg_engine *engine, const cg_strs *allowed, const cg_cancelled_fn *cancelled) {
    char *root = CG_CONFIG_DUP(engine, bundle_root);
    cg_strs names;
    if (!read_dir(root, &names)) {
        free(root);
        return;
    }
    for (size_t i = 0; i < names.len; i++) {
        if (cg_cancelled_fn_check(cancelled)) {
            cg_warn(&engine->host, "cleanupDownloadDirectories was cancelled");
            break;
        }
        char *path = cg_fsutil_join(root, names.items[i]);
        char *id = cg_utf8_lossy((const uint8_t *)names.items[i], strlen(names.items[i]));
        if (cg_fsutil_is_dir(path) && !cg_strs_contains(allowed, id)) {
            cg_error err = CG_ERROR_INIT;
            if (cg_store_remove_path(path, &err)) {
                if (!cg_fsutil_exists(path)) {
                    cg_store_save_bundle_info(engine, id, NULL);
                    cg_info(&engine->host, "Deleted orphan bundle directory");
                    cg_debug(&engine->host, "Bundle ID: %s", id);
                } else {
                    cg_error_log(&engine->host, "Orphan bundle directory still present after delete");
                }
            } else {
                cg_error_log(&engine->host, "Failed to delete orphan bundle directory");
                cg_debug(&engine->host, "Bundle ID: %s, Error: %s", id, cg_or_empty(err.message));
                cg_err_clear(&err);
            }
        }
        free(id);
        free(path);
    }
    cg_strs_free(&names);
    free(root);
}

void cg_store_cleanup_orphaned_temp_folders(cg_engine *engine, const cg_cancelled_fn *cancelled) {
    char *root = CG_CONFIG_DUP(engine, storage_root);
    cg_strs names;
    if (!read_dir(root, &names)) {
        free(root);
        return;
    }
    for (size_t i = 0; i < names.len; i++) {
        if (cg_cancelled_fn_check(cancelled)) {
            cg_warn(&engine->host, "cleanupOrphanedTempFolders was cancelled");
            break;
        }
        char *name = cg_utf8_lossy((const uint8_t *)names.items[i], strlen(names.items[i]));
        char *path = cg_fsutil_join(root, names.items[i]);
        bool stop = false;
        if (cg_fsutil_is_dir(path) && cg_starts_with(name, CG_TEMP_UNZIP_PREFIX)) {
            if (cg_scheduled_running_jobs() > 0) {
                /* A scheduled download of this process may be extracting into it. */
                cg_info(&engine->host, "Scheduled download running, orphaned temp folders are swept next launch");
                stop = true;
            } else {
                cg_error err = CG_ERROR_INIT;
                if (cg_store_remove_path(path, &err)) {
                    cg_info(&engine->host, "Deleted orphaned temp unzip folder");
                } else {
                    cg_error_log(&engine->host, "Failed to delete orphaned temp folder");
                    cg_debug(&engine->host, "Folder: %s, Error: %s", name, cg_or_empty(err.message));
                    cg_err_clear(&err);
                }
            }
        }
        free(path);
        free(name);
        if (stop) break;
    }
    cg_strs_free(&names);
    free(root);
}

void cg_store_cleanup_delta_cache(cg_engine *engine) {
    char *cache = CG_CONFIG_DUP(engine, cache_dir);
    if (*cache && cg_fsutil_exists(cache)) {
        cg_error err = CG_ERROR_INIT;
        if (cg_store_remove_path(cache, &err)) {
            cg_info(&engine->host, "Cleaned up delta cache folder");
        } else {
            cg_error_log(&engine->host, "Failed to cleanup delta cache");
            cg_debug(&engine->host, "Error: %s", cg_or_empty(err.message));
            cg_err_clear(&err);
        }
    }
    free(cache);
}

void cg_store_new_download_record(cg_engine *engine, const char *version, cg_bundle_info *out) {
    char *id = cg_store_random_id();
    char *now = cg_bundle_iso8601_now();
    cg_bundle_info_init(out, id, version, CG_BUNDLE_DOWNLOADING, now, "");
    cg_store_save_bundle_info(engine, id, out);
    free(now);
    free(id);
}
