/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#ifndef CAPGO_UPDATER_CORE_H
#define CAPGO_UPDATER_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Runs one Capgo updater core operation.
 *
 * `operation` is an operation name (`resolvePathInside`: `{base, path}` ->
 * `{path}`), `input_json` a UTF-8 JSON object (NULL or "" means `{}`).
 *
 * Returns a UTF-8 JSON envelope, never NULL:
 *   {"ok":true,"value":{...}}
 *   {"ok":false,"error":{"code":"...","message":"..."}}
 * The returned string must be released with capgo_core_free().
 * Thread-safe.
 */
char *capgo_core_call(const char *operation, const char *input_json);

/** Releases a string returned by capgo_core_call() or capgo_engine_call(). NULL is ignored. */
void capgo_core_free(char *value);

/**
 * Platform services for the updater engine. Every callback may run on any
 * thread. Strings passed in are valid only during the call. kv_get / kv_keys
 * return host-allocated strings (or NULL) that the engine releases with
 * free_string. release is called once when the engine is destroyed.
 * hook (optional) receives platform hooks by name with a JSON payload and
 * returns a host-allocated JSON object reply or NULL ("not handled"). Host
 * services: willSwitchBundle, cancelVersionDownload, beforeDownload,
 * cancelAllDownloads, sendStats, cleartextPermitted, proxyForUrl,
 * scheduleDownload, releaseMethodLane. Plugin layer (payloads in core/src/engine/plugin/mod.rs,
 * `hooks`): applyBundle (bundle switching), splash, previewLoader,
 * previewNotice, shakeMenu, shakeMenuProgress, keepUrlPath, backgroundTask,
 * excludeFromBackup.
 * verify_server_certificate checks a TLS server chain (certificates[i] is a
 * DER certificate of lengths[i] bytes, leaf first) with the platform trust
 * store for server_name. It returns 1 when trusted; any other value rejects
 * the connection, and *error may receive a host-allocated reason: the engine
 * owns it and releases it with free_string (the host must not free it). The
 * engine checks the host name itself as well. NULL refuses every HTTPS
 * connection.
 * http_request (optional) sends requests through the platform network stack
 * (see CapgoHttpRequest); NULL keeps the engine's own HTTP/1.1 client.
 */

/** http_request return values. */
#define CAPGO_HTTP_UNAVAILABLE 0 /* nothing sent: the engine uses its own HTTP/1.1 client */
#define CAPGO_HTTP_COMPLETED 1   /* the whole response went to the sink */
#define CAPGO_HTTP_FAILED 2      /* *result_json: {"error": kind, "message": text} */

/**
 * One HTTP exchange for the host's network stack (URLSession, Android HttpEngine:
 * HTTP/2, HTTP/3, system proxy and trust). Strings are valid during the call.
 *
 * The host must not follow redirects: it reports a 3xx response like any other and
 * the engine applies its own redirect policy. It must not cache, store cookies or
 * add credentials, and must deliver the body without content coding (the platform
 * stacks decode gzip themselves). headers_json is a JSON array of [name, value]
 * pairs, User-Agent first; Accept-Encoding is set (gzip for API calls, identity for
 * bundle files) and Range when a download resumes. timeout_ms is an idle timeout:
 * the request fails with "timeout" when nothing moves for that long.
 */
typedef struct CapgoHttpRequest {
    const char *method;
    const char *url;
    const char *headers_json;
    /** Request body, NULL when there is none. */
    const uint8_t *body;
    size_t body_length;
    uint64_t timeout_ms;
    /**
     * NULL: the body goes to on_data. Otherwise, once on_head returned 0, the host
     * appends the body to this file (it exists and the engine prepared it) and calls
     * on_progress with the total bytes appended so far.
     */
    const char *body_path;
} CapgoHttpRequest;

/**
 * Where the host reports the response: on the thread that called http_request,
 * one call at a time, before http_request returns. Each function returns 0 to
 * continue; any other value means "cancel": the host stops the request, writes
 * nothing more and returns.
 */
typedef struct CapgoHttpSink {
    void *handle;
    /** Status and response headers (JSON array of [name, value] pairs), once, before the body. */
    int32_t (*on_head)(void *handle, int32_t status, const char *headers_json);
    /** Body bytes (requests without body_path). */
    int32_t (*on_data)(void *handle, const uint8_t *data, size_t length);
    /** Total body bytes appended to body_path so far. */
    int32_t (*on_progress)(void *handle, uint64_t written);
} CapgoHttpSink;

typedef struct CapgoHostCallbacks {
    void *context;
    void (*log)(void *context, int level, const char *message);
    char *(*kv_get)(void *context, const char *key);
    /** Persists value durably; a NULL value removes the key. */
    void (*kv_set)(void *context, const char *key, const char *value);
    char *(*kv_keys)(void *context);
    void (*emit)(void *context, const char *event, const char *payload_json);
    void (*free_string)(void *context, char *value);
    char *(*hook)(void *context, const char *name, const char *payload_json);
    void (*release)(void *context);
    int32_t (*verify_server_certificate)(void *context, const char *server_name,
                                         const uint8_t *const *certificates, const size_t *lengths,
                                         size_t count, char **error);
    /**
     * Sends one request (any thread, many at once). Returns CAPGO_HTTP_UNAVAILABLE
     * before reporting anything to fall back to the engine's client. *result_json may
     * receive a host-allocated JSON object (released with free_string):
     * {"protocol": "h3" | "h2" | "http/1.1"} when completed, {"error": "timeout" |
     * "network" | "tls" | "invalid_url" | "io" | "cancelled", "message": "..."} when
     * failed. A request a sink function cancelled may return either.
     */
    int32_t (*http_request)(void *context, const CapgoHttpRequest *request, const CapgoHttpSink *sink,
                            char **result_json);
} CapgoHostCallbacks;

typedef struct CapgoEngine CapgoEngine;

/**
 * Creates an updater engine from a JSON configuration; NULL when invalid.
 * The engine owns host.context in every case: on failure release(context) has
 * already been called when NULL is returned.
 */
CapgoEngine *capgo_engine_new(const char *config_json, CapgoHostCallbacks host);

/** Runs an engine operation (blocking); JSON envelope like capgo_core_call(). */
char *capgo_engine_call(const CapgoEngine *engine, const char *operation, const char *input_json);

/** Destroys an engine (no call may be in flight). */
void capgo_engine_free(CapgoEngine *engine);

#ifdef __cplusplus
}
#endif

#endif /* CAPGO_UPDATER_CORE_H */
