/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* C ABI (include/capgo_updater_core.h), Rust ffi.rs. */

#include <stdlib.h>
#include <string.h>

#include "api.h"
#include "capgo_updater_core.h"
#include "engine/engine_api.h"
#include "host.h"

#define CG_EXPORT __attribute__((visibility("default")))

/* NULL reads as "", invalid UTF-8 is refused (Rust &str). */
static bool read_str(const char *value, cg_error *err) {
    if (value && !cg_utf8_valid(value, strlen(value)))
        return cg_err_invalid_input(err, "Arguments must be UTF-8");
    return true;
}

CG_EXPORT char *capgo_core_call(const char *operation, const char *input_json) {
    cg_error err = CG_ERROR_INIT;
    if (!read_str(operation, &err) || !read_str(input_json, &err)) {
        char *out = cg_api_envelope(NULL, &err);
        cg_err_clear(&err);
        return out;
    }
    return cg_api_call_json(operation ? operation : "", input_json);
}

CG_EXPORT void capgo_core_free(char *value) { free(value); }

CG_EXPORT CapgoEngine *capgo_engine_new(const char *config_json, CapgoHostCallbacks host) {
    cg_error err = CG_ERROR_INIT;
    cg_engine *engine = NULL;
    if (read_str(config_json, &err)) engine = cg_engine_create(config_json, &host, &err);
    if (!engine) {
        cg_host failed = {.cb = host};
        char *display = cg_err_display(&err);
        cg_host_logf(&failed, CG_ERROR, "Capgo engine init failed: %s", display);
        free(display);
        cg_err_clear(&err);
        cg_host_release(&failed);
        return NULL;
    }
    return (CapgoEngine *)engine;
}

CG_EXPORT char *capgo_engine_call(const CapgoEngine *engine, const char *operation, const char *input_json) {
    cg_error err = CG_ERROR_INIT;
    if (!engine) cg_err_invalid_input(&err, "Engine handle is NULL");
    else if (read_str(operation, &err) && read_str(input_json, &err))
        return cg_engine_call_json((cg_engine *)engine, operation ? operation : "", input_json);
    char *out = cg_api_envelope(NULL, &err);
    cg_err_clear(&err);
    return out;
}

CG_EXPORT void capgo_engine_free(CapgoEngine *engine) {
    if (engine) cg_engine_free_handle((cg_engine *)engine);
}
