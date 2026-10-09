/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#include "json.h"

#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "str.h"

static cj *cj_new(cj_type type) {
    cj *value = cg_calloc(1, sizeof(cj));
    value->type = type;
    return value;
}

cj *cj_null(void) { return cj_new(CJ_NULL); }

cj *cj_bool(bool b) {
    cj *value = cj_new(CJ_BOOL);
    value->v.b = b;
    return value;
}

cj *cj_i64(int64_t i) {
    if (i >= 0) return cj_u64((uint64_t)i);
    cj *value = cj_new(CJ_INT);
    value->v.i = i;
    return value;
}

cj *cj_u64(uint64_t u) {
    cj *value = cj_new(CJ_UINT);
    value->v.u = u;
    return value;
}

cj *cj_f64(double f) {
    if (!isfinite(f)) return cj_null();
    cj *value = cj_new(CJ_FLOAT);
    value->v.f = f;
    return value;
}

cj *cj_strn(const char *s, size_t len) {
    if (!s) return cj_null();
    cj *value = cj_new(CJ_STRING);
    value->v.s.ptr = cg_strndup(s, len);
    value->v.s.len = len;
    return value;
}

cj *cj_str(const char *s) { return s ? cj_strn(s, strlen(s)) : cj_null(); }

cj *cj_str_own(char *s) {
    if (!s) return cj_null();
    cj *value = cj_new(CJ_STRING);
    value->v.s.ptr = s;
    value->v.s.len = strlen(s);
    return value;
}

cj *cj_arr(void) { return cj_new(CJ_ARRAY); }
cj *cj_obj(void) { return cj_new(CJ_OBJECT); }

cj *cj_objv(const char *key, ...) {
    cj *object = cj_obj();
    va_list args;
    va_start(args, key);
    while (key) {
        cj *value = va_arg(args, cj *);
        cj_set(object, key, value ? value : cj_null());
        key = va_arg(args, const char *);
    }
    va_end(args);
    return object;
}

cj *cj_arrv(cj *first, ...) {
    cj *array = cj_arr();
    va_list args;
    va_start(args, first);
    for (cj *value = first; value != CJ_END; value = va_arg(args, cj *)) {
        cj_push(array, value ? value : cj_null());
    }
    va_end(args);
    return array;
}

void cj_clear(cj *value) {
    if (!value) return;
    switch (value->type) {
    case CJ_STRING:
        free(value->v.s.ptr);
        break;
    case CJ_ARRAY:
        for (size_t i = 0; i < value->v.a.len; i++) cj_free(value->v.a.items[i]);
        free(value->v.a.items);
        break;
    case CJ_OBJECT:
        for (size_t i = 0; i < value->v.o.len; i++) {
            free(value->v.o.items[i].key);
            cj_free(value->v.o.items[i].value);
        }
        free(value->v.o.items);
        break;
    default:
        break;
    }
    memset(&value->v, 0, sizeof(value->v));
    value->type = CJ_NULL;
}

void cj_free(cj *value) {
    if (!value) return;
    cj_clear(value);
    free(value);
}

cj *cj_clone(const cj *value) {
    if (!value) return cj_null();
    switch (value->type) {
    case CJ_NULL: return cj_null();
    case CJ_BOOL: return cj_bool(value->v.b);
    case CJ_UINT: return cj_u64(value->v.u);
    case CJ_INT: return cj_i64(value->v.i);
    case CJ_FLOAT: return cj_f64(value->v.f);
    case CJ_STRING: return cj_strn(value->v.s.ptr, value->v.s.len);
    case CJ_ARRAY: {
        cj *array = cj_arr();
        for (size_t i = 0; i < value->v.a.len; i++) cj_push(array, cj_clone(value->v.a.items[i]));
        return array;
    }
    case CJ_OBJECT: {
        cj *object = cj_obj();
        object->v.o.items = cg_calloc(value->v.o.len ? value->v.o.len : 1, sizeof(cj_member));
        object->v.o.cap = value->v.o.len ? value->v.o.len : 1;
        for (size_t i = 0; i < value->v.o.len; i++) {
            object->v.o.items[i].key = cg_strdup(value->v.o.items[i].key);
            object->v.o.items[i].value = cj_clone(value->v.o.items[i].value);
        }
        object->v.o.len = value->v.o.len;
        return object;
    }
    }
    return cj_null();
}

