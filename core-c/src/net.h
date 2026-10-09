/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * HTTP client used by the engine (Rust net.rs: update checks, channels, stats,
 * bundle downloads). Plain HTTP/1.1 over POSIX sockets and Mbed TLS; the
 * certificate chain is verified by the host trust store (cg_host_verify_certificate),
 * the host name by this client. Behaves like the Rust client (ureq 2 + rustls):
 * same headers, redirects, proxies, cleartext policy, timeouts, connection pool,
 * error kinds and messages.
 *
 * A cg_http is thread-safe: requests may run concurrently from several threads.
 */
#ifndef CG_NET_H
#define CG_NET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "host.h"
#include "rt/json.h"

/* Largest non-download response body accepted (JSON API responses). */
#define CG_NET_MAX_API_BODY_BYTES (16u * 1024u * 1024u)
#define CG_NET_MAX_REDIRECTS 5

/* ---- errors (Rust NetError / NetErrorKind) */
typedef enum {
    CG_NET_TIMEOUT = 0,
    CG_NET_NETWORK,
    CG_NET_TLS,
    CG_NET_INVALID_URL,
    CG_NET_INSECURE_REDIRECT,
    CG_NET_IO,
} cg_net_error_kind;

typedef struct {
    cg_net_error_kind kind;
    char *message; /* NULL: no error */
} cg_net_error;

#define CG_NET_ERROR_INIT {CG_NET_TIMEOUT, NULL}

/* Sets the error (replacing a previous one). Always returns false. */
bool cg_net_error_set(cg_net_error *err, cg_net_error_kind kind, const char *format, ...) CG_PRINTF(3, 4);
/* Takes ownership of message (NULL stores ""). Always returns false. */
bool cg_net_error_set_own(cg_net_error *err, cg_net_error_kind kind, char *message);
void cg_net_error_clear(cg_net_error *err);
bool cg_net_error_is_timeout(const cg_net_error *err);
/* "timeout", "network", "tls", "invalid_url", "insecure_redirect", "io" (testing.rs net_error codes). */
const char *cg_net_error_kind_code(cg_net_error_kind kind);

/* ---- headers */
/* Request header (borrowed strings). */
typedef struct {
    const char *name;
    const char *value;
} cg_net_header;

/* Response header (owned). Names are lowercase (ureq headers_names()). */
typedef struct {
    char *name;
    char *value;
} cg_net_header_own;

typedef struct {
    cg_net_header_own *items;
    size_t len, cap;
} cg_net_headers;

/* First value whose name matches (ASCII case-insensitive), NULL when absent. */
const char *cg_net_headers_get(const cg_net_headers *headers, const char *name);
void cg_net_headers_push(cg_net_headers *headers, const char *name, const char *value);
void cg_net_headers_clear(cg_net_headers *headers);

/* ---- buffered response (Rust Response) */
typedef struct {
    uint16_t status;
    cg_net_headers headers;
    uint8_t *body; /* malloc'd, NUL-terminated (not counted in body_len); never NULL after success */
    size_t body_len;
} cg_net_response;

const char *cg_net_response_header(const cg_net_response *response, const char *name);
/* Lossy UTF-8 copy of the body (malloc'd). */
char *cg_net_response_text(const cg_net_response *response);
bool cg_net_response_is_success(const cg_net_response *response);
/* Parsed JSON body (caller owns), NULL when the body is not JSON. */
cj *cg_net_response_json(const cg_net_response *response);
void cg_net_response_clear(cg_net_response *response);

/* ---- streamed download (Rust StreamHead / Stream) */
typedef struct {
    uint16_t status;
    cg_net_headers headers;
    bool has_content_length;
    uint64_t content_length;
} cg_net_stream_head;

const char *cg_net_stream_head_header(const cg_net_stream_head *head, const char *name);
void cg_net_stream_head_clear(cg_net_stream_head *head);

typedef enum { CG_NET_STREAM_HEAD = 0, CG_NET_STREAM_CHUNK } cg_net_stream_kind;

typedef struct {
    cg_net_stream_kind kind;
    const cg_net_stream_head *head; /* CG_NET_STREAM_HEAD */
    const uint8_t *data;            /* CG_NET_STREAM_CHUNK */
    size_t len;
} cg_net_stream;

/* Download event handler: return false with *err set to abort the transfer (the error is
 * returned by cg_http_download as is). */
typedef bool (*cg_net_stream_handler)(void *context, const cg_net_stream *event, cg_net_error *err);

/* ---- client (Rust Http) */
typedef struct cg_http cg_http;

/* `host` is borrowed and must outlive the client. timeout_ms 0 = 20 s. */
cg_http *cg_http_new(const cg_host *host, const char *user_agent, uint64_t timeout_ms);
/* Closes pooled connections. No request may be running. NULL-safe. */
void cg_http_free(cg_http *http);

void cg_http_set_user_agent(cg_http *http, const char *user_agent);
/* malloc'd copy. */
char *cg_http_get_user_agent(cg_http *http);
/* Connect/read/write timeout (0 keeps the 20 s default). Downloads use at least 60 s. */
void cg_http_set_timeout(cg_http *http, uint64_t timeout_ms);
void cg_http_set_allow_https_to_http_redirect(cg_http *http, bool allow);

/* Sends a request (follows up to 5 redirects) and buffers the (API sized, gzip decoded) body.
 * `body` NULL = no body (no Content-Length). Non-2xx statuses are responses, not errors.
 * On success *out is filled (clear it with cg_net_response_clear). */
bool cg_http_send(cg_http *http, const char *method, const char *url, const cg_net_header *headers,
                  size_t header_count, const uint8_t *body, size_t body_len, cg_net_response *out,
                  cg_net_error *err);
bool cg_http_get(cg_http *http, const char *url, cg_net_response *out, cg_net_error *err);
bool cg_http_post_json(cg_http *http, const char *url, const cj *body, cg_net_response *out, cg_net_error *err);
bool cg_http_send_json(cg_http *http, const char *method, const char *url, const cj *body, cg_net_response *out,
                       cg_net_error *err);

/* Streams a GET response to `handler`: first CG_NET_STREAM_HEAD, then every CG_NET_STREAM_CHUNK
 * (identity encoding). `head_out` (may be NULL) receives the head on success. */
bool cg_http_download(cg_http *http, const char *url, const cg_net_header *headers, size_t header_count,
                      cg_net_stream_handler handler, void *context, cg_net_stream_head *head_out,
                      cg_net_error *err);

/* A redirect may never downgrade HTTPS to plain HTTP unless explicitly allowed. */
bool cg_net_redirect_allowed(const char *from_scheme, const char *to_scheme, bool allow_downgrade);

#endif
