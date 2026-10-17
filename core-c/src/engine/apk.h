/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Builtin files inside the Android APK (`assets/...`), indexed from the zip
 * central directory alone (Rust engine/apk.rs): the central directory is read
 * once (one contiguous read) and a local header is touched only when that
 * entry is actually used.
 */
#ifndef CG_APK_H
#define CG_APK_H

#include <stdbool.h>
#include <stddef.h>

#include "engine/fsutil.h"
#include "rt/err.h"

typedef struct cg_apk_index cg_apk_index;

/* ApkIndex::shared: the "assets/" index of path, parsed once per process and shared by every
 * worker (the last path is cached). NULL when the APK cannot be indexed. The caller owns a
 * reference: release it with cg_apk_index_release. Thread-safe. */
cg_apk_index *cg_apk_index_shared(const char *path);
/* ApkIndex::open: indexes the entries whose name starts with prefix. NULL with *err (an I/O
 * error, or CG_IO_INVALID_DATA "not a zip", "end of central directory not found", "zip64 locator
 * missing", "zip64 end record missing", "central directory out of bounds", "truncated central
 * directory"). Release with cg_apk_index_release. */
cg_apk_index *cg_apk_index_open(const char *path, const char *prefix, cg_error *err);
/* Drops a reference (NULL is ignored). */
void cg_apk_index_release(cg_apk_index *index);
/* Number of indexed entries. */
size_t cg_apk_index_len(const cg_apk_index *index);

/* ApkIndex::with_entry: a reader over the decompressed bytes of name (stored, or raw deflate
 * without CRC check); NULL when the entry is missing, its local header is unreadable or it uses
 * an unsupported compression method. Rust returns None when its closure fails: callers treat a
 * reader error the same way. The reader keeps the index alive; free it with cg_reader_free. */
cg_reader *cg_apk_index_entry(cg_apk_index *index, const char *name);

#endif
