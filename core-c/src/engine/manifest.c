/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Manifest (delta) downloads (Rust engine/manifest.rs): every file is reused from the builtin
 * bundle, the APK assets (Android) or the delta cache when its hash matches, and only the rest is
 * fetched (resumable partials, brotli, per-file decryption).
 */

#include "engine/manifest.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#include "crypto/aes_cbc.h"
#include "crypto/checksum.h"
#include "crypto/crypto.h"
#include "engine/apk.h"
#include "engine/brotli_stream.h"
#include "engine/engine.h"
#include "engine/fsutil.h"
#include "engine/stats.h"
#include "engine/store.h"
#include "http.h"
#include "paths.h"
#include "policy.h"

#define PER_FILE_ESTIMATE (100ull * 1024)
#define MIN_FREE_BYTES (50ull * 1024 * 1024)
/* Network reads are small: batch them into large writes (Rust BufWriter::with_capacity). */
#define PARTIAL_BUFFER_BYTES (256u * 1024u)

typedef struct {
    char *file_name;
    char *download_url;
    char *hash;
    bool brotli;
    char *target;
    char *builtin;      /* NULL = None */
    char *asset;        /* NULL = None */
    char *cache;        /* NULL = None */
    char *legacy_cache; /* NULL = None */
} task;

static void task_clear(task *t) {
    free(t->file_name);
    free(t->download_url);
    free(t->hash);
    free(t->target);
    free(t->builtin);
    free(t->asset);
    free(t->cache);
    free(t->legacy_cache);
    memset(t, 0, sizeof *t);
}

/* ---------------------------------------------------------------- JSON entries */

/* entry.get(key).and_then(Value::as_str): the JSON string, NULL when absent / not a string. */
static const cj *entry_value(const cj *entry, const char *key) {
    const cj *value = cj_is_obj(entry) ? cj_get(entry, key) : NULL;
    return cj_is_str(value) ? value : NULL;
}

static bool entry_empty(const cj *entry, const char *key) {
    const cj *value = entry_value(entry, key);
    return !value || value->v.s.len == 0;
}

/* The C view of a field ("" when absent). */
static const char *entry_text(const cj *entry, const char *key) {
    const cj *value = entry_value(entry, key);
    return value ? cj_as_str(value) : "";
}

/* A hash (only compared or decoded): NUL bytes become 0x01 so the C string fails every check the
 * Rust string fails (no hex, no base64, never equal to a computed hash). */
static char *hash_text(const cj *value) {
    char *text = cg_strndup(value->v.s.ptr, value->v.s.len);
    for (size_t i = 0; i < value->v.s.len; i++)
        if (text[i] == '\0') text[i] = '\x01';
    return text;
}

/* A URL: NUL bytes are percent-encoded (the Rust url parser escapes C0 controls). */
static char *url_text(const cj *value) {
    cg_buf buf = {0};
    for (size_t i = 0; value && i < value->v.s.len; i++) {
        if (value->v.s.ptr[i] == '\0') {
            cg_buf_puts(&buf, "%00");
        } else {
            cg_buf_putc(&buf, value->v.s.ptr[i]);
        }
    }
    return cg_buf_take(&buf);
}

