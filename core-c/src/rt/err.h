/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Core errors: a stable machine code (static string) and a log message (Rust CoreError). */
#ifndef CG_ERR_H
#define CG_ERR_H

#include <stdbool.h>

#include "str.h"

typedef struct {
    const char *code; /* NULL: no error */
    char *message;
} cg_error;

#define CG_ERROR_INIT {0}

/* Sets the error (replacing a previous one). Always returns false (for `return cg_err_set(...)`). */
bool cg_err_set(cg_error *err, const char *code, const char *format, ...) CG_PRINTF(3, 4);
/* Takes ownership of message. */
bool cg_err_set_own(cg_error *err, const char *code, char *message);
bool cg_err_invalid_input(cg_error *err, const char *format, ...) CG_PRINTF(2, 3);
/* "io_error", "<context>: <strerror> (os error N)" (Rust std::io::Error display). */
bool cg_err_io(cg_error *err, const char *context, int errnum);
/* Rust io::Error display for errno. Caller frees. */
char *cg_io_message(int errnum);
bool cg_err_is(const cg_error *err, const char *code);
void cg_err_clear(cg_error *err);
/* Moves src into dst (dst cleared first); src is left empty. */
void cg_err_move(cg_error *dst, cg_error *src);
/* "code: message" (Rust Display), malloc'd. */
char *cg_err_display(const cg_error *err);

#endif
