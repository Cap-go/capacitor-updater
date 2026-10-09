/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Plugin load, app lifecycle and the auto-update cycle (Rust engine/plugin/flow.rs). */
#ifndef CG_PLUGIN_FLOW_H
#define CG_PLUGIN_FLOW_H

#include <stdbool.h>

#include "bundle.h"
#include "engine/engine_api.h"
#include "rt/err.h"
#include "rt/json.h"

/* How one update cycle ends (`endBackGroundTaskWithNotif`). Every pointer is borrowed. */
typedef struct {
    const char *message;
    const char *latest_version;
    const cg_bundle_info *current;
    bool error;
    bool planned_direct_update;
    bool send_stats;
    bool notify_no_need_update;
    /* Version the failure stat is about (NULL: the current bundle). */
    const char *stat_version;
} cg_cycle_end;

/* CycleEnd::new: send_stats and notify_no_need_update true, no stat_version. */
cg_cycle_end cg_flow_cycle_end(const char *message, const char *latest_version, const cg_bundle_info *current,
                               bool error, bool planned);

/* Capacitor `load()` (pluginLoad operation). Owned, NULL with *err. */
cj *cg_flow_load_plugin(cg_engine *engine, const cj *input, cg_error *err);
/* malloc'd. */
char *cg_flow_stored_native_build(cg_engine *engine);
void cg_flow_persist_native_build_version(cg_engine *engine);
void cg_flow_app_moved_to_foreground(cg_engine *engine);
void cg_flow_background_splash(cg_engine *engine);
void cg_flow_background_work(cg_engine *engine);
void cg_flow_app_terminated(cg_engine *engine);
void cg_flow_install_next(cg_engine *engine);
bool cg_flow_should_use_direct_update(cg_engine *engine);
void cg_flow_consume_on_launch_direct_update(cg_engine *engine, bool planned);
bool cg_flow_is_update_cycle_running(cg_engine *engine);
/* Starts the update cycle in the background. Static string result. */
const char *cg_flow_background_download(cg_engine *engine);
void cg_flow_end_update_cycle(cg_engine *engine, const cg_cycle_end *end);
void cg_flow_scheduled_download_waiting(cg_engine *engine, const char *version, bool waiting);
void cg_flow_scheduled_download_retrying(cg_engine *engine, const char *version);
/* Static string result. */
const char *cg_flow_trigger_update_check(cg_engine *engine);
/* One `periodCheckDelay` tick. */
void cg_flow_periodic_tick(cg_engine *engine);
/* `response`: the backend reply object (borrowed). */
void cg_flow_notify_breaking_events_if_needed(cg_engine *engine, const cj *response, const char *version);

#endif
