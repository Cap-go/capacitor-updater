/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#include "text.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "rt/str.h"

void cg_text_java_trim_range(const char *value, size_t *start, size_t *len) {
    size_t n = value ? strlen(value) : 0, begin = 0;
    while (begin < n && (unsigned char)value[begin] <= 0x20) begin++;
    while (n > begin && (unsigned char)value[n - 1] <= 0x20) n--;
    *start = begin;
    *len = n - begin;
}

char *cg_text_java_trim(const char *value) {
    if (!value) return NULL;
    size_t start, len;
    cg_text_java_trim_range(value, &start, &len);
    return cg_strndup(value + start, len);
}

static const char HEX_DIGITS[17] = "0123456789abcdef";

void cg_text_hex_encode_to(const uint8_t *bytes, size_t len, char *out) {
    for (size_t i = 0; i < len; i++) {
        out[2 * i] = HEX_DIGITS[bytes[i] >> 4];
        out[2 * i + 1] = HEX_DIGITS[bytes[i] & 0x0f];
    }
    out[2 * len] = 0;
}

char *cg_text_hex_encode(const uint8_t *bytes, size_t len) {
    char *out = cg_malloc(2 * len + 1);
    cg_text_hex_encode_to(bytes, len, out);
    return out;
}

static int hex_digit(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

uint8_t *cg_text_hex_decode(const char *value, size_t *out_len) {
    size_t n = value ? strlen(value) : 0;
    if (n % 2 != 0) return NULL;
    uint8_t *out = cg_malloc(n / 2 + 1);
    for (size_t i = 0; i < n; i += 2) {
        int high = hex_digit((unsigned char)value[i]), low = hex_digit((unsigned char)value[i + 1]);
        if (high < 0 || low < 0) {
            free(out);
            return NULL;
        }
        out[i / 2] = (uint8_t)((high << 4) | low);
    }
    if (out_len) *out_len = n / 2;
    return out;
}

bool cg_text_is_hex(const char *value) {
    if (!value || !*value) return false;
    for (const char *p = value; *p; p++)
        if (hex_digit((unsigned char)*p) < 0) return false;
    return true;
}

bool cg_text_is_unicode_whitespace(uint32_t c) {
    return (c >= 0x09 && c <= 0x0d) || c == 0x20 || c == 0x85 || c == 0xa0 || c == 0x1680 ||
           (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000;
}

size_t cg_text_utf8_next(const char *text, size_t len, uint32_t *code_point) {
    const unsigned char *s = (const unsigned char *)text;
    unsigned char c = s[0];
    size_t need;
    uint32_t cp, min;
    if (c < 0x80) {
        *code_point = c;
        return 1;
    } else if (c >= 0xc2 && c <= 0xdf) {
        need = 2, cp = c & 0x1f, min = 0x80;
    } else if (c >= 0xe0 && c <= 0xef) {
        need = 3, cp = c & 0x0f, min = 0x800;
    } else if (c >= 0xf0 && c <= 0xf4) {
        need = 4, cp = c & 0x07, min = 0x10000;
    } else {
        *code_point = 0xfffd;
        return 1;
    }
    if (len < need) {
        *code_point = 0xfffd;
        return 1;
    }
    for (size_t i = 1; i < need; i++) {
        if ((s[i] & 0xc0) != 0x80) {
            *code_point = 0xfffd;
            return 1;
        }
        cp = (cp << 6) | (s[i] & 0x3f);
    }
    if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) {
        *code_point = 0xfffd;
        return 1;
    }
    *code_point = cp;
    return need;
}

/* Standard alphabet; 0xff = not a symbol ('=' included, as in the base64 crate's table). */
static uint8_t base64_value(unsigned char c) {
    if (c >= 'A' && c <= 'Z') return (uint8_t)(c - 'A');
    if (c >= 'a' && c <= 'z') return (uint8_t)(c - 'a' + 26);
    if (c >= '0' && c <= '9') return (uint8_t)(c - '0' + 52);
    if (c == '+') return 62;
    if (c == '/') return 63;
    return 0xff;
}

/* base64 0.22 GeneralPurpose::decode with DecodePaddingMode::Indifferent and
 * decode_allow_trailing_bits(true), over whitespace-free input. */
static uint8_t *base64_decode_compact(const unsigned char *in, size_t n, size_t *out_len) {
    uint8_t *out = cg_malloc(n / 4 * 3 + 4);
    size_t written = 0;
    if (n == 0) {
        *out_len = 0;
        return out;
    }
    /* Every complete quad but the last one is plain symbols; the last 1..4 bytes are the suffix. */
    size_t rem = n % 4;
    size_t body = n - (rem ? rem : 4);
    for (size_t i = 0; i < body; i += 4) {
        uint32_t accum = 0;
        for (size_t j = 0; j < 4; j++) {
            uint8_t v = base64_value(in[i + j]);
            if (v == 0xff) goto invalid;
            accum = (accum << 6) | v;
        }
        out[written++] = (uint8_t)(accum >> 16);
        out[written++] = (uint8_t)(accum >> 8);
        out[written++] = (uint8_t)accum;
    }
    size_t morsel_count = 0, padding = 0;
    uint8_t morsels[4] = {0, 0, 0, 0};
    for (size_t i = body; i < n; i++) {
        size_t leftover_index = i - body;
        if (in[i] == '=') {
            /* Padding only from the third symbol of the final quad on. */
            if (leftover_index < 2) goto invalid;
            padding++;
            continue;
        }
        if (padding > 0) goto invalid; /* a symbol after padding */
        uint8_t v = base64_value(in[i]);
        if (v == 0xff) goto invalid;
        morsels[morsel_count++] = v;
    }
    if (morsel_count < 2) goto invalid;
    uint32_t leftover = ((uint32_t)morsels[0] << 26) | ((uint32_t)morsels[1] << 20) | ((uint32_t)morsels[2] << 14) |
                        ((uint32_t)morsels[3] << 8);
    for (size_t i = 0; i < morsel_count * 6 / 8; i++) {
        out[written++] = (uint8_t)(leftover >> 24);
        leftover <<= 8;
    }
    *out_len = written;
    return out;
invalid:
    free(out);
    return NULL;
}

uint8_t *cg_text_base64_decode_n(const char *value, size_t len, size_t *out_len) {
    unsigned char *compact = cg_malloc(len + 1);
    size_t n = 0;
    for (size_t i = 0; i < len;) {
        uint32_t cp;
        size_t step = cg_text_utf8_next(value + i, len - i, &cp);
        if (!cg_text_is_unicode_whitespace(cp)) {
            memcpy(compact + n, value + i, step);
            n += step;
        }
        i += step;
    }
    size_t decoded_len = 0;
    uint8_t *out = base64_decode_compact(compact, n, &decoded_len);
    free(compact);
    if (out && out_len) *out_len = decoded_len;
    return out;
}

uint8_t *cg_text_base64_decode(const char *value, size_t *out_len) {
    return cg_text_base64_decode_n(value ? value : "", value ? strlen(value) : 0, out_len);
}

int64_t cg_text_f64_to_i64_saturating(double value) {
    if (isnan(value)) return 0;
    if (value >= 9223372036854775808.0) return INT64_MAX;
    if (value <= -9223372036854775808.0) return INT64_MIN;
    return (int64_t)value;
}

bool cg_text_parse_f64(const char *value, size_t len, double *out) {
    size_t i = 0;
    bool negative = false;
    if (i < len && (value[i] == '+' || value[i] == '-')) negative = value[i++] == '-';
    size_t rest = len - i;
    if ((rest == 3 && strncasecmp(value + i, "inf", 3) == 0) ||
        (rest == 8 && strncasecmp(value + i, "infinity", 8) == 0)) {
        *out = negative ? -INFINITY : INFINITY;
        return true;
    }
    if (rest == 3 && strncasecmp(value + i, "nan", 3) == 0) {
        *out = negative ? -NAN : NAN;
        return true;
    }
    size_t digits = 0;
    while (i < len && value[i] >= '0' && value[i] <= '9') i++, digits++;
    if (i < len && value[i] == '.') {
        i++;
        while (i < len && value[i] >= '0' && value[i] <= '9') i++, digits++;
    }
    if (digits == 0) return false;
    if (i < len && (value[i] == 'e' || value[i] == 'E')) {
        i++;
        if (i < len && (value[i] == '+' || value[i] == '-')) i++;
        size_t exponent_digits = 0;
        while (i < len && value[i] >= '0' && value[i] <= '9') i++, exponent_digits++;
        if (exponent_digits == 0) return false;
    }
    if (i != len) return false;
    char *copy = cg_strndup(value, len);
    *out = strtod(copy, NULL);
    free(copy);
    return true;
}
