/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * File-system helpers shared by the download pipeline (Rust engine/fsutil.rs),
 * plus the POSIX equivalents of the std::fs / std::io calls the engine uses
 * (remove_path, create_dir_all, canonicalize, readers).
 *
 * I/O errors (Rust io::Error) are reported in a cg_error whose code is the
 * io::ErrorKind (CG_IO_*) and whose message is the Rust io::Error Display text,
 * e.g. "No such file or directory (os error 2)". A caller building
 * CoreError::io(context, error) formats "<context>: <err.message>" with code
 * "io_error".
 */
#ifndef CG_FSUTIL_H
#define CG_FSUTIL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include "rt/err.h"

/* io::ErrorKind codes used in cg_error.code for I/O errors. */
#define CG_IO_OTHER "io"
#define CG_IO_NOT_FOUND "not_found"
#define CG_IO_INVALID_DATA "invalid_data"
#define CG_IO_INVALID_INPUT "invalid_input"
#define CG_IO_UNEXPECTED_EOF "unexpected_eof"

/* Sets an OS error (errno): code CG_IO_NOT_FOUND for ENOENT, CG_IO_OTHER otherwise. Returns false. */
bool cg_fsutil_os_error(cg_error *err, int errnum);
/* io::Error::new(kind, message). Returns false. */
bool cg_fsutil_io_error(cg_error *err, const char *kind, const char *message);
/* Rust read_exact failure: kind unexpected_eof, "failed to fill whole buffer". */
bool cg_fsutil_eof_error(cg_error *err);

/* ---- readers (Rust `&mut dyn Read`) */

typedef struct cg_reader cg_reader;
struct cg_reader {
    /* Reads up to len bytes: > 0 bytes read, 0 at the end, -1 on error (*err set). */
    ptrdiff_t (*read)(cg_reader *self, uint8_t *buf, size_t len, cg_error *err);
    /* Releases the reader (NULL: nothing to release). */
    void (*free)(cg_reader *self);
};

static inline ptrdiff_t cg_reader_read(cg_reader *reader, uint8_t *buf, size_t len, cg_error *err) {
    return reader->read(reader, buf, len, err);
}
/* NULL-safe. */
void cg_reader_free(cg_reader *reader);
/* Reads until buf is full; false with CG_IO_UNEXPECTED_EOF when the reader ends first. */
bool cg_reader_read_exact(cg_reader *reader, uint8_t *buf, size_t len, cg_error *err);

/* Reader over fd from its current position, at most `limit` bytes (UINT64_MAX: no limit,
 * Rust Read::take). Closes fd on free when owns_fd. */
cg_reader *cg_fsutil_fd_reader(int fd, bool owns_fd, uint64_t limit);
/* Opens path for reading (O_CLOEXEC). NULL with *err. */
cg_reader *cg_fsutil_file_reader(const char *path, cg_error *err);
/* io::empty(). */
cg_reader *cg_fsutil_empty_reader(void);
/* Positional reader over [offset, end) of a shared fd (never closed). A short file is
 * CG_IO_UNEXPECTED_EOF ("unexpected end of file"), like apk.rs `At`. */
cg_reader *cg_fsutil_range_reader(int fd, uint64_t offset, uint64_t end);

/* ---- low level helpers */

/* Opens with O_CLOEXEC, retrying EINTR. -1 with errno. */
int cg_fsutil_open(const char *path, int flags, mode_t mode);
/* pread until len bytes or end of file; returns bytes read or -1 (errno). */
ssize_t cg_fsutil_pread_full(int fd, void *buf, size_t len, uint64_t offset);
/* write until done; false (errno) on error. */
bool cg_fsutil_write_all(int fd, const void *buf, size_t len);

/* Path helpers (pure string operations, '/' separator, Rust Path semantics). */
/* Path::parent (malloc'd), NULL when the path has none ("/" or ""). */
char *cg_fsutil_parent(const char *path);
/* Path::file_name (borrowed pointer into path), NULL when none (ends with ".." or is "/"). */
const char *cg_fsutil_file_name(const char *path);
/* Path::join (malloc'd); an absolute `child` replaces the base. */
char *cg_fsutil_join(const char *base, const char *child);
/* Path::starts_with: component-wise prefix test. */
bool cg_fsutil_path_starts_with(const char *path, const char *prefix);

