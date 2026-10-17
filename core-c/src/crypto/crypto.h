/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Bundle cryptography (Rust crypto/mod.rs): RSA public-key recovery of session keys and
 * checksums (PKCS#1 v1.5 type 1, as produced by the Capgo CLI with `privateEncrypt`).
 * AES-128-CBC is crypto/aes_cbc.h, SHA-256 crypto/checksum.h, RSA crypto/rsa.h. */
#ifndef CG_CRYPTO_H
#define CG_CRYPTO_H

#include <stdbool.h>
#include <stdint.h>

#include "rt/err.h"

/* `<iv base64>:<RSA-encrypted AES key base64>`, both parts non-empty. NULL = absent. */
bool cg_crypto_is_valid_session_key(const char *session_key);

/* First 20 characters of the base64 key body (whitespace and PKCS#1 markers removed);
 * identifies the key in stats. malloc'd. */
char *cg_crypto_key_id(const char *public_key);

/* Decrypts a bundle checksum signed with the private key (lowercase hex, malloc'd).
 * With no public key ("") the checksum is returned unchanged. The encrypted checksum is
 * hex (current CLI) or base64 (legacy CLI) and must be one RSA-2048 block. NULL with
 * *err: invalid_checksum, checksum_not_encrypted, invalid_public_key, decrypt_failed.
 * The parsed key is cached (thread-safe; a different key replaces it). */
char *cg_crypto_decrypt_checksum(const char *checksum, const char *public_key, cg_error *err);

/* Parsed `<iv>:<encrypted key>` session key. */
typedef struct {
    uint8_t iv[16];
    uint8_t key[16];
} cg_session_key;

/* The AES key of an encrypted bundle. Returns false with *err on failure (invalid_iv,
 * invalid_session_key, invalid_public_key, session_key_decrypt_failed). On success
 * *has_key is false when the bundle is not encrypted (no public key, or a session key
 * that is not `<iv>:<key>`), else *out is filled. */
bool cg_crypto_bundle_session_key(const char *public_key, const char *session_key, cg_session_key *out,
                                  bool *has_key, cg_error *err);

#endif
