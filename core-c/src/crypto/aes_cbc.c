/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Streaming AES-128-CBC decryption with PKCS#7 padding. */

#include "crypto/aes_cbc.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if !defined(__APPLE__) && !defined(__ANDROID__) && !defined(__FreeBSD__) && !defined(__OpenBSD__)
#include <sys/random.h>
#endif

#include "crypto/checksum.h"

/* Plaintext processed per read / hash / write round by the file helpers. */
#define DECRYPT_CHUNK_BYTES (1024 * 1024)

void cg_cbc_init(cg_cbc_decryptor *decryptor, const uint8_t key[16], const uint8_t iv[16]) {
    memset(decryptor, 0, sizeof(*decryptor));
    mbedtls_aes_init(&decryptor->aes);
    mbedtls_aes_setkey_dec(&decryptor->aes, key, 128);
    memcpy(decryptor->previous, iv, CG_AES_BLOCK);
}

void cg_cbc_free(cg_cbc_decryptor *decryptor) { mbedtls_aes_free(&decryptor->aes); }

/* Decrypts `len` (a multiple of 16, > 0) bytes into out: the withheld block first, then
 * every new block but the last one, which becomes the withheld block. */
static size_t decrypt_blocks(cg_cbc_decryptor *decryptor, const uint8_t *ciphertext, size_t len, uint8_t *out) {
    size_t written = 0;
    if (decryptor->has_pending) {
        memcpy(out, decryptor->pending, CG_AES_BLOCK);
        written = CG_AES_BLOCK;
    }
    mbedtls_aes_crypt_cbc(&decryptor->aes, MBEDTLS_AES_DECRYPT, len, decryptor->previous, ciphertext, out + written);
    written += len - CG_AES_BLOCK;
    memcpy(decryptor->pending, out + written, CG_AES_BLOCK);
    decryptor->has_pending = true;
    return written;
}

size_t cg_cbc_update(cg_cbc_decryptor *decryptor, const uint8_t *input, size_t len, uint8_t *out) {
    size_t written = 0;
    if (decryptor->partial_len) {
        size_t take = CG_AES_BLOCK - decryptor->partial_len;
        if (take > len) take = len;
        memcpy(decryptor->partial + decryptor->partial_len, input, take);
        decryptor->partial_len += take;
        input += take;
        len -= take;
        if (decryptor->partial_len < CG_AES_BLOCK) return 0;
        uint8_t block[CG_AES_BLOCK];
        memcpy(block, decryptor->partial, CG_AES_BLOCK);
        decryptor->partial_len = 0;
        written += decrypt_blocks(decryptor, block, CG_AES_BLOCK, out);
    }
    size_t whole = len - len % CG_AES_BLOCK;
    if (whole) written += decrypt_blocks(decryptor, input, whole, out + written);
    memcpy(decryptor->partial, input + whole, len - whole);
    decryptor->partial_len = len - whole;
    return written;
}

void cg_cbc_update_buf(cg_cbc_decryptor *decryptor, const uint8_t *input, size_t len, cg_buf *out) {
    cg_buf_reserve(out, len + CG_AES_BLOCK);
    out->len += cg_cbc_update(decryptor, input, len, (uint8_t *)out->data + out->len);
    out->data[out->len] = 0;
}

bool cg_cbc_finish(cg_cbc_decryptor *decryptor, uint8_t out[16], size_t *written, cg_error *err) {
    *written = 0;
    mbedtls_aes_free(&decryptor->aes);
    if (decryptor->partial_len)
        return cg_err_set(err, "decrypt_failed", "Ciphertext is not a multiple of the AES block size");
    if (!decryptor->has_pending) return cg_err_set(err, "decrypt_failed", "Ciphertext is empty");
    const uint8_t *last = decryptor->pending;
    size_t pad = last[CG_AES_BLOCK - 1];
    bool valid = pad != 0 && pad <= CG_AES_BLOCK;
    for (size_t i = CG_AES_BLOCK - (valid ? pad : 0); valid && i < CG_AES_BLOCK; i++)
        if (last[i] != pad) valid = false;
    if (!valid) return cg_err_set(err, "decrypt_failed", "Invalid PKCS#7 padding");
    memcpy(out, last, CG_AES_BLOCK - pad);
    *written = CG_AES_BLOCK - pad;
    return true;
}

