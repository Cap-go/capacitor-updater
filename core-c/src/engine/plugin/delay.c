/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Delay conditions (`setMultiDelay`): pending installs wait until every stored condition is
 * gone. Conditions are re-evaluated at launch (kill), background and foreground.
 * Port of Rust engine/plugin/delay.rs.
 */
#include "engine/plugin/delay.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "engine/engine.h"
#include "engine/plugin/plugin.h"
#include "host.h"
#include "rt/str.h"

const char *cg_delay_source_name(cg_delay_source source) {
    switch (source) {
    case CG_DELAY_KILLED:
        return "KILLED";
    case CG_DELAY_BACKGROUND:
        return "BACKGROUND";
    case CG_DELAY_FOREGROUND:
        return "FOREGROUND";
    }
    return "KILLED";
}

/* ---- DelayCondition */

static void conditions_push(cg_delay_conditions *conditions, char *kind, char *value) {
    if (conditions->len == conditions->cap) {
        conditions->cap = conditions->cap ? conditions->cap * 2 : 4;
        conditions->items = cg_realloc(conditions->items, conditions->cap * sizeof *conditions->items);
    }
    conditions->items[conditions->len].kind = kind;
    conditions->items[conditions->len].value = value;
    conditions->len++;
}

void cg_delay_conditions_clear(cg_delay_conditions *conditions) {
    if (!conditions) return;
    for (size_t i = 0; i < conditions->len; i++) {
        free(conditions->items[i].kind);
        free(conditions->items[i].value);
    }
    free(conditions->items);
    memset(conditions, 0, sizeof *conditions);
}

cj *cg_delay_condition_to_json(const cg_delay_condition *condition) {
    if (condition->value) return cj_objv("kind", cj_str(condition->kind), "value", cj_str(condition->value), NULL);
    return cj_objv("kind", cj_str(condition->kind), NULL);
}

static const char *const KINDS[4] = {"background", "kill", "date", "nativeVersion"};

static bool known_kind(const cj *kind) {
    if (cj_str_has_nul(kind)) return false;
    const char *text = cj_as_str(kind);
    for (size_t i = 0; i < 4; i++)
        if (strcmp(text, KINDS[i]) == 0) return true;
    return false;
}

static void delay_log(void (*log)(void *ctx, const char *message), void *ctx, char *message) {
    if (log) log(ctx, message);
    free(message);
}

void cg_delay_parse_delay_conditions(const char *raw, void (*log)(void *ctx, const char *message), void *ctx,
                                     cg_delay_conditions *out) {
    memset(out, 0, sizeof *out);
    char *error = NULL;
    cj *parsed = cj_parse(raw ? raw : "", &error);
    if (!parsed) {
        delay_log(log, ctx, cg_fmt("Failed to parse delay conditions: %s", error ? error : ""));
        free(error);
        return;
    }
    free(error);
    if (!cj_is_arr(parsed)) {
        delay_log(log, ctx, cg_strdup("Failed to parse delay conditions: not an array"));
        cj_free(parsed);
        return;
    }
    for (size_t index = 0; index < cj_len(parsed); index++) {
        const cj *object = cj_at(parsed, index);
        if (!cj_is_obj(object)) continue;
        const cj *kind = cj_get(object, "kind");
        if (!cj_is_str(kind)) {
            delay_log(log, ctx, cg_fmt("Delay condition missing kind at index %zu", index));
            continue;
        }
        if (!known_kind(kind)) {
            delay_log(log, ctx, cg_fmt("Unknown delay condition kind '%s' at index %zu", cj_as_str(kind), index));
            continue;
        }
        const cj *value = cj_get(object, "value");
        char *text = NULL;
        if (cj_is_str(value)) text = cg_strdup(cj_as_str(value));
        else if (cj_is_number(value)) text = cj_print(value);
        conditions_push(out, cg_strdup(cj_as_str(kind)), text);
    }
    cj_free(parsed);
}

/* ---- ISO 8601 */

/* Option<i64>: non-empty, ASCII digits only, fits an i64. */
static bool digits(const char *text, size_t len, int64_t *out) {
    if (len == 0) return false;
    int64_t value = 0;
    for (size_t i = 0; i < len; i++) {
        if (text[i] < '0' || text[i] > '9') return false;
        int digit = text[i] - '0';
        if (value > (INT64_MAX - digit) / 10) return false;
        value = value * 10 + digit;
    }
    *out = value;
    return true;
}

static int64_t days_in_month(int64_t year, int64_t month) {
    switch (month) {
    case 2:
        return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28;
    case 4:
    case 6:
    case 9:
    case 11:
        return 30;
    default:
        return 31;
    }
}

