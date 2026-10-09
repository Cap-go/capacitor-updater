/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* What ffi.c / jni.c need from the engine (Rust Engine::new / call_json / Drop). */
#ifndef CG_ENGINE_API_H
#define CG_ENGINE_API_H

#include "capgo_updater_core.h"
#include "rt/err.h"

typedef struct cg_engine cg_engine;

/* Creates an engine owning `callbacks` (released with the engine). NULL with *err on an invalid
 * configuration; the caller then still owns the callbacks (ffi.c logs and releases them). */
cg_engine *cg_engine_create(const char *config_json, const CapgoHostCallbacks *callbacks, cg_error *err);
/* Envelope text (malloc'd). Blocking, thread-safe. */
char *cg_engine_call_json(cg_engine *engine, const char *operation, const char *input_json);
/* Drops the host's reference (Rust capgo_engine_free): the engine is destroyed once no worker uses it. */
void cg_engine_free_handle(cg_engine *engine);

#endif
