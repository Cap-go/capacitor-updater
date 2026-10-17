/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Test-only operations `test.<name>` (Rust testing.rs), built with CAPGO_TEST_SUPPORT. */
#ifndef CG_TESTING_H
#define CG_TESTING_H

#include "rt/err.h"
#include "rt/json.h"

#define CG_TEST_PREFIX "test."

struct cg_engine;

/* Stateless test operation (name without the prefix). */
cj *cg_testing_call(const char *name, const cj *input, cg_error *err);
/* Engine test operation; returns false when `name` is not one (then the stateless ones run). */
bool cg_testing_engine_call(struct cg_engine *engine, const char *name, const cj *input, cj **result,
                            cg_error *err);

#endif
