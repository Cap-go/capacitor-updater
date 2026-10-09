/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* SHA-256 helpers (Rust crypto/checksum.rs). */
#ifndef CG_CHECKSUM_H
#define CG_CHECKSUM_H

#include <stddef.h>
#include <stdint.h>

#include "rt/err.h"

/* Buffer size of file reads / download chunks (Rust IO_BUFFER_BYTES). */
#define CG_IO_BUFFER_BYTES (256 * 1024)

/* Lowercase hex SHA-256 (malloc'd). */
char *cg_checksum_sha256_hex(const uint8_t *bytes, size_t len);
/* SHA-256 of a file, NULL with *err on I/O errors. */
char *cg_checksum_sha256_file(const char *path, cg_error *err);
/* short_path_key(value): see Rust. */
char *cg_checksum_short_path_key(const char *value);
/* Same over raw bytes (values may embed NUL). */
char *cg_checksum_short_path_key_bytes(const uint8_t *bytes, size_t len);

#endif
