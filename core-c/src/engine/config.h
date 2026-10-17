/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Engine configuration (Rust engine/config.rs): device facts, endpoints and storage layout
 * provided by the host at creation, plus runtime-mutable settings.
 *
 * A cg_engine_config is an immutable, reference-counted snapshot once published to the
 * engine (Rust `Arc<EngineConfig>`). Read it through cg_engine_config_snapshot (engine.h)
 * and release it; never modify a published snapshot. Changes go through
 * cg_engine_config_begin / cg_engine_config_commit (engine.h), which work on a private copy.
 *
 * Every string member is malloc'd and never NULL ("" when unset). Paths are plain strings
 * (Rust PathBuf); join them with cg_path_join (engine.h).
 */
#ifndef CG_ENGINE_CONFIG_H
#define CG_ENGINE_CONFIG_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "rt/err.h"
#include "rt/json.h"

/* Storage keys. Defaults are the keys every plugin version has used (Rust Keys). */
typedef struct {
    char *server_path;                 /* "serverBasePath" */
    char *info_suffix;                 /* "_info" */
    char *fallback;                    /* "pastVersion" */
    char *next;                        /* "nextVersion" */
    char *preview_fallback;            /* "previewFallbackVersion" */
    char *pending_deletes;             /* "pendingDeleteIds" */
    char *native_build_version;        /* "LatestNativeBuildVersion" */
    char *legacy_native_build_version; /* "LatestVersionNative" */
} cg_engine_keys;

typedef struct cg_engine_config {
    atomic_int refs; /* snapshot references (engine.h); 1 after from_json / clone */
    /* `android`, `ios`, or another host name; sent as `platform` to the backend. */
    char *platform;
    char *app_id;
    char *plugin_version;
    /* Builtin bundle version name (app marketing version). */
    char *version_build;
    char *version_code;
    char *version_os;
    char *device_id;
    char *custom_id;
    char *default_channel;
    bool is_emulator;
    bool is_prod;
    char *install_source;
    char *update_url;
    char *stats_url;
    char *channel_url;
    char *public_key;
    char *key_id;
    bool preview_session;
    /* Follow redirects that downgrade HTTPS to HTTP (off by default). */
    bool allow_https_to_http_redirect;
    uint64_t timeout_ms;
    /* Directory holding one sub-directory per downloaded bundle id. */
    char *bundle_root;
    /* Updater-owned storage root (temp unzip folders, download temp files). */
    char *storage_root;
    /* Directory for the persisted stats queue. */
    char *stats_dir;
    /* Delta cache directory (`capgo_downloads`). */
    char *cache_dir;
    /* Builtin web assets on disk (iOS `Bundle.main/public`, Android `filesDir/public`). */
    char *builtin_dir;
    /* Android APK holding `assets/public/...` (builtin reuse for delta downloads). */
    char *builtin_apk;
    /* Stored server path meaning "builtin" (`public` on Android, empty on iOS). */
    char *builtin_server_path;
    cg_engine_keys keys;
} cg_engine_config;

/* EngineConfig::from_json: a new config (refs = 1), NULL with *err ("bundleRoot is required",
 * invalid_public_key). `value` may be NULL / non-object (read as {}). */
cg_engine_config *cg_config_from_json(const cj *value, cg_error *err);
/* EngineConfig::apply: applies the runtime-mutable fields present in `value` (`configure`).
 * On error (invalid_public_key) fields before `publicKey` may already be applied: callers
 * apply to a copy (see Engine::configure). */
bool cg_config_apply(cg_engine_config *config, const cj *value, cg_error *err);
/* Deep copy with refs = 1 (EngineConfig::clone). */
cg_engine_config *cg_config_clone(const cg_engine_config *config);
/* Snapshot references. Release frees the config when the count reaches zero. NULL-safe. */
cg_engine_config *cg_config_retain(cg_engine_config *config);
void cg_config_release(cg_engine_config *config);

#endif
