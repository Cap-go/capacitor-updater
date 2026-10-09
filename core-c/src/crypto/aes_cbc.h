/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Streaming AES-128-CBC decryption with PKCS#7 padding (Rust crypto/aes_cbc.rs),
 * Mbed TLS AES (ARMv8 / AES-NI instructions when present). */
#ifndef CG_AES_CBC_H
#define CG_AES_CBC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include "mbedtls/aes.h"
#include "rt/err.h"
#include "rt/str.h"

#define CG_AES_BLOCK 16

/* CbcDecryptor: the last decrypted block is withheld until finish() knows whether it
 * carries the padding. */
typedef struct {
    mbedtls_aes_context aes;
    uint8_t previous[CG_AES_BLOCK]; /* chaining value (IV, then the last ciphertext block) */
    uint8_t pending[CG_AES_BLOCK];  /* last plaintext block, withheld */
    bool has_pending;
    uint8_t partial[CG_AES_BLOCK]; /* ciphertext bytes that do not complete a block yet */
    size_t partial_len;
} cg_cbc_decryptor;

void cg_cbc_init(cg_cbc_decryptor *decryptor, const uint8_t key[16], const uint8_t iv[16]);
/* Releases the AES context (finish does it too). Safe to call twice. */
void cg_cbc_free(cg_cbc_decryptor *decryptor);
/* Decrypts `len` bytes of ciphertext, writing plaintext known not to be padding to `out`,
 * which must hold at least len + 16 bytes and must not overlap `input`. Returns the number
 * of plaintext bytes written. */
size_t cg_cbc_update(cg_cbc_decryptor *decryptor, const uint8_t *input, size_t len, uint8_t *out);
/* Same, appending to a buffer. */
void cg_cbc_update_buf(cg_cbc_decryptor *decryptor, const uint8_t *input, size_t len, cg_buf *out);
/* Validates and strips PKCS#7 padding from the final block: writes the last plaintext
 * bytes (at most 15) to `out` (16 bytes) and their count to *written. Errors
 * ("decrypt_failed"): "Ciphertext is not a multiple of the AES block size",
 * "Ciphertext is empty", "Invalid PKCS#7 padding". Frees the AES context. */
bool cg_cbc_finish(cg_cbc_decryptor *decryptor, uint8_t out[16], size_t *written, cg_error *err);
/* Same, appending to a buffer. */
bool cg_cbc_finish_buf(cg_cbc_decryptor *decryptor, cg_buf *out, cg_error *err);

/* Decrypts `source` into `destination` (created, must not exist) in one pass and returns
 * the SHA-256 (lowercase hex, malloc'd) of the plaintext; NULL with *err ("io_error",
 * "empty_input", "decrypt_failed"). The destination is left in place on failure. */
char *cg_aes_cbc_decrypt_file_to(const char *source, const char *destination, const uint8_t key[16],
                                 const uint8_t iv[16], cg_error *err);
/* Decrypts `path` in place (sibling temp file `capgo-aes-<id>.tmp` + atomic rename) and
 * returns the SHA-256 of the plaintext (malloc'd); NULL with *err (temp file removed). */
char *cg_aes_cbc_decrypt_file_in_place_hashed(const char *path, const uint8_t key[16], const uint8_t iv[16],
                                              cg_error *err);

/* ---- CbcDecryptReader: plaintext reader over an AES-128-CBC ciphertext stream
 * (PKCS#7 checked at the end). */

/* Reads up to `len` bytes; returns the count, 0 at end of stream, -1 with errno set. */
typedef ssize_t (*cg_read_fn)(void *context, uint8_t *buffer, size_t len);

typedef struct {
    cg_read_fn read;
    void *context;
    cg_cbc_decryptor decryptor;
    bool finished; /* the decryptor was consumed (Rust: decryptor taken) */
    uint8_t *input;
    uint8_t *plain;
    size_t plain_len, position;
    uint64_t produced;
    int fd;
    int io_errno; /* errno of the last failed inner read */
} cg_cbc_reader;

void cg_cbc_reader_init(cg_cbc_reader *reader, cg_read_fn read, void *context, const uint8_t key[16],
                        const uint8_t iv[16]);
/* Reader over a file descriptor (not closed by the reader; EINTR retried). */
void cg_cbc_reader_init_fd(cg_cbc_reader *reader, int fd, const uint8_t key[16], const uint8_t iv[16]);
/* Rust Read::read: up to `len` plaintext bytes, 0 at the end (or when len is 0, without
 * touching the input). -1 on failure: invalid data (Rust ErrorKind::InvalidData) sets
 * *err to "decrypt_failed" with the decryptor message or "Empty decrypted data"; an
 * inner read error sets *err to "io_error" with the io::Error text and
 * reader->io_errno. */
ssize_t cg_cbc_reader_read(cg_cbc_reader *reader, uint8_t *out, size_t len, cg_error *err);
void cg_cbc_reader_free(cg_cbc_reader *reader);

#endif
