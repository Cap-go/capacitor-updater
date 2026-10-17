/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Stateless core operations (Rust api.rs): capgo_core_call and the engine fallback. */
#ifndef CG_API_H
#define CG_API_H

#include "rt/err.h"
#include "rt/json.h"

/* Runs one stateless operation. `input` NULL reads as {}. Returns an owned value or NULL with *err set. */
cj *cg_api_call(const char *operation, const cj *input, cg_error *err);
/* JSON text in (NULL / blank = {}), envelope text out (malloc'd). */
char *cg_api_call_json(const char *operation, const char *input_json);
/* {"ok":true,"value":...} / {"ok":false,"error":{code,message}}; takes ownership of value. */
char *cg_api_envelope(cj *value, const cg_error *err);

#endif