/* Path::exists (follows symlinks). */
bool cg_fsutil_exists(const char *path);
/* Path::is_dir / is_file (follow symlinks). */
bool cg_fsutil_is_dir(const char *path);
bool cg_fsutil_is_file(const char *path);
/* fs::canonicalize (malloc'd), NULL with errno. */
char *cg_fsutil_canonicalize(const char *path);
/* fs::create_dir_all (iterative: deep trees do not use the stack). false with errno. */
bool cg_fsutil_create_dir_all(const char *path);
/* fs::create_dir_all with an io error in *err. */
bool cg_fsutil_create_dir_all_err(const char *path, cg_error *err);
/* store::remove_path: a file or symlink is unlinked, a directory removed with its content
 * (iteratively, symlinks never followed); a missing path is fine. */
bool cg_fsutil_remove_path(const char *path, cg_error *err);
/* fs::copy: content and permission bits; returns false with *err. */
bool cg_fsutil_copy_file(const char *source, const char *destination, cg_error *err);
/* fs::read_dir names (excluding "." and ".."), unsorted. NULL with *err. Caller frees with
 * cg_strs_free + free. count in *len. */
char **cg_fsutil_read_dir(const char *path, size_t *len, cg_error *err);
void cg_fsutil_free_names(char **names, size_t len);

/* Lowercase hex of bytes (malloc'd). */
char *cg_fsutil_hex(const uint8_t *bytes, size_t len);
/* 10 characters of [0-9A-Za-z] from the system RNG (store::random_id). */
char *cg_fsutil_random_id(void);

/* ---- fsutil.rs */

/* Free bytes available to the app on the volume holding path (deepest existing ancestor).
 * false when unknown (Rust None). */
bool cg_fsutil_available_space(const char *path, uint64_t *out);
/* `<dir>/<prefix><random id><suffix>` (malloc'd). */
char *cg_fsutil_unique_temp(const char *dir, const char *prefix, const char *suffix);
/* Copies source to destination through a sibling temp file + rename. */
bool cg_fsutil_copy_atomically(const char *source, const char *destination, cg_error *err);
/* Hard-links source to destination (atomically replacing it); copies when linking is not
 * possible. Only for files the updater owns and never rewrites in place. */
bool cg_fsutil_link_or_copy(const char *source, const char *destination, cg_error *err);
/* Writes data to destination through a sibling temp file + rename. */
bool cg_fsutil_write_atomically(const char *destination, const void *data, size_t len, cg_error *err);
/* Streams reader into destination (temp + rename) and returns true with its SHA-256 in *hash
 * (malloc'd lowercase hex). With `expected`, the file is only put in place when the hash
 * matches (case-insensitive); otherwise *hash is NULL (Rust Ok(None)) and nothing is written.
 * false with *err on I/O errors (reader errors are passed through). */
bool cg_fsutil_write_verified(cg_reader *reader, const char *destination, const char *expected, char **hash,
                              cg_error *err);
/* SHA-256 (lowercase hex, malloc'd) of a reader, NULL with *err. */
char *cg_fsutil_sha256_reader(cg_reader *reader, cg_error *err);
/* expected non-empty, path a regular file whose SHA-256 matches (case-insensitive). */
bool cg_fsutil_file_matches_hash(const char *path, const char *expected);
/* The file's mtime is more than age_ms in the past. */
bool cg_fsutil_modified_before(const char *path, uint64_t age_ms);

/* What the side thread of a block writer does with the bytes (Rust StreamSink). */
typedef enum {
    CG_SINK_NONE = 0,
    CG_SINK_HASH,    /* SHA-256 of the bytes */
    CG_SINK_DECRYPT, /* AES-128-CBC decrypt into `plain` and SHA-256 of the plaintext */
} cg_stream_sink_kind;

typedef struct {
    cg_stream_sink_kind kind;
    uint8_t key[16];
    uint8_t iv[16];
    const char *plain; /* CG_SINK_DECRYPT: borrowed, copied by cg_block_writer_new */
} cg_stream_sink;

/* Writes a stream to a file in 1 MiB blocks; a side thread hashes (or decrypts and hashes)
 * the same blocks, overlapping with network and disk I/O (Rust BlockWriter). */
typedef struct cg_block_writer cg_block_writer;

/* Takes ownership of fd (closed by finish / free). sink NULL = CG_SINK_NONE. */
cg_block_writer *cg_block_writer_new(int fd, const cg_stream_sink *sink);
bool cg_block_writer_write(cg_block_writer *writer, const void *data, size_t len, cg_error *err);
/* Writes what is buffered, frees the writer and returns the side thread's result in *hash:
 * SHA-256 of the bytes (HASH) or of the plaintext (DECRYPT), NULL when unavailable.
 * false with *err when the final write fails (the writer is freed anyway). */
bool cg_block_writer_finish(cg_block_writer *writer, char **hash, cg_error *err);
/* Drops the writer without finishing (Rust drop): the side thread ends on its own. */
void cg_block_writer_free(cg_block_writer *writer);

#endif
