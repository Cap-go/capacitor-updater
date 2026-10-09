/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Minimal RSA public-key support: PEM/DER parsing and the raw public operation. Only
 * public data is handled here, so the operation does not need to be constant time. */

#include "crypto/rsa.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "mbedtls/bignum.h"
/* mbedtls_mpi_exp_mod_unsafe: the variable-time exponentiation for public exponents. */
#include "bignum_internal.h"
#include "rt/str.h"
#include "text.h"

#define TAG_INTEGER 0x02
#define TAG_BIT_STRING 0x03
#define TAG_SEQUENCE 0x30
#define MIN_MODULUS_BITS 1024
#define MAX_MODULUS_BITS 8192

static const uint8_t RSA_ENCRYPTION_OID[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01};

struct cg_rsa_public_key {
    atomic_int refs;
    mbedtls_mpi n;
    mbedtls_mpi rr; /* R^2 mod n, precomputed (read-only copy per operation) */
    /* Big-endian, without leading zero bytes. */
    uint8_t *exponent;
    size_t exponent_len;
    mbedtls_mpi e;   /* the exponent, when it fits Mbed TLS limits */
    bool e_is_mpi;
    size_t size_bytes;
};

static bool invalid_key(cg_error *err, const char *message) { return cg_err_set(err, "invalid_public_key", "%s", message); }

typedef struct {
    const uint8_t *ptr;
    size_t len;
} bytes;

/* One DER TLV at input[0..]: tag, content, rest. */
static bool read_tlv(bytes input, uint8_t *tag, bytes *content, bytes *rest, cg_error *err) {
    if (input.len < 1) return invalid_key(err, "Truncated DER");
    *tag = input.ptr[0];
    if (input.len < 2) return invalid_key(err, "Truncated DER length");
    uint8_t first_len = input.ptr[1];
    const uint8_t *p = input.ptr + 2;
    size_t remaining = input.len - 2;
    size_t len;
    if ((first_len & 0x80) == 0) {
        len = first_len;
    } else {
        size_t count = first_len & 0x7f;
        if (count == 0 || count > 4 || remaining < count) return invalid_key(err, "Unsupported DER length");
        len = 0;
        for (size_t i = 0; i < count; i++) len = (len << 8) | p[i];
        p += count;
        remaining -= count;
    }
    if (remaining < len) return invalid_key(err, "Truncated DER content");
    *content = (bytes){p, len};
    *rest = (bytes){p + len, remaining - len};
    return true;
}

static bool expect_tlv(bytes input, uint8_t tag, bytes *content, bytes *rest, cg_error *err) {
    uint8_t found = 0;
    if (!read_tlv(input, &found, content, rest, err)) return false;
    if (found != tag) return invalid_key(err, "Unexpected DER tag");
    return true;
}

static bytes strip_leading_zeros(bytes value) {
    while (value.len && value.ptr[0] == 0) value.ptr++, value.len--;
    return value;
}

/* Bit length of a big-endian value without leading zeros. */
static size_t bit_length(bytes value) {
    if (!value.len) return 0;
    size_t bits = (value.len - 1) * 8;
    for (uint8_t top = value.ptr[0]; top; top >>= 1) bits++;
    return bits;
}

static void key_free(cg_rsa_public_key *key) {
    mbedtls_mpi_free(&key->n);
    mbedtls_mpi_free(&key->rr);
    mbedtls_mpi_free(&key->e);
    free(key->exponent);
    free(key);
}

static cg_rsa_public_key *key_from_parts(bytes modulus, bytes exponent) {
    cg_rsa_public_key *key = cg_calloc(1, sizeof(*key));
    atomic_init(&key->refs, 1);
    mbedtls_mpi_init(&key->n);
    mbedtls_mpi_init(&key->rr);
    mbedtls_mpi_init(&key->e);
    key->size_bytes = (bit_length(modulus) + 7) / 8;
    key->exponent_len = exponent.len;
    key->exponent = cg_malloc(exponent.len);
    memcpy(key->exponent, exponent.ptr, exponent.len);
    bool ok = mbedtls_mpi_read_binary(&key->n, modulus.ptr, modulus.len) == 0;
    key->e_is_mpi = bit_length(exponent) <= MBEDTLS_MPI_MAX_BITS &&
                    mbedtls_mpi_read_binary(&key->e, exponent.ptr, exponent.len) == 0;
    if (ok && key->e_is_mpi) {
        /* One operation fills R^2 mod n. */
        mbedtls_mpi x, one;
        mbedtls_mpi_init(&x);
        mbedtls_mpi_init(&one);
        ok = mbedtls_mpi_lset(&one, 1) == 0 && mbedtls_mpi_exp_mod_unsafe(&x, &one, &key->e, &key->n, &key->rr) == 0;
        mbedtls_mpi_free(&x);
        mbedtls_mpi_free(&one);
    }
    if (!ok) {
        /* Allocation failure in Mbed TLS (sizes are already validated). */
        abort();
    }
    return key;
}

