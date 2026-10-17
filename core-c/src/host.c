/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#include "host.h"

#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>

/* The host contract: strings passed in are NUL-free (Rust CString::new(value.replace('\0', ""))). */
static char *c_string(const char *value) { return cg_replace_all(value ? value : "", "\0", ""); }

/* Takes a host-allocated string: copy, then free_string. */
static char *take_string(const cg_host *host, char *raw) {
    if (!raw) return NULL;
    char *value = cg_strdup(raw);
    if (host->cb.free_string) host->cb.free_string(host->cb.context, raw);
    return value;
}

void cg_host_release(cg_host *host) {
    if (host && host->cb.release) {
        void (*release)(void *) = host->cb.release;
        host->cb.release = NULL;
        release(host->cb.context);
    }
}

void cg_host_log(const cg_host *host, cg_log_level level, const char *message) {
    if (host && host->cb.log) host->cb.log(host->cb.context, (int)level, message ? message : "");
}

void cg_host_logf(const cg_host *host, cg_log_level level, const char *format, ...) {
    if (!host || !host->cb.log) return;
    va_list args;
    va_start(args, format);
    char *message = cg_vfmt(format, args);
    va_end(args);
    cg_host_log(host, level, message);
    free(message);
}

char *cg_host_kv_get(const cg_host *host, const char *key, const char *fallback) {
    if (host && host->cb.kv_get) {
        char *value = take_string(host, host->cb.kv_get(host->cb.context, key));
        if (value) return value;
    }
    return cg_strdup(fallback);
}

bool cg_host_kv_contains(const cg_host *host, const char *key) {
    char *value = cg_host_kv_get(host, key, NULL);
    bool found = value != NULL;
    free(value);
    return found;
}

void cg_host_kv_set(const cg_host *host, const char *key, const char *value) {
    if (host && host->cb.kv_set) host->cb.kv_set(host->cb.context, key, value);
}

cg_strs cg_host_kv_keys(const cg_host *host) {
    cg_strs keys = {0};
    if (!host || !host->cb.kv_keys) return keys;
    char *json = take_string(host, host->cb.kv_keys(host->cb.context));
    cj *parsed = json ? cj_parse(json, NULL) : NULL;
    free(json);
    /* serde: Vec<String> or nothing at all. */
    bool all_strings = cj_is_arr(parsed);
    for (size_t i = 0; all_strings && i < cj_len(parsed); i++)
        if (!cj_is_str(cj_at(parsed, i))) all_strings = false;
    if (all_strings)
        for (size_t i = 0; i < cj_len(parsed); i++) cg_strs_push_copy(&keys, cj_as_str(cj_at(parsed, i)));
    cj_free(parsed);
    return keys;
}

void cg_host_emit(const cg_host *host, const char *event, const cj *payload) {
    if (!host || !host->cb.emit) return;
    char *text = cj_print(payload);
    host->cb.emit(host->cb.context, event, text);
    free(text);
}

void cg_host_emit_retained(const cg_host *host, const char *event, const cj *payload) {
    cj *copy = cj_clone(payload);
    if (cj_is_obj(copy)) cj_set(copy, CG_RETAIN_EVENT_KEY, cj_bool(true));
    cg_host_emit(host, event, copy);
    cj_free(copy);
}

cj *cg_host_hook(const cg_host *host, const char *name, const cj *payload) {
    if (!host || !host->cb.hook) return NULL;
    char *text = cj_print(payload);
    char *reply = take_string(host, host->cb.hook(host->cb.context, name, text));
    free(text);
    if (!reply) return NULL;
    cj *value = cj_parse(reply, NULL);
    free(reply);
    return value;
}

int cg_host_cleartext_permitted(const cg_host *host, const char *hostname) {
    cj *payload = cj_objv("host", cj_str(hostname), NULL);
    cj *reply = cg_host_hook(host, "cleartextPermitted", payload);
    cj_free(payload);
    bool permitted;
    int result = cj_as_bool(cj_get(reply, "permitted"), &permitted) ? (permitted ? 1 : 0) : -1;
    cj_free(reply);
    return result;
}

