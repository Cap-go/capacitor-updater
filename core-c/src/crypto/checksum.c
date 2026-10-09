/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#include "crypto/checksum.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "mbedtls/aes.h"
#include "mbedtls/sha256.h"
#include "text.h"

void cg_sha256_init(cg_sha256 *hasher) {
    mbedtls_sha256_init(&hasher->ctx);
    mbedtls_sha256_starts(&hasher->ctx, 0);
}

void cg_sha256_update(cg_sha256 *hasher, const void *bytes, size_t len) {
    if (len) mbedtls_sha256_update(&hasher->ctx, bytes, len);
}

void cg_sha256_finish(cg_sha256 *hasher, uint8_t digest[32]) {
    mbedtls_sha256_finish(&hasher->ctx, digest);
    mbedtls_sha256_free(&hasher->ctx);
}

void cg_sha256_finish_hex(cg_sha256 *hasher, char out[65]) {
    uint8_t digest[32];
    cg_sha256_finish(hasher, digest);
    cg_text_hex_encode_to(digest, sizeof(digest), out);
}

void cg_sha256_free(cg_sha256 *hasher) { mbedtls_sha256_free(&hasher->ctx); }

char *cg_checksum_sha256_hex(const uint8_t *bytes, size_t len) {
    uint8_t digest[32];
    mbedtls_sha256(bytes, len, digest, 0);
    return cg_text_hex_encode(digest, sizeof(digest));
}

char *cg_checksum_sha256_file(const char *path, cg_error *err) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        cg_err_io(err, "Cannot open file for checksum", errno);
        return NULL;
    }
    uint8_t *buffer = cg_malloc(CG_IO_BUFFER_BYTES);
    cg_sha256 hasher;
    cg_sha256_init(&hasher);
    while (true) {
        ssize_t got = read(fd, buffer, CG_IO_BUFFER_BYTES);
        if (got < 0) {
            if (errno == EINTR) continue;
            int error = errno;
            cg_sha256_free(&hasher);
            free(buffer);
            close(fd);
            cg_err_io(err, "Cannot read file for checksum", error);
            return NULL;
        }
        if (got == 0) break;
        cg_sha256_update(&hasher, buffer, (size_t)got);
    }
    free(buffer);
    close(fd);
    char *out = cg_malloc(65);
    cg_sha256_finish_hex(&hasher, out);
    return out;
}

char *cg_checksum_short_path_key_bytes(const uint8_t *bytes, size_t len) {
    char *key = cg_checksum_sha256_hex(bytes, len);
    key[16] = 0;
    return key;
}

char *cg_checksum_short_path_key(const char *value) {
    const char *text = value ? value : "";
    return cg_checksum_short_path_key_bytes((const uint8_t *)text, strlen(text));
}

/* Mbed TLS caches its CPU feature detection (SHA-256 / AES instructions) in plain statics on
 * first use; two threads hashing at once race on them. Run it once at load, before any thread. */
__attribute__((constructor)) static void cg_crypto_warm_up(void) {
    uint8_t digest[32];
    mbedtls_sha256((const unsigned char *)"", 0, digest, 0);
    mbedtls_aes_context aes;
    const unsigned char key[16] = {0};
    mbedtls_aes_init(&aes);
    mbedtls_aes_setkey_dec(&aes, key, 128);
    mbedtls_aes_free(&aes);
}