cg_rsa_public_key *cg_rsa_from_der(const uint8_t *der, size_t len, cg_error *err) {
    bytes sequence, trailing;
    if (!expect_tlv((bytes){der, len}, TAG_SEQUENCE, &sequence, &trailing, err)) return NULL;
    if (trailing.len) {
        invalid_key(err, "Trailing data after public key");
        return NULL;
    }
    uint8_t first_tag;
    bytes ignored_content, ignored_rest;
    if (!read_tlv(sequence, &first_tag, &ignored_content, &ignored_rest, err)) return NULL;
    if (first_tag == TAG_SEQUENCE) {
        /* SubjectPublicKeyInfo { AlgorithmIdentifier, BIT STRING { RSAPublicKey } } */
        bytes algorithm, rest, oid, oid_rest, bits, bits_rest;
        uint8_t oid_tag;
        if (!expect_tlv(sequence, TAG_SEQUENCE, &algorithm, &rest, err)) return NULL;
        if (!read_tlv(algorithm, &oid_tag, &oid, &oid_rest, err)) return NULL;
        if (oid_tag != 0x06 || oid.len != sizeof(RSA_ENCRYPTION_OID) ||
            memcmp(oid.ptr, RSA_ENCRYPTION_OID, oid.len) != 0) {
            invalid_key(err, "Public key is not an RSA key");
            return NULL;
        }
        if (!expect_tlv(rest, TAG_BIT_STRING, &bits, &bits_rest, err)) return NULL;
        if (!bits.len) {
            invalid_key(err, "Empty key bit string");
            return NULL;
        }
        if (bits.ptr[0] != 0) {
            invalid_key(err, "Unexpected key bit string padding");
            return NULL;
        }
        return cg_rsa_from_der(bits.ptr + 1, bits.len - 1, err);
    }

    /* RSAPublicKey { modulus INTEGER, publicExponent INTEGER } */
    bytes modulus, rest, exponent, exponent_rest;
    if (!expect_tlv(sequence, TAG_INTEGER, &modulus, &rest, err)) return NULL;
    if (!expect_tlv(rest, TAG_INTEGER, &exponent, &exponent_rest, err)) return NULL;
    modulus = strip_leading_zeros(modulus);
    exponent = strip_leading_zeros(exponent);
    size_t bits = bit_length(modulus);
    if (bits < MIN_MODULUS_BITS || bits > MAX_MODULUS_BITS) {
        invalid_key(err, "Unsupported RSA modulus size");
        return NULL;
    }
    /* An RSA modulus is a product of two odd primes. */
    if ((modulus.ptr[modulus.len - 1] & 1) == 0) {
        invalid_key(err, "Invalid RSA modulus");
        return NULL;
    }
    if (!exponent.len || (exponent.len == 1 && exponent.ptr[0] == 1) || (exponent.ptr[exponent.len - 1] & 1) == 0) {
        invalid_key(err, "Invalid RSA public exponent");
        return NULL;
    }
    return key_from_parts(modulus, exponent);
}

cg_rsa_public_key *cg_rsa_from_pem(const char *pem, cg_error *err) {
    static const char *const MARKERS[] = {
        "-----BEGIN RSA PUBLIC KEY-----", "-----END RSA PUBLIC KEY-----", "-----BEGIN PUBLIC KEY-----",
        "-----END PUBLIC KEY-----",
        /* Keys pasted into JSON config sometimes keep literal "\n" sequences. */
        "\\n",
    };
    char *body = cg_strdup(pem ? pem : "");
    for (size_t i = 0; i < sizeof(MARKERS) / sizeof(MARKERS[0]); i++) {
        char *next = cg_replace_all(body, MARKERS[i], "");
        free(body);
        body = next;
    }
    size_t der_len;
    uint8_t *der = cg_text_base64_decode(body, &der_len);
    free(body);
    if (!der) {
        invalid_key(err, "Public key is not valid base64");
        return NULL;
    }
    cg_rsa_public_key *key = cg_rsa_from_der(der, der_len, err);
    free(der);
    return key;
}

