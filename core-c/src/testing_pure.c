/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Stateless test operations of Rust testing.rs `call()`: the contract fixture groups
 * (native-contract-tests/<file>.json) and the crypto primitives. The archive, network and
 * engine operations live in their own testing_*.c files. */

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bundle.h"
#include "crypto/aes_cbc.h"
#include "crypto/checksum.h"
#include "crypto/crypto.h"
#include "crypto/rsa.h"
#include "http.h"
#include "paths.h"
#include "policy.h"
#include "rt/err.h"
#include "rt/json.h"
#include "rt/str.h"
#include "text.h"

bool cg_testing_pure(const char *name, const cj *input, cj **result, cg_error *err);

/* ---- input accessors (Rust testing.rs: same checks, same invalid_input messages) */

static bool opt_str(const cj *input, const char *key, const char **out, cg_error *err) {
    const cj *value = cj_get(input, key);
    *out = NULL;
    if (cj_is_null(value)) return true;
    if (cj_is_str(value)) {
        *out = cj_as_str(value);
        return true;
    }
    char *text = cj_print(value);
    cg_err_invalid_input(err, "`%s` must be a string, got %s", key, text);
    free(text);
    return false;
}

static bool str_or_empty(const cj *input, const char *key, const char **out, cg_error *err) {
    if (!opt_str(input, key, out, err)) return false;
    if (!*out) *out = "";
    return true;
}

static bool req_str(const cj *input, const char *key, const char **out, cg_error *err) {
    if (!opt_str(input, key, out, err)) return false;
    if (!*out) return cg_err_invalid_input(err, "`%s` is required", key);
    return true;
}

static bool req_bool(const cj *input, const char *key, bool *out, cg_error *err) {
    if (!cj_as_bool(cj_get(input, key), out)) return cg_err_invalid_input(err, "`%s` must be a boolean", key);
    return true;
}

/* *has = false when absent / null. Integers, or floats without a fraction (saturating). */
static bool opt_i64(const cj *input, const char *key, bool *has, int64_t *out, cg_error *err) {
    const cj *value = cj_get(input, key);
    *has = false;
    if (cj_is_null(value)) return true;
    double number;
    if (cj_as_i64(value, out)) {
        *has = true;
        return true;
    }
    /* f64::fract() == 0.0: finite and integral. */
    if (cj_as_f64(value, &number) && isfinite(number) && trunc(number) == number) {
        *out = cg_text_f64_to_i64_saturating(number);
        *has = true;
        return true;
    }
    return cg_err_invalid_input(err, "`%s` must be an integer", key);
}

static bool req_i64(const cj *input, const char *key, int64_t *out, cg_error *err) {
    bool has;
    if (!opt_i64(input, key, &has, out, err)) return false;
    if (!has) return cg_err_invalid_input(err, "`%s` is required", key);
    return true;
}

/* malloc'd bytes; NULL with *err. */
static uint8_t *hex(const cj *input, const char *key, size_t *len, cg_error *err) {
    const char *text;
    if (!req_str(input, key, &text, err)) return NULL;
    uint8_t *bytes = cg_text_hex_decode(text, len);
    if (!bytes) cg_err_invalid_input(err, "`%s` must be hex", key);
    return bytes;
}

static bool block16(const cj *input, const char *key, uint8_t out[16], cg_error *err) {
    size_t len;
    uint8_t *bytes = hex(input, key, &len, err);
    if (!bytes) return false;
    bool ok = len == 16;
    if (ok) memcpy(out, bytes, 16);
    else cg_err_invalid_input(err, "`%s` must be 16 bytes", key);
    free(bytes);
    return ok;
}

/* Path::join. */
static char *path_join(const char *dir, const char *name) {
    if (!*dir) return cg_strdup(name);
    return cg_ends_with(dir, "/") ? cg_fmt("%s%s", dir, name) : cg_fmt("%s/%s", dir, name);
}

