/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Engine configuration (Rust engine/config.rs). */

#include "engine/config.h"

#include <stdlib.h>
#include <string.h>

#include "crypto/crypto.h"
#include "crypto/rsa.h"

/* object[key] as a string, "" otherwise (Rust `text`). */
static char *text(const cj *object, const char *key) { return cg_strdup(cg_or_empty(cj_get_str(object, key))); }

static void set_text(char **field, const cj *object, const char *key) {
    if (cj_has(object, key)) cg_replace(field, text(object, key));
}

/* Rust Path::parent of a non-empty path, as a string ("" for None and for a bare name). */
static char *path_parent(const char *path) {
    size_t len = strlen(path);
    /* Trailing separators and `.` components do not count (Path::components). */
    while (true) {
        while (len > 1 && path[len - 1] == '/') len--;
        if (len >= 2 && path[len - 1] == '.' && path[len - 2] == '/') {
            len -= 2;
            continue;
        }
        break;
    }
    if (len == 1 && path[0] == '/') return cg_strdup(""); /* the root has no parent */
    size_t slash = len;
    while (slash > 0 && path[slash - 1] != '/') slash--;
    if (slash == 0) return cg_strdup(""); /* "name" -> Some("") */
    size_t end = slash - 1;
    while (end > 0 && path[end - 1] == '/') end--;
    if (end == 0) return cg_strdup("/");
    return cg_strndup(path, end);
}

static void keys_default(cg_engine_keys *keys) {
    keys->server_path = cg_strdup("serverBasePath");
    keys->info_suffix = cg_strdup("_info");
    keys->fallback = cg_strdup("pastVersion");
    keys->next = cg_strdup("nextVersion");
    keys->preview_fallback = cg_strdup("previewFallbackVersion");
    keys->pending_deletes = cg_strdup("pendingDeleteIds");
    keys->native_build_version = cg_strdup("LatestNativeBuildVersion");
    keys->legacy_native_build_version = cg_strdup("LatestVersionNative");
}

/* Every string member, for clone / free. */
#define CG_CONFIG_STRINGS(X)                                                                                         \
    X(platform)                                                                                                      \
    X(app_id)                                                                                                        \
    X(plugin_version)                                                                                                \
    X(version_build)                                                                                                 \
    X(version_code)                                                                                                  \
    X(version_os)                                                                                                    \
    X(device_id)                                                                                                     \
    X(custom_id)                                                                                                     \
    X(default_channel)                                                                                               \
    X(install_source)                                                                                                \
    X(update_url)                                                                                                    \
    X(stats_url)                                                                                                     \
    X(channel_url)                                                                                                   \
    X(public_key)                                                                                                    \
    X(key_id)                                                                                                        \
    X(bundle_root)                                                                                                   \
    X(storage_root)                                                                                                  \
    X(stats_dir)                                                                                                     \
    X(cache_dir)                                                                                                     \
    X(builtin_dir)                                                                                                   \
    X(builtin_apk)                                                                                                   \
    X(builtin_server_path)                                                                                           \
    CG_CONFIG_KEY_STRINGS(X)

#define CG_CONFIG_KEY_STRINGS(X)                                                                                     \
    X(keys.server_path)                                                                                              \
    X(keys.info_suffix)                                                                                              \
    X(keys.fallback)                                                                                                 \
    X(keys.next)                                                                                                     \
    X(keys.preview_fallback)                                                                                         \
    X(keys.pending_deletes)                                                                                          \
    X(keys.native_build_version)                                                                                     \
    X(keys.legacy_native_build_version)

static void config_free(cg_engine_config *config) {
#define X(field) free(config->field);
    CG_CONFIG_STRINGS(X)
#undef X
    free(config);
}

/* EngineConfig::default() with Keys::default(). */
static cg_engine_config *config_default(void) {
    cg_engine_config *config = cg_calloc(1, sizeof(cg_engine_config));
    atomic_init(&config->refs, 1);
#define X(field) config->field = cg_strdup("");
    CG_CONFIG_STRINGS(X)
#undef X
#define X(field) free(config->field);
    CG_CONFIG_KEY_STRINGS(X)
#undef X
    keys_default(&config->keys);
    return config;
}

