/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#include "str.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void out_of_memory(size_t size) {
    fprintf(stderr, "capgo core: out of memory (%zu bytes)\n", size);
    abort();
}

void *cg_malloc(size_t size) {
    void *ptr = malloc(size ? size : 1);
    if (!ptr) out_of_memory(size);
    return ptr;
}

void *cg_calloc(size_t count, size_t size) {
    void *ptr = calloc(count ? count : 1, size ? size : 1);
    if (!ptr) out_of_memory(count * size);
    return ptr;
}

void *cg_realloc(void *ptr, size_t size) {
    void *result = realloc(ptr, size ? size : 1);
    if (!result) out_of_memory(size);
    return result;
}

char *cg_strdup(const char *value) { return value ? cg_strndup(value, strlen(value)) : NULL; }

char *cg_strndup(const char *value, size_t len) {
    if (!value) return NULL;
    char *copy = cg_malloc(len + 1);
    memcpy(copy, value, len);
    copy[len] = 0;
    return copy;
}

char *cg_vfmt(const char *format, va_list args) {
    va_list copy;
    va_copy(copy, args);
    int needed = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (needed < 0) return cg_strdup("");
    char *out = cg_malloc((size_t)needed + 1);
    vsnprintf(out, (size_t)needed + 1, format, args);
    return out;
}

char *cg_fmt(const char *format, ...) {
    va_list args;
    va_start(args, format);
    char *out = cg_vfmt(format, args);
    va_end(args);
    return out;
}

void cg_replace(char **slot, char *value) {
    free(*slot);
    *slot = value;
}

bool cg_eq(const char *a, const char *b) {
    if (!a || !b) return a == b;
    return strcmp(a, b) == 0;
}

bool cg_eq_nocase(const char *a, const char *b) {
    if (!a || !b) return a == b;
    while (*a && *b) {
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) return false;
        a++;
        b++;
    }
    return *a == *b;
}

bool cg_empty(const char *value) { return !value || !*value; }

bool cg_starts_with(const char *value, const char *prefix) {
    if (!value || !prefix) return false;
    return strncmp(value, prefix, strlen(prefix)) == 0;
}

bool cg_ends_with(const char *value, const char *suffix) {
    if (!value || !suffix) return false;
    size_t n = strlen(value), m = strlen(suffix);
    return n >= m && memcmp(value + n - m, suffix, m) == 0;
}

bool cg_contains(const char *value, const char *needle) {
    return value && needle && strstr(value, needle) != NULL;
}

const char *cg_or_empty(const char *value) { return value ? value : ""; }

/* Decodes one UTF-8 scalar at s (valid input assumed); returns its length. */
static size_t utf8_decode(const unsigned char *s, size_t len, uint32_t *cp) {
    if (s[0] < 0x80 || len < 2) {
        *cp = s[0];
        return 1;
    }
    if ((s[0] & 0xe0) == 0xc0) {
        *cp = ((uint32_t)(s[0] & 0x1f) << 6) | (s[1] & 0x3f);
        return 2;
    }
    if ((s[0] & 0xf0) == 0xe0 && len >= 3) {
        *cp = ((uint32_t)(s[0] & 0x0f) << 12) | ((uint32_t)(s[1] & 0x3f) << 6) | (s[2] & 0x3f);
        return 3;
    }
    if (len >= 4) {
        *cp = ((uint32_t)(s[0] & 0x07) << 18) | ((uint32_t)(s[1] & 0x3f) << 12) | ((uint32_t)(s[2] & 0x3f) << 6) |
              (s[3] & 0x3f);
        return 4;
    }
    *cp = s[0];
    return 1;
}

