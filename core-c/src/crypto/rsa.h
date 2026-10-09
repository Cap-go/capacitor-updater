/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Minimal RSA public-key support (Rust crypto/rsa.rs): PEM/DER parsing (PKCS#1
 * `RSA PUBLIC KEY` and SPKI `PUBLIC KEY`) and the raw public operation used to recover
 * data signed with Node's `privateEncrypt` (PKCS#1 v1.5 block type 1). The modular
 * exponentiation is Mbed TLS bignum; the validation rules are the Rust ones. */
#ifndef CG_RSA_H
#define CG_RSA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "rt/err.h"

/* Immutable once parsed, reference counted, safe to share between threads. */
typedef struct cg_rsa_public_key cg_rsa_public_key;

/* Parses a PKCS#1 or SPKI PEM (headers optional, literal "\n" sequences ignored).
 * NULL with *err "invalid_public_key". The caller owns one reference. */
cg_rsa_public_key *cg_rsa_from_pem(const char *pem, cg_error *err);
/* RSAPublicKey or SubjectPublicKeyInfo DER: modulus of 1024..8192 bits and odd,
 * exponent odd and > 1. NULL with *err "invalid_public_key". */
cg_rsa_public_key *cg_rsa_from_der(const uint8_t *der, size_t len, cg_error *err);
cg_rsa_public_key *cg_rsa_retain(cg_rsa_public_key *key);
/* Drops one reference (frees at zero). NULL-safe. */
void cg_rsa_release(cg_rsa_public_key *key);
/* Modulus size in bytes. */
size_t cg_rsa_size_bytes(const cg_rsa_public_key *key);

/* Raw public operation value^e mod n, big-endian and left-padded to the key size
 * (malloc'd, length in *out_len). NULL with *err "decrypt_failed" when the input length
 * is not the key size or the value is not below the modulus. */
uint8_t *cg_rsa_public_op(const cg_rsa_public_key *key, const uint8_t *value, size_t len, size_t *out_len,
                          cg_error *err);
/* Recovers the payload of a PKCS#1 v1.5 type-1 block (malloc'd). NULL with *err
 * "decrypt_failed" ("Invalid PKCS#1 signature padding" when the block is malformed). */
uint8_t *cg_rsa_public_decrypt(const cg_rsa_public_key *key, const uint8_t *ciphertext, size_t len, size_t *out_len,
                               cg_error *err);
/* RFC 8017: `00 01`, at least eight `FF`, `00`, then a non-empty payload. malloc'd payload,
 * NULL (Rust None) when malformed. */
uint8_t *cg_rsa_unpad_type1(const uint8_t *block, size_t len, size_t *out_len);

#endif
