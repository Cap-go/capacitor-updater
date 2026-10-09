/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Test-only operations of the HTTP client (Rust testing.rs: `http`, `redirectAllowed`,
 * `proxyFromReply`). Built with CAPGO_TEST_SUPPORT. */

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "engine/engine.h"
#include "net.h"
#include "testing.h"

bool cg_testing_net(struct cg_engine *engine, const char *name, const cj *input, cj **result, cg_error *err);
bool cg_testing_net_pure(const char *name, const cj *input, cj **result, cg_error *err);

static char *hex_encode(const uint8_t *bytes, size_t len) {
    static const char digits[] = "0123456789abcdef";
    char *out = cg_malloc(len * 2 + 1);
    for (size_t i = 0; i < len; i++) {
        out[2 * i] = digits[bytes[i] >> 4];
        out[2 * i + 1] = digits[bytes[i] & 15];
    }
    out[len * 2] = 0;
    return out;
}

/* testing.rs opt_str: absent / null -> NULL. */
static bool opt_str(const cj *input, const char *key, const char **out, cg_error *err) {
    const cj *value = cj_get(input, key);
    *out = NULL;
    if (cj_is_null(value)) return true;
    if (cj_is_str(value)) {
        *out = cj_as_str(value);
        return true;
    }
    char *text = cj_print(value);
    cg_err_invalid_input(err, "`%s` must be a string, got %s", key, text);
    free(text);
    return false;
}

static bool req_str(const cj *input, const char *key, const char **out, cg_error *err) {
    if (!opt_str(input, key, out, err)) return false;
    if (!*out) return cg_err_invalid_input(err, "`%s` is required", key);
    return true;
}

static bool req_bool(const cj *input, const char *key, bool *out, cg_error *err) {
    if (!cj_as_bool(cj_get(input, key), out)) return cg_err_invalid_input(err, "`%s` must be a boolean", key);
    return true;
}

/* testing.rs opt_i64: integers, or floats without a fractional part. */
static bool opt_i64(const cj *input, const char *key, bool *present, int64_t *out, cg_error *err) {
    const cj *value = cj_get(input, key);
    *present = false;
    if (cj_is_null(value)) return true;
    double number;
    if (cj_as_i64(value, out)) {
        *present = true;
        return true;
    }
    if (cj_as_f64(value, &number) && isfinite(number) && number == trunc(number)) {
        *out = number >= 9223372036854775807.0 ? INT64_MAX : number <= -9223372036854775808.0 ? INT64_MIN
                                                                                              : (int64_t)number;
        *present = true;
        return true;
    }
    return cg_err_invalid_input(err, "`%s` must be an integer", key);
}

static bool net_error(cg_net_error *net, cg_error *err) {
    cg_err_set(err, cg_net_error_kind_code(net->kind), "%s", net->message ? net->message : "");
    cg_net_error_clear(net);
    return true;
}

static cj *headers_json(const cg_net_headers *headers) {
    cj *list = cj_arr();
    for (size_t i = 0; i < headers->len; i++)
        cj_push(list, cj_arrv(cj_str(headers->items[i].name), cj_str(headers->items[i].value), CJ_END));
    return list;
}

static bool collect_body(void *context, const cg_net_stream *event, cg_net_error *err) {
    if (event->kind == CG_NET_STREAM_CHUNK) cg_buf_put(context, event->data, event->len);
    return true;
}

/* testing.rs http_request: one request with a fresh client (no pooled connection or TLS session). */
static bool http_request(struct cg_engine *engine, const cj *input, cj **result, cg_error *err) {
    const char *user_agent_input;
    if (!opt_str(input, "userAgent", &user_agent_input, err)) return true;
    bool has_timeout;
    int64_t timeout_ms = 10000;
    if (!opt_i64(input, "timeoutMs", &has_timeout, &timeout_ms, err)) return true;
    if (!has_timeout) timeout_ms = 10000;
    if (timeout_ms < 1) timeout_ms = 1;
    char *user_agent = user_agent_input ? cg_strdup(user_agent_input) : cg_engine_user_agent(engine);
    cg_http *client = cg_http_new(&engine->host, user_agent, (uint64_t)timeout_ms);
    free(user_agent);
    const char *url;
    if (!req_str(input, "url", &url, err)) {
        cg_http_free(client);
        return true;
    }
    cg_net_error net = CG_NET_ERROR_INIT;
    bool download = false;
    cj_as_bool(cj_get(input, "download"), &download);
    if (download) {
        cg_buf body = {0};
        cg_net_stream_head head;
        if (!cg_http_download(client, url, NULL, 0, collect_body, &body, &head, &net)) {
            cg_buf_free(&body);
            cg_http_free(client);
            return net_error(&net, err);
        }
        *result = cj_objv("status", cj_u64(head.status), "headers", headers_json(&head.headers), "bodyHex",
                          cj_str_own(hex_encode((const uint8_t *)body.data, body.len)), NULL);
        cg_net_stream_head_clear(&head);
        cg_buf_free(&body);
        cg_http_free(client);
        return true;
    }
    const char *method;
    if (!opt_str(input, "method", &method, err)) {
        cg_http_free(client);
        return true;
    }
    if (!method) method = "GET";
    const cj *json = cj_get(input, "json");
    cg_net_response response;
    bool ok = !cj_is_null(json) ? cg_http_send_json(client, method, url, json, &response, &net)
                                : cg_http_send(client, method, url, NULL, 0, NULL, 0, &response, &net);
    cg_http_free(client);
    if (!ok) return net_error(&net, err);
    *result = cj_objv("status", cj_u64(response.status), "headers", headers_json(&response.headers), "bodyHex",
                      cj_str_own(hex_encode(response.body, response.body_len)), NULL);
    cg_net_response_clear(&response);
    return true;
}

bool cg_testing_net(struct cg_engine *engine, const char *name, const cj *input, cj **result, cg_error *err) {
    if (strcmp(name, "http") == 0) return http_request(engine, input, result, err);
    return false;
}

bool cg_testing_net_pure(const char *name, const cj *input, cj **result, cg_error *err) {
    if (strcmp(name, "redirectAllowed") == 0) {
        const char *from, *to;
        bool allow;
        if (req_str(input, "from", &from, err) && req_str(input, "to", &to, err) &&
            req_bool(input, "allowDowngrade", &allow, err))
            *result = cj_objv("allowed", cj_bool(cg_net_redirect_allowed(from, to, allow)), NULL);
        return true;
    }
    if (strcmp(name, "proxyFromReply") == 0) {
        cg_http_proxy proxy = {0};
        cj *value = cj_null();
        if (cg_http_proxy_from_reply(cj_get(input, "reply"), &proxy)) {
            cj_free(value);
            value = cj_objv("host", cj_str(proxy.host), "port", cj_u64(proxy.port), NULL);
            cg_http_proxy_free(&proxy);
        }
        *result = cj_objv("proxy", value, NULL);
        return true;
    }
    return false;
}
