/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Path and cache-name guards. These are security boundaries: manifest `file_name` values,
 * zip entry names and bundle ids come from the network and must never escape the directory
 * they are resolved against. */

#include "paths.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#include "crypto/checksum.h"

/* Virtual root used to resolve builtin (APK / app bundle) asset paths. */
#define BUILTIN_ASSETS_ROOT "/capgo-builtin-assets"

bool cg_paths_contains_path_traversal_segment(const char *relative_path) {
    const char *segment = relative_path ? relative_path : "";
    while (true) {
        const char *end = strchr(segment, '/');
        size_t len = end ? (size_t)(end - segment) : strlen(segment);
        if (len == 2 && segment[0] == '.' && segment[1] == '.') return true;
        if (!end) return false;
        segment = end + 1;
    }
}

static bool is_absolute(const char *relative_path) {
    /* `~` is expanded by Foundation path APIs, so treat it like an absolute path. */
    return relative_path[0] == '/' || relative_path[0] == '~';
}

/* Validates relative_path and returns its normalized components joined with '/'. */
static char *relative_components(const char *relative_path, cg_error *err) {
    if (!*relative_path) {
        cg_err_set(err, "empty_path", "Invalid empty path");
        return NULL;
    }
    if (strchr(relative_path, '\\')) {
        cg_err_set(err, "invalid_separator", "Invalid path separator");
        return NULL;
    }
    if (cg_paths_contains_path_traversal_segment(relative_path)) {
        cg_err_set(err, "path_traversal", "Path traversal segments are not allowed");
        return NULL;
    }
    if (is_absolute(relative_path)) {
        cg_err_set(err, "absolute_path", "Absolute paths are not allowed");
        return NULL;
    }
    cg_buf out = {0};
    const char *segment = relative_path;
    while (true) {
        const char *end = strchr(segment, '/');
        size_t len = end ? (size_t)(end - segment) : strlen(segment);
        if (len && !(len == 1 && segment[0] == '.')) {
            if (out.len) cg_buf_putc(&out, '/');
            cg_buf_put(&out, segment, len);
        }
        if (!end) break;
        segment = end + 1;
    }
    /* Require a strict child of the base: "." (or "./") would target the base itself. */
    if (!out.len) {
        cg_buf_free(&out);
        cg_err_set(err, "escapes_base", "Path escapes base directory: %s", relative_path);
        return NULL;
    }
    return cg_buf_take(&out);
}

char *cg_paths_resolve_path_inside(const char *base, const char *relative_path, cg_error *err) {
    char *components = relative_components(relative_path ? relative_path : "", err);
    if (!components) return NULL;
    size_t len = strlen(base ? base : "");
    while (len && base[len - 1] == '/') len--;
    char *out = len ? cg_fmt("%.*s/%s", (int)len, base, components) : cg_fmt("/%s", components);
    free(components);
    return out;
}

const char *cg_paths_manifest_target_name(const char *file_name, size_t *len) {
    size_t n = strlen(file_name);
    *len = n >= 3 && strcmp(file_name + n - 3, ".br") == 0 ? n - 3 : n;
    return file_name;
}

char *cg_paths_resolve_manifest_target_path(const char *base, const char *file_name, cg_error *err) {
    size_t len;
    cg_paths_manifest_target_name(file_name, &len);
    char *target = cg_strndup(file_name, len);
    char *out = cg_paths_resolve_path_inside(base, target, err);
    free(target);
    return out;
}

char *cg_paths_builtin_asset_path(const char *file_name, cg_error *err) {
    char *resolved = cg_paths_resolve_manifest_target_path(BUILTIN_ASSETS_ROOT, file_name, err);
    if (!resolved) return NULL;
    char *out = cg_fmt("public/%s", resolved + strlen(BUILTIN_ASSETS_ROOT) + 1);
    free(resolved);
    return out;
}

bool cg_paths_is_safe_cache_hash(const char *hash) {
    if (!hash) return false;
    size_t n = strlen(hash);
    if (n != 64 && n != 8) return false;
    for (size_t i = 0; i < n; i++)
        if (!isxdigit((unsigned char)hash[i])) return false;
    return true;
}

bool cg_paths_is_reusable_cache_file(const char *hash, bool has_size, int64_t size) {
    if (!hash) return false;
    if (!cg_paths_is_safe_cache_hash(hash) || strlen(hash) != 64) return false;
    if (!has_size) return false;
    if (size > 0) return true;
    if (size == 0) return cg_eq_nocase(hash, CG_EMPTY_SHA256);
    return false;
}

char *cg_paths_cache_file_name(const char *hash, const char *file_name) {
    const char *slash = strrchr(file_name, '/');
    const char *base_name = slash ? slash + 1 : file_name;
    size_t len;
    cg_paths_manifest_target_name(base_name, &len);
    return cg_fmt("%s_%.*s", hash, (int)len, base_name);
}

char *cg_paths_manifest_partial_name(const char *hash, const char *file_name) {
    char *token = cg_checksum_short_path_key(file_name);
    char *out;
    if (hash && cg_paths_is_safe_cache_hash(hash) && strlen(hash) == 64) {
        out = cg_fmt("partial_%s_%s.tmp", hash, token);
    } else {
        /* format!("{}\0{file_name}") */
        const char *h = hash ? hash : "";
        size_t hl = strlen(h), fl = strlen(file_name);
        char *joined = cg_malloc(hl + 1 + fl + 1);
        memcpy(joined, h, hl);
        joined[hl] = 0;
        memcpy(joined + hl + 1, file_name, fl + 1);
        char *digest = cg_checksum_short_path_key_bytes((const uint8_t *)joined, hl + 1 + fl);
        free(joined);
        out = cg_fmt("partial_%s_%s.tmp", digest, token);
        free(digest);
    }
    free(token);
    return out;
}