/* fs::write(path, content repeated `repeat` times); false with *err ("<context>: <io error>"). */
static bool write_file(const char *path, const uint8_t *content, size_t len, size_t repeat, cg_error *err) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
    if (fd < 0) return cg_err_io(err, "write", errno);
    /* Batch small contents into ~1 MiB writes. */
    size_t per_chunk = len ? (1024 * 1024) / len : 0;
    if (per_chunk == 0) per_chunk = 1;
    if (per_chunk > repeat) per_chunk = repeat;
    uint8_t *chunk = cg_malloc(len * per_chunk + 1);
    for (size_t i = 0; i < per_chunk; i++) memcpy(chunk + i * len, content, len);
    bool ok = true;
    for (size_t done = 0; ok && done < repeat && len;) {
        size_t count = repeat - done < per_chunk ? repeat - done : per_chunk;
        size_t remaining = count * len;
        const uint8_t *p = chunk;
        while (remaining) {
            ssize_t written = write(fd, p, remaining);
            if (written < 0) {
                if (errno == EINTR) continue;
                ok = cg_err_io(err, "write", errno);
                break;
            }
            p += written;
            remaining -= (size_t)written;
        }
        done += count;
    }
    free(chunk);
    close(fd);
    return ok;
}

static uint8_t *read_file(const char *path, size_t *len, cg_error *err) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        cg_err_io(err, "read", errno);
        return NULL;
    }
    cg_buf buf = {0};
    uint8_t chunk[64 * 1024];
    while (true) {
        ssize_t got = read(fd, chunk, sizeof(chunk));
        if (got < 0) {
            if (errno == EINTR) continue;
            int error = errno;
            close(fd);
            cg_buf_free(&buf);
            cg_err_io(err, "read", error);
            return NULL;
        }
        if (got == 0) break;
        cg_buf_put(&buf, chunk, (size_t)got);
    }
    close(fd);
    *len = buf.len;
    return (uint8_t *)cg_buf_take(&buf);
}

/* C strings end at the first NUL: a path with an embedded NUL would be truncated before
 * reaching the path guards. Rust rejects such paths as `invalid_separator` (paths.rs); do the
 * same here. Returns false with *err when `key` holds a string with a NUL. */
static bool reject_nul_path(const cj *input, const char *key, cg_error *err) {
    const cj *value = cj_get(input, key);
    if (cj_is_str(value) && strlen(value->v.s.ptr) != value->v.s.len)
        return cg_err_set(err, "invalid_separator", "Invalid path separator");
    return true;
}

static cj *hex_value(const uint8_t *bytes, size_t len) { return cj_str_own(cg_text_hex_encode(bytes, len)); }

/* ---- operations (each returns the result, or NULL with *err) */

