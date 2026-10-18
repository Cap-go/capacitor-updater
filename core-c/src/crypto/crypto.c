/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#include "crypto/crypto.h"

#include <stdlib.h>
#include <string.h>

#include "crypto/rsa.h"
#include "rt/str.h"
#include "rt/sync.h"
#include "text.h"

bool cg_crypto_is_valid_session_key(const char *session_key) {
    if (!session_key) return false;
    const char *colon = strchr(session_key, ':');
    if (!colon || colon == session_key) return false;
    const char *key = colon + 1;
    return *key && !strchr(key, ':');
}

char *cg_crypto_key_id(const char *public_key) {
    const char *text = public_key ? public_key : "";
    size_t len = strlen(text);
    cg_buf compact = {0};
    for (size_t i = 0; i < len;) {
        uint32_t cp;
        size_t step = cg_text_utf8_next(text + i, len - i, &cp);
        if (!cg_text_is_unicode_whitespace(cp)) cg_buf_put(&compact, text + i, step);
        i += step;
    }
    char *joined = cg_buf_take(&compact);
    char *without_begin = cg_replace_all(joined, "-----BEGINRSAPUBLICKEY-----", "");
    char *cleaned = cg_replace_all(without_begin, "-----ENDRSAPUBLICKEY-----", "");
    free(joined);
    free(without_begin);
    /* The first 20 characters (Unicode scalar values). */
    size_t end = 0, cleaned_len = strlen(cleaned);
    for (int count = 0; count < 20 && end < cleaned_len; count++) {
        uint32_t cp;
        end += cg_text_utf8_next(cleaned + end, cleaned_len - end, &cp);
    }
    cleaned[end] = 0;
    return cleaned;
}

/* The configured public key parsed once (manifests decrypt one checksum per file). */
static cg_mutex cache_mutex = CG_MUTEX_INIT;
static char *cache_pem;
static cg_rsa_public_key *cache_key;

/* A new reference to the parsed key, NULL with *err. */
static cg_rsa_public_key *cached_public_key(const char *pem, cg_error *err) {
    cg_lock(&cache_mutex);
    if (cache_key && strcmp(cache_pem, pem) == 0) {
        cg_rsa_public_key *key = cg_rsa_retain(cache_key);
        cg_unlock(&cache_mutex);
        return key;
    }
    cg_rsa_public_key *key = cg_rsa_from_pem(pem, err);
    if (key) {
        cg_rsa_release(cache_key);
        free(cache_pem);
        cache_key = cg_rsa_retain(key);
        cache_pem = cg_strdup(pem);
    }
    cg_unlock(&cache_mutex);
    return key;
}

char *cg_crypto_decrypt_checksum(const char *checksum, const char *public_key, cg_error *err) {
    checksum = cg_or_empty(checksum);
    if (cg_empty(public_key)) return cg_strdup(checksum);
    size_t len = 0;
    uint8_t *encrypted =
        cg_text_is_hex(checksum) ? cg_text_hex_decode(checksum, &len) : cg_text_base64_decode(checksum, &len);
    if (!encrypted || len == 0) {
        free(encrypted);
        cg_err_set(err, "invalid_checksum", "Cannot decode checksum as hex or base64");
        return NULL;
    }
    if (len != 256) {
        free(encrypted);
        cg_err_set(err, "checksum_not_encrypted",
                   "Checksum is not RSA encrypted (size: %zu bytes, expected 256 for RSA-2048). Upload the bundle "
                   "with encryption when a public key is configured.",
                   len);
        return NULL;
    }
    char *out = NULL;
    cg_rsa_public_key *key = cached_public_key(public_key, err);
    if (key) {
        size_t decrypted_len;
        uint8_t *decrypted = cg_rsa_public_decrypt(key, encrypted, len, &decrypted_len, err);
        if (decrypted) out = cg_text_hex_encode(decrypted, decrypted_len);
        free(decrypted);
        cg_rsa_release(key);
    }
    free(encrypted);
    return out;
}

static bool decrypt_session_key(const char *public_key, const char *session_key, cg_session_key *out,
                                cg_error *err) {
    const char *colon = strchr(session_key, ':');
    if (!colon) return cg_err_set(err, "invalid_session_key", "Session key must be <iv>:<key>");
    size_t iv_len = 0;
    uint8_t *iv = cg_text_base64_decode_n(session_key, (size_t)(colon - session_key), &iv_len);
    if (!iv || iv_len != 16) {
        free(iv);
        return cg_err_set(err, "invalid_iv", "IV must be 16 bytes of base64");
    }
    memcpy(out->iv, iv, 16);
    free(iv);
    size_t encrypted_len = 0;
    uint8_t *encrypted = cg_text_base64_decode(colon + 1, &encrypted_len);
    if (!encrypted) return cg_err_set(err, "invalid_session_key", "Session key is not base64");
    cg_rsa_public_key *rsa_key = cached_public_key(public_key, err);
    if (!rsa_key) {
        free(encrypted);
        return false;
    }
    cg_error decrypt_error = CG_ERROR_INIT;
    size_t key_len = 0;
    uint8_t *key = cg_rsa_public_decrypt(rsa_key, encrypted, encrypted_len, &key_len, &decrypt_error);
    cg_rsa_release(rsa_key);
    free(encrypted);
    if (!key) {
        cg_err_set(err, "session_key_decrypt_failed", "Failed to decrypt session key: %s",
                   cg_or_empty(decrypt_error.message));
        cg_err_clear(&decrypt_error);
        return false;
    }
    if (key_len != 16) {
        free(key);
        return cg_err_set(err, "invalid_session_key", "Decrypted session key must be 16 bytes, got %zu", key_len);
    }
    memcpy(out->key, key, 16);
    free(key);
    return true;
}

bool cg_crypto_bundle_session_key(const char *public_key, const char *session_key, cg_session_key *out,
                                  bool *has_key, cg_error *err) {
    *has_key = false;
    if (cg_empty(public_key) || !cg_crypto_is_valid_session_key(session_key)) return true;
    cg_session_key parsed;
    if (!decrypt_session_key(public_key, session_key, &parsed, err)) return false;
    *out = parsed;
    *has_key = true;
    return true;
}