bool cg_cbc_finish_buf(cg_cbc_decryptor *decryptor, cg_buf *out, cg_error *err) {
    uint8_t last[CG_AES_BLOCK];
    size_t written;
    if (!cg_cbc_finish(decryptor, last, &written, err)) return false;
    cg_buf_put(out, last, written);
    return true;
}

/* ---- files */

static bool write_all(int fd, const uint8_t *bytes, size_t len) {
    while (len) {
        ssize_t done = write(fd, bytes, len);
        if (done < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        bytes += done;
        len -= (size_t)done;
    }
    return true;
}

static ssize_t read_some(int fd, uint8_t *buffer, size_t len) {
    while (true) {
        ssize_t got = read(fd, buffer, len);
        if (got < 0 && errno == EINTR) continue;
        return got;
    }
}

/* Fills `buffer` as far as the file allows (fewer bytes only at the end). */
static ssize_t read_full(int fd, uint8_t *buffer, size_t len) {
    size_t total = 0;
    while (total < len) {
        ssize_t got = read_some(fd, buffer + total, len - total);
        if (got < 0) return total ? (ssize_t)total : -1;
        if (got == 0) break;
        total += (size_t)got;
    }
    return (ssize_t)total;
}

char *cg_aes_cbc_decrypt_file_to(const char *source, const char *destination, const uint8_t key[16],
                                 const uint8_t iv[16], cg_error *err) {
    struct stat info;
    if (stat(source, &info) != 0) {
        cg_err_io(err, "Cannot stat encrypted file", errno);
        return NULL;
    }
    if (info.st_size == 0) {
        cg_err_set(err, "empty_input", "Empty encrypted data");
        return NULL;
    }
    int input = open(source, O_RDONLY | O_CLOEXEC);
    if (input < 0) {
        cg_err_io(err, "Cannot open encrypted file", errno);
        return NULL;
    }
    int output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0666);
    if (output < 0) {
        cg_err_io(err, "Cannot create temp file", errno);
        close(input);
        return NULL;
    }
    uint8_t *cipher = cg_malloc(DECRYPT_CHUNK_BYTES);
    uint8_t *plain = cg_malloc(DECRYPT_CHUNK_BYTES + CG_AES_BLOCK);
    cg_cbc_decryptor decryptor;
    cg_cbc_init(&decryptor, key, iv);
    cg_sha256 hasher;
    cg_sha256_init(&hasher);
    uint64_t produced = 0;
    char *hash = NULL;
    bool finished = false;
    while (true) {
        ssize_t got = read_full(input, cipher, DECRYPT_CHUNK_BYTES);
        if (got < 0) {
            cg_err_io(err, "Cannot read encrypted file", errno);
            goto done;
        }
        size_t count;
        if (got == 0) {
            finished = true;
            if (!cg_cbc_finish(&decryptor, plain, &count, err)) goto done;
            if (produced == 0 && count == 0) {
                cg_err_set(err, "decrypt_failed", "Empty decrypted data");
                goto done;
            }
        } else {
            count = cg_cbc_update(&decryptor, cipher, (size_t)got, plain);
        }
        cg_sha256_update(&hasher, plain, count);
        if (!write_all(output, plain, count)) {
            cg_err_io(err, "Cannot write decrypted file", errno);
            goto done;
        }
        produced += count;
        if (finished) break;
    }
    hash = cg_malloc(65);
    cg_sha256_finish_hex(&hasher, hash);
done:
    if (!hash) cg_sha256_free(&hasher);
    if (!finished) cg_cbc_free(&decryptor);
    free(cipher);
    free(plain);
    close(input);
    if (close(output) != 0 && hash) {
        cg_err_io(err, "Cannot flush decrypted file", errno);
        free(hash);
        hash = NULL;
    }
    return hash;
}

