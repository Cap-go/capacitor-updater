/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Streaming Brotli decoding for manifest `.br` files: the Rust core uses
 * brotli_decompressor::Decompressor (a Read adapter) and manifest.rs
 * decode_brotli. Neither has cancellation or size limits: the caller hashes the
 * output (write_verified) and only keeps it when the hash matches.
 */
#ifndef CG_BROTLI_STREAM_H
#define CG_BROTLI_STREAM_H

#include <stdbool.h>
#include <stddef.h>

#include "engine/fsutil.h"
#include "rt/err.h"

/* brotli_decompressor::Decompressor::new(inner, buffer_size) over inner (owned). A corrupt or
 * truncated stream fails once with CG_IO_INVALID_DATA "Invalid Data" (later reads return 0);
 * bytes after the end of the stream are ignored; inner reader errors are passed through. */
cg_reader *cg_brotli_reader(cg_reader *inner, size_t buffer_size);

/* manifest.rs decode_brotli: decodes source into target (temp + rename through
 * cg_fsutil_write_verified) with the Capgo CLI "stored" wrapper shortcuts (an empty file or the
 * 3-byte empty stream, and a 3-byte header + raw bytes + 0x03 trailer). Returns true with the
 * SHA-256 of the output in *hash when it matches expected (case-insensitive); *hash NULL when it
 * does not (nothing written). false with *err on I/O or decode errors (message "Invalid Data"). */
bool cg_brotli_decode_file(const char *source, const char *target, const char *expected, char **hash,
                           cg_error *err);

#endif
