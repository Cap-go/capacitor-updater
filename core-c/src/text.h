/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* String helpers with the exact semantics the Android and iOS plugins shipped with
 * (Rust text.rs), so every host gets byte-identical results. */
#ifndef CG_TEXT_H
#define CG_TEXT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* java.lang.String#trim: range of `value` without leading / trailing bytes <= 0x20
 * (code points <= U+0020; UTF-8 continuation bytes are all >= 0x80). */
void cg_text_java_trim_range(const char *value, size_t *start, size_t *len);
/* java_trim as a malloc'd copy (NULL in, NULL out). */
char *cg_text_java_trim(const char *value);

/* Lowercase hex (malloc'd, NUL-terminated). */
char *cg_text_hex_encode(const uint8_t *bytes, size_t len);
/* Lowercase hex into `out`, which holds at least 2 * len + 1 bytes (NUL-terminated). */
void cg_text_hex_encode_to(const uint8_t *bytes, size_t len, char *out);
/* Strict hex decoding (even length, [0-9a-fA-F] only). malloc'd bytes (never NULL on
 * success, even when empty), length in *out_len; NULL when `value` is not hex. */
uint8_t *cg_text_hex_decode(const char *value, size_t *out_len);
/* Non-empty and only ASCII hex digits. */
bool cg_text_is_hex(const char *value);

/* Lenient standard base64 (Rust base64 crate, standard alphabet, padding indifferent,
 * non-canonical trailing bits allowed) after removing Unicode whitespace
 * (char::is_whitespace). malloc'd bytes (never NULL on success, even when empty),
 * length in *out_len; NULL when invalid. */
uint8_t *cg_text_base64_decode(const char *value, size_t *out_len);
/* Same over `len` bytes of UTF-8 text. */
uint8_t *cg_text_base64_decode_n(const char *value, size_t len, size_t *out_len);

/* Rust char::is_whitespace (Unicode White_Space). */
bool cg_text_is_unicode_whitespace(uint32_t code_point);
/* Decodes one UTF-8 scalar at s[0..len) (len >= 1) into *code_point and returns its
 * byte length. Invalid or truncated sequences decode as U+FFFD with length 1. */
size_t cg_text_utf8_next(const char *s, size_t len, uint32_t *code_point);

/* Rust `f64 as i64`: truncation toward zero, saturating, NaN -> 0. */
int64_t cg_text_f64_to_i64_saturating(double value);
/* Rust str::parse::<f64> (decimal or inf / infinity / nan, ASCII case-insensitive,
 * optional sign, no surrounding whitespace). */
bool cg_text_parse_f64(const char *value, size_t len, double *out);

#endif