bool cg_http_proxy_from_reply(const cj *reply, cg_http_proxy *out) {
    const char *type = cj_get_str(reply, "type");
    if (!type || !cg_eq_nocase(type, "http")) return false;
    const char *raw_host = cj_get_str(reply, "host");
    if (!raw_host) return false;
    char *host = cg_trim(raw_host);
    size_t len = strlen(host);
    if (len >= 2 && host[0] == '[' && host[len - 1] == ']') {
        memmove(host, host + 1, len - 2);
        host[len - 2] = 0;
    }
    uint64_t port;
    if (!cj_as_u64(cj_get(reply, "port"), &port)) {
        free(host);
        return false;
    }
    bool valid_host;
    if (strchr(host, ':')) {
        struct in6_addr address;
        valid_host = inet_pton(AF_INET6, host, &address) == 1;
    } else {
        valid_host = *host && !strpbrk(host, "@/ ");
    }
    if (!valid_host || port < 1 || port > 65535) {
        free(host);
        return false;
    }
    out->host = host;
    out->port = (uint16_t)port;
    return true;
}

bool cg_host_proxy_for_url(const cg_host *host, const char *url, cg_http_proxy *out) {
    cj *payload = cj_objv("url", cj_str(url), NULL);
    cj *reply = cg_host_hook(host, "proxyForUrl", payload);
    cj_free(payload);
    bool found = reply && cg_http_proxy_from_reply(reply, out);
    cj_free(reply);
    return found;
}

void cg_http_proxy_free(cg_http_proxy *proxy) {
    free(proxy->host);
    proxy->host = NULL;
}

static void hook_void(const cg_host *host, const char *name, cj *payload) {
    cj_free(cg_host_hook(host, name, payload));
    cj_free(payload);
}

void cg_host_will_switch_bundle(const cg_host *host, const char *path) {
    hook_void(host, "willSwitchBundle", cj_objv("path", cj_str(path), NULL));
}

bool cg_host_cancel_version_download(const cg_host *host, const char *version) {
    cj *payload = cj_objv("version", cj_str(version), NULL);
    cj *reply = cg_host_hook(host, "cancelVersionDownload", payload);
    cj_free(payload);
    bool cancelled = true;
    cj_as_bool(cj_get(reply, "cancelled"), &cancelled);
    cj_free(reply);
    return cancelled;
}

char *cg_host_before_download(const cg_host *host) {
    cj *payload = cj_obj();
    cj *reply = cg_host_hook(host, "beforeDownload", payload);
    cj_free(payload);
    char *error = cg_strdup(cj_get_str(reply, "error"));
    cj_free(reply);
    return error;
}

void cg_host_cancel_all_downloads(const cg_host *host) { hook_void(host, "cancelAllDownloads", cj_obj()); }

bool cg_host_send_stats(const cg_host *host, const char *action, const char *version_name,
                        const char *old_version_name) {
    cj *payload = cj_objv("action", cj_str(action), "versionName", cj_str(version_name), "oldVersionName",
                          cj_str(old_version_name), NULL);
    cj *reply = cg_host_hook(host, "sendStats", payload);
    cj_free(payload);
    bool handled = false;
    cj_as_bool(cj_get(reply, "handled"), &handled);
    cj_free(reply);
    return handled;
}

int cg_host_verify_certificate(const cg_host *host, const uint8_t *const *chain, const size_t *lengths, size_t count,
                               const char *server_name, char **error) {
    *error = NULL;
    if (!host || !host->cb.verify_server_certificate) return -1;
    char *name = c_string(server_name);
    char *raw_error = NULL;
    int32_t verdict =
        host->cb.verify_server_certificate(host->cb.context, name, chain, lengths, count, &raw_error);
    free(name);
    char *message = take_string(host, raw_error);
    /* Only an explicit 1 trusts the chain. */
    if (verdict == 1) {
        free(message);
        return 1;
    }
    *error = message ? message : cg_strdup("Certificate rejected by the platform trust store");
    return 0;
}

static _Thread_local const cg_host *method_lane;

void cg_method_lane_hold(const cg_host *host) { method_lane = host; }

void cg_method_lane_drop(void) { method_lane = NULL; }

void cg_release_method_lane(void) {
    const cg_host *host = method_lane;
    method_lane = NULL;
    if (host) hook_void(host, "releaseMethodLane", cj_obj());
}
