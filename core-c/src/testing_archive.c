/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Test-only archive operations (Rust testing.rs): extractZip, installExtracted, manifestSizeUrl. */

#include <stdlib.h>
#include <string.h>

#include "engine/archive.h"
#include "testing.h"

bool cg_testing_archive(const char *name, const cj *input, cj **result, cg_error *err);

/* req_str: NULL with invalid_input. */
static const char *req_str(const cj *input, const char *key, cg_error *err) {
    const cj *value = cj_get(input, key);
    if (!value || cj_is_null(value)) {
        cg_err_invalid_input(err, "`%s` is required", key);
        return NULL;
    }
    if (!cj_is_str(value)) {
        char *text = cj_print(value);
        cg_err_invalid_input(err, "`%s` must be a string, got %s", key, text);
        free(text);
        return NULL;
    }
    return cj_as_str(value);
}

static bool flag(const cj *input, const char *key) {
    bool value = false;
    return cj_as_bool(cj_get(input, key), &value) && value;
}

static bool always_cancelled(void *ctx) { return *(bool *)ctx; }

/* testing.rs extract_error: code = kind, message = the inner string. */
static const char *extract_code(cg_extract_kind kind) {
    switch (kind) {
    case CG_EXTRACT_WINDOWS_PATH: return "windows_path";
    case CG_EXTRACT_PATH_ESCAPE: return "path_escape";
    case CG_EXTRACT_DIRECTORY: return "directory";
    case CG_EXTRACT_CANCELLED: return "cancelled";
    default: return "failed";
    }
}

/* backend.rs manifest_size_url. */
static char *manifest_size_url(const char *update_url) {
    size_t len = strcspn(update_url, "?#");
    while (len && update_url[len - 1] == '/') len--;
    return cg_fmt("%.*s/manifest_size", (int)len, update_url);
}

bool cg_testing_archive(const char *name, const cj *input, cj **result, cg_error *err) {
    if (strcmp(name, "extractZip") == 0) {
        bool cancelled = flag(input, "cancelled");
        const char *zip = req_str(input, "zip", err);
        const char *destination = zip ? req_str(input, "destination", err) : NULL;
        if (!destination) return true;
        cg_extract_error error = CG_EXTRACT_ERROR_INIT;
        if (cg_archive_extract_zip(zip, destination, NULL, always_cancelled, &cancelled, &error)) {
            *result = cj_objv("error", cj_null(), NULL);
            return true;
        }
        const char *code = extract_code(error.kind);
        if (flag(input, "report")) {
            const char *stat = cg_extract_error_stat(&error);
            size_t message_len;
            char *text = cg_extract_error_message(&error, &message_len);
            cj *message = cj_strn(text, message_len);
            free(text);
            *result = cj_objv("error",
                              cj_objv("code", cj_str(code), "name", cj_strn(cg_or_empty(error.detail), error.detail_len),
                                      "stat", stat ? cj_str(stat) : cj_null(), "message", message, NULL),
                              NULL);
        } else {
            cg_err_set(err, code, "%s", cg_or_empty(error.detail));
        }
        cg_extract_error_clear(&error);
        return true;
    }
    if (strcmp(name, "installExtracted") == 0) {
        const char *source = req_str(input, "source", err);
        const char *destination = source ? req_str(input, "destination", err) : NULL;
        if (destination && cg_archive_install_extracted(source, destination, err)) *result = cj_obj();
        return true;
    }
    if (strcmp(name, "manifestSizeUrl") == 0) {
        const char *url = req_str(input, "updateUrl", err);
        if (url) *result = cj_objv("url", cj_str_own(manifest_size_url(url)), NULL);
        return true;
    }
    return false;
}