static const char ID_ALPHABET[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

static void random_bytes(uint8_t *bytes, size_t len) {
#if defined(__APPLE__) || defined(__ANDROID__) || defined(__FreeBSD__) || defined(__OpenBSD__)
    arc4random_buf(bytes, len);
#else
    size_t done = 0;
    while (done < len) {
        ssize_t got = getrandom(bytes + done, len - done, 0);
        if (got < 0) {
            if (errno == EINTR) continue;
            abort(); /* Rust: "system RNG available" */
        }
        done += (size_t)got;
    }
#endif
}

/* store::random_id: 10 characters of [0-9A-Za-z]. */
static void random_id(char out[11]) {
    uint8_t bytes[10];
    random_bytes(bytes, sizeof(bytes));
    for (size_t i = 0; i < 10; i++) out[i] = ID_ALPHABET[bytes[i] % (sizeof(ID_ALPHABET) - 1)];
    out[10] = 0;
}

/* Rust Path::parent: NULL for "" and the root, "" for a bare file name. malloc'd. */
static char *path_parent(const char *path) {
    size_t n = strlen(path);
    while (n > 0 && path[n - 1] == '/') n--;
    if (n == 0) return NULL;
    size_t slash = n;
    while (slash > 0 && path[slash - 1] != '/') slash--;
    if (slash == 0) return cg_strdup("");
    size_t end = slash;
    while (end > 0 && path[end - 1] == '/') end--;
    return end == 0 ? cg_strdup("/") : cg_strndup(path, end);
}

char *cg_aes_cbc_decrypt_file_in_place_hashed(const char *path, const uint8_t key[16], const uint8_t iv[16],
                                              cg_error *err) {
    char *parent = path_parent(path);
    if (!parent) {
        cg_err_set(err, "io_error", "No parent directory for %s", path);
        return NULL;
    }
    /* Files are decrypted in parallel in one directory: the name must be unique per call. */
    char id[11];
    random_id(id);
    char *temp = !*parent                       ? cg_fmt("capgo-aes-%s.tmp", id)
                 : cg_ends_with(parent, "/") ? cg_fmt("%scapgo-aes-%s.tmp", parent, id)
                                             : cg_fmt("%s/capgo-aes-%s.tmp", parent, id);
    free(parent);
    char *hash = cg_aes_cbc_decrypt_file_to(path, temp, key, iv, err);
    if (hash && rename(temp, path) != 0) {
        cg_err_io(err, "Cannot replace encrypted file", errno);
        free(hash);
        hash = NULL;
    }
    if (!hash) unlink(temp);
    free(temp);
    return hash;
}

/* ---- CbcDecryptReader */

static ssize_t fd_read(void *context, uint8_t *buffer, size_t len) {
    return read_some(*(int *)context, buffer, len);
}

void cg_cbc_reader_init(cg_cbc_reader *reader, cg_read_fn read, void *context, const uint8_t key[16],
                        const uint8_t iv[16]) {
    memset(reader, 0, sizeof(*reader));
    reader->read = read;
    reader->context = context;
    cg_cbc_init(&reader->decryptor, key, iv);
    reader->input = cg_malloc(CG_IO_BUFFER_BYTES);
    reader->plain = cg_malloc(CG_IO_BUFFER_BYTES + CG_AES_BLOCK);
    reader->fd = -1;
}

void cg_cbc_reader_init_fd(cg_cbc_reader *reader, int fd, const uint8_t key[16], const uint8_t iv[16]) {
    cg_cbc_reader_init(reader, fd_read, NULL, key, iv);
    reader->fd = fd;
    reader->context = &reader->fd;
}

ssize_t cg_cbc_reader_read(cg_cbc_reader *reader, uint8_t *out, size_t len, cg_error *err) {
    if (len == 0) return 0;
    while (true) {
        if (reader->position < reader->plain_len) {
            size_t count = reader->plain_len - reader->position;
            if (count > len) count = len;
            memcpy(out, reader->plain + reader->position, count);
            reader->position += count;
            reader->produced += count;
            return (ssize_t)count;
        }
        if (reader->finished) return 0;
        reader->plain_len = 0;
        reader->position = 0;
        ssize_t got = reader->read(reader->context, reader->input, CG_IO_BUFFER_BYTES);
        if (got < 0) {
            reader->io_errno = errno;
            cg_err_set_own(err, "io_error", cg_io_message(reader->io_errno));
            return -1;
        }
        if (got == 0) {
            reader->finished = true;
            size_t count;
            if (!cg_cbc_finish(&reader->decryptor, reader->plain, &count, err)) return -1;
            reader->plain_len = count;
            if (reader->produced == 0 && count == 0) {
                cg_err_set(err, "decrypt_failed", "Empty decrypted data");
                return -1;
            }
        } else {
            reader->plain_len = cg_cbc_update(&reader->decryptor, reader->input, (size_t)got, reader->plain);
        }
    }
}

void cg_cbc_reader_free(cg_cbc_reader *reader) {
    if (!reader->finished) cg_cbc_free(&reader->decryptor);
    reader->finished = true;
    free(reader->input);
    free(reader->plain);
    reader->input = reader->plain = NULL;
}
