/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Crash-loop breaker (Rust engine/crash_guard.rs). The steps that can take the process down
 * with them (a bundle download with its verification, decryption and extraction; applying a
 * new bundle) leave a marker in the key-value storage while they run (CG_KEY_CRASH_GUARD, one
 * record per version). A marker of another process still there at the next plugin load means
 * that process died in the step; two deaths in a row for the same version mark it failed.
 */
#ifndef CG_ENGINE_CRASH_GUARD_H
#define CG_ENGINE_CRASH_GUARD_H

#include <stdbool.h>

#include "bundle.h"
#include "engine/engine_api.h"
#include "rt/json.h"

#define CG_STEP_DOWNLOAD "download"
#define CG_STEP_SET "set"

/* step_version: the version a step on `bundle` is recorded under (its id without a version).
 * Borrowed from bundle. */
const char *cg_crash_guard_step_version(const cg_bundle_info *bundle);
/* begin_native_step: records that `step` starts for `version` (bundle `id`, may be ""). Every
 * call is paired with cg_crash_guard_end_native_step(version) (Rust: the NativeStep guard). */
void cg_crash_guard_begin_native_step(cg_engine *engine, const char *step, const char *version, const char *id);
void cg_crash_guard_end_native_step(cg_engine *engine, const char *version);
void cg_crash_guard_mark_native_steps_background(cg_engine *engine, bool background);
/* account_native_deaths: plugin load; exits = native.previousExits (array) or NULL. */
void cg_crash_guard_account_native_deaths(cg_engine *engine, const cj *exits);
bool cg_crash_guard_native_step_failed(cg_engine *engine, const char *version);
void cg_crash_guard_forget_native_steps_except(cg_engine *engine, const char *version);

#endif
