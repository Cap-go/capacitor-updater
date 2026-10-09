/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#include "api.h"

#include <stdlib.h>
#include <string.h>

#include "paths.h"
#ifdef CAPGO_TEST_SUPPORT
#include "testing.h"
#endif

static const char *req_str(const cj *input, const char *key, cg_error *err) {
    cj *value = cj_get(input, key);
    if (cj_is_str(value)) return cj_as_str(value);
    if (cj_is_null(value)) cg_err_invalid_input(err, "`%s` is required", key);
    else cg_err_invalid_input(err, "`%s` must be a string", key);
    return NULL;
}

cj *cg_api_call(const char *operation, const cj *input, cg_error *err) {
    cj empty = {.type = CJ_OBJECT};
    if (cj_is_null(input)) input = &empty;
    if (!cj_is_obj(input)) {
        cg_err_invalid_input(err, "input must be a JSON object");
        return NULL;
    }
    if (strcmp(operation, "resolvePathInside") == 0) {
        const char *base = req_str(input, "base", err);
        if (!base) return NULL;
        const char *path = req_str(input, "path", err);
        if (!path) return NULL;
        char *resolved = cg_paths_resolve_path_inside(base, path, err);
        if (!resolved) return NULL;
        return cj_objv("path", cj_str_own(resolved), NULL);
    }
#ifdef CAPGO_TEST_SUPPORT
    if (strncmp(operation, CG_TEST_PREFIX, strlen(CG_TEST_PREFIX)) == 0)
        return cg_testing_call(operation + strlen(CG_TEST_PREFIX), input, err);
#endif
    cg_err_set(err, "unknown_operation", "Unknown core operation: %s", operation);
    return NULL;
}

char *cg_api_envelope(cj *value, const cg_error *err) {
    cj *envelope;
    if (err && err->code) {
        cj_free(value);
        envelope = cj_objv("ok", cj_bool(false), "error",
                           cj_objv("code", cj_str(err->code), "message", cj_str(cg_or_empty(err->message)), NULL),
                           NULL);
    } else {
        envelope = cj_objv("ok", cj_bool(true), "value", value ? value : cj_null(), NULL);
    }
    char *text = cj_print(envelope);
    cj_free(envelope);
    return text;
}

char *cg_api_call_json(const char *operation, const char *input_json) {
    cg_error err = CG_ERROR_INIT;
    cj *value = NULL;
    size_t start, len;
    cg_trim_range(input_json, &start, &len);
    if (len == 0) {
        value = cg_api_call(operation, NULL, &err);
    } else {
        char *parse_error = NULL;
        cj *input = cj_parse(input_json, &parse_error);
        if (!input) {
            cg_err_invalid_input(&err, "Invalid JSON input: %s", parse_error);
        } else {
            value = cg_api_call(operation, input, &err);
            cj_free(input);
        }
        free(parse_error);
    }
    char *out = cg_api_envelope(value, &err);
    cg_err_clear(&err);
    return out;
}