bool cj_eq(const cj *a, const cj *b) {
    cj_type ta = cj_typeof(a), tb = cj_typeof(b);
    if (ta != tb) return false;
    switch (ta) {
    case CJ_NULL: return true;
    case CJ_BOOL: return a->v.b == b->v.b;
    case CJ_UINT: return a->v.u == b->v.u;
    case CJ_INT: return a->v.i == b->v.i;
    case CJ_FLOAT: return a->v.f == b->v.f;
    case CJ_STRING: return a->v.s.len == b->v.s.len && memcmp(a->v.s.ptr, b->v.s.ptr, a->v.s.len) == 0;
    case CJ_ARRAY:
        if (a->v.a.len != b->v.a.len) return false;
        for (size_t i = 0; i < a->v.a.len; i++)
            if (!cj_eq(a->v.a.items[i], b->v.a.items[i])) return false;
        return true;
    case CJ_OBJECT:
        if (a->v.o.len != b->v.o.len) return false;
        for (size_t i = 0; i < a->v.o.len; i++) {
            if (strcmp(a->v.o.items[i].key, b->v.o.items[i].key) != 0) return false;
            if (!cj_eq(a->v.o.items[i].value, b->v.o.items[i].value)) return false;
        }
        return true;
    }
    return false;
}

cj_type cj_typeof(const cj *value) { return value ? value->type : CJ_NULL; }
bool cj_is_null(const cj *value) { return cj_typeof(value) == CJ_NULL; }
bool cj_is_bool(const cj *value) { return cj_typeof(value) == CJ_BOOL; }
bool cj_is_number(const cj *value) {
    cj_type type = cj_typeof(value);
    return type == CJ_UINT || type == CJ_INT || type == CJ_FLOAT;
}
bool cj_is_str(const cj *value) { return cj_typeof(value) == CJ_STRING; }
bool cj_is_arr(const cj *value) { return cj_typeof(value) == CJ_ARRAY; }
bool cj_is_obj(const cj *value) { return cj_typeof(value) == CJ_OBJECT; }

const char *cj_as_str(const cj *value) { return cj_is_str(value) ? value->v.s.ptr : NULL; }

bool cj_str_has_nul(const cj *value) {
    return cj_is_str(value) && memchr(value->v.s.ptr, 0, value->v.s.len) != NULL;
}

bool cj_as_bool(const cj *value, bool *out) {
    if (!cj_is_bool(value)) return false;
    if (out) *out = value->v.b;
    return true;
}

bool cj_as_i64(const cj *value, int64_t *out) {
    switch (cj_typeof(value)) {
    case CJ_INT:
        if (out) *out = value->v.i;
        return true;
    case CJ_UINT:
        if (value->v.u > (uint64_t)INT64_MAX) return false;
        if (out) *out = (int64_t)value->v.u;
        return true;
    default:
        return false;
    }
}

bool cj_as_u64(const cj *value, uint64_t *out) {
    if (cj_typeof(value) != CJ_UINT) return false;
    if (out) *out = value->v.u;
    return true;
}

bool cj_as_f64(const cj *value, double *out) {
    double result;
    switch (cj_typeof(value)) {
    case CJ_UINT: result = (double)value->v.u; break;
    case CJ_INT: result = (double)value->v.i; break;
    case CJ_FLOAT: result = value->v.f; break;
    default: return false;
    }
    if (out) *out = result;
    return true;
}

/* Binary search: index of key, or the insertion point with *found = false. */
static size_t find_key(const cj *object, const char *key, bool *found) {
    size_t lo = 0, hi = object->v.o.len;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        int cmp = strcmp(object->v.o.items[mid].key, key);
        if (cmp == 0) {
            *found = true;
            return mid;
        }
        if (cmp < 0) lo = mid + 1;
        else hi = mid;
    }
    *found = false;
    return lo;
}

cj *cj_get(const cj *object, const char *key) {
    if (!cj_is_obj(object) || !key) return NULL;
    bool found;
    size_t index = find_key(object, key, &found);
    return found ? object->v.o.items[index].value : NULL;
}