static const char *basename_of(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

/* paths::resolve_manifest_target_path, refusing a name holding a NUL byte (Rust: invalid
 * separator) instead of resolving its truncated C view. */
static char *resolve_target(const char *base, const cj *file_name) {
    if (!file_name || cj_str_has_nul(file_name)) return NULL;
    cg_error ignored = CG_ERROR_INIT;
    char *path = cg_paths_resolve_manifest_target_path(base, cj_as_str(file_name), &ignored);
    cg_err_clear(&ignored);
    return path;
}

static char *builtin_asset(const cj *file_name) {
    if (!file_name || cj_str_has_nul(file_name)) return NULL;
    cg_error ignored = CG_ERROR_INIT;
    char *path = cg_paths_builtin_asset_path(cj_as_str(file_name), &ignored);
    cg_err_clear(&ignored);
    return path;
}

/* ---------------------------------------------------------------- APK assets */

/* ApkAssets::with_entry: reader over `assets/<name>`, NULL (Rust None). *index must be released. */
static cg_reader *apk_entry(const char *apk, const char *name, cg_apk_index **index) {
    *index = cg_apk_index_shared(apk);
    if (!*index) return NULL;
    char *entry = cg_fmt("assets/%s", name);
    cg_reader *reader = cg_apk_index_entry(*index, entry);
    free(entry);
    return reader;
}

static bool apk_matches(const char *apk, const char *name, const char *hash) {
    cg_apk_index *index = NULL;
    cg_reader *reader = apk_entry(apk, name, &index);
    bool matches = false;
    if (reader) {
        cg_error ignored = CG_ERROR_INIT;
        char *actual = cg_fsutil_sha256_reader(reader, &ignored);
        cg_err_clear(&ignored);
        matches = actual && cg_eq_nocase(actual, hash);
        free(actual);
        cg_reader_free(reader);
    }
    cg_apk_index_release(index);
    return matches;
}

static bool apk_copy_if_matches(const char *apk, const char *name, const char *hash, const char *target) {
    cg_apk_index *index = NULL;
    cg_reader *reader = apk_entry(apk, name, &index);
    bool copied = false;
    if (reader) {
        cg_error ignored = CG_ERROR_INIT;
        char *written = NULL;
        copied = cg_fsutil_write_verified(reader, target, hash, &written, &ignored) && written;
        cg_err_clear(&ignored);
        free(written);
        cg_reader_free(reader);
    }
    cg_apk_index_release(index);
    return copied;
}

/* Engine::apk_assets: the APK path when it is a file, NULL otherwise. */
static char *apk_assets(cg_engine *engine) {
    char *path = CG_CONFIG_DUP(engine, builtin_apk);
    if (*path && cg_fsutil_is_file(path)) return path;
    free(path);
    return NULL;
}

/* ---------------------------------------------------------------- partial locks */

/* Per-path lock shared by every engine in the process (entries die with their last user). */
typedef struct partial_lock {
    struct partial_lock *next;
    char *path;
    size_t users;
    cg_mutex mutex;
} partial_lock;

static cg_mutex partial_locks_mutex = CG_MUTEX_INIT;
static partial_lock *partial_locks;

static partial_lock *partial_lock_acquire(const char *path) {
    cg_lock(&partial_locks_mutex);
    partial_lock *lock = partial_locks;
    while (lock && strcmp(lock->path, path) != 0) lock = lock->next;
    if (!lock) {
        lock = cg_calloc(1, sizeof *lock);
        lock->path = cg_strdup(path);
        cg_mutex_init(&lock->mutex);
        lock->next = partial_locks;
        partial_locks = lock;
    }
    lock->users++;
    cg_unlock(&partial_locks_mutex);
    cg_lock(&lock->mutex);
    return lock;
}

static void partial_lock_release(partial_lock *lock) {
    cg_unlock(&lock->mutex);
    cg_lock(&partial_locks_mutex);
    if (--lock->users == 0) {
        partial_lock **slot = &partial_locks;
        while (*slot != lock) slot = &(*slot)->next;
        *slot = lock->next;
        cg_mutex_destroy(&lock->mutex);
        free(lock->path);
        free(lock);
    }
    cg_unlock(&partial_locks_mutex);
}

/* ---------------------------------------------------------------- session key */

/* AES key of an encrypted manifest download: one RSA operation, done the first time a file
 * actually has to be decrypted (reused files need none). */
typedef struct {
    cg_mutex lock;
    bool done;
    bool ok;
    bool has_key;
    cg_session_key key;
    char *error;
    const char *public_key;
    const char *session_key;
} lazy_session;

/* true: *key is the session key or NULL (not encrypted). false: *error is the message (borrowed). */
static bool lazy_session_get(lazy_session *session, const cg_session_key **key, const char **error) {
    cg_lock(&session->lock);
    if (!session->done) {
        cg_error err = CG_ERROR_INIT;
        session->ok = cg_crypto_bundle_session_key(session->public_key, session->session_key, &session->key,
                                                   &session->has_key, &err);
        if (!session->ok) session->error = cg_fmt("Failed to decrypt session key: %s", cg_or_empty(err.message));
        cg_err_clear(&err);
        session->done = true;
    }
    cg_unlock(&session->lock);
    *key = session->ok && session->has_key ? &session->key : NULL;
    *error = session->error;
    return session->ok;
}

/* ---------------------------------------------------------------- decrypting reader */

/* crypto::aes_cbc::CbcDecryptReader as a cg_reader: invalid data is CG_IO_INVALID_DATA. */
typedef struct {
    cg_reader base;
    cg_cbc_reader cbc;
    int fd;
} cbc_reader;

static ptrdiff_t cbc_reader_read(cg_reader *self, uint8_t *buf, size_t len, cg_error *err) {
    cbc_reader *reader = (cbc_reader *)self;
    cg_error error = CG_ERROR_INIT;
    ssize_t n = cg_cbc_reader_read(&reader->cbc, buf, len, &error);
    if (n < 0) {
        if (cg_err_is(&error, "decrypt_failed")) {
            cg_fsutil_io_error(err, CG_IO_INVALID_DATA, cg_or_empty(error.message));
        } else {
            cg_fsutil_io_error(err, reader->cbc.io_errno == ENOENT ? CG_IO_NOT_FOUND : CG_IO_OTHER,
                               cg_or_empty(error.message));
        }
        cg_err_clear(&error);
        return -1;
    }
    return (ptrdiff_t)n;
}

static void cbc_reader_free(cg_reader *self) {
    cbc_reader *reader = (cbc_reader *)self;
    cg_cbc_reader_free(&reader->cbc);
    close(reader->fd);
    free(reader);
}

/* Takes ownership of fd. */
static cg_reader *cbc_reader_new(int fd, const cg_session_key *key) {
    cbc_reader *reader = cg_calloc(1, sizeof *reader);
    reader->base.read = cbc_reader_read;
    reader->base.free = cbc_reader_free;
    reader->fd = fd;
    cg_cbc_reader_init_fd(&reader->cbc, fd, key->key, key->iv);
    return &reader->base;
}

/* ---------------------------------------------------------------- hashes and cache */

/* Engine::manifest_hash: NULL (Rust None) when absent or undecryptable. */
static char *manifest_hash(const char *public_key, const cj *entry, const char *session_key) {
    const cj *value = entry_value(entry, "file_hash");
    if (!value || value->v.s.len == 0) return NULL;
    char *hash = hash_text(value);
    if (!*public_key) return hash;
    char *decrypted = NULL;
    if (cg_crypto_is_valid_session_key(session_key)) {
        cg_error ignored = CG_ERROR_INIT;
        decrypted = cg_crypto_decrypt_checksum(hash, public_key, &ignored);
        cg_err_clear(&ignored);
    }
    free(hash);
    return decrypted;
}

/* Engine::cache_paths: (current, legacy) delta-cache files of a hash, NULL when none. */
static void cache_paths(const char *cache, const char *hash, const cj *file_name, char **current, char **legacy) {
    *current = *legacy = NULL;
    if (!*cache || !cg_paths_is_safe_cache_hash(hash)) return;
    /* A name holding a NUL byte has no usable cache file (Rust: the path cannot exist). */
    if (!file_name || cj_str_has_nul(file_name)) return;
    const char *name = cj_as_str(file_name);
    char *cache_name = cg_paths_cache_file_name(hash, name);
    *current = cg_fsutil_join(cache, cache_name);
    free(cache_name);
    if (cg_ends_with(name, ".br")) {
        char *legacy_name = cg_fmt("%s_%s", hash, basename_of(name));
        *legacy = cg_fsutil_join(cache, legacy_name);
        free(legacy_name);
    }
}

/* Engine::reusable. */
static bool reusable(const char *path, const char *hash) {
    if (!path) return false;
    struct stat st;
    bool is_file = stat(path, &st) == 0 && S_ISREG(st.st_mode);
    return cg_paths_is_reusable_cache_file(hash, is_file, is_file ? (int64_t)st.st_size : -1);
}

cj *cg_manifest_missing_bundle_files(cg_engine *engine, const cj *manifest, const char *session_key) {
    cg_engine_config *config = cg_engine_config_snapshot(engine);
    char *assets = apk_assets(engine);
    cj *missing = cj_arr();
    size_t total = cj_is_arr(manifest) ? cj_len(manifest) : 0;
    for (size_t i = 0; i < total; i++) {
        const cj *entry = cj_at(manifest, i);
        const cj *file_name = entry_value(entry, "file_name");
        char *hash = manifest_hash(config->public_key, entry, session_key);
        bool is_missing = true;
        if (hash && file_name && file_name->v.s.len > 0) {
            char *path = resolve_target(config->builtin_dir, file_name);
            if (path && *config->builtin_dir && cg_fsutil_file_matches_hash(path, hash)) is_missing = false;
            free(path);
            if (is_missing && assets) {
                char *asset = builtin_asset(file_name);
                if (asset && apk_matches(assets, asset, hash)) is_missing = false;
                free(asset);
            }
            if (is_missing) {
                char *current, *legacy;
                cache_paths(config->cache_dir, hash, file_name, &current, &legacy);
                if (reusable(current, hash) || reusable(legacy, hash)) is_missing = false;
                free(current);
                free(legacy);
            }
        }
        free(hash);
        if (is_missing) cj_push(missing, cj_clone(entry));
    }
    size_t missing_count = cj_len(missing);
    free(assets);
    cg_config_release(config);
    return cj_objv("missing", missing, "total", cj_u64(total), "missingCount", cj_u64(missing_count),
                   "reusableCount", cj_u64(total - missing_count), NULL);
}

/* ---------------------------------------------------------------- download_manifest */

bool cg_manifest_download_manifest(cg_engine *engine, const cg_download_request *request, cg_bundle_info *out,
                                   cg_error *err) {
    if (!cg_download_require_session_key(engine, request->session_key, request->version, err)) return false;
    char *blocked = cg_host_before_download(&engine->host);
    if (blocked) return cg_err_set_own(err, "download_blocked", blocked);
    cg_bundle_info existing;
    if (cg_store_get_bundle_info_by_name(engine, request->version, &existing)) {
        bool failed = (cg_bundle_info_is_error(&existing) || cg_bundle_info_is_deleted(&existing) ||
                       cg_bundle_info_is_deleting(&existing)) &&
                      !cg_store_delete_bundle(engine, existing.id, true, false);
        cg_bundle_info_clear(&existing);
        if (failed) return cg_err_set(err, "delete_failed", "Failed to delete existing bundle before retry");
    }
    cg_download_request copy;
    cg_download_request_copy(&copy, request);
    if (!copy.manifest) copy.manifest = cj_arr();
    cg_bundle_info record;
    cg_download_start_record(engine, &copy, &record);
    cg_download_progress(engine, record.id, 0);
    bool ok = cg_download_run_download(engine, &copy, &record, out, err);
    cg_bundle_info_clear(&record);
    cg_download_request_clear(&copy);
    return ok;
}

static void manifest_path_fail(cg_engine *engine, const char *version, const char *file_name) {
    char *name = cg_fmt("%s:%s", version, file_name);
    cg_stats_send_stats(engine, "manifest_path_fail", name, NULL, NULL);
    free(name);
}

/* Path key with Rust Path equality (components: repeated separators, `.` and a trailing
 * separator do not count). */
static char *path_key(const char *path) {
    cg_buf buf = {0};
    const char *p = path;
    if (*p == '/') cg_buf_putc(&buf, '/');
    bool first = true;
    while (*p) {
        while (*p == '/') p++;
        const char *start = p;
        while (*p && *p != '/') p++;
        size_t len = (size_t)(p - start);
        if (len == 0) break;
        if (len == 1 && start[0] == '.' && !(first && path[0] != '/')) continue;
        if (!first && buf.len > 0 && buf.data[buf.len - 1] != '/') cg_buf_putc(&buf, '/');
        cg_buf_put(&buf, start, len);
        first = false;
    }
    return cg_buf_take(&buf);
}

/* BTreeSet<PathBuf> of planned targets: open addressing over path keys. */
typedef struct {
    char **slots;
    size_t cap, len;
} path_set;

static uint64_t hash_string(const char *value) {
    uint64_t h = 1469598103934665603ull;
    for (const unsigned char *p = (const unsigned char *)value; *p; p++) h = (h ^ *p) * 1099511628211ull;
    return h;
}

/* Inserts (takes ownership of key); false when already present (key freed). */
static bool path_set_insert(path_set *set, char *key) {
    if ((set->len + 1) * 2 > set->cap) {
        size_t cap = set->cap ? set->cap * 2 : 64;
        char **slots = cg_calloc(cap, sizeof(char *));
        for (size_t i = 0; i < set->cap; i++) {
            if (!set->slots[i]) continue;
            size_t at = hash_string(set->slots[i]) & (cap - 1);
            while (slots[at]) at = (at + 1) & (cap - 1);
            slots[at] = set->slots[i];
        }
        free(set->slots);
        set->slots = slots;
        set->cap = cap;
    }
    size_t at = hash_string(key) & (set->cap - 1);
    while (set->slots[at]) {
        if (strcmp(set->slots[at], key) == 0) {
            free(key);
            return false;
        }
        at = (at + 1) & (set->cap - 1);
    }
    set->slots[at] = key;
    set->len++;
    return true;
}

static void path_set_free(path_set *set) {
    for (size_t i = 0; i < set->cap; i++) free(set->slots[i]);
    free(set->slots);
}

/* Keeps the first error. Returns false. */
static bool first_fail(cg_error *first, const char *code, char *message) {
    if (!first->code) {
        cg_err_set_own(first, code, message);
    } else {
        free(message);
    }
    return false;
}

static bool plan_tasks(cg_engine *engine, const cg_download_request *request, const cj *manifest,
                       const char *destination, task **out, size_t *count, cg_error *err) {
    cg_engine_config *config = cg_engine_config_snapshot(engine);
    const char *builtin = config->builtin_dir;
    path_set seen = {0};
    size_t total = cj_is_arr(manifest) ? cj_len(manifest) : 0;
    task *tasks = cg_calloc(total ? total : 1, sizeof(task));
    size_t len = 0;
    cg_error first = CG_ERROR_INIT;
    for (size_t i = 0; i < total; i++) {
        const cj *entry = cj_at(manifest, i);
        const cj *file_name_value = entry_value(entry, "file_name");
        const char *file_name = entry_text(entry, "file_name");
        if (entry_empty(entry, "file_name") || entry_empty(entry, "download_url")) {
            first_fail(&first, "invalid_manifest", cg_strdup("Manifest entry is missing file_name or download_url"));
            continue;
        }
        if (entry_empty(entry, "file_hash")) {
            cg_error_log(&engine->host, "Missing file_hash for manifest entry: %s", file_name);
            first_fail(&first, "invalid_manifest", cg_fmt("Manifest entry is missing file_hash for %s", file_name));
            continue;
        }
        char *hash = manifest_hash(config->public_key, entry, request->session_key);
        if (!hash) {
            cg_error_log(&engine->host, "Checksum decryption failed for %s", file_name);
            first_fail(&first, "decrypt_fail", cg_fmt("Cannot decrypt file_hash for %s", file_name));
            continue;
        }
        char *target = resolve_target(destination, file_name_value);
        if (!target) {
            cg_error_log(&engine->host, "Invalid manifest file path: %s", file_name);
            manifest_path_fail(engine, request->version, file_name);
            first_fail(&first, "invalid_manifest", cg_fmt("Invalid manifest file path: %s", file_name));
            free(hash);
            continue;
        }
        if (!path_set_insert(&seen, path_key(target))) {
            cg_error_log(&engine->host, "Duplicate manifest target path: %s", file_name);
            manifest_path_fail(engine, request->version, file_name);
            first_fail(&first, "invalid_manifest", cg_fmt("Duplicate manifest target path for %s", file_name));
            free(hash);
            free(target);
            continue;
        }
        task *t = &tasks[len++];
        t->file_name = cg_strdup(file_name);
        t->download_url = url_text(entry_value(entry, "download_url"));
        t->hash = hash;
        t->brotli = cg_ends_with(file_name, ".br");
        t->target = target;
        t->builtin = *builtin ? resolve_target(builtin, file_name_value) : NULL;
        t->asset = builtin_asset(file_name_value);
        cache_paths(config->cache_dir, hash, file_name_value, &t->cache, &t->legacy_cache);
    }
    path_set_free(&seen);
    cg_config_release(config);
    if (first.code) {
        for (size_t i = 0; i < len; i++) task_clear(&tasks[i]);
        free(tasks);
        if (err) {
            cg_err_move(err, &first);
        } else {
            cg_err_clear(&first);
        }
        return false;
    }
    *out = tasks;
    *count = len;
    return true;
}

/* ---------------------------------------------------------------- one network file */

typedef struct {
    const cg_cancel *cancel;
    const char *partial;
    uint64_t existing;
    int fd; /* -1: no output (Rust None) */
    uint8_t *buffer;
    size_t buffered;
    bool hashing;
    cg_sha256 hasher;
} file_transfer;

/* BufWriter::flush of the buffered bytes. false with errno. */
static bool flush_buffer(file_transfer *t) {
    if (t->buffered == 0) return true;
    bool ok = cg_fsutil_write_all(t->fd, t->buffer, t->buffered);
    t->buffered = 0;
    return ok;
}

static bool file_handler(void *context, const cg_net_stream *event, cg_net_error *err) {
    file_transfer *t = context;
    if (event->kind == CG_NET_STREAM_HEAD) {
        const cg_net_stream_head *head = event->head;
        /* The partial already holds the whole file. */
        if (head->status == 416 && t->existing > 0) return true;
        if (head->status != 200 && head->status != 206)
            return cg_net_error_set(err, CG_NET_NETWORK, "Unexpected response code: %u", (unsigned)head->status);
        bool append = cg_http_should_append_http_body(head->status, (int64_t)t->existing);
        int fd = cg_fsutil_open(t->partial, O_CREAT | O_WRONLY | (append ? O_APPEND : O_TRUNC), 0666);
        if (fd < 0) return cg_net_error_set_own(err, CG_NET_IO, cg_io_message(errno));
        if (t->fd >= 0) close(t->fd);
        t->fd = fd;
        if (!t->buffer) t->buffer = cg_malloc(PARTIAL_BUFFER_BYTES);
        t->buffered = 0;
        if (t->hashing) cg_sha256_free(&t->hasher);
        t->hashing = !append;
        if (t->hashing) cg_sha256_init(&t->hasher);
        return true;
    }
    if (cg_cancel_is_cancelled(t->cancel)) return cg_net_error_set(err, CG_NET_IO, "download_stopped");
    if (t->hashing) cg_sha256_update(&t->hasher, event->data, event->len);
    if (t->fd < 0) return true;
    /* BufWriter::write_all: small writes are batched, large ones go straight through. */
    if (t->buffered + event->len > PARTIAL_BUFFER_BYTES) {
        if (!flush_buffer(t)) return cg_net_error_set_own(err, CG_NET_IO, cg_io_message(errno));
    }
    if (event->len >= PARTIAL_BUFFER_BYTES) {
        if (!cg_fsutil_write_all(t->fd, event->data, event->len))
            return cg_net_error_set_own(err, CG_NET_IO, cg_io_message(errno));
    } else {
        memcpy(t->buffer + t->buffered, event->data, event->len);
        t->buffered += event->len;
    }
    return true;
}

typedef struct {
    cg_engine *engine;
    const cg_download_request *request;
    lazy_session *session;
    const char *assets; /* APK path, NULL = None */
    const cg_cancel *cancel;
    const char *id;
    task *tasks;
    size_t total;
    size_t next;
    cg_mutex queue_lock;
    atomic_size_t completed;
    atomic_bool failed;
    cg_mutex error_lock;
    cg_error first_error;
} pool;

static void file_stat(cg_engine *engine, const char *action, const char *version, const char *file_name) {
    char *name = cg_fmt("%s:%s", version, file_name);
    cg_stats_send_stats(engine, action, name, NULL, NULL);
    free(name);
}

/* file_fail: download_manifest_file_fail stat + error (takes message). */
static bool file_fail(pool *p, const task *t, char *message, cg_error *err) {
    file_stat(p->engine, "download_manifest_file_fail", p->request->version, t->file_name);
    return cg_err_set_own(err, "download_manifest_file_fail", message);
}

/* decrypt_failed: drops the partial, decrypt_fail stat + error. */
static bool decrypt_failed(pool *p, const task *t, const char *partial, const char *error, cg_error *err) {
    unlink(partial);
    cg_stats_send_stats(p->engine, "decrypt_fail", p->request->version, NULL, NULL);
    return cg_err_set(err, "decrypt_fail", "Failed to decrypt %s: %s", t->file_name, error);
}

static bool cached_copy(const char *cached, const char *hash, const char *target) {
    if (!reusable(cached, hash)) return false;
    cg_error ignored = CG_ERROR_INIT;
    bool ok = cg_fsutil_link_or_copy(cached, target, &ignored);
    cg_err_clear(&ignored);
    return ok;
}

/* Decodes or moves the downloaded partial into the target. Rust `written`: returns 1 (Ok(Some)),
 * 0 (Ok(None): checksum mismatch) or -1 (Err: *io set); -2 when a decrypt failure already set
 * *err (the function returned). */
static int write_target(pool *p, const task *t, const char *partial, const char *partial_dir, char *streamed_hash,
                        cg_error *io, cg_error *err) {
    const cg_session_key *session = NULL;
    const char *session_error = NULL;
    if (!lazy_session_get(p->session, &session, &session_error)) {
        free(streamed_hash);
        decrypt_failed(p, t, partial, cg_or_empty(session_error), err);
        return -2;
    }
    char *written = NULL;
    bool ok;
    if (session && t->brotli) {
        /* Brotli needs a seekable plaintext file: decrypt into a work file in one pass. */
        free(streamed_hash);
        char *random = cg_store_random_id();
        char *name = cg_fmt("work_%s_%s", random, basename_of(t->file_name));
        char *work = cg_fsutil_join(partial_dir, name);
        free(name);
        free(random);
        cg_error error = CG_ERROR_INIT;
        char *plain_hash = cg_aes_cbc_decrypt_file_to(partial, work, session->key, session->iv, &error);
        if (!plain_hash) {
            unlink(work);
            free(work);
            decrypt_failed(p, t, partial, cg_or_empty(error.message), err);
            cg_err_clear(&error);
            return -2;
        }
        free(plain_hash);
        ok = cg_brotli_decode_file(work, t->target, t->hash, &written, io);
        unlink(work);
        free(work);
    } else if (session) {
        free(streamed_hash);
        int fd = cg_fsutil_open(partial, O_RDONLY, 0);
        if (fd < 0) {
            char *message = cg_io_message(errno);
            decrypt_failed(p, t, partial, message, err);
            free(message);
            return -2;
        }
        cg_reader *reader = cbc_reader_new(fd, session);
        ok = cg_fsutil_write_verified(reader, t->target, t->hash, &written, io);
        cg_reader_free(reader);
        if (!ok && cg_err_is(io, CG_IO_INVALID_DATA)) {
            decrypt_failed(p, t, partial, cg_or_empty(io->message), err);
            cg_err_clear(io);
            return -2;
        }
    } else if (t->brotli) {
        free(streamed_hash);
        ok = cg_brotli_decode_file(partial, t->target, t->hash, &written, io);
    } else if (streamed_hash) {
        /* Plain file hashed while downloading: move it in place, no second pass. */
        if (cg_eq_nocase(streamed_hash, t->hash)) {
            ok = rename(partial, t->target) == 0;
            if (ok) {
                written = streamed_hash;
            } else {
                cg_fsutil_os_error(io, errno);
                free(streamed_hash);
            }
        } else {
            free(streamed_hash);
            ok = true;
        }
    } else {
        cg_reader *reader = cg_fsutil_file_reader(partial, io);
        ok = reader != NULL;
        if (reader) {
            ok = cg_fsutil_write_verified(reader, t->target, t->hash, &written, io);
            cg_reader_free(reader);
        }
    }
    if (!ok) return -1;
    bool matched = written != NULL;
    free(written);
    return matched ? 1 : 0;
}

static bool download_manifest_file(pool *p, const task *t, cg_error *err) {
    cg_engine *engine = p->engine;
    const cg_download_request *request = p->request;
    char *cache = CG_CONFIG_DUP(engine, cache_dir);
    char *partial_dir = *cache ? cg_strdup(cache) : CG_CONFIG_DUP(engine, storage_root);
    free(cache);
    cg_fsutil_create_dir_all(partial_dir);
    char *partial_name = cg_paths_manifest_partial_name(t->hash, t->file_name);
    char *partial = cg_fsutil_join(partial_dir, partial_name);
    free(partial_name);
    /* The partial is named by file and hash, so overlapping downloads that share a file would
     * append to, rename or delete each other's partial: one transfer at a time. */
    partial_lock *lock = partial_lock_acquire(partial);
    bool ok = false;
    /* The transfer we waited for may have left the file in the delta cache. */
    if (t->cache && cached_copy(t->cache, t->hash, t->target)) {
        ok = true;
        goto done;
    }
    file_transfer transfer = {.cancel = p->cancel, .partial = partial, .fd = -1};
    struct stat st;
    transfer.existing = stat(partial, &st) == 0 ? (uint64_t)st.st_size : 0;
    char range[48];
    snprintf(range, sizeof range, "bytes=%" PRIu64 "-", transfer.existing);
    cg_net_header headers[1] = {{"Range", range}};
    cg_net_error net = CG_NET_ERROR_INIT;
    bool transferred = cg_http_download(engine->http, t->download_url, headers, transfer.existing > 0 ? 1 : 0,
                                        file_handler, &transfer, NULL, &net);
    if (transfer.fd >= 0) {
        bool flushed = flush_buffer(&transfer);
        int flush_errno = errno;
        close(transfer.fd);
        if (transferred && !flushed) {
            transferred = false;
            cg_net_error_set_own(&net, CG_NET_IO, cg_io_message(flush_errno));
        }
    }
    free(transfer.buffer);
    char *streamed_hash = NULL;
    if (transfer.hashing) {
        char hex[65];
        cg_sha256_finish_hex(&transfer.hasher, hex);
        cg_sha256_free(&transfer.hasher);
        streamed_hash = cg_strdup(hex);
    }
    if (!transferred) {
        free(streamed_hash);
        const char *message = cg_or_empty(net.message);
        if (strcmp(message, "download_stopped") == 0) {
            cg_err_set(err, "download_stopped", "Download cancelled");
        } else {
            char *full = cg_fmt("Failed to download %s: %s", t->file_name, message);
            bool has_status = false;
            int64_t status = 0;
            if (cg_starts_with(message, "Unexpected response code: ")) {
                char *text = cg_trim(message + strlen("Unexpected response code: "));
                has_status = cg_parse_i64(text, &status);
                free(text);
            }
            bool retryable =
                has_status ? cg_http_is_retryable_http_status(status) : cg_download_net_error_retryable(&net);
            if (retryable) {
                /* The partial stays for the next attempt; the code says it can succeed later. */
                file_stat(engine, "download_manifest_file_fail", request->version, t->file_name);
                cg_err_set_own(err, has_status ? "network_error" : cg_download_net_error_code(&net), full);
            } else {
                file_fail(p, t, full, err);
            }
        }
        cg_net_error_clear(&net);
        goto done;
    }
    cg_net_error_clear(&net);
    /* The partial stays encrypted (resumable, reusable): decrypt while reading it. */
    cg_error io = CG_ERROR_INIT;
    int written = write_target(p, t, partial, partial_dir, streamed_hash, &io, err);
    if (written == -2) goto done;
    size_t target_len = 0;
    const char *target_name = cg_paths_manifest_target_name(t->file_name, &target_len);
    char *stat_target = cg_fmt("%s:%.*s", request->version, (int)target_len, target_name);
    if (written == 0) {
        unlink(partial);
        cg_stats_send_stats(engine, "download_manifest_checksum_fail", stat_target, NULL, NULL);
        cg_err_set(err, "checksum_fail", "Computed checksum is not equal to required checksum for file %s at url %s",
                   t->file_name, t->download_url);
        free(stat_target);
        goto done;
    }
    if (written < 0) {
        if (t->brotli) {
            unlink(partial);
            cg_stats_send_stats(engine, "download_manifest_brotli_fail", stat_target, NULL, NULL);
            cg_err_set(err, "brotli_fail", "Brotli process failed for %s: %s", t->file_name,
                       cg_or_empty(io.message));
        } else {
            /* Destination I/O error: the downloaded payload stays resumable (like the previous
             * Android plugin, which dropped it only on checksum, decrypt or brotli failures). */
            file_fail(p, t, cg_fmt("Failed to write %s: %s", t->file_name, cg_or_empty(io.message)), err);
        }
        cg_err_clear(&io);
        free(stat_target);
        goto done;
    }
    free(stat_target);
    unlink(partial);
    /* Best effort: a full cache must not fail the update. */
    if (t->cache && !cg_fsutil_exists(t->cache)) {
        cg_error ignored = CG_ERROR_INIT;
        if (!cg_fsutil_link_or_copy(t->target, t->cache, &ignored))
            cg_debug(&engine->host, "Delta cache write failed: %s", t->cache);
        cg_err_clear(&ignored);
    }
    ok = true;
done:
    partial_lock_release(lock);
    free(partial);
    free(partial_dir);
    return ok;
}

static bool process_manifest_file(pool *p, const task *t, cg_error *err) {
    char *parent = cg_fsutil_parent(t->target);
    if (parent) {
        cg_error io = CG_ERROR_INIT;
        bool created = cg_fsutil_create_dir_all_err(parent, &io);
        free(parent);
        if (!created) {
            cg_err_set(err, "io_error", "Failed to create parent directory: %s", cg_or_empty(io.message));
            cg_err_clear(&io);
            return false;
        }
    }
    /* 1. Builtin bundle on disk. */
    if (t->builtin && cg_fsutil_file_matches_hash(t->builtin, t->hash)) {
        cg_error ignored = CG_ERROR_INIT;
        bool copied = cg_fsutil_copy_atomically(t->builtin, t->target, &ignored);
        cg_err_clear(&ignored);
        if (copied) return true;
    }
    /* 2. Builtin APK assets (Android). */
    if (p->assets && t->asset && apk_copy_if_matches(p->assets, t->asset, t->hash, t->target)) return true;
    /* 3. Delta cache (hash-named files were verified when written). */
    if (t->cache && cached_copy(t->cache, t->hash, t->target)) return true;
    if (t->legacy_cache && cached_copy(t->legacy_cache, t->hash, t->target)) return true;
    /* 4. Network. */
    return download_manifest_file(p, t, err);
}

static void worker_main(void *arg) {
    pool *p = arg;
    for (;;) {
        if (atomic_load(&p->failed) || cg_cancel_is_cancelled(p->cancel)) return;
        cg_lock(&p->queue_lock);
        task *t = p->next < p->total ? &p->tasks[p->next++] : NULL;
        cg_unlock(&p->queue_lock);
        if (!t) return;
        cg_error error = CG_ERROR_INIT;
        if (process_manifest_file(p, t, &error)) {
            size_t done = atomic_fetch_add(&p->completed, 1) + 1;
            size_t total = p->total > 1 ? p->total : 1;
            cg_download_progress(p->engine, p->id, 10 + (int64_t)(done * 60 / total));
        } else {
            cg_error_log(&p->engine->host, "Manifest file download failed: %s (%s)", t->file_name,
                         cg_or_empty(error.message));
            atomic_store(&p->failed, true);
            cg_lock(&p->error_lock);
            if (!p->first_error.code) {
                cg_err_move(&p->first_error, &error);
            }
            cg_unlock(&p->error_lock);
            cg_err_clear(&error);
            return;
        }
    }
}

bool cg_manifest_download_manifest_inner(cg_engine *engine, const cg_download_request *request, const cj *manifest,
                                         const cg_bundle_info *record, const cg_cancel *cancel, cg_bundle_info *out,
                                         cg_error *err) {
    const char *id = record->id;
    size_t entries = cj_is_arr(manifest) ? cj_len(manifest) : 0;
    uint64_t needed = (uint64_t)entries * PER_FILE_ESTIMATE;
    if (!cg_download_check_disk_space(engine, needed > MIN_FREE_BYTES ? needed : MIN_FREE_BYTES, request->version,
                                      err))
        return false;
    char *destination = cg_store_bundle_directory(engine, id, err);
    if (!destination) return false;
    cg_error io = CG_ERROR_INIT;
    if (!cg_fsutil_create_dir_all_err(destination, &io)) {
        cg_err_set(err, "io_error", "Failed to create destination directory: %s", cg_or_empty(io.message));
        cg_err_clear(&io);
        free(destination);
        return false;
    }
    char *cache = CG_CONFIG_DUP(engine, cache_dir);
    if (*cache) cg_fsutil_create_dir_all(cache);
    free(cache);
    cg_stats_send_stats(engine, "download_manifest_start", request->version, NULL, NULL);
    task *tasks = NULL;
    size_t total = 0;
    bool planned = plan_tasks(engine, request, manifest, destination, &tasks, &total, err);
    free(destination);
    if (!planned) return false;
    char *public_key = CG_CONFIG_DUP(engine, public_key);
    lazy_session session = {.public_key = public_key, .session_key = request->session_key};
    cg_mutex_init(&session.lock);
    int64_t limit = cg_policy_manifest_max_concurrent_files(cg_cpu_count());
    size_t workers = limit > 0 ? (size_t)limit : 1;
    if (workers > (total > 1 ? total : 1)) workers = total > 1 ? total : 1;
    pool p = {.engine = engine,
              .request = request,
              .session = &session,
              .cancel = cancel,
              .id = id,
              .tasks = tasks,
              .total = total};
    p.assets = apk_assets(engine);
    cg_mutex_init(&p.queue_lock);
    cg_mutex_init(&p.error_lock);
    atomic_init(&p.completed, 0);
    atomic_init(&p.failed, false);
    /* std::thread::scope: every worker is joined before returning. */
    pthread_t *threads = cg_calloc(workers, sizeof(pthread_t));
    size_t started = 0;
    for (size_t i = 0; i < workers; i++) {
        if (!cg_spawn_joinable("manifest", worker_main, &p, &threads[started])) break;
        started++;
    }
    /* No thread at all: the calling thread does the work. */
    if (started == 0) worker_main(&p);
    for (size_t i = 0; i < started; i++) cg_join(threads[i]);
    free(threads);
    cg_mutex_destroy(&p.queue_lock);
    cg_mutex_destroy(&p.error_lock);
    cg_mutex_destroy(&session.lock);
    free(session.error);
    free(public_key);
    free((char *)p.assets);
    for (size_t i = 0; i < total; i++) task_clear(&tasks[i]);
    free(tasks);
    if (cg_cancel_is_cancelled(cancel)) {
        cg_err_clear(&p.first_error);
        return cg_err_set(err, "download_stopped", "Download cancelled");
    }
    if (p.first_error.code) {
        if (err) {
            cg_err_move(err, &p.first_error);
        } else {
            cg_err_clear(&p.first_error);
        }
        return false;
    }
    cg_stats_send_stats(engine, "download_manifest_complete", request->version, NULL, NULL);
    cg_download_progress(engine, id, 71);
    cg_download_progress(engine, id, 91);
    cg_download_finish_install(engine, record, "", request, out);
    return true;
}

/* ---------------------------------------------------------------- download tokens */

cg_cancel *cg_manifest_register_download_token(cg_engine *engine, const char *version) {
    cg_cancel *token = cg_cancel_new();
    cg_download_map *map = &engine->downloads;
    cg_lock(&map->lock);
    cg_download_entry *entry = cg_download_map_find(map, version);
    if (!entry) {
        if (map->len == map->cap) {
            map->cap = map->cap ? map->cap * 2 : 4;
            map->items = cg_realloc(map->items, map->cap * sizeof(cg_download_entry));
        }
        entry = &map->items[map->len++];
        memset(entry, 0, sizeof *entry);
        entry->version = cg_strdup(version);
    }
    if (entry->len == entry->cap) {
        entry->cap = entry->cap ? entry->cap * 2 : 2;
        entry->tokens = cg_realloc(entry->tokens, entry->cap * sizeof(cg_cancel *));
    }
    entry->tokens[entry->len++] = cg_cancel_retain(token);
    cg_unlock(&map->lock);
    return token;
}

void cg_manifest_unregister_download_token(cg_engine *engine, const char *version, const cg_cancel *token) {
    cg_download_map *map = &engine->downloads;
    cg_cancel *removed = NULL;
    cg_lock(&map->lock);
    cg_download_entry *entry = cg_download_map_find(map, version);
    if (entry) {
        size_t out = 0;
        for (size_t i = 0; i < entry->len; i++) {
            if (entry->tokens[i] == token) {
                removed = entry->tokens[i];
            } else {
                entry->tokens[out++] = entry->tokens[i];
            }
        }
        entry->len = out;
        if (entry->len == 0) {
            free(entry->tokens);
            free(entry->version);
            size_t index = (size_t)(entry - map->items);
            map->items[index] = map->items[--map->len];
        }
    }
    cg_unlock(&map->lock);
    /* Released outside the leaf lock. */
    cg_cancel_release(removed);
}