cg_engine_config *cg_config_from_json(const cj *value, cg_error *err) {
    cj empty = {.type = CJ_OBJECT};
    const cj *object = cj_is_obj(value) ? value : &empty;
    cg_engine_config *config = config_default();
    cg_replace(&config->platform, text(object, "platform"));
    uint64_t timeout;
    config->timeout_ms = cj_as_u64(cj_get(object, "timeoutMs"), &timeout) ? timeout : 20000;
    config->is_prod = cj_get_bool(object, "isProd", true);
    cg_replace(&config->bundle_root, text(object, "bundleRoot"));
    cg_replace(&config->storage_root, text(object, "storageRoot"));
    cg_replace(&config->stats_dir, text(object, "statsDir"));
    cg_replace(&config->cache_dir, text(object, "cacheDir"));
    cg_replace(&config->builtin_dir, text(object, "builtinDir"));
    cg_replace(&config->builtin_apk, text(object, "builtinApk"));
    cg_replace(&config->builtin_server_path, text(object, "builtinServerPath"));
    if (!cg_config_apply(config, value, err)) {
        config_free(config);
        return NULL;
    }
    if (!*config->bundle_root) {
        config_free(config);
        cg_err_invalid_input(err, "bundleRoot is required");
        return NULL;
    }
    if (!*config->storage_root) cg_replace(&config->storage_root, path_parent(config->bundle_root));
    if (!*config->stats_dir) cg_replace(&config->stats_dir, cg_strdup(config->storage_root));
    const cj *keys = cj_get(object, "keys");
    if (cj_is_obj(keys)) {
        static const struct {
            size_t offset;
            const char *key;
        } overridable[] = {
            {offsetof(cg_engine_keys, server_path), "serverPath"},
            {offsetof(cg_engine_keys, fallback), "fallback"},
            {offsetof(cg_engine_keys, next), "next"},
            {offsetof(cg_engine_keys, preview_fallback), "previewFallback"},
            {offsetof(cg_engine_keys, pending_deletes), "pendingDeletes"},
        };
        for (size_t i = 0; i < sizeof overridable / sizeof overridable[0]; i++) {
            const char *override = cj_get_str(keys, overridable[i].key);
            if (override) cg_replace((char **)((char *)&config->keys + overridable[i].offset), cg_strdup(override));
        }
    }
    return config;
}

bool cg_config_apply(cg_engine_config *config, const cj *value, cg_error *err) {
    if (!cj_is_obj(value)) return true;
    const cj *object = value;
    set_text(&config->app_id, object, "appId");
    set_text(&config->plugin_version, object, "pluginVersion");
    set_text(&config->version_build, object, "versionBuild");
    set_text(&config->version_code, object, "versionCode");
    set_text(&config->version_os, object, "versionOs");
    set_text(&config->device_id, object, "deviceId");
    set_text(&config->custom_id, object, "customId");
    set_text(&config->default_channel, object, "defaultChannel");
    set_text(&config->install_source, object, "installSource");
    set_text(&config->update_url, object, "updateUrl");
    set_text(&config->stats_url, object, "statsUrl");
    set_text(&config->channel_url, object, "channelUrl");
    bool flag;
    if (cj_as_bool(cj_get(object, "isEmulator"), &flag)) config->is_emulator = flag;
    if (cj_as_bool(cj_get(object, "isProd"), &flag)) config->is_prod = flag;
    if (cj_as_bool(cj_get(object, "previewSession"), &flag)) config->preview_session = flag;
    if (cj_as_bool(cj_get(object, "allowHttpsToHttpRedirect"), &flag)) config->allow_https_to_http_redirect = flag;
    uint64_t timeout;
    if (cj_as_u64(cj_get(object, "timeoutMs"), &timeout)) config->timeout_ms = timeout;
    if (cj_has(object, "publicKey")) {
        const char *public_key = cg_or_empty(cj_get_str(object, "publicKey"));
        if (!*public_key) {
            cg_replace(&config->public_key, cg_strdup(""));
            cg_replace(&config->key_id, cg_strdup(""));
        } else {
            /* Any parseable RSA key loads, as on previous Android: a non-2048-bit key cannot
             * verify CLI checksums (one 256-byte block), so encrypted updates fail their
             * checksum, but the app still starts (previous iOS crashed at launch instead). */
            cg_error parse = CG_ERROR_INIT;
            cg_rsa_public_key *key = cg_rsa_from_pem(public_key, &parse);
            cg_err_clear(&parse);
            if (!key)
                return cg_err_set(err, "invalid_public_key",
                                  "Invalid public key in capacitor.config.json: failed to parse RSA key. Remove the "
                                  "key or provide a valid PEM-formatted RSA public key.");
            cg_rsa_release(key);
            cg_replace(&config->public_key, cg_strdup(public_key));
            cg_replace(&config->key_id, cg_crypto_key_id(public_key));
        }
    }
    return true;
}

cg_engine_config *cg_config_clone(const cg_engine_config *config) {
    cg_engine_config *copy = cg_malloc(sizeof(cg_engine_config));
    memcpy(copy, config, sizeof(cg_engine_config));
    atomic_init(&copy->refs, 1);
#define X(field) copy->field = cg_strdup(config->field);
    CG_CONFIG_STRINGS(X)
#undef X
    return copy;
}

cg_engine_config *cg_config_retain(cg_engine_config *config) {
    if (config) atomic_fetch_add(&config->refs, 1);
    return config;
}

void cg_config_release(cg_engine_config *config) {
    if (config && atomic_fetch_sub(&config->refs, 1) == 1) config_free(config);
}
