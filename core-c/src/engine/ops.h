/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Engine operation table (Rust engine/ops.rs): JSON in, JSON out. */
#ifndef CG_ENGINE_OPS_H
#define CG_ENGINE_OPS_H

#include <stdbool.h>

#include "engine/engine_api.h"
#include "rt/err.h"
#include "rt/json.h"

/* Engine::call_engine: false when `operation` is not an engine operation (the caller falls
 * back to the stateless ones). Otherwise true with *result (owned) or *err set. `input` is
 * a JSON object. */
bool cg_ops_call_engine(cg_engine *engine, const char *operation, const cj *input, cj **result, cg_error *err);

#endif