static cj *contract_policy(const char *name, const cj *input, cg_error *err, bool *handled) {
    *handled = true;
    if (strcmp(name, "periodCheckDelay") == 0) {
        int64_t seconds;
        if (!req_i64(input, "seconds", &seconds, err)) return NULL;
        return cj_objv("normalizedSeconds", cj_i64(cg_policy_normalized_period_check_delay_seconds(seconds)), NULL);
    }
    if (strcmp(name, "autoUpdateMode") == 0) {
        const char *value;
        if (!opt_str(input, "mode", &value, err)) return NULL;
        const char *mode = cg_policy_normalized_auto_update_mode(value);
        return cj_objv("mode", cj_str(mode), "enabled", cj_bool(cg_policy_is_auto_update_mode_enabled(mode)),
                       "directUpdateMode", cj_str(cg_policy_direct_update_mode_for_auto_update_mode(mode)),
                       "setNextBundle", cj_bool(cg_policy_should_auto_update_mode_set_next_bundle(mode)), NULL);
    }
    if (strcmp(name, "legacyDirectUpdateAutoMode") == 0) {
        const char *mode;
        if (!req_str(input, "directUpdateMode", &mode, err)) return NULL;
        return cj_objv("mode", cj_str(cg_policy_auto_update_mode_for_legacy_direct_update_mode(mode)), NULL);
    }
    if (strcmp(name, "onLaunchDirectUpdateConsumption") == 0) {
        const char *mode;
        bool planned;
        if (!req_str(input, "mode", &mode, err) || !req_bool(input, "plannedDirectUpdate", &planned, err))
            return NULL;
        return cj_objv("consume", cj_bool(cg_policy_should_consume_on_launch_direct_update(mode, planned)), NULL);
    }
    if (strcmp(name, "updateResponseKind") == 0) {
        const char *kind;
        if (!opt_str(input, "kind", &kind, err)) return NULL;
        return cj_objv("kind", cj_str(cg_policy_normalized_update_response_kind(kind)), NULL);
    }
    if (strcmp(name, "shakeMenuGesture") == 0) {
        const char *value;
        if (!opt_str(input, "value", &value, err)) return NULL;
        return cj_objv("gesture", cj_str(cg_policy_normalized_shake_menu_gesture(value)), NULL);
    }
    if (strcmp(name, "webViewErrorStatsAction") == 0) {
        const char *type;
        if (!str_or_empty(input, "type", &type, err)) return NULL;
        return cj_objv("action", cj_str(cg_policy_stats_action_for_webview_error_type(type)), NULL);
    }
    if (strcmp(name, "foreignBundleReset") == 0) {
        const char *bundle_path;
        bool is_builtin, has_stored;
        if (!opt_str(input, "bundlePath", &bundle_path, err) || !req_bool(input, "isBuiltin", &is_builtin, err) ||
            !req_bool(input, "hasStoredBundleInfo", &has_stored, err))
            return NULL;
        return cj_objv("reset", cj_bool(cg_policy_should_reset_for_foreign_bundle(bundle_path, is_builtin, has_stored)),
                       NULL);
    }
    if (strcmp(name, "clearPersistedDefaultChannel") == 0) {
        bool persist, reset, changed, restored;
        if (!req_bool(input, "persistDefaultChannelOnReinstall", &persist, err) ||
            !req_bool(input, "resetWhenUpdate", &reset, err) ||
            !req_bool(input, "nativeBuildVersionChanged", &changed, err) ||
            !req_bool(input, "restoredReinstall", &restored, err))
            return NULL;
        return cj_objv("clear",
                       cj_bool(cg_policy_should_clear_persisted_default_channel(persist, reset, changed, restored)),
                       NULL);
    }
    if (strcmp(name, "manifestConcurrency") == 0) {
        int64_t count;
        if (!req_i64(input, "processorCount", &count, err)) return NULL;
        return cj_objv("maxConcurrentFiles", cj_i64(cg_policy_manifest_max_concurrent_files(count)), NULL);
    }
    if (strcmp(name, "bundleStatus") == 0) {
        const char *value;
        if (!opt_str(input, "value", &value, err)) return NULL;
        return cj_objv("status", cj_str(cg_bundle_parse_bundle_status(value)), NULL);
    }
    *handled = false;
    return NULL;
}

