/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * What the engine needs from the platform (Rust host.rs + the C-ABI host of
 * ffi.rs): logging, key-value storage, events, hooks and TLS verification,
 * reached through the CapgoHostCallbacks of include/capgo_updater_core.h.
 * Every function is thread-safe and NULL-safe on missing callbacks.
 */
#ifndef CG_HOST_H
#define CG_HOST_H

#include <stdbool.h>
#include <stdint.h>

#include "capgo_updater_core.h"
#include "rt/json.h"
#include "rt/str.h"

typedef enum { CG_DEBUG = 0, CG_INFO = 1, CG_WARN = 2, CG_ERROR = 3 } cg_log_level;

/* Payload flag of retained events (Host::emit_retained). */
#define CG_RETAIN_EVENT_KEY "__retainUntilConsumed"

typedef struct cg_host {
    CapgoHostCallbacks cb;
} cg_host;

/* Releases the host context (callbacks.release), once. */
void cg_host_release(cg_host *host);

void cg_host_log(const cg_host *host, cg_log_level level, const char *message);
void cg_host_logf(const cg_host *host, cg_log_level level, const char *format, ...) CG_PRINTF(3, 4);
#define cg_debug(host, ...) cg_host_logf((host), CG_DEBUG, __VA_ARGS__)
#define cg_info(host, ...) cg_host_logf((host), CG_INFO, __VA_ARGS__)
#define cg_warn(host, ...) cg_host_logf((host), CG_WARN, __VA_ARGS__)
#define cg_error_log(host, ...) cg_host_logf((host), CG_ERROR, __VA_ARGS__)

/* malloc'd value; `fallback` copy (or NULL) when absent. */
char *cg_host_kv_get(const cg_host *host, const char *key, const char *fallback);
bool cg_host_kv_contains(const cg_host *host, const char *key);
/* NULL value removes the key. */
void cg_host_kv_set(const cg_host *host, const char *key, const char *value);
cg_strs cg_host_kv_keys(const cg_host *host);

void cg_host_emit(const cg_host *host, const char *event, const cj *payload);
void cg_host_emit_retained(const cg_host *host, const char *event, const cj *payload);
/* Owned reply, NULL when not handled. */
cj *cg_host_hook(const cg_host *host, const char *name, const cj *payload);

/* 1 permitted, 0 refused, -1 no answer (treated as refused). */
int cg_host_cleartext_permitted(const cg_host *host, const char *hostname);

typedef struct {
    char *host; /* name or IP literal (IPv6 without brackets) */
    uint16_t port;
} cg_http_proxy;

/* HttpProxy::from_reply: true and *out filled (out->host malloc'd) for a usable HTTP proxy. */
bool cg_http_proxy_from_reply(const cj *reply, cg_http_proxy *out);
bool cg_host_proxy_for_url(const cg_host *host, const char *url, cg_http_proxy *out);
void cg_http_proxy_free(cg_http_proxy *proxy);

void cg_host_will_switch_bundle(const cg_host *host, const char *path);
bool cg_host_cancel_version_download(const cg_host *host, const char *version);
/* NULL when downloads may start, else a malloc'd error. */
char *cg_host_before_download(const cg_host *host);
void cg_host_cancel_all_downloads(const cg_host *host);
bool cg_host_send_stats(const cg_host *host, const char *action, const char *version_name,
                        const char *old_version_name);

/* 1 trusted; 0 rejected (*error malloc'd reason); -1 no verifier. */
int cg_host_verify_certificate(const cg_host *host, const uint8_t *const *chain, const size_t *lengths, size_t count,
                               const char *server_name, char **error);

/* ---- method lane (thread-local; see Rust host::MethodLaneHold) */
void cg_method_lane_hold(const cg_host *host);
void cg_method_lane_drop(void);
/* Called before the running detached method waits: the host may run the next calls. */
void cg_release_method_lane(void);

#endif
