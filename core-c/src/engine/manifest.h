/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Manifest (delta) bundle downloads (Rust engine/manifest.rs): every file comes from the
 * builtin bundle, the APK assets, the delta cache or the network, with a worker pool of
 * cg_policy_manifest_max_concurrent_files threads (Rust thread::scope: the call joins every
 * worker before returning). Also the registration of in-flight download tokens.
 *
 * `manifest` arguments are JSON arrays of `{file_name, file_hash, download_url}` objects
 * (borrowed; NULL reads as []).
 */
#ifndef CG_ENGINE_MANIFEST_H
#define CG_ENGINE_MANIFEST_H

#include <stdbool.h>

#include "bundle.h"
#include "engine/download.h"
#include "engine/engine_api.h"
#include "rt/err.h"
#include "rt/json.h"

/* `{missing, total, missingCount, reusableCount}` for a manifest. Owned. */
cj *cg_manifest_missing_bundle_files(cg_engine *engine, const cj *manifest, const char *session_key);
/* Downloads a manifest bundle into `versions/<id>`. Blocking. CoreResult<BundleInfo>
 * convention of download.h. */
bool cg_manifest_download_manifest(cg_engine *engine, const cg_download_request *request, cg_bundle_info *out,
                                   cg_error *err);
/* Transfer + install of a started manifest download (download_manifest_inner). */
bool cg_manifest_download_manifest_inner(cg_engine *engine, const cg_download_request *request, const cj *manifest,
                                         const cg_bundle_info *record, const cg_cancel *cancel, cg_bundle_info *out,
                                         cg_error *err);
/* Registers a new token for `version` in engine->downloads. Returns it with one reference
 * for the caller (the map holds its own); pass it to unregister, then cg_cancel_release. */
cg_cancel *cg_manifest_register_download_token(cg_engine *engine, const char *version);
/* Removes this download's token only (another download of the version may still run). */
void cg_manifest_unregister_download_token(cg_engine *engine, const char *version, const cg_cancel *token);

#endif