cg_rsa_public_key *cg_rsa_retain(cg_rsa_public_key *key) {
    if (key) atomic_fetch_add(&key->refs, 1);
    return key;
}

void cg_rsa_release(cg_rsa_public_key *key) {
    if (key && atomic_fetch_sub(&key->refs, 1) == 1) key_free(key);
}

size_t cg_rsa_size_bytes(const cg_rsa_public_key *key) { return key->size_bytes; }

/* x = base^exponent mod n by square-and-multiply over the exponent bytes, for exponents
 * beyond Mbed TLS limits (Rust accepts any size). */
static int pow_slow(const cg_rsa_public_key *key, mbedtls_mpi *x, const mbedtls_mpi *base) {
    int ret = mbedtls_mpi_lset(x, 1);
    mbedtls_mpi t;
    mbedtls_mpi_init(&t);
    for (size_t i = 0; ret == 0 && i < key->exponent_len; i++) {
        for (int shift = 7; ret == 0 && shift >= 0; shift--) {
            ret = mbedtls_mpi_mul_mpi(&t, x, x);
            if (ret == 0) ret = mbedtls_mpi_mod_mpi(x, &t, &key->n);
            if (ret == 0 && ((key->exponent[i] >> shift) & 1)) {
                ret = mbedtls_mpi_mul_mpi(&t, x, base);
                if (ret == 0) ret = mbedtls_mpi_mod_mpi(x, &t, &key->n);
            }
        }
    }
    mbedtls_mpi_free(&t);
    return ret;
}

uint8_t *cg_rsa_public_op(const cg_rsa_public_key *key, const uint8_t *value, size_t len, size_t *out_len,
                          cg_error *err) {
    if (len != key->size_bytes) {
        cg_err_set(err, "decrypt_failed", "Ciphertext length does not match the RSA key size");
        return NULL;
    }
    mbedtls_mpi base, x, rr;
    mbedtls_mpi_init(&base);
    mbedtls_mpi_init(&x);
    mbedtls_mpi_init(&rr);
    uint8_t *out = NULL;
    if (mbedtls_mpi_read_binary(&base, value, len) != 0) abort();
    if (mbedtls_mpi_cmp_mpi(&base, &key->n) >= 0) {
        cg_err_set(err, "decrypt_failed", "Ciphertext is out of range for the RSA key");
        goto done;
    }
    int ret;
    if (key->e_is_mpi) {
        /* A private copy of R^2 mod n keeps the shared key read-only. */
        ret = mbedtls_mpi_copy(&rr, &key->rr);
        if (ret == 0) ret = mbedtls_mpi_exp_mod_unsafe(&x, &base, &key->e, &key->n, &rr);
    } else {
        ret = pow_slow(key, &x, &base);
    }
    if (ret != 0) abort();
    out = cg_malloc(key->size_bytes ? key->size_bytes : 1);
    if (mbedtls_mpi_write_binary(&x, out, key->size_bytes) != 0) abort();
    if (out_len) *out_len = key->size_bytes;
done:
    mbedtls_mpi_free(&base);
    mbedtls_mpi_free(&x);
    mbedtls_mpi_free(&rr);
    return out;
}

uint8_t *cg_rsa_unpad_type1(const uint8_t *block, size_t len, size_t *out_len) {
    if (len < 11 || block[0] != 0 || block[1] != 1) return NULL;
    size_t separator = 2;
    while (separator < len && block[separator] == 0xff) separator++;
    if (separator < 10 || separator >= len - 1 || block[separator] != 0) return NULL;
    size_t payload = len - separator - 1;
    uint8_t *out = cg_malloc(payload);
    memcpy(out, block + separator + 1, payload);
    if (out_len) *out_len = payload;
    return out;
}

uint8_t *cg_rsa_public_decrypt(const cg_rsa_public_key *key, const uint8_t *ciphertext, size_t len, size_t *out_len,
                               cg_error *err) {
    size_t block_len;
    uint8_t *block = cg_rsa_public_op(key, ciphertext, len, &block_len, err);
    if (!block) return NULL;
    uint8_t *payload = cg_rsa_unpad_type1(block, block_len, out_len);
    free(block);
    if (!payload) cg_err_set(err, "decrypt_failed", "Invalid PKCS#1 signature padding");
    return payload;
}
