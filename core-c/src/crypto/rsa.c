/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Minimal RSA public-key support: PEM/DER parsing and the raw public operation. Only
 * public data is handled here, so the operation does not need to be constant time: a
 * small Montgomery modular exponentiation (as in Rust crypto/rsa.rs) replaces a general
 * big-integer library. Limbs are 64-bit where the compiler has a 128-bit product (arm64,
 * x86_64), 32-bit otherwise (armeabi-v7a, x86). */

#include "crypto/rsa.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "rt/str.h"
#include "text.h"

#define TAG_INTEGER 0x02
#define TAG_BIT_STRING 0x03
#define TAG_SEQUENCE 0x30
#define MIN_MODULUS_BITS 1024
#define MAX_MODULUS_BITS 8192

#if defined(__SIZEOF_INT128__)
typedef uint64_t limb;
typedef unsigned __int128 dlimb;
#else
typedef uint32_t limb;
typedef uint64_t dlimb;
#endif
#define LIMB_BITS (8 * sizeof(limb))
#define MAX_LIMBS (MAX_MODULUS_BITS / LIMB_BITS)

static const uint8_t RSA_ENCRYPTION_OID[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01};

struct cg_rsa_public_key {
    atomic_int refs;
    /* Big-endian, without leading zero bytes. */
    uint8_t *exponent;
    size_t exponent_len;
    size_t size_bytes;
    /* Montgomery arithmetic modulo n, R = 2^(LIMB_BITS * limbs). */
    size_t limbs;
    limb n_prime;    /* -n^-1 mod 2^LIMB_BITS */
    limb *n;         /* little-endian, no high zero limb */
    limb *r_squared; /* R^2 mod n, to enter the Montgomery domain */
    limb words[];    /* storage of n and r_squared */
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

/* ---- limbs */

/* Little-endian limbs of a big-endian value, zero-extended to `count` limbs (the value fits). */
static void limbs_from_be(const uint8_t *be, size_t len, limb *out, size_t count) {
    memset(out, 0, count * sizeof(limb));
    for (size_t i = 0; i < len; i++) out[i / sizeof(limb)] |= (limb)be[len - 1 - i] << (8 * (i % sizeof(limb)));
}

/* Big-endian bytes of `limbs`, left-padded to `len` (the value fits). */
static void limbs_to_be(const limb *limbs, size_t count, uint8_t *out, size_t len) {
    for (size_t i = 0; i < len; i++) {
        size_t index = i / sizeof(limb);
        out[len - 1 - i] = index < count ? (uint8_t)(limbs[index] >> (8 * (i % sizeof(limb)))) : 0;
    }
}

/* -1, 0 or 1 for a, b of equal length. */
static int compare(const limb *a, const limb *b, size_t count) {
    for (size_t i = count; i-- > 0;) {
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}

/* a -= b over equal lengths; the final borrow cancels a carry the caller tracks. */
static void sub_assign(limb *a, const limb *b, size_t count) {
    limb borrow = 0;
    for (size_t i = 0; i < count; i++) {
        limb x = a[i], y = b[i];
        a[i] = x - y - borrow;
        borrow = (limb)((x < y) | ((x == y) & borrow));
    }
}

/* ---- Montgomery arithmetic (inputs below n, outputs fully reduced) */

/* out = a * b * R^-1 mod n (CIOS). out may alias a or b. */
static void mont_mul(const cg_rsa_public_key *key, const limb *a, const limb *b, limb *out) {
    const size_t k = key->limbs;
    const limb *n = key->n;
    limb t[MAX_LIMBS + 1];
    memset(t, 0, (k + 1) * sizeof(limb));
    for (size_t i = 0; i < k; i++) {
        /* t = (t + a[i] * b + m * n) / 2^LIMB_BITS, with m making the low limb zero. The
         * product and reduction carries are two independent chains in one pass. */
        const limb a_i = a[i];
        dlimb product = (dlimb)t[0] + (dlimb)a_i * b[0];
        const limb m = (limb)product * key->n_prime;
        dlimb reduced = (dlimb)(limb)product + (dlimb)m * n[0];
        limb carry = (limb)(product >> LIMB_BITS), carry_n = (limb)(reduced >> LIMB_BITS);
        for (size_t j = 1; j < k; j++) {
            product = (dlimb)t[j] + (dlimb)a_i * b[j] + carry;
            reduced = (dlimb)(limb)product + (dlimb)m * n[j] + carry_n;
            carry = (limb)(product >> LIMB_BITS);
            carry_n = (limb)(reduced >> LIMB_BITS);
            t[j - 1] = (limb)reduced;
        }
        product = (dlimb)t[k] + carry + carry_n;
        t[k - 1] = (limb)product;
        t[k] = (limb)(product >> LIMB_BITS);
    }
    /* t < 2n: one conditional subtraction. */
    if (t[k] != 0 || compare(t, n, k) >= 0) sub_assign(t, n, k);
    memcpy(out, t, k * sizeof(limb));
}

/* out = base^exponent mod n, left-to-right binary; base < n, exponent odd and > 1. A
 * dedicated squaring was slower than this fused multiplication on arm64. */
static void mont_pow(const cg_rsa_public_key *key, const limb *base, limb *out) {
    const size_t k = key->limbs;
    limb base_m[MAX_LIMBS], acc[MAX_LIMBS];
    mont_mul(key, base, key->r_squared, base_m);
    bool started = false;
    for (size_t i = 0; i < key->exponent_len; i++) {
        for (int shift = 7; shift >= 0; shift--) {
            if (started) mont_mul(key, acc, acc, acc);
            if ((key->exponent[i] >> shift) & 1) {
                if (started) {
                    mont_mul(key, acc, base_m, acc);
                } else {
                    memcpy(acc, base_m, k * sizeof(limb));
                    started = true;
                }
            }
        }
    }
    /* Leave the Montgomery domain: acc * 1 * R^-1. */
    limb one[MAX_LIMBS] = {1};
    mont_mul(key, acc, one, out);
}

/* ---- keys */

static cg_rsa_public_key *key_from_parts(bytes modulus, bytes exponent) {
    size_t limbs = (modulus.len + sizeof(limb) - 1) / sizeof(limb);
    cg_rsa_public_key *key = cg_calloc(1, sizeof(*key) + 2 * limbs * sizeof(limb));
    atomic_init(&key->refs, 1);
    key->size_bytes = (bit_length(modulus) + 7) / 8;
    key->exponent_len = exponent.len;
    key->exponent = cg_malloc(exponent.len);
    memcpy(key->exponent, exponent.ptr, exponent.len);
    key->limbs = limbs;
    key->n = key->words;
    key->r_squared = key->words + limbs;
    limbs_from_be(modulus.ptr, modulus.len, key->n, limbs);
    /* Newton iteration for n[0]^-1 mod 2^LIMB_BITS: n0 * n0 == 1 mod 8, then 3 -> 6 -> ... bits. */
    limb inverse = key->n[0];
    for (int i = 0; i < 5; i++) inverse *= (limb)2 - key->n[0] * inverse;
    key->n_prime = (limb)0 - inverse;
    /* R^2 mod n by doubling 1, reducing after each step (2x < 2n needs one subtraction). */
    limb *r = key->r_squared;
    r[0] = 1;
    for (size_t step = 0; step < 2 * LIMB_BITS * limbs; step++) {
        limb carry = 0;
        for (size_t i = 0; i < limbs; i++) {
            limb next = r[i] >> (LIMB_BITS - 1);
            r[i] = (r[i] << 1) | carry;
            carry = next;
        }
        if (carry != 0 || compare(r, key->n, limbs) >= 0) sub_assign(r, key->n, limbs);
    }
    return key;
}

static void key_free(cg_rsa_public_key *key) {
    free(key->exponent);
    free(key);
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

uint8_t *cg_rsa_public_op(const cg_rsa_public_key *key, const uint8_t *value, size_t len, size_t *out_len,
                          cg_error *err) {
    if (len != key->size_bytes) {
        cg_err_set(err, "decrypt_failed", "Ciphertext length does not match the RSA key size");
        return NULL;
    }
    /* len * 8 <= LIMB_BITS * limbs: the value fits the modulus limb count. */
    limb base[MAX_LIMBS], result[MAX_LIMBS];
    limbs_from_be(value, len, base, key->limbs);
    if (compare(base, key->n, key->limbs) >= 0) {
        cg_err_set(err, "decrypt_failed", "Ciphertext is out of range for the RSA key");
        return NULL;
    }
    mont_pow(key, base, result);
    uint8_t *out = cg_malloc(key->size_bytes ? key->size_bytes : 1);
    limbs_to_be(result, key->limbs, out, key->size_bytes);
    if (out_len) *out_len = key->size_bytes;
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
