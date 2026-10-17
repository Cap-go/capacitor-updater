/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Memory, strings and byte buffers. Allocation failures abort (like Rust's global allocator). */
#ifndef CG_STR_H
#define CG_STR_H

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(__GNUC__) || defined(__clang__)
#define CG_PRINTF(fmt, args) __attribute__((format(printf, fmt, args)))
#else
#define CG_PRINTF(fmt, args)
#endif

void *cg_malloc(size_t size);
void *cg_calloc(size_t count, size_t size);
void *cg_realloc(void *ptr, size_t size);

/* NULL in, NULL out. */
char *cg_strdup(const char *value);
char *cg_strndup(const char *value, size_t len);
/* malloc'd printf. */
char *cg_fmt(const char *format, ...) CG_PRINTF(1, 2);
char *cg_vfmt(const char *format, va_list args);

/* Frees *slot and stores value (owned). */
void cg_replace(char **slot, char *value);

/* NULL-safe comparisons and predicates. */
bool cg_eq(const char *a, const char *b);
bool cg_eq_nocase(const char *a, const char *b);
bool cg_empty(const char *value); /* NULL or "" */
bool cg_starts_with(const char *value, const char *prefix);
bool cg_ends_with(const char *value, const char *suffix);
bool cg_contains(const char *value, const char *needle);
/* "" when NULL. */
const char *cg_or_empty(const char *value);

/* Rust str::trim (Unicode White_Space, ASCII + common Unicode spaces): malloc'd copy. */
char *cg_trim(const char *value);
/* Range of the trimmed text without copying. */
void cg_trim_range(const char *value, size_t *start, size_t *len);
char *cg_lower(const char *value); /* ASCII lowercase copy */
/* Replaces every `from` with `to` (malloc'd). */
char *cg_replace_all(const char *value, const char *from, const char *to);
/* Valid UTF-8 check (Rust str rules: no surrogates, no overlongs). */
bool cg_utf8_valid(const char *bytes, size_t len);
/* Lossy UTF-8 copy (invalid sequences become U+FFFD), like String::from_utf8_lossy. */
char *cg_utf8_lossy(const uint8_t *bytes, size_t len);
/* Number of Unicode scalar values. */
size_t cg_utf8_chars(const char *value);

/* Strict integer parse of the whole string (Rust str::parse::<i64>: optional +/- then digits). */
bool cg_parse_i64(const char *value, int64_t *out);
bool cg_parse_u64(const char *value, uint64_t *out);

/* ---- growable byte buffer (always NUL-terminated when data != NULL) */
typedef struct {
    char *data;
    size_t len, cap;
} cg_buf;

void cg_buf_reserve(cg_buf *buf, size_t extra);
void cg_buf_put(cg_buf *buf, const void *bytes, size_t len);
void cg_buf_puts(cg_buf *buf, const char *text);
void cg_buf_putc(cg_buf *buf, char c);
void cg_buf_printf(cg_buf *buf, const char *format, ...) CG_PRINTF(2, 3);
/* Returns the data (malloc'd, NUL-terminated, "" when empty) and resets the buffer. */
char *cg_buf_take(cg_buf *buf);
void cg_buf_clear(cg_buf *buf);
void cg_buf_free(cg_buf *buf);

/* ---- string list */
typedef struct {
    char **items;
    size_t len, cap;
} cg_strs;

void cg_strs_push(cg_strs *list, char *value); /* owned */
void cg_strs_push_copy(cg_strs *list, const char *value);
bool cg_strs_contains(const cg_strs *list, const char *value);
void cg_strs_free(cg_strs *list);
/* Splits on a separator character (all parts, empty ones kept). */
cg_strs cg_split(const char *value, char separator);

#endif