cj *cj_path(const cj *value, ...) {
    va_list args;
    va_start(args, value);
    const char *key;
    cj *current = (cj *)value;
    while ((key = va_arg(args, const char *)) != NULL) {
        current = cj_get(current, key);
        if (!current) break;
    }
    va_end(args);
    return current;
}

bool cj_has(const cj *object, const char *key) { return cj_get(object, key) != NULL; }

void cj_set(cj *object, const char *key, cj *value) {
    if (!value) value = cj_null();
    if (!cj_is_obj(object) || !key) {
        cj_free(value);
        return;
    }
    bool found;
    size_t index = find_key(object, key, &found);
    if (found) {
        cj_free(object->v.o.items[index].value);
        object->v.o.items[index].value = value;
        return;
    }
    if (object->v.o.len == object->v.o.cap) {
        object->v.o.cap = object->v.o.cap ? object->v.o.cap * 2 : 4;
        object->v.o.items = cg_realloc(object->v.o.items, object->v.o.cap * sizeof(cj_member));
    }
    memmove(&object->v.o.items[index + 1], &object->v.o.items[index],
            (object->v.o.len - index) * sizeof(cj_member));
    object->v.o.items[index].key = cg_strdup(key);
    object->v.o.items[index].value = value;
    object->v.o.len++;
}

cj *cj_entry(cj *object, const char *key, cj *value) {
    cj *existing = cj_get(object, key);
    if (existing) {
        cj_free(value);
        return existing;
    }
    if (!cj_is_obj(object)) {
        cj_free(value);
        return NULL;
    }
    if (!value) value = cj_null();
    cj_set(object, key, value);
    return value;
}

cj *cj_take(cj *object, const char *key) {
    if (!cj_is_obj(object) || !key) return NULL;
    bool found;
    size_t index = find_key(object, key, &found);
    if (!found) return NULL;
    cj *value = object->v.o.items[index].value;
    free(object->v.o.items[index].key);
    memmove(&object->v.o.items[index], &object->v.o.items[index + 1],
            (object->v.o.len - index - 1) * sizeof(cj_member));
    object->v.o.len--;
    return value;
}

bool cj_remove(cj *object, const char *key) {
    cj *value = cj_take(object, key);
    if (!value) return false;
    cj_free(value);
    return true;
}

const char *cj_get_str(const cj *object, const char *key) { return cj_as_str(cj_get(object, key)); }

bool cj_get_bool(const cj *object, const char *key, bool fallback) {
    bool value;
    return cj_as_bool(cj_get(object, key), &value) ? value : fallback;
}

size_t cj_len(const cj *value) {
    switch (cj_typeof(value)) {
    case CJ_ARRAY: return value->v.a.len;
    case CJ_OBJECT: return value->v.o.len;
    case CJ_STRING: return value->v.s.len;
    default: return 0;
    }
}

cj *cj_at(const cj *array, size_t index) {
    if (!cj_is_arr(array) || index >= array->v.a.len) return NULL;
    return array->v.a.items[index];
}

const char *cj_key_at(const cj *object, size_t index) {
    if (!cj_is_obj(object) || index >= object->v.o.len) return NULL;
    return object->v.o.items[index].key;
}

cj *cj_value_at(const cj *object, size_t index) {
    if (!cj_is_obj(object) || index >= object->v.o.len) return NULL;
    return object->v.o.items[index].value;
}

void cj_push(cj *array, cj *value) {
    if (!value) value = cj_null();
    if (!cj_is_arr(array)) {
        cj_free(value);
        return;
    }
    if (array->v.a.len == array->v.a.cap) {
        array->v.a.cap = array->v.a.cap ? array->v.a.cap * 2 : 4;
        array->v.a.items = cg_realloc(array->v.a.items, array->v.a.cap * sizeof(cj *));
    }
    array->v.a.items[array->v.a.len++] = value;
}

cj *cj_remove_at(cj *array, size_t index) {
    if (!cj_is_arr(array) || index >= array->v.a.len) return NULL;
    cj *value = array->v.a.items[index];
    memmove(&array->v.a.items[index], &array->v.a.items[index + 1],
            (array->v.a.len - index - 1) * sizeof(cj *));
    array->v.a.len--;
    return value;
}

/* ---------------------------------------------------------------- printing */

