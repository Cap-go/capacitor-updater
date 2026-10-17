/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* SHA-256 helpers (Rust crypto/checksum.rs), Mbed TLS SHA-256 (ARMv8 SHA instructions
 * when the CPU has them). */
#ifndef CG_CHECKSUM_H
#define CG_CHECKSUM_H

#include <stddef.h>
#include <stdint.h>

#include "mbedtls/sha256.h"
#include "rt/err.h"

/* Buffer size of file reads / download chunks (Rust IO_BUFFER_BYTES). */
#define CG_IO_BUFFER_BYTES (256 * 1024)

/* Lowercase hex SHA-256 (malloc'd). */
char *cg_checksum_sha256_hex(const uint8_t *bytes, size_t len);
/* SHA-256 of a file, NULL with *err on I/O errors ("io_error", "Cannot open file for
 * checksum: ..." / "Cannot read file for checksum: ..."). */
char *cg_checksum_sha256_file(const char *path, cg_error *err);
/* short_path_key(value): first 16 hex chars of the SHA-256 of the UTF-8 string. */
char *cg_checksum_short_path_key(const char *value);
/* Same over raw bytes (values may embed NUL). */
char *cg_checksum_short_path_key_bytes(const uint8_t *bytes, size_t len);

/* Streaming SHA-256 (ring::digest::Context). init, update*, finish (which also frees);
 * cg_sha256_free releases an unfinished context. */
typedef struct {
    mbedtls_sha256_context ctx;
} cg_sha256;

void cg_sha256_init(cg_sha256 *hasher);
void cg_sha256_update(cg_sha256 *hasher, const void *bytes, size_t len);
void cg_sha256_finish(cg_sha256 *hasher, uint8_t digest[32]);
/* Lowercase hex digest into out (65 bytes, NUL-terminated). */
void cg_sha256_finish_hex(cg_sha256 *hasher, char out[65]);
void cg_sha256_free(cg_sha256 *hasher);

#endif
