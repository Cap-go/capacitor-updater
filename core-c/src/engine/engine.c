/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* PLACEHOLDER engine (wave 1), see engine.h. */

#include "engine/engine.h"

#include <stdlib.h>
#include <string.h>

#include "api.h"
#ifdef CAPGO_TEST_SUPPORT
#include "testing.h"
#endif

cg_engine *cg_engine_create(const char *config_json, const CapgoHostCallbacks *callbacks, cg_error *err) {
    char *parse_error = NULL;
    size_t start, len;
    cg_trim_range(config_json, &start, &len);
    cj *config = len ? cj_parse(config_json, &parse_error) : cj_null();
    if (!config) {
        cg_err_invalid_input(err, "Invalid engine config: %s", parse_error);
        free(parse_error);
        return NULL;
    }
    cj_free(config);
    cg_engine *engine = cg_calloc(1, sizeof(cg_engine));
    engine->host.cb = *callbacks;
    atomic_init(&engine->refs, 1);
    return engine;
}

char *cg_engine_user_agent(cg_engine *engine) { return cg_strdup(""); }

char *cg_engine_call_json(cg_engine *engine, const char *operation, const char *input_json) {
    cg_error err = CG_ERROR_INIT;
    cj *value = NULL;
    char *parse_error = NULL;
    size_t start, len;
    cg_trim_range(input_json, &start, &len);
    cj *input = len ? cj_parse(input_json, &parse_error) : cj_obj();
    if (!input) {
        cg_err_invalid_input(&err, "Invalid JSON input: %s", parse_error);
    } else {
#ifdef CAPGO_TEST_SUPPORT
        if (strncmp(operation, CG_TEST_PREFIX, strlen(CG_TEST_PREFIX)) == 0 &&
            cg_testing_engine_call(engine, operation + strlen(CG_TEST_PREFIX), input, &value, &err))
            goto done;
#endif
        value = cg_api_call(operation, input, &err);
        if (cg_err_is(&err, "unknown_operation"))
            cg_err_set(&err, "unknown_operation", "Unknown engine operation: %s", operation);
    }
#ifdef CAPGO_TEST_SUPPORT
done:
#endif
    cj_free(input);
    free(parse_error);
    char *out = cg_api_envelope(value, &err);
    cg_err_clear(&err);
    return out;
}

void cg_engine_free_handle(cg_engine *engine) {
    if (atomic_fetch_sub(&engine->refs, 1) == 1) {
        cg_host_release(&engine->host);
        free(engine);
    }
}