static cj *contract_http(const char *name, const cj *input, cg_error *err, bool *handled) {
    *handled = true;
    if (strcmp(name, "userAgent") == 0) {
        const char *app_id, *plugin_version, *version_os, *platform;
        if (!str_or_empty(input, "appId", &app_id, err) || !str_or_empty(input, "pluginVersion", &plugin_version, err) ||
            !str_or_empty(input, "versionOs", &version_os, err) || !req_str(input, "platform", &platform, err))
            return NULL;
        return cj_objv("userAgent", cj_str_own(cg_http_user_agent(app_id, plugin_version, version_os, platform)),
                       NULL);
    }
    if (strcmp(name, "retryableHttpStatus") == 0) {
        int64_t status;
        if (!req_i64(input, "status", &status, err)) return NULL;
        return cj_objv("retryable", cj_bool(cg_http_is_retryable_http_status(status)), NULL);
    }
    if (strcmp(name, "contentRange") == 0) {
        const char *header;
        if (!opt_str(input, "header", &header, err)) return NULL;
        cg_content_range range;
        if (!cg_http_parse_content_range(header, &range)) return cj_objv("range", cj_null(), NULL);
        return cj_objv("range",
                       cj_objv("start", cj_i64(range.start), "end", cj_i64(range.end), "total", cj_i64(range.total),
                               NULL),
                       NULL);
    }
    if (strcmp(name, "zipResumePlan") == 0) {
        int64_t code, downloaded;
        const char *content_range;
        if (!req_i64(input, "responseCode", &code, err) || !req_i64(input, "downloadedBytes", &downloaded, err) ||
            !opt_str(input, "contentRange", &content_range, err))
            return NULL;
        cg_zip_write_plan plan;
        const char *error_code;
        if (!cg_http_plan_zip_resume_write(code, downloaded, content_range, &plan, &error_code)) {
            cg_err_set(err, error_code, "%s", error_code);
            return NULL;
        }
        return cj_objv("responseCode", cj_i64(plan.response_code), "writeOffset", cj_i64(plan.write_offset), NULL);
    }
    if (strcmp(name, "appendHttpBody") == 0) {
        int64_t status, existing;
        if (!req_i64(input, "statusCode", &status, err) || !req_i64(input, "existingBytes", &existing, err))
            return NULL;
        return cj_objv("append", cj_bool(cg_http_should_append_http_body(status, existing)), NULL);
    }
    if (strcmp(name, "rateLimitDeadline") == 0) {
        const char *retry_after, *body;
        int64_t now;
        if (!opt_str(input, "retryAfter", &retry_after, err) || !opt_str(input, "body", &body, err) ||
            !req_i64(input, "nowMs", &now, err))
            return NULL;
        return cj_objv("blockedUntilMs", cj_i64(cg_http_rate_limit_blocked_until_ms(retry_after, body, now)), NULL);
    }
    if (strcmp(name, "remoteError") == 0) {
        const char *body;
        if (!opt_str(input, "body", &body, err)) return NULL;
        char *error, *message;
        cg_http_parse_remote_error(body, &error, &message);
        return cj_objv("error", cj_str_own(error), "message", cj_str_own(message), NULL);
    }
    *handled = false;
    return NULL;
}

static cj *contract_paths(const char *name, const cj *input, cg_error *err, bool *handled) {
    *handled = true;
    if (strcmp(name, "pathTraversalSegment") == 0) {
        const char *path;
        if (!req_str(input, "path", &path, err)) return NULL;
        return cj_objv("traversal", cj_bool(cg_paths_contains_path_traversal_segment(path)), NULL);
    }
    if (strcmp(name, "resolvePathInside") == 0) {
        const char *base, *path;
        if (!req_str(input, "base", &base, err) || !req_str(input, "path", &path, err) ||
            !reject_nul_path(input, "path", err))
            return NULL;
        char *resolved = cg_paths_resolve_path_inside(base, path, err);
        return resolved ? cj_objv("path", cj_str_own(resolved), NULL) : NULL;
    }
    if (strcmp(name, "manifestTargetPath") == 0) {
        const char *base, *file_name;
        if (!req_str(input, "base", &base, err) || !req_str(input, "fileName", &file_name, err) ||
            !reject_nul_path(input, "fileName", err))
            return NULL;
        char *resolved = cg_paths_resolve_manifest_target_path(base, file_name, err);
        return resolved ? cj_objv("path", cj_str_own(resolved), NULL) : NULL;
    }
    if (strcmp(name, "builtinAssetPath") == 0) {
        const char *file_name;
        if (!req_str(input, "fileName", &file_name, err) || !reject_nul_path(input, "fileName", err)) return NULL;
        char *resolved = cg_paths_builtin_asset_path(file_name, err);
        return resolved ? cj_objv("assetPath", cj_str_own(resolved), NULL) : NULL;
    }
    if (strcmp(name, "safeCacheHash") == 0) {
        const char *hash;
        if (!opt_str(input, "hash", &hash, err)) return NULL;
        return cj_objv("safe", cj_bool(cg_paths_is_safe_cache_hash(hash)), NULL);
    }
    if (strcmp(name, "reusableCacheFile") == 0) {
        const char *hash;
        bool has_size;
        int64_t size = 0;
        if (!opt_str(input, "hash", &hash, err) || !opt_i64(input, "size", &has_size, &size, err)) return NULL;
        return cj_objv("reusable", cj_bool(cg_paths_is_reusable_cache_file(hash, has_size, size)), NULL);
    }
    if (strcmp(name, "manifestPartialName") == 0) {
        const char *hash, *file_name;
        if (!opt_str(input, "hash", &hash, err) || !str_or_empty(input, "fileName", &file_name, err)) return NULL;
        return cj_objv("name", cj_str_own(cg_paths_manifest_partial_name(hash, file_name)), NULL);
    }
    if (strcmp(name, "shortPathKey") == 0) {
        const char *value;
        if (!str_or_empty(input, "value", &value, err)) return NULL;
        return cj_objv("key", cj_str_own(cg_checksum_short_path_key(value)), NULL);
    }
    *handled = false;
    return NULL;
}