/* Unicode White_Space property (what Rust's char::is_whitespace uses). */
static bool unicode_space(uint32_t c) {
    return (c >= 0x09 && c <= 0x0d) || c == 0x20 || c == 0x85 || c == 0xa0 || c == 0x1680 ||
           (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000;
}

void cg_trim_range(const char *value, size_t *start, size_t *len) {
    const unsigned char *s = (const unsigned char *)(value ? value : "");
    size_t n = strlen((const char *)s);
    size_t begin = 0;
    while (begin < n) {
        uint32_t cp;
        size_t step = utf8_decode(s + begin, n - begin, &cp);
        if (!unicode_space(cp)) break;
        begin += step;
    }
    size_t end = n;
    while (end > begin) {
        size_t back = end - 1;
        while (back > begin && (s[back] & 0xc0) == 0x80) back--;
        uint32_t cp;
        utf8_decode(s + back, end - back, &cp);
        if (!unicode_space(cp)) break;
        end = back;
    }
    *start = begin;
    *len = end - begin;
}

char *cg_trim(const char *value) {
    size_t start, len;
    cg_trim_range(value, &start, &len);
    return cg_strndup(value ? value + start : "", len);
}

char *cg_lower(const char *value) {
    char *copy = cg_strdup(value ? value : "");
    for (char *p = copy; *p; p++) *p = (char)tolower((unsigned char)*p);
    return copy;
}

char *cg_replace_all(const char *value, const char *from, const char *to) {
    if (!value) return NULL;
    size_t from_len = strlen(from);
    if (!from_len) return cg_strdup(value);
    cg_buf out = {0};
    const char *p = value;
    const char *hit;
    while ((hit = strstr(p, from)) != NULL) {
        cg_buf_put(&out, p, (size_t)(hit - p));
        cg_buf_puts(&out, to);
        p = hit + from_len;
    }
    cg_buf_puts(&out, p);
    return cg_buf_take(&out);
}

/* Length of the valid UTF-8 sequence at s, 0 when invalid. */
static size_t utf8_valid_at(const unsigned char *s, size_t len) {
    unsigned char c = s[0];
    if (c < 0x80) return 1;
    if (c >= 0xc2 && c <= 0xdf) return len >= 2 && (s[1] & 0xc0) == 0x80 ? 2 : 0;
    if (c >= 0xe0 && c <= 0xef) {
        if (len < 3 || (s[1] & 0xc0) != 0x80 || (s[2] & 0xc0) != 0x80) return 0;
        if (c == 0xe0 && s[1] < 0xa0) return 0; /* overlong */
        if (c == 0xed && s[1] > 0x9f) return 0; /* surrogate */
        return 3;
    }
    if (c >= 0xf0 && c <= 0xf4) {
        if (len < 4 || (s[1] & 0xc0) != 0x80 || (s[2] & 0xc0) != 0x80 || (s[3] & 0xc0) != 0x80) return 0;
        if (c == 0xf0 && s[1] < 0x90) return 0;
        if (c == 0xf4 && s[1] > 0x8f) return 0;
        return 4;
    }
    return 0;
}

bool cg_utf8_valid(const char *bytes, size_t len) {
    const unsigned char *s = (const unsigned char *)bytes;
    size_t i = 0;
    while (i < len) {
        size_t step = utf8_valid_at(s + i, len - i);
        if (!step) return false;
        i += step;
    }
    return true;
}

char *cg_utf8_lossy(const uint8_t *bytes, size_t len) {
    cg_buf out = {0};
    size_t i = 0;
    while (i < len) {
        size_t step = utf8_valid_at(bytes + i, len - i);
        if (step) {
            cg_buf_put(&out, bytes + i, step);
            i += step;
            continue;
        }
        /* One U+FFFD per maximal invalid prefix (from_utf8_lossy's rule). */
        size_t skip = 1;
        unsigned char c = bytes[i];
        size_t want = c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : c >= 0xc2 ? 2 : 1;
        while (skip < want && i + skip < len && (bytes[i + skip] & 0xc0) == 0x80) {
            /* Respect the second-byte ranges of E0/ED/F0/F4. */
            if (skip == 1) {
                unsigned char b = bytes[i + 1];
                if ((c == 0xe0 && b < 0xa0) || (c == 0xed && b > 0x9f) || (c == 0xf0 && b < 0x90) ||
                    (c == 0xf4 && b > 0x8f) || c > 0xf4)
                    break;
            }
            skip++;
        }
        cg_buf_puts(&out, "\xEF\xBF\xBD");
        i += skip;
    }
    return cg_buf_take(&out);
}

size_t cg_utf8_chars(const char *value) {
    size_t count = 0;
    for (const unsigned char *p = (const unsigned char *)(value ? value : ""); *p; p++)
        if ((*p & 0xc0) != 0x80) count++;
    return count;
}

bool cg_parse_i64(const char *value, int64_t *out) {
    if (!value || !*value) return false;
    const char *p = value;
    if (*p == '+' || *p == '-') p++;
    if (!*p) return false;
    for (const char *q = p; *q; q++)
        if (*q < '0' || *q > '9') return false;
    errno = 0;
    char *end;
    long long parsed = strtoll(value[0] == '+' ? value + 1 : value, &end, 10);
    if (errno || *end) return false;
    if (out) *out = parsed;
    return true;
}

bool cg_parse_u64(const char *value, uint64_t *out) {
    if (!value || !*value) return false;
    const char *p = value;
    if (*p == '+') p++;
    if (!*p) return false;
    for (const char *q = p; *q; q++)
        if (*q < '0' || *q > '9') return false;
    errno = 0;
    char *end;
    unsigned long long parsed = strtoull(p, &end, 10);
    if (errno || *end) return false;
    if (out) *out = parsed;
    return true;
}

void cg_buf_reserve(cg_buf *buf, size_t extra) {
    size_t needed = buf->len + extra + 1;
    if (needed <= buf->cap) return;
    size_t cap = buf->cap ? buf->cap : 64;
    while (cap < needed) cap *= 2;
    buf->data = cg_realloc(buf->data, cap);
    buf->cap = cap;
}

void cg_buf_put(cg_buf *buf, const void *bytes, size_t len) {
    cg_buf_reserve(buf, len);
    if (len) memcpy(buf->data + buf->len, bytes, len);
    buf->len += len;
    buf->data[buf->len] = 0;
}

void cg_buf_puts(cg_buf *buf, const char *text) { cg_buf_put(buf, text, text ? strlen(text) : 0); }

void cg_buf_putc(cg_buf *buf, char c) { cg_buf_put(buf, &c, 1); }

void cg_buf_printf(cg_buf *buf, const char *format, ...) {
    va_list args;
    va_start(args, format);
    char *text = cg_vfmt(format, args);
    va_end(args);
    cg_buf_puts(buf, text);
    free(text);
}

char *cg_buf_take(cg_buf *buf) {
    char *data = buf->data ? buf->data : cg_strdup("");
    buf->data = NULL;
    buf->len = buf->cap = 0;
    return data;
}

void cg_buf_clear(cg_buf *buf) {
    buf->len = 0;
    if (buf->data) buf->data[0] = 0;
}

void cg_buf_free(cg_buf *buf) {
    free(buf->data);
    buf->data = NULL;
    buf->len = buf->cap = 0;
}

void cg_strs_push(cg_strs *list, char *value) {
    if (list->len == list->cap) {
        list->cap = list->cap ? list->cap * 2 : 8;
        list->items = cg_realloc(list->items, list->cap * sizeof(char *));
    }
    list->items[list->len++] = value;
}

void cg_strs_push_copy(cg_strs *list, const char *value) { cg_strs_push(list, cg_strdup(value)); }

bool cg_strs_contains(const cg_strs *list, const char *value) {
    for (size_t i = 0; i < list->len; i++)
        if (cg_eq(list->items[i], value)) return true;
    return false;
}

void cg_strs_free(cg_strs *list) {
    for (size_t i = 0; i < list->len; i++) free(list->items[i]);
    free(list->items);
    list->items = NULL;
    list->len = list->cap = 0;
}

cg_strs cg_split(const char *value, char separator) {
    cg_strs parts = {0};
    const char *start = value ? value : "";
    const char *p = start;
    while (true) {
        if (*p == separator || !*p) {
            cg_strs_push(&parts, cg_strndup(start, (size_t)(p - start)));
            if (!*p) break;
            start = p + 1;
        }
        p++;
    }
    return parts;
}
