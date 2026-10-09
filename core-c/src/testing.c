/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Dispatch of the test-only operations (Rust testing.rs) to the module test files. */

#include "testing.h"

#include <stddef.h>

/* Each returns false when `name` is not one of its operations. Weak: a module may be missing
 * while the port is in progress. */
extern bool cg_testing_pure(const char *name, const cj *input, cj **result, cg_error *err) __attribute__((weak));
extern bool cg_testing_archive(const char *name, const cj *input, cj **result, cg_error *err)
    __attribute__((weak));
extern bool cg_testing_net_pure(const char *name, const cj *input, cj **result, cg_error *err)
    __attribute__((weak));
extern bool cg_testing_net(struct cg_engine *engine, const char *name, const cj *input, cj **result, cg_error *err)
    __attribute__((weak));
extern bool cg_testing_engine(struct cg_engine *engine, const char *name, const cj *input, cj **result,
                              cg_error *err) __attribute__((weak));

cj *cg_testing_call(const char *name, const cj *input, cg_error *err) {
    cj *result = NULL;
    if (cg_testing_pure && cg_testing_pure(name, input, &result, err)) return result;
    if (cg_testing_archive && cg_testing_archive(name, input, &result, err)) return result;
    if (cg_testing_net_pure && cg_testing_net_pure(name, input, &result, err)) return result;
    cg_err_set(err, "unknown_operation", "Unknown test operation: " CG_TEST_PREFIX "%s", name);
    return NULL;
}

bool cg_testing_engine_call(struct cg_engine *engine, const char *name, const cj *input, cj **result,
                            cg_error *err) {
    if (cg_testing_net && cg_testing_net(engine, name, input, result, err)) return true;
    if (cg_testing_engine && cg_testing_engine(engine, name, input, result, err)) return true;
    return false;
}
