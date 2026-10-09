/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Preview sessions (Rust engine/plugin/preview.rs): deep links, preview bundles, the
 * preview fallback and the preview plugin methods. Methods follow the MethodResult
 * convention of plugin.h; Rust `Result<(), Rejection>` is `bool f(..., cg_rejection *)`.
 */
#ifndef CG_PLUGIN_PREVIEW_H
#define CG_PLUGIN_PREVIEW_H

#include <stdbool.h>

#include "bundle.h"
#include "engine/engine_api.h"
#include "engine/plugin/plugin.h"
#include "rt/json.h"

bool cg_preview_is_preview_deep_link(const char *url);

/* Owned JSON array of preview infos (`previewMenuPreviews`). */
cj *cg_preview_list_preview_infos(cg_engine *engine, bool cleanup);
/* old_id NULL = None. Owned. */
cj *cg_preview_record_preview_bundle(cg_engine *engine, const cg_bundle_info *bundle, const char *old_id);
void cg_preview_set_active_app_id(cg_engine *engine, const char *app_id);
void cg_preview_clear_incoming_preview_transition(cg_engine *engine);
bool cg_preview_leave_preview_session(cg_engine *engine);
void cg_preview_leave_preview_for_launch_url(cg_engine *engine, const char *url);
/* `openUrl` operation: whether the app is leaving the preview. */
bool cg_preview_handle_open_url(cg_engine *engine, const char *url);
bool cg_preview_reload_preview_session(cg_engine *engine);
void cg_preview_clear_preview_session_for_native_build_change(cg_engine *engine);
void cg_preview_restore_preview_state_at_load(cg_engine *engine);
void cg_preview_show_preview_notice_if_needed(cg_engine *engine);

cj *cg_preview_method_start_preview_session(cg_engine *engine, const cj *args, cg_rejection *rejection);
cj *cg_preview_method_list_previews(cg_engine *engine, cg_rejection *rejection);
/* set_preview: true on success, false with *rejection. */
bool cg_preview_set_preview(cg_engine *engine, const char *id, const char *reason, cg_rejection *rejection);
cj *cg_preview_method_set_preview(cg_engine *engine, const cj *args, cg_rejection *rejection);
cj *cg_preview_method_reset_preview(cg_engine *engine, cg_rejection *rejection);
cj *cg_preview_method_delete_preview(cg_engine *engine, const cj *args, cg_rejection *rejection);
cj *cg_preview_method_preview_update(cg_engine *engine, const cj *args, bool download, cg_rejection *rejection);

#endif
