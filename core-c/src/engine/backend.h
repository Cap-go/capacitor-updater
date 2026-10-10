/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Capgo backend client (Rust engine/backend.rs): update checks, channels, bundle size, and
 * the process-wide 429 (rate limit) block shared by every request.
 *
 * The rate-limit state is process-wide (a static in backend.c guarded by its own mutex, a
 * leaf lock: Rust takes `self.config()` inside it, which never blocks here).
 *
 * Rust `Map<String, Value>` results are owned JSON objects (`cj *`, never NULL).
 */
#ifndef CG_ENGINE_BACKEND_H
#define CG_ENGINE_BACKEND_H

#include <stdbool.h>

#include "engine/engine_api.h"
#include "net.h"
#include "rt/err.h"
#include "rt/json.h"

/* RemoteBlock. */
typedef struct {
    bool blocked;
    char *error;   /* never NULL ("" when not blocked) */
    char *message; /* never NULL */
} cg_remote_block;

void cg_remote_block_clear(cg_remote_block *block);

/* Device/app facts sent with every backend request. app_id_override NULL = None. Owned object. */
cj *cg_backend_info_object(cg_engine *engine, const char *app_id_override);
bool cg_backend_is_remote_blocked(cg_engine *engine);
/* Handles a 429: records the Retry-After block (longest wins) and sends the
 * `rate_limit_reached` statistic once (on a "stats" thread). *out initialized. */
void cg_backend_handle_rate_limit(cg_engine *engine, const cg_net_response *response, cg_remote_block *out);
/* Asks the backend for the latest bundle of this device's channel. NULL arguments = None. */
cj *cg_backend_get_latest(cg_engine *engine, const char *update_url, const char *channel,
                          const char *app_id_override);
cj *cg_backend_unset_channel(cg_engine *engine, const char *persist_key, const char *config_default_channel,
                             bool allow_set_default_channel);
cj *cg_backend_set_channel(cg_engine *engine, const char *channel, const char *persist_key,
                           bool allow_set_default_channel, const char *config_default_channel);
cj *cg_backend_get_channel(cg_engine *engine, const char *persist_key);
cj *cg_backend_list_channels(cg_engine *engine);
/* Asks `<updateUrl>/manifest_size` how much a manifest download weighs. `manifest`: a JSON
 * array (borrowed; NULL reads as []). version NULL = None. */
cj *cg_backend_bundle_download_size(cg_engine *engine, const char *update_url, const char *version,
                                    const cj *manifest);
/* GETs a JSON document (preview payloads) on the bundle-transfer client. Owned object, NULL
 * with *err (invalid_url, network_error, response_error, parse_error). */
cj *cg_backend_fetch_json(cg_engine *engine, const char *url, cg_error *err);
/* `<updateUrl>/manifest_size`, dropping the query string (also the `test.manifestSizeUrl`
 * stateless test operation). malloc'd. */
char *cg_backend_manifest_size_url(const char *update_url);

#endif
