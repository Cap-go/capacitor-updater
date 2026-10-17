/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Bundle archive extraction (Rust engine/archive.rs): zip-slip safe, CRC checked,
 * symlinks only when they stay inside their own directory, then the single-folder
 * unwrap rule. The zip reader reproduces the `zip` crate (2.4) rules and error
 * messages; stored and deflated entries, ZIP64, Info-ZIP unicode names.
 */
#ifndef CG_ARCHIVE_H
#define CG_ARCHIVE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "engine/fsutil.h"
#include "rt/err.h"

/* Why an entry was rejected (Rust ExtractError), mapped to the historical statistic names. */
typedef enum {
    CG_EXTRACT_OK = 0,
    CG_EXTRACT_WINDOWS_PATH, /* entry name uses `\` (Windows zip): stat windows_path_fail */
    CG_EXTRACT_PATH_ESCAPE,  /* entry escapes the destination: stat canonical_path_fail */
    CG_EXTRACT_DIRECTORY,    /* a directory could not be created: stat directory_path_fail */
    CG_EXTRACT_FAILED,       /* anything else (corrupt archive, CRC mismatch, I/O): stat unzip_fail */
    CG_EXTRACT_CANCELLED,
} cg_extract_kind;

typedef struct {
    cg_extract_kind kind;
    /* WindowsPath / PathEscape: entry name; Directory: path; Failed: message; Cancelled: NULL. */
    char *detail;
    /* Length of detail (entry names may contain NUL bytes, rejected as PathEscape). */
    size_t detail_len;
} cg_extract_error;

#define CG_EXTRACT_ERROR_INIT {CG_EXTRACT_OK, NULL, 0}

void cg_extract_error_clear(cg_extract_error *error);
/* ExtractError::stat (static string), NULL for Failed / Cancelled. */
const char *cg_extract_error_stat(const cg_extract_error *error);
/* ExtractError::message (malloc'd, length in *len when len is not NULL): "Unzip failed: Windows
 * path not supported: <name>", "Unzip failed: entry escapes bundle: <name>", "Failed to ensure
 * directory: <path>", the Failed message, "download_stopped". */
char *cg_extract_error_message(const cg_extract_error *error, size_t *len);

/* progress(ctx, done, total) after each entry; cancelled(ctx) aborts between entries. Both are
 * called on the caller's thread only. Either may be NULL. */
typedef void (*cg_extract_progress)(void *ctx, size_t done, size_t total);
typedef bool (*cg_extract_cancelled)(void *ctx);

/* Extracts zip_path into destination (created). Directories and symlinks are created first, in
 * archive order; regular files are then written by up to 4 threads. false with *error. */
bool cg_archive_extract_zip(const char *zip_path, const char *destination, cg_extract_progress progress,
                            cg_extract_cancelled cancelled, void *ctx, cg_extract_error *error);

/* Moves an extracted bundle into destination. A single top-level folder (ignoring __MACOSX and
 * dot files) without index.html next to it is unwrapped (`dist/index.html` zips).
 * Errors: unzip_fail / io_error (CoreError). */
bool cg_archive_install_extracted(const char *source, const char *destination, cg_error *err);

/* ---- shared with apk.c */

/* CRC-32 (IEEE, zlib compatible): ARMv8 CRC instructions when available. */
uint32_t cg_archive_crc32(uint32_t crc, const uint8_t *bytes, size_t len);

/* Raw deflate decoder over `inner` (owned), like flate2::read::DeflateDecoder: a truncated stream
 * is CG_IO_UNEXPECTED_EOF "incomplete deflate stream", corrupt data CG_IO_INVALID_INPUT "corrupt
 * deflate stream". */
cg_reader *cg_archive_inflate_reader(cg_reader *inner, size_t buffer_size);

#endif