static cj *session_key_value(const cg_session_key *session) {
    return cj_objv("keyHex", hex_value(session->key, 16), "ivHex", hex_value(session->iv, 16), NULL);
}

static cj *contract_crypto(const char *name, const cj *input, cg_error *err, bool *handled) {
    *handled = true;
    if (strcmp(name, "sessionKeyValid") == 0) {
        const char *session_key;
        if (!opt_str(input, "sessionKey", &session_key, err)) return NULL;
        return cj_objv("valid", cj_bool(cg_crypto_is_valid_session_key(session_key)), NULL);
    }
    if (strcmp(name, "keyId") == 0) {
        const char *public_key;
        if (!str_or_empty(input, "publicKey", &public_key, err)) return NULL;
        return cj_objv("keyId", cj_str_own(cg_crypto_key_id(public_key)), NULL);
    }
    if (strcmp(name, "publicKeyValid") == 0) {
        const char *public_key;
        if (!str_or_empty(input, "publicKey", &public_key, err)) return NULL;
        cg_error parse_error = CG_ERROR_INIT;
        cg_rsa_public_key *key = cg_rsa_from_pem(public_key, &parse_error);
        cg_err_clear(&parse_error);
        cg_rsa_release(key);
        return cj_objv("valid", cj_bool(key != NULL), NULL);
    }
    if (strcmp(name, "checksumFile") == 0) {
        size_t len;
        uint8_t *content = hex(input, "contentHex", &len, err);
        if (!content) return NULL;
        bool has_repeat;
        int64_t repeat = 1;
        const char *temp_dir;
        if (!opt_i64(input, "repeat", &has_repeat, &repeat, err) || !req_str(input, "tempDir", &temp_dir, err)) {
            free(content);
            return NULL;
        }
        if (!has_repeat) repeat = 1;
        char *path = path_join(temp_dir, "checksum.bin");
        cj *out = NULL;
        if (write_file(path, content, len, (size_t)repeat, err)) {
            char *checksum = cg_checksum_sha256_file(path, err);
            if (checksum) out = cj_objv("checksum", cj_str_own(checksum), NULL);
        }
        free(path);
        free(content);
        return out;
    }
    if (strcmp(name, "decryptChecksum") == 0) {
        const char *checksum, *public_key;
        if (!str_or_empty(input, "checksum", &checksum, err) || !str_or_empty(input, "publicKey", &public_key, err))
            return NULL;
        char *decrypted = cg_crypto_decrypt_checksum(checksum, public_key, err);
        return decrypted ? cj_objv("checksum", cj_str_own(decrypted), NULL) : NULL;
    }
    /* What download.c runs on a zip: session key, then in-place AES-CBC decryption. */
    if (strcmp(name, "decryptFile") == 0) {
        const char *temp_dir, *public_key, *session_key;
        if (!req_str(input, "tempDir", &temp_dir, err)) return NULL;
        size_t len;
        uint8_t *ciphertext = hex(input, "ciphertextHex", &len, err);
        if (!ciphertext) return NULL;
        char *path = path_join(temp_dir, "bundle.zip");
        cj *out = NULL;
        bool ok = write_file(path, ciphertext, len, 1, err) && str_or_empty(input, "publicKey", &public_key, err) &&
                  str_or_empty(input, "sessionKey", &session_key, err);
        cg_session_key session;
        bool has_key = false;
        ok = ok && cg_crypto_bundle_session_key(public_key, session_key, &session, &has_key, err);
        if (ok && has_key) {
            char *hash = cg_aes_cbc_decrypt_file_in_place_hashed(path, session.key, session.iv, err);
            ok = hash != NULL;
            free(hash);
        }
        if (ok) {
            size_t plain_len;
            uint8_t *plain = read_file(path, &plain_len, err);
            if (plain) out = cj_objv("plaintextHex", hex_value(plain, plain_len), NULL);
            free(plain);
        }
        free(path);
        free(ciphertext);
        return out;
    }
    if (strcmp(name, "rsaPublicDecrypt") == 0) {
        const char *pem;
        if (!req_str(input, "publicKey", &pem, err)) return NULL;
        cg_rsa_public_key *key = cg_rsa_from_pem(pem, err);
        if (!key) return NULL;
        size_t len, plain_len;
        uint8_t *ciphertext = hex(input, "ciphertextHex", &len, err);
        uint8_t *plain = ciphertext ? cg_rsa_public_decrypt(key, ciphertext, len, &plain_len, err) : NULL;
        cj *out = plain ? cj_objv("plaintextHex", hex_value(plain, plain_len), NULL) : NULL;
        free(plain);
        free(ciphertext);
        cg_rsa_release(key);
        return out;
    }
    *handled = false;
    return NULL;
}

