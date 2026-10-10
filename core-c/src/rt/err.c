/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#include "err.h"

#include <stdlib.h>
#include <string.h>

bool cg_err_set_own(cg_error *err, const char *code, char *message) {
    if (!err) {
        free(message);
        return false;
    }
    free(err->message);
    err->code = code;
    err->message = message ? message : cg_strdup("");
    return false;
}

bool cg_err_set(cg_error *err, const char *code, const char *format, ...) {
    va_list args;
    va_start(args, format);
    char *message = cg_vfmt(format, args);
    va_end(args);
    return cg_err_set_own(err, code, message);
}

bool cg_err_invalid_input(cg_error *err, const char *format, ...) {
    va_list args;
    va_start(args, format);
    char *message = cg_vfmt(format, args);
    va_end(args);
    return cg_err_set_own(err, "invalid_input", message);
}

char *cg_io_message(int errnum) {
    char detail[256] = {0};
#if defined(__GLIBC__) && defined(_GNU_SOURCE)
    const char *text = strerror_r(errnum, detail, sizeof detail);
#else
    const char *text = strerror_r(errnum, detail, sizeof detail) == 0 ? detail : "Unknown error";
#endif
    return cg_fmt("%s (os error %d)", text, errnum);
}

bool cg_err_io(cg_error *err, const char *context, int errnum) {
    char *detail = cg_io_message(errnum);
    char *message = cg_fmt("%s: %s", context, detail);
    free(detail);
    return cg_err_set_own(err, "io_error", message);
}

bool cg_err_is(const cg_error *err, const char *code) { return err && err->code && strcmp(err->code, code) == 0; }

void cg_err_clear(cg_error *err) {
    if (!err) return;
    free(err->message);
    err->message = NULL;
    err->code = NULL;
}

void cg_err_move(cg_error *dst, cg_error *src) {
    if (!dst) {
        cg_err_clear(src);
        return;
    }
    cg_err_clear(dst);
    *dst = *src;
    src->code = NULL;
    src->message = NULL;
}

char *cg_err_display(const cg_error *err) {
    return cg_fmt("%s: %s", err && err->code ? err->code : "", err && err->message ? err->message : "");
}
