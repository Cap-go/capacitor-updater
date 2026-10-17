/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Reload, `notifyAppReady` and rollback (Rust engine/plugin/ready.rs), plus the splash
 * screen. Uses engine->plugin.ready, .app_ready_check, .splash_timer and .confirmation.
 */
#ifndef CG_PLUGIN_READY_H
#define CG_PLUGIN_READY_H

#include <stdbool.h>
#include <stdint.h>

#include "bundle.h"
#include "engine/engine_api.h"
#include "rt/json.h"

/* The document-start script stamping notifyAppReady calls with `generation`. malloc'd. */
char *cg_ready_ready_generation_script(int64_t generation);

void cg_ready_arm_pending_ready_wait(cg_engine *engine);
void cg_ready_clear_pending_ready_wait(cg_engine *engine);
/* Waits until the ready signal count passes `token` or timeout_ms elapses. */
bool cg_ready_wait_for_app_ready(cg_engine *engine, uint64_t token, int64_t timeout_ms);
void cg_ready_send_ready_to_js(cg_engine *engine, const cg_bundle_info *current, const char *message);
/* Duration in ms. */
int64_t cg_ready_app_ready_check_timeout(cg_engine *engine);
void cg_ready_check_app_ready(cg_engine *engine, int64_t wait_ms);
void cg_ready_invalidate_app_ready_check(cg_engine *engine);
void cg_ready_check_revert(cg_engine *engine);
void cg_ready_disarm_ready_guard(cg_engine *engine, int64_t generation);
/* reported NULL = None. */
bool cg_ready_accepts_ready_call(cg_engine *engine, const int64_t *reported);
bool cg_ready_apply_current_bundle(cg_engine *engine);
void cg_ready_restore_live_bundle(cg_engine *engine);
bool cg_ready_reload_app(cg_engine *engine);
bool cg_ready_reload_without_waiting(cg_engine *engine);
bool cg_ready_apply_downloaded_bundle(cg_engine *engine, const cg_bundle_info *bundle);
/* Result<BundleInfo, String>: true with *out initialized, false with *error (malloc'd). */
bool cg_ready_set_and_reload(cg_engine *engine, const char *id, cg_bundle_info *out, char **error);
/* Result<(), String>: false with *error (malloc'd). */
bool cg_ready_reload_with_pending(cg_engine *engine, char **error);
bool cg_ready_perform_reset(cg_engine *engine, bool to_last_successful, bool use_pending_bundle, bool internal);
/* `notifyAppReady`; reported_generation NULL = None. Owned. */
cj *cg_ready_notify_app_ready(cg_engine *engine, const int64_t *reported_generation);
/* `getFailedUpdate`. Owned. */
cj *cg_ready_take_failed_update(cg_engine *engine);
void cg_ready_show_splashscreen(cg_engine *engine);
void cg_ready_hide_splashscreen(cg_engine *engine);

#endif
