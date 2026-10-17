/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* manifest: the input is the JSON of an update reply (an object with `manifest`) or a
 * manifest array. Reads it like the engine does: the download request
 * (cg_download_request_from_json / to_json), the engine's manifest scan (`missingBundleFiles`:
 * file hashes decrypted with the public key, builtin, APK and delta-cache lookups) and the
 * per-entry path and cache-name guards. Rust: core/fuzz/fuzz_targets/manifest.rs. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "capgo_updater_core.h"
#include "engine/download.h"
#include "fuzz_support.h"
#include "path_check.h"
#include "paths.h"
#include "rt/json.h"
#include "rt/str.h"

static CapgoEngine *engine;

static void create_engine(void) {
    const char *dir = fz_scratch_dir();
    cj *config = cj_obj();
    cj_set(config, "platform", cj_str("android"));
    cj_set(config, "appId", cj_str("app.capgo.fuzz"));
    cj_set(config, "versionBuild", cj_str("1.0.0"));
    cj_set(config, "deviceId", cj_str("fuzz"));
    cj_set(config, "publicKey", cj_str(FZ_PUBLIC_KEY));
    cj_set(config, "storageRoot", cj_str_own(cg_fmt("%s", dir)));
    cj_set(config, "bundleRoot", cj_str_own(cg_fmt("%s/versions", dir)));
    cj_set(config, "cacheDir", cj_str_own(cg_fmt("%s/cache", dir)));
    cj_set(config, "builtinDir", cj_str_own(cg_fmt("%s/builtin", dir)));
    char *text = cj_print(config);
    engine = capgo_engine_new(text, fz_host_callbacks());
    if (!engine) fz_fail("engine refused the fuzz configuration");
    free(text);
    cj_free(config);
}

static void check_entry(const cj *entry) {
    const cj *file_name = cj_get(entry, "file_name");
    const cj *file_hash = cj_get(entry, "file_hash");
    if (!cj_is_str(file_name) || cj_str_has_nul(file_name)) return;
    const char *name = cj_as_str(file_name);
    cg_error err = CG_ERROR_INIT;
    char *target = cg_paths_resolve_manifest_target_path("/data/app/versions/b1", name, &err);
    if (target) fz_check_inside("/data/app/versions/b1", name, target);
    free(target);
    cg_err_clear(&err);
    if (cj_is_str(file_hash) && !cj_str_has_nul(file_hash)) {
        const char *hash = cj_as_str(file_hash);
        char *partial = cg_paths_manifest_partial_name(hash, name);
        if (strchr(partial, '/')) fz_fail("partial name %s has a separator", partial);
        free(partial);
        if (cg_paths_is_safe_cache_hash(hash)) {
            char *cache = cg_paths_cache_file_name(hash, name);
            if (strchr(cache, '/')) fz_fail("cache name %s has a separator", cache);
            free(cache);
        }
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (!engine) create_engine();
    char *error = NULL;
    cj *value = cj_parsen((const char *)data, size, &error);
    free(error);
    if (!value) return 0;

    const cj *manifest = cj_is_arr(value) ? value : cj_get(value, "manifest");
    if (cj_is_obj(value)) {
        cg_download_request request;
        cg_error err = CG_ERROR_INIT;
        if (cg_download_request_from_json(value, &request, &err)) {
            cj_free(cg_download_request_to_json(&request));
            cg_download_request_clear(&request);
        }
        cg_err_clear(&err);
    }
    if (cj_is_arr(manifest)) {
        for (size_t i = 0; i < cj_len(manifest); i++) check_entry(cj_at(manifest, i));
        cj *input = cj_obj();
        cj_set(input, "manifest", cj_clone(manifest));
        const cj *session_key = cj_get(value, "sessionKey");
        if (cj_is_str(session_key)) cj_set(input, "sessionKey", cj_clone(session_key));
        char *text = cj_print(input);
        capgo_core_free(capgo_engine_call(engine, "missingBundleFiles", text));
        free(text);
        cj_free(input);
    }
    cj_free(value);
    return 0;
}
