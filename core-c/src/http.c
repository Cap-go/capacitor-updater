/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* HTTP helper decisions shared by every host: user agent, resumable downloads and
 * rate-limit (429) handling. The core only decides; the client lives in net.c. */

#include "http.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "rt/json.h"
#include "rt/str.h"
#include "text.h"

#define HTTP_OK 200
#define HTTP_PARTIAL 206

static void put_code_point(cg_buf *out, uint32_t cp) {
    if (cp < 0x80) {
        cg_buf_putc(out, (char)cp);
    } else {
        /* Only U+00A0..U+00FF are kept besides ASCII. */
        cg_buf_putc(out, (char)(0xc0 | (cp >> 6)));
        cg_buf_putc(out, (char)(0x80 | (cp & 0x3f)));
    }
}

static void put_sanitized_user_agent_value(cg_buf *out, const char *value) {
    size_t len = value ? strlen(value) : 0;
    uint32_t *kept = cg_malloc((len + 1) * sizeof(uint32_t));
    size_t count = 0;
    for (size_t i = 0; i < len;) {
        uint32_t cp;
        i += cg_text_utf8_next(value + i, len - i, &cp);
        if ((cp >= 0x20 && cp <= 0x7e) || (cp >= 0xa0 && cp <= 0xff)) kept[count++] = cp;
    }
    size_t start = 0, end = count;
    while (start < end && (kept[start] == ' ' || kept[start] == 0xa0)) start++;
    while (end > start && (kept[end - 1] == ' ' || kept[end - 1] == 0xa0)) end--;
    if (start == end) {
        cg_buf_puts(out, "unknown");
    } else {
        for (size_t i = start; i < end; i++) put_code_point(out, kept[i]);
    }
    free(kept);
}

char *cg_http_user_agent(const char *app_id, const char *plugin_version, const char *version_os,
                         const char *platform) {
    cg_buf out = {0};
    cg_buf_puts(&out, "CapacitorUpdater/");
    put_sanitized_user_agent_value(&out, plugin_version);
    cg_buf_puts(&out, " (");
    put_sanitized_user_agent_value(&out, app_id);
    cg_buf_puts(&out, ") ");
    put_sanitized_user_agent_value(&out, platform);
    cg_buf_putc(&out, '/');
    put_sanitized_user_agent_value(&out, version_os);
    return cg_buf_take(&out);
}

bool cg_http_is_retryable_http_status(int64_t status) { return status >= 500 || status == 408 || status == 429; }

/* java_trim(value).parse::<i64>() over value[0..len). */
static bool parse_java_long(const char *value, size_t len, int64_t *out) {
    char *copy = cg_strndup(value, len);
    size_t start, trimmed;
    cg_text_java_trim_range(copy, &start, &trimmed);
    copy[start + trimmed] = 0;
    bool ok = cg_parse_i64(copy + start, out);
    free(copy);
    return ok;
}

bool cg_http_parse_content_range(const char *header, cg_content_range *out) {
    if (!header) return false;
    size_t start, len;
    cg_text_java_trim_range(header, &start, &len);
    const char *trimmed = header + start;
    if (len < 6 || memcmp(trimmed, "bytes ", 6) != 0) return false;
    const char *rest = trimmed + 6;
    size_t rest_len = len - 6;
    const char *slash = memchr(rest, '/', rest_len);
    const char *dash = memchr(rest, '-', rest_len);
    if (!slash || !dash || dash >= slash) return false;
    cg_content_range range;
    if (!parse_java_long(rest, (size_t)(dash - rest), &range.start)) return false;
    if (!parse_java_long(dash + 1, (size_t)(slash - dash - 1), &range.end)) return false;
    const char *total_part = slash + 1;
    size_t total_len = rest_len - (size_t)(total_part - rest);
    size_t total_start, total_trimmed;
    char *total_copy = cg_strndup(total_part, total_len);
    cg_text_java_trim_range(total_copy, &total_start, &total_trimmed);
    if (total_trimmed == 1 && total_copy[total_start] == '*') {
        range.total = -1;
    } else if (!parse_java_long(total_copy + total_start, total_trimmed, &range.total)) {
        free(total_copy);
        return false;
    }
    free(total_copy);
    if (range.end < range.start) return false;
    if (out) *out = range;
    return true;
}

