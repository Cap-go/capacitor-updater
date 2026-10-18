/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Delay conditions (Rust engine/plugin/delay.rs, `setMultiDelay`): pending installs wait
 * until every stored condition is gone. Conditions are re-evaluated at launch (kill),
 * background and foreground. Also the ISO-8601 and native version comparisons they use.
 */
#ifndef CG_PLUGIN_DELAY_H
#define CG_PLUGIN_DELAY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "engine/engine_api.h"
#include "rt/json.h"

typedef enum {
    CG_DELAY_KILLED = 0,
    CG_DELAY_BACKGROUND,
    CG_DELAY_FOREGROUND,
} cg_delay_source;

/* DelaySource::name: "KILLED", "BACKGROUND", "FOREGROUND". */
const char *cg_delay_source_name(cg_delay_source source);

typedef struct {
    char *kind;  /* "background" | "kill" | "date" | "nativeVersion" */
    char *value; /* NULL = None */
} cg_delay_condition;

typedef struct {
    cg_delay_condition *items;
    size_t len, cap;
} cg_delay_conditions;

void cg_delay_conditions_clear(cg_delay_conditions *conditions);
/* DelayCondition::to_json. Owned. */
cj *cg_delay_condition_to_json(const cg_delay_condition *condition);

/* Parses stored conditions, dropping malformed entries and unknown kinds; each problem is
 * passed to log(ctx, message) (log may be NULL). *out initialized. */
void cg_delay_parse_delay_conditions(const char *raw, void (*log)(void *ctx, const char *message), void *ctx,
                                     cg_delay_conditions *out);
/* Option<bool>: -1 when `value` is unparseable, else 1 when now_ms is past it, 0 otherwise. */
int cg_delay_is_date_passed(const char *value, int64_t now_ms);
/* `yyyy-MM-ddTHH:mm:ss[.SSS][Z|±HH:mm|±HHmm|±HH]` (local time when no zone). false = None. */
bool cg_delay_parse_iso8601_ms(const char *value, int64_t *out);

/* Native version comparison (numeric components, then pre-release < release). */
typedef struct {
    uint64_t *numbers;
    size_t len;
    char *prerelease; /* NULL = None */
} cg_native_version;

/* NativeVersion::parse: false (None) when it does not start with a digit (after `v`). */
bool cg_native_version_parse(const char *value, cg_native_version *out);
/* Ord::cmp: <0, 0, >0. Equality follows the ordering (`beta.02` == `beta.2`). */
int cg_native_version_cmp(const cg_native_version *a, const cg_native_version *b);
void cg_native_version_clear(cg_native_version *version);

/* Stored conditions (`DELAY_CONDITION_PREFERENCES_CAPGO`), parse problems logged as warnings. */
void cg_delay_delay_conditions(cg_engine *engine, cg_delay_conditions *out);
bool cg_delay_has_delay_conditions(cg_engine *engine);
/* `conditions`: JSON array (borrowed). */
bool cg_delay_set_multi_delay(cg_engine *engine, const cj *conditions);
bool cg_delay_cancel_delay(cg_engine *engine, const char *source);
void cg_delay_set_background_timestamp(cg_engine *engine, int64_t timestamp);
void cg_delay_unset_background_timestamp(cg_engine *engine);
/* Drops the conditions satisfied by `source`; keeps the rest. */
void cg_delay_check_cancel_delay(cg_engine *engine, cg_delay_source source);

#endif