static void print_string(cg_buf *out, const char *s, size_t len) {
    static const char hex[] = "0123456789abcdef";
    cg_buf_putc(out, '"');
    size_t start = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        const char *escape = NULL;
        switch (c) {
        case '"': escape = "\\\""; break;
        case '\\': escape = "\\\\"; break;
        case '\b': escape = "\\b"; break;
        case '\f': escape = "\\f"; break;
        case '\n': escape = "\\n"; break;
        case '\r': escape = "\\r"; break;
        case '\t': escape = "\\t"; break;
        default:
            if (c >= 0x20) continue;
        }
        cg_buf_put(out, s + start, i - start);
        if (escape) {
            cg_buf_puts(out, escape);
        } else {
            char u[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
            cg_buf_put(out, u, 6);
        }
        start = i + 1;
    }
    cg_buf_put(out, s + start, len - start);
    cg_buf_putc(out, '"');
}

/* Shortest round-trip formatting with serde_json's layout. */
static void print_float(cg_buf *out, double value) {
    if (value == 0) {
        cg_buf_puts(out, signbit(value) ? "-0.0" : "0.0");
        return;
    }
    char sci[40];
    for (int precision = 0; precision <= 17; precision++) {
        snprintf(sci, sizeof sci, "%.*e", precision, value);
        if (strtod(sci, NULL) == value) break;
    }
    /* sci: [-]d[.ddd]e[+-]XX */
    char digits[24];
    size_t n = 0;
    const char *p = sci;
    bool negative = false;
    if (*p == '-') {
        negative = true;
        p++;
    }
    for (; *p && *p != 'e'; p++)
        if (*p != '.') digits[n++] = *p;
    while (n > 1 && digits[n - 1] == '0') n--;
    int exponent = atoi(p + 1);
    int kk = exponent + 1; /* decimal point position relative to the first digit */
    int k = kk - (int)n;
    if (negative) cg_buf_putc(out, '-');
    if (k >= 0 && kk <= 16) {
        cg_buf_put(out, digits, n);
        for (int i = 0; i < k; i++) cg_buf_putc(out, '0');
        cg_buf_puts(out, ".0");
    } else if (kk > 0 && kk <= 16) {
        cg_buf_put(out, digits, (size_t)kk);
        cg_buf_putc(out, '.');
        cg_buf_put(out, digits + kk, n - (size_t)kk);
    } else if (kk > -5 && kk <= 0) {
        cg_buf_puts(out, "0.");
        for (int i = 0; i < -kk; i++) cg_buf_putc(out, '0');
        cg_buf_put(out, digits, n);
    } else {
        cg_buf_putc(out, digits[0]);
        if (n > 1) {
            cg_buf_putc(out, '.');
            cg_buf_put(out, digits + 1, n - 1);
        }
        /* serde_json 1.0.151: "1e+300", "1.5e-7". */
        cg_buf_printf(out, kk - 1 >= 0 ? "e+%d" : "e%d", kk - 1);
    }
}

static void print_value(cg_buf *out, const cj *value) {
    switch (cj_typeof(value)) {
    case CJ_NULL: cg_buf_puts(out, "null"); break;
    case CJ_BOOL: cg_buf_puts(out, value->v.b ? "true" : "false"); break;
    case CJ_UINT: cg_buf_printf(out, "%llu", (unsigned long long)value->v.u); break;
    case CJ_INT: cg_buf_printf(out, "%lld", (long long)value->v.i); break;
    case CJ_FLOAT: print_float(out, value->v.f); break;
    case CJ_STRING: print_string(out, value->v.s.ptr, value->v.s.len); break;
    case CJ_ARRAY:
        cg_buf_putc(out, '[');
        for (size_t i = 0; i < value->v.a.len; i++) {
            if (i) cg_buf_putc(out, ',');
            print_value(out, value->v.a.items[i]);
        }
        cg_buf_putc(out, ']');
        break;
    case CJ_OBJECT:
        cg_buf_putc(out, '{');
        for (size_t i = 0; i < value->v.o.len; i++) {
            if (i) cg_buf_putc(out, ',');
            print_string(out, value->v.o.items[i].key, strlen(value->v.o.items[i].key));
            cg_buf_putc(out, ':');
            print_value(out, value->v.o.items[i].value);
        }
        cg_buf_putc(out, '}');
        break;
    }
}

