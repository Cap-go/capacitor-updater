/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Default channel persistence (reinstall handling, backup-excluded state files) and the
 * channel / latest-version plugin methods (Rust engine/plugin/channel.rs).
 * Methods follow the MethodResult convention of plugin.h.
 */
#ifndef CG_PLUGIN_CHANNEL_H
#define CG_PLUGIN_CHANNEL_H

#include <stdbool.h>

#include "engine/engine_api.h"
#include "engine/plugin/plugin.h"
#include "rt/err.h"
#include "rt/json.h"

/* What the preview snapshot file says about the channel to restore after a preview. */
typedef enum {
    CG_CHANNEL_SNAPSHOT_MISSING = 0,
    CG_CHANNEL_SNAPSHOT_INVALIDATED,
    CG_CHANNEL_SNAPSHOT_SNAPSHOT, /* Snapshot(channel): channel NULL = Snapshot(None) */
    CG_CHANNEL_SNAPSHOT_UNREADABLE,
} cg_channel_snapshot_kind;

typedef struct {
    cg_channel_snapshot_kind kind;
    char *channel; /* CG_CHANNEL_SNAPSHOT_SNAPSHOT only; malloc'd or NULL */
} cg_channel_snapshot;

void cg_channel_snapshot_clear(cg_channel_snapshot *snapshot);

/* Authoritative default channel state (excluded from backups). */
typedef struct {
    bool exists;
    char *channel; /* NULL = None */
    bool readable;
} cg_channel_state;

void cg_channel_state_clear(cg_channel_state *state);

/* *out initialized. */
void cg_channel_default_channel_state(cg_engine *engine, cg_channel_state *out);
void cg_channel_channel_snapshot(cg_engine *engine, cg_channel_snapshot *out);
/* io::Result<()>: false with *err (io error, see fsutil.h). */
bool cg_channel_write_channel_snapshot(cg_engine *engine, const cg_channel_snapshot *snapshot, cg_error *err);
/* malloc'd, NULL = None. */
char *cg_channel_persisted_default_channel(cg_engine *engine);
bool cg_channel_persist_default_channel_state_from_store(cg_engine *engine);
void cg_channel_prepare_default_channel(cg_engine *engine, bool native_build_changed);
void cg_channel_restore_preview_previous_default_channel(cg_engine *engine);
bool cg_channel_snapshot_default_channel_for_preview(cg_engine *engine);

cj *cg_channel_method_set_channel(cg_engine *engine, const cj *args, cg_rejection *rejection);
cj *cg_channel_method_unset_channel(cg_engine *engine, const cj *args, cg_rejection *rejection);
cj *cg_channel_method_get_channel(cg_engine *engine, cg_rejection *rejection);
cj *cg_channel_method_list_channels(cg_engine *engine, cg_rejection *rejection);
cj *cg_channel_method_get_latest(cg_engine *engine, const cj *args, cg_rejection *rejection);
/* `shakeMenuSwitchChannel` operation. Owned. */
cj *cg_channel_shake_menu_switch_channel(cg_engine *engine, const char *channel);

#endif
