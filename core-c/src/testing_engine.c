/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Engine test operations of Rust testing.rs `engine_call` (built with CAPGO_TEST_SUPPORT),
 * except `test.http`, which lives with the HTTP client tests (testing_net.c). */

#include <stdlib.h>
#include <string.h>

#include "engine/backend.h"
#include "engine/download.h"
#include "engine/engine.h"
#include "engine/plugin/plugin.h"
#include "testing.h"

bool cg_testing_engine(struct cg_engine *engine, const char *name, const cj *input, cj **result, cg_error *err);

static const char *req_str(const cj *input, const char *key, cg_error *err) {
    const cj *value = cj_get(input, key);
    if (cj_is_null(value)) {
        cg_err_invalid_input(err, "`%s` is required", key);
        return NULL;
    }
    if (!cj_is_str(value)) {
        char *shown = cj_print(value);
        cg_err_invalid_input(err, "`%s` must be a string, got %s", key, shown);
        free(shown);
        return NULL;
    }
    return cj_as_str(value);
}

bool cg_testing_engine(struct cg_engine *engine, const char *name, const cj *input, cj **result, cg_error *err) {
    if (strcmp(name, "waitForCleanup") == 0) {
        cg_plugin_wait_for_cleanup_for_tests(engine);
        *result = cj_obj();
    } else if (strcmp(name, "fetchJson") == 0) {
        const char *url = req_str(input, "url", err);
        *result = url ? cg_backend_fetch_json(engine, url, err) : NULL;
    } else if (strcmp(name, "pluginForeground") == 0) {
        /* Foreground handling and one `periodCheckDelay` tick, synchronously (hosts get them from
         * `appForeground` on a lifecycle thread and from the periodic thread). */
        cg_plugin_plugin_foreground_for_tests(engine);
        *result = cj_obj();
    } else if (strcmp(name, "pluginPeriodicTick") == 0) {
        cg_plugin_plugin_periodic_tick_for_tests(engine);
        *result = cj_obj();
    } else if (strcmp(name, "cleanupDownloadTempFiles") == 0) {
        /* The launch sweep of download leftovers (normally run by the plugin load flow). */
        cg_download_cleanup_download_temp_files(engine);
        *result = cj_obj();
    } else {
        return false;
    }
    return true;
}
