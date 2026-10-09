/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * JavaScript plugin methods (Rust engine/plugin/methods.rs). Hosts forward the call
 * arguments and settle the call with the result (`resolve` / `reject`); app store methods
 * stay native.
 */
#ifndef CG_PLUGIN_METHODS_H
#define CG_PLUGIN_METHODS_H

#include <stdbool.h>
#include <stddef.h>

#include "bundle.h"
#include "engine/engine_api.h"
#include "engine/plugin/plugin.h"
#include "rt/err.h"
#include "rt/json.h"

/* ENGINE_METHODS: methods implemented by the engine (everything but listeners and app store
 * APIs), in the Rust order, as an owned JSON array (`pluginMethods` operation).
 * Functions, not extern arrays: an undefined data symbol makes the library fail to load
 * while modules are missing (CAPGO_ALLOW_UNDEFINED), an undefined function does not. */
cj *cg_methods_engine_methods(void);
/* DETACHED_METHODS: engine methods hosts must not run on their serial method lane
 * (`detachedPluginMethods`), as an owned JSON array. */
cj *cg_methods_detached_methods(void);
/* DETACHED_METHODS.contains(name). */
bool cg_methods_is_detached(const char *name);

/* Downloads a bundle for `download()` / previews (session key and checksum rules apply).
 * manifest: JSON array or NULL (borrowed). CoreResult<BundleInfo> convention of download.h. */
bool cg_methods_download_bundle(cg_engine *engine, const char *url, const char *version, const char *session_key,
                                const char *checksum, const cj *manifest, cg_bundle_info *out, cg_error *err);
/* Dispatches one plugin method (MethodResult convention of plugin.h). */
cj *cg_methods_run_plugin_method(cg_engine *engine, const char *name, const cj *args, cg_rejection *rejection);

#endif