/* Days since 1970-01-01 (proleptic Gregorian). */
static int64_t days_from_civil(int64_t year, int64_t month, int64_t day) {
    year = month <= 2 ? year - 1 : year;
    int64_t era = (year >= 0 ? year : year - 399) / 400;
    int64_t yoe = year - era * 400;
    int64_t month_index = (month + 9) % 12;
    int64_t doy = (153 * month_index + 2) / 5 + day - 1;
    int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

/* Local UTC offset (seconds) at the instant `utc_seconds`. */
static int64_t local_offset_seconds(int64_t utc_seconds) {
    time_t time = (time_t)utc_seconds;
    struct tm tm;
    memset(&tm, 0, sizeof tm);
    if (!localtime_r(&time, &tm)) return 0;
    return (int64_t)tm.tm_gmtoff;
}

/* UTC seconds of a local wall-clock time; the offset is looked up again at the first
 * estimate, so a DST change between the pseudo-UTC instant and the real one is honoured. */
static int64_t local_to_utc_seconds(int64_t local) {
    int64_t estimate = local - local_offset_seconds(local);
    return local - local_offset_seconds(estimate);
}

/* Splits the next `sep`-separated part of [*cursor, end): false when there is none (Rust
 * `split(sep).next()` is None only after the last part). */
typedef struct {
    const char *at, *end;
    bool done;
} splitter;

static bool split_next(splitter *split, char sep, const char **part, size_t *len) {
    if (split->done) return false;
    const char *stop = memchr(split->at, sep, (size_t)(split->end - split->at));
    if (!stop) {
        *part = split->at;
        *len = (size_t)(split->end - split->at);
        split->done = true;
        return true;
    }
    *part = split->at;
    *len = (size_t)(stop - split->at);
    split->at = stop + 1;
    return true;
}

bool cg_delay_parse_iso8601_ms(const char *raw, int64_t *out) {
    size_t start, total;
    cg_trim_range(raw ? raw : "", &start, &total);
    const char *value = (raw ? raw : "") + start;
    for (size_t i = 0; i < total; i++)
        if ((unsigned char)value[i] >= 0x80) return false;
    if (total < 19 || value[10] != 'T') return false;
    const char *rest = value + 11;
    size_t rest_len = total - 11;

    splitter date = {value, value + 10, false};
    const char *part;
    size_t len;
    int64_t year, month, day;
    if (!split_next(&date, '-', &part, &len) || !digits(part, len, &year)) return false;
    if (!split_next(&date, '-', &part, &len) || !digits(part, len, &month)) return false;
    if (!split_next(&date, '-', &part, &len) || !digits(part, len, &day)) return false;
    if (split_next(&date, '-', &part, &len) || month < 1 || month > 12 || day < 1 ||
        day > days_in_month(year, month))
        return false;

    splitter time = {rest, rest + 8, false};
    int64_t hour, minute, second;
    if (!split_next(&time, ':', &part, &len) || !digits(part, len, &hour)) return false;
    if (!split_next(&time, ':', &part, &len) || !digits(part, len, &minute)) return false;
    if (!split_next(&time, ':', &part, &len) || !digits(part, len, &second)) return false;
    if (hour > 23 || minute > 59 || second > 60) return false;

    const char *tail = rest + 8;
    size_t tail_len = rest_len - 8;
    int64_t millis = 0;
    if (tail_len > 0 && tail[0] == '.') {
        const char *fraction = tail + 1;
        size_t fraction_len = tail_len - 1;
        size_t end = 0;
        while (end < fraction_len && fraction[end] >= '0' && fraction[end] <= '9') end++;
        if (end == 0) return false;
        char padded[4] = {'0', '0', '0', 0};
        memcpy(padded, fraction, end < 3 ? end : 3);
        millis = (padded[0] - '0') * 100 + (padded[1] - '0') * 10 + (padded[2] - '0');
        tail = fraction + end;
        tail_len = fraction_len - end;
    }

    bool has_offset;
    int64_t offset_minutes = 0;
    if (tail_len == 0) {
        has_offset = false;
    } else if (tail_len == 1 && (tail[0] == 'Z' || tail[0] == 'z')) {
        has_offset = true;
    } else {
        int64_t sign;
        if (tail[0] == '+') sign = 1;
        else if (tail[0] == '-') sign = -1;
        else return false;
        char body[64];
        size_t body_len = 0;
        for (size_t i = 1; i < tail_len; i++) {
            if (tail[i] == ':') continue;
            if (body_len == sizeof body) return false; /* longer than 4: rejected below anyway */
            body[body_len++] = tail[i];
        }
        int64_t hours, minutes = 0;
        if (body_len == 2) {
            if (!digits(body, 2, &hours)) return false;
        } else if (body_len == 4) {
            if (!digits(body, 2, &hours) || !digits(body + 2, 2, &minutes)) return false;
        } else {
            return false;
        }
        has_offset = true;
        offset_minutes = sign * (hours * 60 + minutes);
    }
    int64_t days = days_from_civil(year, month, day);
    int64_t seconds = days * 86400 + hour * 3600 + minute * 60 + second;
    int64_t utc_seconds = has_offset ? seconds - offset_minutes * 60 : local_to_utc_seconds(seconds);
    *out = utc_seconds * 1000 + millis;
    return true;
}

int cg_delay_is_date_passed(const char *value, int64_t now_ms) {
    int64_t deadline;
    if (!cg_delay_parse_iso8601_ms(value, &deadline)) return -1;
    return now_ms > deadline ? 1 : 0;
}

/* ---- NativeVersion */

/* Decodes one UTF-8 character (input is valid UTF-8: JSON / host strings). */
static size_t utf8_next(const unsigned char *s, size_t n, uint32_t *cp) {
    unsigned char c = s[0];
    size_t need = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 1;
    if (need > n) need = 1;
    if (need == 1) {
        *cp = c;
        return 1;
    }
    uint32_t value = c & (0x7f >> need);
    for (size_t i = 1; i < need; i++) value = (value << 6) | (s[i] & 0x3f);
    *cp = value;
    return need;
}

/* char::is_whitespace (Unicode White_Space). */
static bool unicode_whitespace(uint32_t c) {
    return (c >= 0x09 && c <= 0x0d) || c == 0x20 || c == 0x85 || c == 0xa0 || c == 0x1680 ||
           (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000;
}

bool cg_native_version_parse(const char *raw, cg_native_version *out) {
    memset(out, 0, sizeof *out);
    const unsigned char *s = (const unsigned char *)(raw ? raw : "");
    size_t n = strlen((const char *)s);
    cg_buf compact = {0};
    for (size_t i = 0; i < n;) {
        uint32_t cp;
        size_t step = utf8_next(s + i, n - i, &cp);
        if (!unicode_whitespace(cp)) cg_buf_put(&compact, s + i, step);
        i += step;
    }
    char *text = cg_buf_take(&compact);
    const char *value = text[0] == 'v' ? text + 1 : text;
    if (!(value[0] >= '0' && value[0] <= '9')) {
        free(text);
        return false;
    }
    size_t core_len = strcspn(value, "+");
    size_t index = 0;
    while (index < core_len && ((value[index] >= '0' && value[index] <= '9') || value[index] == '.')) index++;
    size_t numbers_len = index;
    char *prerelease = NULL;
    if (index < core_len) {
        size_t suffix = index;
        while (suffix < core_len && (value[suffix] == '-' || value[suffix] == '.')) suffix++;
        if (suffix < core_len) {
            prerelease = cg_strndup(value + suffix, core_len - suffix);
            for (char *p = prerelease; *p; p++)
                if (*p >= 'A' && *p <= 'Z') *p = (char)(*p + 32);
        }
    }
    uint64_t *numbers = NULL;
    size_t count = 0, cap = 0;
    splitter split = {value, value + numbers_len, false};
    const char *part;
    size_t len;
    while (split_next(&split, '.', &part, &len)) {
        if (len == 0) continue;
        uint64_t number = 0;
        bool overflow = false;
        for (size_t i = 0; i < len; i++) {
            int digit = part[i] - '0';
            if (number > (UINT64_MAX - (uint64_t)digit) / 10) {
                overflow = true;
                break;
            }
            number = number * 10 + (uint64_t)digit;
        }
        if (count == cap) {
            cap = cap ? cap * 2 : 4;
            numbers = cg_realloc(numbers, cap * sizeof *numbers);
        }
        numbers[count++] = overflow ? UINT64_MAX : number;
    }
    while (count > 0 && numbers[count - 1] == 0) count--;
    free(text);
    out->numbers = numbers;
    out->len = count;
    out->prerelease = prerelease;
    return true;
}

void cg_native_version_clear(cg_native_version *version) {
    if (!version) return;
    free(version->numbers);
    free(version->prerelease);
    memset(version, 0, sizeof *version);
}

/* str Ord: byte-wise, then length. */
static int compare_bytes(const char *a, size_t a_len, const char *b, size_t b_len) {
    int order = memcmp(a, b, a_len < b_len ? a_len : b_len);
    if (order != 0) return order < 0 ? -1 : 1;
    return a_len < b_len ? -1 : a_len > b_len ? 1 : 0;
}

/* Numeric identifier: non-empty, ASCII digits only; trimmed of leading zeros. */
static bool numeric(const char *identifier, size_t len, const char **trimmed, size_t *trimmed_len) {
    if (len == 0) return false;
    for (size_t i = 0; i < len; i++)
        if (identifier[i] < '0' || identifier[i] > '9') return false;
    size_t skip = 0;
    while (skip < len && identifier[skip] == '0') skip++;
    *trimmed = identifier + skip;
    *trimmed_len = len - skip;
    return true;
}

/* SemVer precedence: dot-separated identifiers compared in order, numeric ones numerically
 * and below alphanumeric ones; a shorter list of equal identifiers comes first. */
static int compare_prerelease(const char *left, const char *right) {
    splitter left_parts = {left, left + strlen(left), false};
    splitter right_parts = {right, right + strlen(right), false};
    for (;;) {
        const char *a, *b;
        size_t a_len, b_len;
        bool has_a = split_next(&left_parts, '.', &a, &a_len);
        bool has_b = split_next(&right_parts, '.', &b, &b_len);
        if (!has_a && !has_b) return 0;
        if (!has_a) return -1;
        if (!has_b) return 1;
        const char *na, *nb;
        size_t na_len, nb_len;
        bool a_numeric = numeric(a, a_len, &na, &na_len);
        bool b_numeric = numeric(b, b_len, &nb, &nb_len);
        int ordering;
        if (a_numeric && b_numeric) {
            ordering = na_len < nb_len ? -1 : na_len > nb_len ? 1 : compare_bytes(na, na_len, nb, nb_len);
        } else if (a_numeric) {
            ordering = -1;
        } else if (b_numeric) {
            ordering = 1;
        } else {
            ordering = compare_bytes(a, a_len, b, b_len);
        }
        if (ordering != 0) return ordering;
    }
}

int cg_native_version_cmp(const cg_native_version *a, const cg_native_version *b) {
    size_t length = a->len > b->len ? a->len : b->len;
    for (size_t index = 0; index < length; index++) {
        uint64_t left = index < a->len ? a->numbers[index] : 0;
        uint64_t right = index < b->len ? b->numbers[index] : 0;
        if (left != right) return left < right ? -1 : 1;
    }
    if (!a->prerelease && !b->prerelease) return 0;
    if (!a->prerelease) return 1;
    if (!b->prerelease) return -1;
    return compare_prerelease(a->prerelease, b->prerelease);
}

/* ---- Engine */

static void warn_log(void *ctx, const char *message) { cg_host_log(&((cg_engine *)ctx)->host, CG_WARN, message); }

void cg_delay_delay_conditions(cg_engine *engine, cg_delay_conditions *out) {
    char *raw = cg_plugin_kv_text(engine, CG_KEY_DELAY_CONDITIONS);
    cg_delay_parse_delay_conditions(raw ? raw : "[]", warn_log, engine, out);
    free(raw);
}

bool cg_delay_has_delay_conditions(cg_engine *engine) {
    cg_delay_conditions conditions;
    cg_delay_delay_conditions(engine, &conditions);
    bool has = conditions.len > 0;
    cg_delay_conditions_clear(&conditions);
    return has;
}

static void write_conditions(cg_engine *engine, const cj *array) {
    char *text = cj_print(array);
    cg_plugin_kv_write(engine, CG_KEY_DELAY_CONDITIONS, text);
    free(text);
}

/* Stores conditions; `background` without a value means "0 ms". */
bool cg_delay_set_multi_delay(cg_engine *engine, const cj *conditions) {
    cj *normalized = cj_arr();
    for (size_t i = 0; i < cj_len(conditions); i++) {
        cj *condition = cj_clone(cj_at(conditions, i));
        if (cj_is_obj(condition)) {
            const cj *kind = cj_get(condition, "kind");
            bool is_background = cj_is_str(kind) && !cj_str_has_nul(kind) && strcmp(cj_as_str(kind), "background") == 0;
            const cj *value = cj_get(condition, "value");
            bool empty = !value || (cj_is_str(value) && cj_len(value) == 0) || cj_is_null(value);
            if (is_background && empty) cj_set(condition, "value", cj_str("0"));
        }
        cj_push(normalized, condition);
    }
    write_conditions(engine, normalized);
    cj_free(normalized);
    cg_host_log(&engine->host, CG_INFO, "Delay update saved");
    return true;
}

bool cg_delay_cancel_delay(cg_engine *engine, const char *source) {
    cg_plugin_kv_write(engine, CG_KEY_DELAY_CONDITIONS, NULL);
    cg_info(&engine->host, "All delays canceled from %s", source);
    return true;
}

void cg_delay_set_background_timestamp(cg_engine *engine, int64_t timestamp) {
    char *text = cg_fmt("%lld", (long long)timestamp);
    cg_plugin_kv_write(engine, CG_KEY_BACKGROUND_TIMESTAMP, text);
    free(text);
}

void cg_delay_unset_background_timestamp(cg_engine *engine) {
    cg_plugin_kv_write(engine, CG_KEY_BACKGROUND_TIMESTAMP, NULL);
}

/* Rust `text.trim().parse::<i64>()`. */
static bool parse_trimmed_i64(const char *text, int64_t *out) {
    char *trimmed = cg_trim(text ? text : "");
    bool ok = cg_parse_i64(trimmed, out);
    free(trimmed);
    return ok;
}

static int64_t background_timestamp(cg_engine *engine) {
    char *value = cg_plugin_kv_text(engine, CG_KEY_BACKGROUND_TIMESTAMP);
    int64_t timestamp = 0;
    if (!value || !parse_trimmed_i64(value, &timestamp)) timestamp = 0;
    free(value);
    return timestamp;
}

/* Drops the conditions satisfied by `source`; keeps the rest. */
void cg_delay_check_cancel_delay(cg_engine *engine, cg_delay_source source) {
    cg_delay_conditions conditions;
    cg_delay_delay_conditions(engine, &conditions);
    if (conditions.len == 0) {
        cg_delay_conditions_clear(&conditions);
        return;
    }
    cg_plugin_config config;
    cg_plugin_plugin_config(engine, &config);
    cg_native_version native;
    bool has_native = cg_native_version_parse(config.native_version, &native);
    cg_plugin_config_clear(&config);
    int64_t now = cg_plugin_now_ms();
    const cg_host *host = &engine->host;
    cj *stored = cj_arr();
    for (size_t index = 0; index < conditions.len; index++) {
        const cg_delay_condition *condition = &conditions.items[index];
        const char *value = condition->value ? condition->value : "";
        bool keep;
        if (strcmp(condition->kind, "background") == 0) {
            if (source == CG_DELAY_FOREGROUND) {
                int64_t delta = now - background_timestamp(engine);
                if (delta < 0) delta = 0;
                int64_t limit;
                if (!parse_trimmed_i64(value, &limit)) {
                    cg_warn(host,
                            "Background condition (value: %s) had an invalid value at index %zu. We will likely "
                            "remove it.",
                            value, index);
                    limit = 0;
                }
                keep = delta <= limit;
            } else {
                keep = true;
            }
        } else if (strcmp(condition->kind, "kill") == 0) {
            keep = source != CG_DELAY_KILLED;
        } else if (strcmp(condition->kind, "date") == 0) {
            if (!*value) {
                cg_error_log(host, "Date delay (value: %s) condition removed due to empty value at index %zu", value,
                             index);
                keep = false;
            } else {
                int passed = cg_delay_is_date_passed(value, now);
                if (passed < 0) {
                    cg_error_log(host, "Date delay (value: %s) condition removed due to parsing issue at index %zu",
                                 value, index);
                    keep = false;
                } else {
                    keep = !passed;
                }
            }
        } else if (strcmp(condition->kind, "nativeVersion") == 0) {
            cg_native_version limit;
            if (cg_native_version_parse(value, &limit) && has_native) {
                keep = cg_native_version_cmp(&native, &limit) < 0;
                cg_native_version_clear(&limit);
            } else {
                cg_native_version_clear(&limit);
                cg_error_log(host,
                             "Native version delay (value: %s) condition removed due to parsing issue at index %zu",
                             value, index);
                keep = false;
            }
        } else {
            keep = false;
        }
        cg_info(host, "%s delay (value: %s) %s at index %zu (source: %s)", condition->kind, value,
                keep ? "kept" : "removed", index, cg_delay_source_name(source));
        if (keep) cj_push(stored, cg_delay_condition_to_json(condition));
    }
    if (has_native) cg_native_version_clear(&native);
    if (cj_len(stored) == 0) cg_delay_cancel_delay(engine, "checkCancelDelay");
    else write_conditions(engine, stored);
    cj_free(stored);
    cg_delay_conditions_clear(&conditions);
}
