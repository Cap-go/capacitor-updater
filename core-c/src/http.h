/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* HTTP helper decisions shared by every host (Rust http.rs): user agent, resumable
 * downloads and rate-limit (429) handling. Pure rules; the network client is net.c. */
#ifndef CG_HTTP_H
#define CG_HTTP_H

#include <stdbool.h>
#include <stdint.h>

/* Upper bound for a client-side 429 block, so a bogus Retry-After cannot block for days. */
#define CG_MAX_RATE_LIMIT_WINDOW_MS (24.0 * 60.0 * 60.0 * 1000.0)

/* `CapacitorUpdater/<plugin> (<appId>) <platform>/<os>` restricted to header-safe
 * ISO-8859-1 (each value filtered, trimmed, "unknown" when empty). NULL reads as "".
 * malloc'd. */
char *cg_http_user_agent(const char *app_id, const char *plugin_version, const char *version_os,
                         const char *platform);

bool cg_http_is_retryable_http_status(int64_t status);

typedef struct {
    int64_t start;
    int64_t end;
    /* -1 when the server answered `*`. */
    int64_t total;
} cg_content_range;

/* Parses `Content-Range: bytes <start>-<end>/<total|*>`. false (Rust None) when absent
 * (NULL) or malformed. */
bool cg_http_parse_content_range(const char *header, cg_content_range *out);

typedef struct {
    int64_t response_code;
    int64_t write_offset;
} cg_zip_write_plan;

/* Decides how a (possibly resumed) zip download response must be written. Returns false
 * with *error_code = "invalid_content_range" (static) when a 206 does not continue the
 * partial file. content_range NULL = no header. */
bool cg_http_plan_zip_resume_write(int64_t response_code, int64_t downloaded_bytes, const char *content_range,
                                   cg_zip_write_plan *out, const char **error_code);

bool cg_http_should_append_http_body(int64_t status_code, int64_t existing_bytes);

/* `{"error": "...", "message": "..."}` from a backend error body: *error and *message are
 * malloc'd, "" when absent (body NULL, not a JSON object, or the field is not a string). */
void cg_http_parse_remote_error(const char *body, char **error, char **message);

/* Epoch ms until which requests must be blocked after a 429, or 0 for no block. Honours
 * `Retry-After`, then `retryAfterSeconds`, then `rateLimitResetAt` (in `moreInfo` first,
 * then top level), capped at one day. NULL = absent. */
int64_t cg_http_rate_limit_blocked_until_ms(const char *retry_after, const char *body, int64_t now_ms);

#endif