char *cj_print(const cj *value) {
    cg_buf out = {0};
    print_value(&out, value);
    return cg_buf_take(&out);
}

/* ---------------------------------------------------------------- parsing */

#define RECURSION_LIMIT 128

typedef struct {
    const char *text;
    size_t len, pos;
    int depth;
    const char *error; /* static description */
} parser;

static void position(const parser *p, size_t at, size_t *line, size_t *column) {
    *line = 1;
    *column = 0;
    for (size_t i = 0; i < at && i < p->len; i++) {
        if (p->text[i] == '\n') {
            (*line)++;
            *column = 0;
        } else {
            (*column)++;
        }
    }
}

static cj *fail(parser *p, const char *message) {
    if (!p->error) p->error = message;
    return NULL;
}

static void skip_ws(parser *p) {
    while (p->pos < p->len) {
        char c = p->text[p->pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') p->pos++;
        else break;
    }
}

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool read_hex4(parser *p, unsigned *out) {
    if (p->pos + 4 > p->len) {
        p->pos = p->len;
        fail(p, "EOF while parsing a string");
        return false;
    }
    unsigned value = 0;
    for (int i = 0; i < 4; i++) {
        int digit = hex_digit(p->text[p->pos]);
        if (digit < 0) {
            fail(p, "invalid escape");
            return false;
        }
        value = (value << 4) | (unsigned)digit;
        p->pos++;
    }
    *out = value;
    return true;
}

static void put_utf8(cg_buf *out, unsigned cp) {
    char b[4];
    if (cp < 0x80) {
        b[0] = (char)cp;
        cg_buf_put(out, b, 1);
    } else if (cp < 0x800) {
        b[0] = (char)(0xc0 | (cp >> 6));
        b[1] = (char)(0x80 | (cp & 0x3f));
        cg_buf_put(out, b, 2);
    } else if (cp < 0x10000) {
        b[0] = (char)(0xe0 | (cp >> 12));
        b[1] = (char)(0x80 | ((cp >> 6) & 0x3f));
        b[2] = (char)(0x80 | (cp & 0x3f));
        cg_buf_put(out, b, 3);
    } else {
        b[0] = (char)(0xf0 | (cp >> 18));
        b[1] = (char)(0x80 | ((cp >> 12) & 0x3f));
        b[2] = (char)(0x80 | ((cp >> 6) & 0x3f));
        b[3] = (char)(0x80 | (cp & 0x3f));
        cg_buf_put(out, b, 4);
    }
}

/* At the opening quote. */
static char *parse_string(parser *p, size_t *out_len) {
    p->pos++;
    cg_buf out = {0};
    size_t start = p->pos;
    while (true) {
        if (p->pos >= p->len) {
            cg_buf_free(&out);
            fail(p, "EOF while parsing a string");
            return NULL;
        }
        unsigned char c = (unsigned char)p->text[p->pos];
        if (c == '"') {
            cg_buf_put(&out, p->text + start, p->pos - start);
            p->pos++;
            break;
        }
        if (c < 0x20) {
            cg_buf_free(&out);
            fail(p, "control character (\\u0000-\\u001F) found while parsing a string");
            return NULL;
        }
        if (c != '\\') {
            p->pos++;
            continue;
        }
        cg_buf_put(&out, p->text + start, p->pos - start);
        p->pos++;
        if (p->pos >= p->len) {
            cg_buf_free(&out);
            fail(p, "EOF while parsing a string");
            return NULL;
        }
        char e = p->text[p->pos++];
        switch (e) {
        case '"': cg_buf_putc(&out, '"'); break;
        case '\\': cg_buf_putc(&out, '\\'); break;
        case '/': cg_buf_putc(&out, '/'); break;
        case 'b': cg_buf_putc(&out, '\b'); break;
        case 'f': cg_buf_putc(&out, '\f'); break;
        case 'n': cg_buf_putc(&out, '\n'); break;
        case 'r': cg_buf_putc(&out, '\r'); break;
        case 't': cg_buf_putc(&out, '\t'); break;
        case 'u': {
            unsigned cp;
            if (!read_hex4(p, &cp)) {
                cg_buf_free(&out);
                return NULL;
            }
            if (cp >= 0xdc00 && cp <= 0xdfff) {
                cg_buf_free(&out);
                fail(p, "lone leading surrogate in hex escape");
                return NULL;
            }
            if (cp >= 0xd800 && cp <= 0xdbff) {
                unsigned low;
                if (p->pos + 2 > p->len || p->text[p->pos] != '\\' || p->text[p->pos + 1] != 'u') {
                    cg_buf_free(&out);
                    fail(p, "unexpected end of hex escape");
                    return NULL;
                }
                p->pos += 2;
                if (!read_hex4(p, &low)) {
                    cg_buf_free(&out);
                    return NULL;
                }
                if (low < 0xdc00 || low > 0xdfff) {
                    cg_buf_free(&out);
                    fail(p, "lone leading surrogate in hex escape");
                    return NULL;
                }
                cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
            }
            put_utf8(&out, cp);
            break;
        }
        default:
            cg_buf_free(&out);
            fail(p, "invalid escape");
            return NULL;
        }
        start = p->pos;
    }
    *out_len = out.len;
    char *result = cg_buf_take(&out);
    return result;
}

static cj *parse_number(parser *p) {
    size_t start = p->pos;
    bool negative = false, is_float = false;
    if (p->text[p->pos] == '-') {
        negative = true;
        p->pos++;
    }
    if (p->pos >= p->len) return fail(p, "EOF while parsing a value");
    if (p->text[p->pos] == '0') {
        p->pos++;
        if (p->pos < p->len && p->text[p->pos] >= '0' && p->text[p->pos] <= '9')
            return fail(p, "invalid number");
    } else if (p->text[p->pos] >= '1' && p->text[p->pos] <= '9') {
        while (p->pos < p->len && p->text[p->pos] >= '0' && p->text[p->pos] <= '9') p->pos++;
    } else {
        return fail(p, "invalid number");
    }
    if (p->pos < p->len && p->text[p->pos] == '.') {
        is_float = true;
        p->pos++;
        if (p->pos >= p->len || p->text[p->pos] < '0' || p->text[p->pos] > '9')
            return fail(p, p->pos >= p->len ? "EOF while parsing a value" : "invalid number");
        while (p->pos < p->len && p->text[p->pos] >= '0' && p->text[p->pos] <= '9') p->pos++;
    }
    if (p->pos < p->len && (p->text[p->pos] == 'e' || p->text[p->pos] == 'E')) {
        is_float = true;
        p->pos++;
        if (p->pos < p->len && (p->text[p->pos] == '+' || p->text[p->pos] == '-')) p->pos++;
        if (p->pos >= p->len || p->text[p->pos] < '0' || p->text[p->pos] > '9')
            return fail(p, p->pos >= p->len ? "EOF while parsing a value" : "invalid number");
        while (p->pos < p->len && p->text[p->pos] >= '0' && p->text[p->pos] <= '9') p->pos++;
    }
    char *literal = cg_strndup(p->text + start, p->pos - start);
    cj *value = NULL;
    if (!is_float) {
        errno = 0;
        if (negative) {
            long long parsed = strtoll(literal, NULL, 10);
            if (errno == 0) value = cj_i64(parsed);
        } else {
            unsigned long long parsed = strtoull(literal, NULL, 10);
            if (errno == 0) value = cj_u64(parsed);
        }
    }
    if (!value) {
        double parsed = strtod(literal, NULL);
        if (!isfinite(parsed)) {
            free(literal);
            return fail(p, "number out of range");
        }
        value = cj_f64(parsed);
    }
    free(literal);
    return value;
}

static bool literal(parser *p, const char *word) {
    size_t n = strlen(word);
    if (p->pos + n > p->len || memcmp(p->text + p->pos, word, n) != 0) {
        /* Point at the first mismatching byte, like serde. */
        size_t i = 0;
        while (p->pos + i < p->len && i < n && p->text[p->pos + i] == word[i]) i++;
        p->pos += i;
        fail(p, p->pos >= p->len ? "EOF while parsing a value" : "expected ident");
        return false;
    }
    p->pos += n;
    return true;
}

static cj *parse_value(parser *p);

static cj *parse_array(parser *p) {
    if (++p->depth > RECURSION_LIMIT) return fail(p, "recursion limit exceeded");
    p->pos++;
    cj *array = cj_arr();
    skip_ws(p);
    if (p->pos < p->len && p->text[p->pos] == ']') {
        p->pos++;
        p->depth--;
        return array;
    }
    while (true) {
        cj *item = parse_value(p);
        if (!item) {
            cj_free(array);
            return NULL;
        }
        cj_push(array, item);
        skip_ws(p);
        if (p->pos >= p->len) {
            cj_free(array);
            return fail(p, "EOF while parsing a list");
        }
        char c = p->text[p->pos];
        if (c == ',') {
            p->pos++;
            skip_ws(p);
            if (p->pos < p->len && p->text[p->pos] == ']') {
                cj_free(array);
                return fail(p, "trailing comma");
            }
            continue;
        }
        if (c == ']') {
            p->pos++;
            break;
        }
        cj_free(array);
        return fail(p, "expected `,` or `]`");
    }
    p->depth--;
    return array;
}

static cj *parse_object(parser *p) {
    if (++p->depth > RECURSION_LIMIT) return fail(p, "recursion limit exceeded");
    p->pos++;
    cj *object = cj_obj();
    skip_ws(p);
    if (p->pos < p->len && p->text[p->pos] == '}') {
        p->pos++;
        p->depth--;
        return object;
    }
    while (true) {
        skip_ws(p);
        if (p->pos >= p->len) {
            cj_free(object);
            return fail(p, "EOF while parsing an object");
        }
        if (p->text[p->pos] != '"') {
            cj_free(object);
            return fail(p, p->text[p->pos] == '}' ? "trailing comma" : "key must be a string");
        }
        size_t key_len;
        char *key = parse_string(p, &key_len);
        if (!key) {
            cj_free(object);
            return NULL;
        }
        skip_ws(p);
        if (p->pos >= p->len || p->text[p->pos] != ':') {
            free(key);
            cj_free(object);
            return fail(p, p->pos >= p->len ? "EOF while parsing an object" : "expected `:`");
        }
        p->pos++;
        cj *value = parse_value(p);
        if (!value) {
            free(key);
            cj_free(object);
            return NULL;
        }
        cj_set(object, key, value); /* duplicate keys: last wins, like serde_json::Value */
        free(key);
        skip_ws(p);
        if (p->pos >= p->len) {
            cj_free(object);
            return fail(p, "EOF while parsing an object");
        }
        char c = p->text[p->pos];
        if (c == ',') {
            p->pos++;
            continue;
        }
        if (c == '}') {
            p->pos++;
            break;
        }
        cj_free(object);
        return fail(p, "expected `,` or `}`");
    }
    p->depth--;
    return object;
}

static cj *parse_value(parser *p) {
    skip_ws(p);
    if (p->pos >= p->len) return fail(p, "EOF while parsing a value");
    char c = p->text[p->pos];
    switch (c) {
    case 'n': return literal(p, "null") ? cj_null() : NULL;
    case 't': return literal(p, "true") ? cj_bool(true) : NULL;
    case 'f': return literal(p, "false") ? cj_bool(false) : NULL;
    case '"': {
        size_t len;
        char *s = parse_string(p, &len);
        if (!s) return NULL;
        cj *value = cj_new(CJ_STRING);
        value->v.s.ptr = s;
        value->v.s.len = len;
        return value;
    }
    case '[': return parse_array(p);
    case '{': return parse_object(p);
    default:
        if (c == '-' || (c >= '0' && c <= '9')) return parse_number(p);
        return fail(p, "expected value");
    }
}

cj *cj_parsen(const char *text, size_t len, char **error) {
    if (error) *error = NULL;
    parser p = {.text = text ? text : "", .len = text ? len : 0};
    cj *value = parse_value(&p);
    if (value) {
        skip_ws(&p);
        if (p.pos < p.len) {
            cj_free(value);
            value = fail(&p, "trailing characters");
            p.pos++;
        }
    }
    if (!value && error) {
        size_t line, column;
        /* serde reports the column of the offending byte (1-based, 0 at EOF of an empty line). */
        position(&p, p.pos < p.len ? p.pos + 1 : p.pos, &line, &column);
        *error = cg_fmt("%s at line %zu column %zu", p.error ? p.error : "invalid JSON", line, column);
    }
    return value;
}

cj *cj_parse(const char *text, char **error) { return cj_parsen(text, text ? strlen(text) : 0, error); }
