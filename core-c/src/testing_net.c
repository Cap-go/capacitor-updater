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
#include "text.h"
#include "crypto/checksum.h"

bool cg_testing_net(struct cg_engine *engine, const char *name, const cj *input, cj **result, cg_error *err);
bool cg_testing_net_pure(const char *name, const cj *input, cj **result, cg_error *err);

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

typedef struct { cg_buf bytes; bool cancel; int64_t limit; } collect;
static bool collect_body(void *context, const cg_net_stream *event, cg_net_error *err) {
    collect *body = context;
    if (event->kind == CG_NET_STREAM_CHUNK) {
        cg_buf_put(&body->bytes, event->data, event->len);
        if (body->cancel && (int64_t)body->bytes.len >= body->limit)
            return cg_net_error_set(err, CG_NET_IO, "download_stopped");
    }
    return true;
}

static cg_http *test_client(cg_engine *engine, const cj *input, cg_error *err) {
    const char *agent;
    bool present;
    int64_t timeout = 10000, connections = 0;
    if (!opt_str(input, "userAgent", &agent, err) || !opt_i64(input, "timeoutMs", &present, &timeout, err)) return NULL;
    if (!present) timeout = 10000;
    char *owned = agent ? cg_strdup(agent) : cg_engine_user_agent(engine);
    cg_http *client = cg_http_new(&engine->host, owned, timeout < 1 ? 1 : (uint64_t)timeout);
    free(owned);
    cg_engine_config *config = cg_engine_config_snapshot(engine);
    bool enabled = cj_get_bool(input, "http3", config->http3);
    if (!opt_i64(input, "http3Connections", &present, &connections, err)) {
        cg_config_release(config); cg_http_free(client); return NULL;
    }
    cg_http_set_http3(client, enabled, present ? (connections < 0 ? 0 : (size_t)connections) : config->http3_connections);
    cg_config_release(config);
    return client;
}

static bool run_request(cg_http *client, const cj *input, cj **result, cg_error *err) {
    const char *url;
    if (!req_str(input, "url", &url, err)) return false;
    const cj *list = cj_get(input, "headers");
    if (!cj_is_null(list) && !cj_is_arr(list)) return cg_err_invalid_input(err, "`headers` must be an array");
    size_t count = cj_len(list);
    cg_net_header *headers = cg_calloc(count, sizeof *headers);
    for (size_t i = 0; i < count; i++) {
        const cj *pair = cj_at(list, i);
        if (!cj_is_str(cj_at(pair, 0)) || !cj_is_str(cj_at(pair, 1))) {
            free(headers); return cg_err_invalid_input(err, "`headers` entries must be [name, value]");
        }
        headers[i] = (cg_net_header){cj_as_str(cj_at(pair, 0)), cj_as_str(cj_at(pair, 1))};
    }
    cg_net_error net = CG_NET_ERROR_INIT;
    if (cj_get_bool(input, "download", false)) {
        collect body = {0};
        if (!opt_i64(input, "cancelAfterBytes", &body.cancel, &body.limit, err)) { free(headers); return false; }
        cg_net_stream_head head = {0};
        bool ok = cg_http_download(client, url, headers, count, collect_body, &body, &head, &net);
        free(headers);
        if (ok) *result = cj_objv("status", cj_u64(head.status), "headers", headers_json(&head.headers),
            "bodyHex", cj_str_own(cg_text_hex_encode((const uint8_t *)body.bytes.data, body.bytes.len)),
            "protocol", cj_str(head.protocol), NULL);
        cg_net_stream_head_clear(&head);
        cg_buf_free(&body.bytes);
        if (!ok) net_error(&net, err);
        return ok;
    }
    const char *method;
    if (!opt_str(input, "method", &method, err)) { free(headers); return false; }
    if (!method) method = "GET";
    const cj *json = cj_get(input, "json");
    cg_net_response response = {0};
    bool ok = !cj_is_null(json) ? cg_http_send_json(client, method, url, json, &response, &net)
        : cg_http_send(client, method, url, headers, count, NULL, 0, &response, &net);
    free(headers);
    if (!ok) { net_error(&net, err); return false; }
    *result = cj_objv("status", cj_u64(response.status), "headers", headers_json(&response.headers),
        "bodyHex", cj_str_own(cg_text_hex_encode(response.body, response.body_len)), "protocol", cj_str(response.protocol), NULL);
    cg_net_response_clear(&response);
    return true;
}

typedef struct {
    cg_http *client;
    const cj *requests;
    cj **results;
    atomic_size_t next;
} batch;
static void *batch_worker(void *data) {
    batch *b = data;
    for (;;) {
        size_t index = atomic_fetch_add(&b->next, 1);
        if (index >= cj_len(b->requests)) break;
        cj *reply = NULL;
        cg_error err = CG_ERROR_INIT;
        if (run_request(b->client, cj_at(b->requests, index), &reply, &err)) {
            const char *hex = cj_get_str(reply, "bodyHex");
            uint8_t *bytes = NULL; size_t len = 0;
            bytes = cg_text_hex_decode(hex, &len);
            b->results[index] = cj_objv("status", cj_clone(cj_get(reply, "status")),
                "protocol", cj_clone(cj_get(reply, "protocol")), "bodyLength", cj_u64(len),
                "bodySha256", cj_str_own(cg_checksum_sha256_hex(bytes, len)), NULL);
            free(bytes); cj_free(reply);
        } else b->results[index] = cj_objv("error", cj_objv("code", cj_str(err.code), "message", cj_str(err.message), NULL), NULL);
        cg_err_clear(&err);
    }
    return NULL;
}

bool cg_testing_net(struct cg_engine *engine, const char *name, const cj *input, cj **result, cg_error *err) {
    if (strcmp(name, "httpProtocols") == 0) {
        *result = cj_objv("protocols", cg_http_protocols(engine->http), "quicConnections",
            cj_u64(cg_http_http3_connections_opened(engine->http)), NULL);
        return true;
    }
    bool is_batch = strcmp(name, "httpBatch") == 0;
    if (!is_batch && strcmp(name, "http") != 0) return false;
    cg_http *client = test_client(engine, input, err);
    if (!client) return true;
    if (!is_batch) run_request(client, input, result, err);
    else {
        const cj *requests = cj_get(input, "requests");
        if (!cj_is_arr(requests)) cg_err_invalid_input(err, "`requests` must be an array");
        else {
            size_t len = cj_len(requests);
            int64_t parallel = 0; bool present;
            if (opt_i64(input, "parallel", &present, &parallel, err)) {
                size_t workers = present ? (parallel < 1 ? 1 : (size_t)parallel) : len;
                if (workers > len) workers = len;
                batch b = {client, requests, cg_calloc(len, sizeof(cj *))};
                atomic_init(&b.next, 0);
                pthread_t *threads = cg_calloc(workers, sizeof *threads);
                size_t started = 0;
                for (; started + 1 < workers; started++)
                    if (pthread_create(&threads[started], NULL, batch_worker, &b) != 0) break;
                batch_worker(&b);
                for (size_t i = 0; i < started; i++) pthread_join(threads[i], NULL);
                free(threads);
                cj *out = cj_arr();
                for (size_t i = 0; i < len; i++) cj_push(out, b.results[i]);
                free(b.results);
                *result = cj_objv("results", out, "quicConnections", cj_u64(cg_http_http3_connections_opened(client)), NULL);
            }
        }
    }
    cg_http_free(client);
    return true;
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
