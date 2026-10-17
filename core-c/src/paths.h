/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Path and cache-name guards (Rust paths.rs). Security boundaries. */
#ifndef CG_PATHS_H
#define CG_PATHS_H

#include <stdbool.h>
#include <stdint.h>

#include "rt/err.h"

/* SHA-256 of zero bytes. */
#define CG_EMPTY_SHA256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

bool cg_paths_contains_path_traversal_segment(const char *relative_path);
/* Owned path, NULL with *err (empty_path, invalid_separator, path_traversal, absolute_path, escapes_base). */
char *cg_paths_resolve_path_inside(const char *base, const char *relative_path, cg_error *err);
/* Borrowed: file_name without a trailing ".br" (length in *len). */
const char *cg_paths_manifest_target_name(const char *file_name, size_t *len);
char *cg_paths_resolve_manifest_target_path(const char *base, const char *file_name, cg_error *err);
char *cg_paths_builtin_asset_path(const char *file_name, cg_error *err);
bool cg_paths_is_safe_cache_hash(const char *hash);
/* size < 0: the cache file does not exist (Rust None). */
bool cg_paths_is_reusable_cache_file(const char *hash, bool has_size, int64_t size);
char *cg_paths_cache_file_name(const char *hash, const char *file_name);
char *cg_paths_manifest_partial_name(const char *hash, const char *file_name);

#endif