bool cg_http_plan_zip_resume_write(int64_t response_code, int64_t downloaded_bytes, const char *content_range,
                                   cg_zip_write_plan *out, const char **error_code) {
    cg_zip_write_plan plan;
    if (response_code == HTTP_PARTIAL) {
        cg_content_range range;
        int64_t range_start = cg_http_parse_content_range(content_range, &range) ? range.start : -1;
        if (range_start == downloaded_bytes) {
            plan = (cg_zip_write_plan){HTTP_PARTIAL, downloaded_bytes};
        } else if (range_start == 0) {
            plan = (cg_zip_write_plan){HTTP_OK, 0};
        } else {
            if (error_code) *error_code = "invalid_content_range";
            return false;
        }
    } else if (response_code == HTTP_OK && downloaded_bytes > 0) {
        plan = (cg_zip_write_plan){HTTP_OK, 0};
    } else {
        plan = (cg_zip_write_plan){response_code, downloaded_bytes};
    }
    if (out) *out = plan;
    return true;
}

bool cg_http_should_append_http_body(int64_t status_code, int64_t existing_bytes) {
    return existing_bytes > 0 && status_code == HTTP_PARTIAL;
}

/* serde_json::from_str::<Value>(body) when it is an object; NULL otherwise. */
static cj *parse_json_object(const char *body) {
    if (!body) return NULL;
    cj *json = cj_parse(body, NULL);
    if (!cj_is_obj(json)) {
        cj_free(json);
        return NULL;
    }
    return json;
}

void cg_http_parse_remote_error(const char *body, char **error, char **message) {
    cj *json = parse_json_object(body);
    *error = cg_strdup(cg_or_empty(cj_as_str(cj_get(json, "error"))));
    *message = cg_strdup(cg_or_empty(cj_as_str(cj_get(json, "message"))));
    cj_free(json);
}

/* moreInfo.<key> as f64, else <key> as f64. */
static bool rate_limit_number(const cj *json, const char *key, double *out) {
    cj *more_info = cj_get(json, "moreInfo");
    if (cj_is_obj(more_info) && cj_as_f64(cj_get(more_info, key), out)) return true;
    return cj_as_f64(cj_get(json, key), out);
}

static double raw_rate_limit_deadline_ms(const char *retry_after, const char *body, double now_ms) {
    if (retry_after) {
        size_t start, len;
        cg_text_java_trim_range(retry_after, &start, &len);
        double seconds;
        if (cg_text_parse_f64(retry_after + start, len, &seconds) && seconds >= 0.0) return now_ms + seconds * 1000.0;
    }
    cj *json = parse_json_object(body);
    if (json) {
        double value;
        if (rate_limit_number(json, "retryAfterSeconds", &value) && value >= 0.0) {
            cj_free(json);
            return now_ms + value * 1000.0;
        }
        if (rate_limit_number(json, "rateLimitResetAt", &value)) {
            cj_free(json);
            return value;
        }
        cj_free(json);
    }
    /* No retry hint: no client-side block, allow an immediate retry. */
    return 0.0;
}

int64_t cg_http_rate_limit_blocked_until_ms(const char *retry_after, const char *body, int64_t now_ms) {
    double now = (double)now_ms;
    double candidate = raw_rate_limit_deadline_ms(retry_after, body, now);
    /* NaN and past deadlines mean "no client-side block"; anything further out is capped. */
    if (isnan(candidate) || candidate <= now) return 0;
    double cap = now + CG_MAX_RATE_LIMIT_WINDOW_MS;
    return cg_text_f64_to_i64_saturating(candidate < cap ? candidate : cap);
}
