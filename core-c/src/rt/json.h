/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * JSON values with the semantics of serde_json (the Rust core): objects keep
 * their keys sorted (BTreeMap), numbers are an unsigned, signed or floating
 * value, printing is compact with the same escaping and float formatting.
 *
 * Ownership: every function that takes a `cj *` to store (cj_set, cj_push,
 * builders) takes ownership of it. Getters return borrowed pointers.
 * A NULL `const cj *` reads as JSON null everywhere.
 */
#ifndef CG_JSON_H
#define CG_JSON_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    CJ_NULL = 0,
    CJ_BOOL,
    CJ_UINT,  /* non-negative integer (serde PosInt) */
    CJ_INT,   /* negative integer (serde NegInt) */
    CJ_FLOAT,
    CJ_STRING,
    CJ_ARRAY,
    CJ_OBJECT,
} cj_type;

typedef struct cj cj;

typedef struct cj_member {
    char *key;
    cj *value;
} cj_member;

struct cj {
    cj_type type;
    union {
        bool b;
        uint64_t u;
        int64_t i;
        double f;
        struct {
            char *ptr;
            size_t len;
        } s;
        struct {
            cj **items;
            size_t len, cap;
        } a;
        struct {
            cj_member *items; /* sorted by key (byte order) */
            size_t len, cap;
        } o;
    } v;
};

/* ---- construction */
cj *cj_null(void);
cj *cj_bool(bool value);
cj *cj_i64(int64_t value);
cj *cj_u64(uint64_t value);
/* Non-finite values become null (serde_json does the same). */
cj *cj_f64(double value);
/* Copies; NULL makes a JSON null. */
cj *cj_str(const char *value);
cj *cj_strn(const char *value, size_t len);
/* Takes ownership of a malloc'd string; NULL makes a JSON null. */
cj *cj_str_own(char *value);
cj *cj_arr(void);
cj *cj_obj(void);

/* Object from key/value pairs, NULL-terminated: cj_objv("a", cj_i64(1), "b", cj_str("x"), NULL).
 * A NULL value stores null. */
cj *cj_objv(const char *key, ...);
/* Array from values, terminated by CJ_END. */
#define CJ_END ((cj *)(intptr_t)-1)
cj *cj_arrv(cj *first, ...);

void cj_free(cj *value);
cj *cj_clone(const cj *value);
bool cj_eq(const cj *a, const cj *b);

/* ---- type checks (NULL reads as null) */
cj_type cj_typeof(const cj *value);
bool cj_is_null(const cj *value);
bool cj_is_bool(const cj *value);
bool cj_is_number(const cj *value);
bool cj_is_str(const cj *value);
bool cj_is_arr(const cj *value);
bool cj_is_obj(const cj *value);

/* ---- serde-style accessors: false / NULL when the type does not match */
const char *cj_as_str(const cj *value);
bool cj_as_bool(const cj *value, bool *out);
/* Integer in range only (floats refused), like serde as_i64 / as_u64. */
bool cj_as_i64(const cj *value, int64_t *out);
bool cj_as_u64(const cj *value, uint64_t *out);
/* Any number. */
bool cj_as_f64(const cj *value, double *out);

/* ---- objects */
cj *cj_get(const cj *object, const char *key);
/* Path lookup: cj_path(v, "a", "b", NULL). */
cj *cj_path(const cj *value, ...);
/* Stores value (owned) under key, replacing an existing one. No-op (value freed) if not an object. */
void cj_set(cj *object, const char *key, cj *value);
/* Removes and returns the value (caller owns), NULL when absent. */
cj *cj_take(cj *object, const char *key);
bool cj_remove(cj *object, const char *key);
bool cj_has(const cj *object, const char *key);
/* Inserts when absent (value owned; freed when the key exists). Returns the stored value. */
cj *cj_entry(cj *object, const char *key, cj *value);

/* Typed object reads. */
const char *cj_get_str(const cj *object, const char *key);
bool cj_get_bool(const cj *object, const char *key, bool fallback);

/* ---- arrays and objects */
size_t cj_len(const cj *value);
cj *cj_at(const cj *array, size_t index);
const char *cj_key_at(const cj *object, size_t index);
cj *cj_value_at(const cj *object, size_t index);
void cj_push(cj *array, cj *value);
/* Removes and returns element `index` (caller owns). */
cj *cj_remove_at(cj *array, size_t index);
void cj_clear(cj *value);

/* ---- text */
/* Compact serde_json text. Caller frees. */
char *cj_print(const cj *value);
/* Parses strict JSON (trailing whitespace allowed). On failure returns NULL and,
 * when `error` is set, a malloc'd serde-like message ("expected value at line 1 column 1"). */
cj *cj_parse(const char *text, char **error);
cj *cj_parsen(const char *text, size_t len, char **error);

#endif
