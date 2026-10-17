/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * HTTP/3 transport of the engine's client (Rust h3.rs): ngtcp2 (QUIC) + nghttp3 (HTTP/3)
 * over picotls running on Mbed TLS crypto, with the host trust decision of the TCP path
 * (h3_tls.c). net.c decides when to use it (Alt-Svc, fallback); this module moves requests.
 *
 * - Up to `max_connections` QUIC connections per origin; a request goes to the connection
 *   with the fewest requests in flight, a new one is opened while every existing connection
 *   is busy and the limit is not reached.
 * - Each connection runs on its own thread ("capgo-quic"), which alone touches ngtcp2 /
 *   nghttp3. Callers queue requests and read bodies from per-stream buffers; flow control
 *   credit is returned as the caller consumes the body (backpressure).
 * - CG_H3_FALLBACK: the connection could not be established, or the request failed before
 *   its response head (only idempotent requests once something was sent): the caller marks
 *   the origin broken and uses HTTP/1.1.
 */
#ifndef CG_H3_H
#define CG_H3_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "host.h"
#include "net.h"
#include "net_internal.h"

#define CG_H3_HANDSHAKE_TIMEOUT_MS 3000u
#define CG_H3_IDLE_TIMEOUT_MS 30000u
#define CG_H3_STREAM_WINDOW (2u * 1024u * 1024u)
#define CG_H3_CONNECTION_WINDOW (16u * 1024u * 1024u)
#define CG_H3_MAX_FIELD_SECTION_SIZE (100u * 1024u)
#define CG_H3_MAX_HEADER_COUNT 100

#define CG_H3_MESSAGE_TIMEOUT "timed out reading response"
#define CG_H3_MESSAGE_SHORT_BODY "response body closed before all bytes were read"
#define CG_H3_MESSAGE_LONG_BODY "HTTP/3 response body longer than Content-Length"
#define CG_H3_MESSAGE_RESET "HTTP/3 stream reset by the server"
#define CG_H3_MESSAGE_CLOSED "HTTP/3 connection closed"
#define CG_H3_MESSAGE_PROTOCOL "HTTP/3 protocol error"
#define CG_H3_MESSAGE_TOO_MANY_HEADERS "more than 100 header fields in response"
#define CG_H3_MESSAGE_REQUEST_FAILED "HTTP/3 request failed"

typedef struct cg_h3_client cg_h3_client;
typedef struct cg_h3_stream cg_h3_stream;

/* A request (borrowed strings). Field names are lowercase, without pseudo-headers. */
typedef struct {
    const char *method;
    const char *authority; /* host[:port] as in the URL */
    const char *path;      /* path?query */
    const char *host;      /* URL host, lowercase (IPv6 in brackets) */
    uint16_t port;         /* announced HTTP/3 port */
    const cg_net_header *fields;
    size_t field_count;
    const uint8_t *body; /* NULL: no body */
    size_t body_len;
    uint64_t timeout_ms; /* connect, write and per-read timeout */
    bool idempotent;
} cg_h3_request;

/* A response field line: lowercase name, raw value bytes (NUL-terminated copy). */
typedef struct {
    char *name;
    uint8_t *value;
    size_t value_len;
} cg_h3_field;

typedef struct {
    uint16_t status;
    cg_h3_field *fields;
    size_t field_count;
    cg_h3_stream *body; /* read with cg_h3_body_read, release with cg_h3_body_free */
} cg_h3_response;

typedef enum { CG_H3_OK = 0, CG_H3_FALLBACK, CG_H3_FAIL } cg_h3_outcome;

/* `host` is borrowed (trust decisions, logs) and must outlive the client. */
cg_h3_client *cg_h3_client_new(const cg_host *host);
/* Closes every connection and waits for their threads. No request may be running. */
void cg_h3_client_free(cg_h3_client *client);
/* QUIC connections opened so far (tests, bench). */
size_t cg_h3_opened_connections(cg_h3_client *client);

/* Sends `request`. CG_H3_OK: *out holds the head and the body reader. CG_H3_FAIL: *err is the
 * request's error. CG_H3_FALLBACK: *reason (malloc'd, for the debug log) says why. */
cg_h3_outcome cg_h3_send(cg_h3_client *client, const cg_h3_request *request, size_t max_connections,
                         cg_h3_response *out, cg_net_error *err, char **reason);

/* Body read: bytes, 0 at the end, -1 with *io (Content-Length enforced). */
long cg_h3_body_read(cg_h3_stream *body, uint8_t *buffer, size_t len, net_io_error *io);
/* Data is ready without waiting. */
bool cg_h3_body_buffered(cg_h3_stream *body);
/* Releases the body; an unfinished one is cancelled (STOP_SENDING / RESET_STREAM). NULL-safe. */
void cg_h3_body_free(cg_h3_stream *body);
/* Frees the fields and the body. */
void cg_h3_response_clear(cg_h3_response *response);

/* Response fields as net.c gives HTTP/1.1 headers (ureq semantics, Rust net::h3_headers): each
 * name with the first value of that name, when that value is valid. */
void cg_h3_headers_of(const cg_h3_field *fields, size_t count, cg_net_headers *out);
/* `content-length` of a response head: false when absent or not only digits. */
bool cg_h3_content_length(const cg_h3_field *fields, size_t count, uint64_t *out);

/* ---- h3_tls.c: picotls on Mbed TLS with the host trust decision */
struct st_ptls_context_t;
/* The shared client context (TLS 1.3, X25519 / P-256, AES-GCM / ChaCha20-Poly1305), NULL when the
 * crypto library could not start. */
struct st_ptls_context_t *cg_h3_tls_context(void);
/* Host and server name the verifier of a connection uses: set on the ptls_t data pointer's
 * conn_ref user data (see h3.c). */
typedef struct {
    const cg_host *host;
    const char *server_name; /* URL host without brackets */
} cg_h3_tls_peer;



#endif
