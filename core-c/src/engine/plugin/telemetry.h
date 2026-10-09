/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Launch, lifecycle, health and WebView statistics, and download progress events (Rust
 * engine/plugin/telemetry.rs).
 */
#ifndef CG_PLUGIN_TELEMETRY_H
#define CG_PLUGIN_TELEMETRY_H

#include <stdbool.h>
#include <stdint.h>

#include "bundle.h"
#include "engine/engine_api.h"
#include "rt/json.h"

/* Strips query, fragment and sensitive path segments. malloc'd. */
char *cg_telemetry_sanitize_stats_url(const char *value);
/* Metadata object of a `reportWebViewError` payload (borrowed). Owned object. */
cj *cg_telemetry_webview_error_metadata(const cj *data);
/* Android ApplicationExitInfo reason -> stats action; NULL = None. Static string. */
const char *cg_telemetry_exit_reason_action(int64_t reason);
/* Static string. */
const char *cg_telemetry_exit_reason_name(int64_t reason);

void cg_telemetry_report_app_launch_start(cg_engine *engine);
void cg_telemetry_report_app_launch_ready(cg_engine *engine, const cg_bundle_info *bundle);
void cg_telemetry_report_app_launch_timeout(cg_engine *engine, const cg_bundle_info *bundle);
/* `os_version_changed` / `native_app_version_changed` (acknowledged writes, stats.h acks). */
void cg_telemetry_report_native_version_stats_if_changed(cg_engine *engine);
/* metadata: JSON object (borrowed; NULL reads as {}). */
void cg_telemetry_report_webview_stats(cg_engine *engine, const char *action, const cj *metadata);
void cg_telemetry_report_webview_error(cg_engine *engine, const cj *data);
/* exits: JSON array (borrowed). */
void cg_telemetry_report_previous_exits(cg_engine *engine, const cj *exits);
void cg_telemetry_report_previous_unclean_exit_and_start_session(cg_engine *engine);
void cg_telemetry_mark_session_foreground(cg_engine *engine, bool foreground);
void cg_telemetry_report_memory_warning(cg_engine *engine);
void cg_telemetry_persist_render_process_gone(cg_engine *engine, const cj *metadata);
void cg_telemetry_report_previous_render_process_gone(cg_engine *engine);
/* `download` progress event and `download_<bucket>` statistics. */
void cg_telemetry_notify_download(cg_engine *engine, const char *id, int64_t percent);
void cg_telemetry_forget_download_progress(cg_engine *engine, const char *id);

#endif