static cj *primitives(const char *name, const cj *input, cg_error *err, bool *handled) {
    *handled = true;
    if (strcmp(name, "rsaKeyFromDer") == 0) {
        size_t len;
        uint8_t *der = hex(input, "derHex", &len, err);
        if (!der) return NULL;
        cg_error parse_error = CG_ERROR_INIT;
        cg_rsa_public_key *key = cg_rsa_from_der(der, len, &parse_error);
        cg_err_clear(&parse_error);
        free(der);
        cg_rsa_release(key);
        return cj_objv("valid", cj_bool(key != NULL), NULL);
    }
    if (strcmp(name, "rsaPublicOp") == 0) {
        size_t der_len, value_len, out_len;
        uint8_t *der = hex(input, "derHex", &der_len, err);
        if (!der) return NULL;
        cg_rsa_public_key *key = cg_rsa_from_der(der, der_len, err);
        free(der);
        if (!key) return NULL;
        uint8_t *value = hex(input, "inputHex", &value_len, err);
        uint8_t *output = value ? cg_rsa_public_op(key, value, value_len, &out_len, err) : NULL;
        cj *out = output ? cj_objv("outputHex", hex_value(output, out_len), NULL) : NULL;
        free(output);
        free(value);
        cg_rsa_release(key);
        return out;
    }
    if (strcmp(name, "rsaUnpadType1") == 0) {
        size_t len, payload_len;
        uint8_t *block = hex(input, "blockHex", &len, err);
        if (!block) return NULL;
        uint8_t *payload = cg_rsa_unpad_type1(block, len, &payload_len);
        cj *out = cj_objv("payloadHex", payload ? hex_value(payload, payload_len) : cj_null(), NULL);
        free(payload);
        free(block);
        return out;
    }
    if (strcmp(name, "sessionKey") == 0) {
        const char *public_key, *session_key;
        if (!str_or_empty(input, "publicKey", &public_key, err) || !str_or_empty(input, "sessionKey", &session_key, err))
            return NULL;
        cg_session_key session;
        bool has_key;
        if (!cg_crypto_bundle_session_key(public_key, session_key, &session, &has_key, err)) return NULL;
        return cj_objv("session", has_key ? session_key_value(&session) : cj_null(), NULL);
    }
    /* Streaming AES-128-CBC with PKCS#7: `chunkSize` bytes per update. */
    if (strcmp(name, "aesCbcDecrypt") == 0) {
        size_t len;
        uint8_t *ciphertext = hex(input, "ciphertextHex", &len, err);
        if (!ciphertext) return NULL;
        bool has_chunk;
        int64_t chunk = 0;
        uint8_t key[16], iv[16];
        if (!opt_i64(input, "chunkSize", &has_chunk, &chunk, err) || !block16(input, "keyHex", key, err) ||
            !block16(input, "ivHex", iv, err)) {
            free(ciphertext);
            return NULL;
        }
        if (!has_chunk) chunk = len > 1 ? (int64_t)len : 1;
        if (chunk < 1) chunk = 1;
        cg_cbc_decryptor decryptor;
        cg_cbc_init(&decryptor, key, iv);
        cg_buf plain = {0};
        for (size_t offset = 0; offset < len; offset += (size_t)chunk) {
            size_t part = len - offset < (size_t)chunk ? len - offset : (size_t)chunk;
            cg_cbc_update_buf(&decryptor, ciphertext + offset, part, &plain);
        }
        free(ciphertext);
        cj *out = NULL;
        if (cg_cbc_finish_buf(&decryptor, &plain, err))
            out = cj_objv("plaintextHex", hex_value((const uint8_t *)plain.data, plain.len), NULL);
        cg_buf_free(&plain);
        return out;
    }
    if (strcmp(name, "decryptFileInPlace") == 0) {
        const char *path;
        uint8_t key[16], iv[16];
        if (!req_str(input, "path", &path, err) || !block16(input, "keyHex", key, err) ||
            !block16(input, "ivHex", iv, err))
            return NULL;
        char *hash = cg_aes_cbc_decrypt_file_in_place_hashed(path, key, iv, err);
        return hash ? cj_objv("hash", cj_str_own(hash), NULL) : NULL;
    }
    if (strcmp(name, "decryptFileTo") == 0) {
        const char *source, *destination;
        uint8_t key[16], iv[16];
        if (!req_str(input, "source", &source, err) || !req_str(input, "destination", &destination, err) ||
            !block16(input, "keyHex", key, err) || !block16(input, "ivHex", iv, err))
            return NULL;
        char *hash = cg_aes_cbc_decrypt_file_to(source, destination, key, iv, err);
        return hash ? cj_objv("hash", cj_str_own(hash), NULL) : NULL;
    }
    if (strcmp(name, "sha256File") == 0) {
        const char *path;
        if (!req_str(input, "path", &path, err)) return NULL;
        char *checksum = cg_checksum_sha256_file(path, err);
        return checksum ? cj_objv("checksum", cj_str_own(checksum), NULL) : NULL;
    }
    *handled = false;
    return NULL;
}

bool cg_testing_pure(const char *name, const cj *input, cj **result, cg_error *err) {
    static cj *(*const GROUPS[])(const char *, const cj *, cg_error *, bool *) = {
        contract_policy, contract_http, contract_paths, contract_crypto, primitives,
    };
    for (size_t i = 0; i < sizeof(GROUPS) / sizeof(GROUPS[0]); i++) {
        bool handled;
        cj *value = GROUPS[i](name, input, err, &handled);
        if (handled) {
            *result = value;
            return true;
        }
    }
    return false;
}
