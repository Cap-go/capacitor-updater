/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* HTTP/3 transport (Rust h3.rs) over ngtcp2 + nghttp3 + picotls / Mbed TLS, see h3.h. */

#include "h3.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <nghttp3/nghttp3.h>
#include <ngtcp2/ngtcp2.h>
#include <ngtcp2/ngtcp2_crypto.h>
#include <ngtcp2/ngtcp2_crypto_picotls.h>
#include <picotls.h>
#include <picotls/mbedtls.h>

#include "rt/str.h"
#include "rt/sync.h"

/* HTTP/3 error codes (RFC 9114). */
#define H3_NO_ERROR 0x100
#define H3_REQUEST_CANCELLED 0x10c
/* Receive buffer of the UDP socket and largest datagram read. */
#define UDP_RECV_BUFFER (4 * 1024 * 1024)
#define MAX_DATAGRAM 65536
/* Packets written per burst (one send each). */
#define TX_BUFFER (64 * 1024)
/* Flow control credit is returned once this much was read (or the buffer drained). */
#define CREDIT_STEP (64 * 1024)

typedef enum { CONN_CONNECTING = 0, CONN_READY, CONN_CLOSED } conn_state;
typedef enum { STREAM_OK = 0, STREAM_RESET, STREAM_CLOSED, STREAM_PROTOCOL } stream_error;

typedef struct h3_conn h3_conn;

struct cg_h3_stream {
    h3_conn *conn; /* holds a reference */
    int refs;      /* caller + connection thread, under conn->lock */
    cg_cond cond;
    int64_t id; /* -1 until opened */
    bool opened, unusable;
    /* request, owned (nghttp3 reads it until the stream closes) */
    nghttp3_nv *nva;
    size_t nvlen;
    char **strings;
    size_t string_count;
    uint8_t *body;
    size_t body_len;
    bool body_given;
    /* response, written by the connection thread */
    uint16_t status;
    bool head, in_head, too_many_headers;
    cg_h3_field *fields;
    size_t field_count, field_cap;
    uint8_t *data;
    size_t data_start, data_len, data_cap;
    bool fin;
    stream_error error;
    uint64_t credit; /* bytes read by the caller, not yet returned to stream flow control */
    bool abandoned, cancelled, closed;
    /* caller side */
    bool has_remaining, bodiless, finished;
    uint64_t remaining, timeout_ms;
};

struct h3_conn {
    cg_h3_tls_peer peer; /* first: the TLS verifier reads it from the conn_ref user data */
    cg_h3_client *client;
    char *key;
    char *server_name;
    uint16_t port;
    uint64_t connect_timeout_ms;
    cg_mutex lock;
    cg_cond cond;
    conn_state state;
    char *failure;
    int refs; /* client list + streams, under the client lock for the list, conn lock otherwise */
    int active;
    bool dead, goaway, stop, thread_started;
    pthread_t thread;
    int wake[2];
    cg_h3_stream **pending;
    size_t pending_len, pending_cap;
    cg_h3_stream **streams; /* opened, not closed */
    size_t stream_len, stream_cap;
    uint64_t connection_credit; /* body bytes read or dropped, not yet returned to flow control */
    /* connection thread only */
    int fd;
    struct sockaddr_storage local, remote;
    socklen_t local_len, remote_len;
    ngtcp2_conn *quic;
    nghttp3_conn *http;
    ngtcp2_crypto_conn_ref conn_ref;
    ngtcp2_crypto_picotls_ctx cptls;
    ptls_raw_extension_t extensions[2];
    ngtcp2_ccerr last_error;
    bool handshake_done, fatal;
};

struct cg_h3_client {
    const cg_host *host;
    cg_mutex lock;
    h3_conn **conns;
    size_t conn_len, conn_cap;
    atomic_size_t opened;
};

/* ======================================================================================
 * helpers
 * ==================================================================================== */

static uint64_t now_ns(void) { return cg_mono_ns(); }

static void wake(h3_conn *conn) {
    uint8_t byte = 1;
    ssize_t written;
    do {
        written = write(conn->wake[1], &byte, 1);
    } while (written < 0 && errno == EINTR);
}

static void drain_wake(h3_conn *conn) {
    uint8_t buffer[64];
    while (read(conn->wake[0], buffer, sizeof buffer) > 0) {
    }
}

static void push_ptr(void ***items, size_t *len, size_t *cap, void *item) {
    if (*len == *cap) {
        *cap = *cap ? *cap * 2 : 8;
        *items = cg_realloc(*items, *cap * sizeof **items);
    }
    (*items)[(*len)++] = item;
}

static bool remove_ptr(void **items, size_t *len, void *item) {
    for (size_t i = 0; i < *len; i++)
        if (items[i] == item) {
            memmove(items + i, items + i + 1, (*len - i - 1) * sizeof *items);
            (*len)--;
            return true;
        }
    return false;
}

static void fields_free(cg_h3_field *fields, size_t count) {
    for (size_t i = 0; i < count; i++) {
        free(fields[i].name);
        free(fields[i].value);
    }
    free(fields);
}

static void stream_destroy(cg_h3_stream *stream) {
    free(stream->nva);
    for (size_t i = 0; i < stream->string_count; i++)
        free(stream->strings[i]);
    free(stream->strings);
    free(stream->body);
    fields_free(stream->fields, stream->field_count);
    free(stream->data);
    cg_cond_destroy(&stream->cond);
    free(stream);
}

static void conn_destroy(h3_conn *conn) {
    if (conn->wake[0] >= 0)
        close(conn->wake[0]);
    if (conn->wake[1] >= 0)
        close(conn->wake[1]);
    free(conn->pending);
    free(conn->streams);
    free(conn->key);
    free(conn->server_name);
    free(conn->failure);
    cg_mutex_destroy(&conn->lock);
    cg_cond_destroy(&conn->cond);
    free(conn);
}

/* Drops one reference (conn->lock NOT held). */
static void conn_release(h3_conn *conn) {
    cg_lock(&conn->lock);
    bool last = --conn->refs == 0;
    cg_unlock(&conn->lock);
    if (last)
        conn_destroy(conn);
}

/* Drops one stream reference; caller holds conn->lock. True when the stream was freed. */
static bool stream_unref_locked(cg_h3_stream *stream) {
    if (--stream->refs > 0)
        return false;
    stream_destroy(stream);
    return true;
}

/* `content-length` of a response head. */
bool cg_h3_content_length(const cg_h3_field *fields, size_t count, uint64_t *out) {
    for (size_t i = 0; i < count; i++) {
        if (strcmp(fields[i].name, "content-length") != 0)
            continue;
        const uint8_t *value = fields[i].value;
        size_t len = fields[i].value_len;
        if (len == 0)
            return false;
        uint64_t total = 0;
        for (size_t j = 0; j < len; j++) {
            if (value[j] < '0' || value[j] > '9')
                return false;
            uint64_t digit = (uint64_t)(value[j] - '0');
            if (total > (UINT64_MAX - digit) / 10)
                return false;
            total = total * 10 + digit;
        }
        *out = total;
        return true;
    }
    return false;
}

static bool is_field_char(uint8_t c) { return c == ' ' || c == '\t' || (c >= 0x21 && c <= 0x7E); }

void cg_h3_headers_of(const cg_h3_field *fields, size_t count, cg_net_headers *out) {
    /* Each field: its trimmed value when valid (UTF-8, no NUL, visible ASCII, spaces, tabs). */
    char **values = cg_calloc(count ? count : 1, sizeof *values);
    for (size_t i = 0; i < count; i++) {
        const cg_h3_field *field = &fields[i];
        if (!cg_utf8_valid((const char *)field->value, field->value_len) ||
            memchr(field->value, 0, field->value_len))
            continue;
        char *trimmed = cg_trim((const char *)field->value);
        bool valid = true;
        for (const char *c = trimmed; valid && *c; c++)
            valid = is_field_char((uint8_t)*c);
        if (valid)
            values[i] = trimmed;
        else
            free(trimmed);
    }
    for (size_t i = 0; i < count; i++) {
        size_t first = i;
        for (size_t j = 0; j < i; j++)
            if (strcmp(fields[j].name, fields[i].name) == 0) {
                first = j;
                break;
            }
        if (values[first])
            cg_net_headers_push(out, fields[i].name, values[first]);
    }
    for (size_t i = 0; i < count; i++)
        free(values[i]);
    free(values);
}

/* ======================================================================================
 * nghttp3 callbacks (connection thread; also driven without QUIC by the fuzz target)
 * ==================================================================================== */

static cg_h3_stream *stream_of(void *stream_user_data) { return stream_user_data; }

static int http_begin_headers(nghttp3_conn *http, int64_t stream_id, void *user, void *stream_user) {
    cg_h3_stream *stream = stream_of(stream_user);
    if (!stream)
        return 0;
    h3_conn *conn = user;
    if (conn)
        cg_lock(&conn->lock);
    fields_free(stream->fields, stream->field_count);
    stream->fields = NULL;
    stream->field_count = stream->field_cap = 0;
    stream->status = 0;
    stream->in_head = true;
    if (conn)
        cg_unlock(&conn->lock);
    return 0;
}

static int http_recv_header(nghttp3_conn *http, int64_t stream_id, int32_t token, nghttp3_rcbuf *name,
                            nghttp3_rcbuf *value, uint8_t flags, void *user, void *stream_user) {
    cg_h3_stream *stream = stream_of(stream_user);
    if (!stream)
        return 0;
    nghttp3_vec n = nghttp3_rcbuf_get_buf(name), v = nghttp3_rcbuf_get_buf(value);
    h3_conn *conn = user;
    if (conn)
        cg_lock(&conn->lock);
    if (n.len > 0 && n.base[0] == ':') {
        /* :status, validated by nghttp3 (three digits). */
        if (n.len == 7 && memcmp(n.base, ":status", 7) == 0 && v.len == 3) {
            stream->status = (uint16_t)((v.base[0] - '0') * 100 + (v.base[1] - '0') * 10 + (v.base[2] - '0'));
        }
    } else if (stream->field_count >= CG_H3_MAX_HEADER_COUNT) {
        stream->too_many_headers = true;
    } else {
        if (stream->field_count == stream->field_cap) {
            stream->field_cap = stream->field_cap ? stream->field_cap * 2 : 16;
            stream->fields = cg_realloc(stream->fields, stream->field_cap * sizeof *stream->fields);
        }
        cg_h3_field *field = &stream->fields[stream->field_count++];
        char *raw_name = cg_strndup((const char *)n.base, n.len);
        field->name = cg_lower(raw_name);
        free(raw_name);
        field->value = cg_malloc(v.len + 1);
        if (v.len)
            memcpy(field->value, v.base, v.len);
        field->value[v.len] = 0;
        field->value_len = v.len;
    }
    if (conn)
        cg_unlock(&conn->lock);
    return 0;
}

static int http_end_headers(nghttp3_conn *http, int64_t stream_id, int fin, void *user, void *stream_user) {
    cg_h3_stream *stream = stream_of(stream_user);
    if (!stream)
        return 0;
    h3_conn *conn = user;
    if (conn)
        cg_lock(&conn->lock);
    stream->in_head = false;
    /* Interim responses (1xx) are skipped. */
    if (stream->status >= 200 || stream->status < 100) {
        stream->head = true;
        cg_cond_broadcast(&stream->cond);
    } else {
        fields_free(stream->fields, stream->field_count);
        stream->fields = NULL;
        stream->field_count = stream->field_cap = 0;
        stream->too_many_headers = false;
    }
    if (conn)
        cg_unlock(&conn->lock);
    return 0;
}

static void data_append(cg_h3_stream *stream, const uint8_t *data, size_t len) {
    if (stream->data_start > 0 && stream->data_start + stream->data_len + len > stream->data_cap) {
        memmove(stream->data, stream->data + stream->data_start, stream->data_len);
        stream->data_start = 0;
    }
    if (stream->data_start + stream->data_len + len > stream->data_cap) {
        size_t need = stream->data_len + len;
        size_t cap = stream->data_cap ? stream->data_cap : 64 * 1024;
        while (cap < need)
            cap *= 2;
        stream->data = cg_realloc(stream->data, cap);
        stream->data_cap = cap;
    }
    memcpy(stream->data + stream->data_start + stream->data_len, data, len);
    stream->data_len += len;
}

static int http_recv_data(nghttp3_conn *http, int64_t stream_id, const uint8_t *data, size_t len, void *user,
                          void *stream_user) {
    cg_h3_stream *stream = stream_of(stream_user);
    h3_conn *conn = user;
    if (!stream) {
        /* No reader: give the credit back right away. */
        if (conn && conn->quic) {
            ngtcp2_conn_extend_max_stream_offset(conn->quic, stream_id, len);
            ngtcp2_conn_extend_max_offset(conn->quic, len);
        }
        return 0;
    }
    if (conn)
        cg_lock(&conn->lock);
    if (stream->abandoned) {
        if (conn && conn->quic) {
            ngtcp2_conn_extend_max_stream_offset(conn->quic, stream_id, len);
            ngtcp2_conn_extend_max_offset(conn->quic, len);
        }
    } else {
        data_append(stream, data, len);
        cg_cond_broadcast(&stream->cond);
    }
    if (conn)
        cg_unlock(&conn->lock);
    return 0;
}

static int http_deferred_consume(nghttp3_conn *http, int64_t stream_id, size_t consumed, void *user,
                                 void *stream_user) {
    h3_conn *conn = user;
    if (conn && conn->quic) {
        ngtcp2_conn_extend_max_stream_offset(conn->quic, stream_id, consumed);
        ngtcp2_conn_extend_max_offset(conn->quic, consumed);
    }
    return 0;
}

static int http_end_stream(nghttp3_conn *http, int64_t stream_id, void *user, void *stream_user) {
    cg_h3_stream *stream = stream_of(stream_user);
    if (!stream)
        return 0;
    h3_conn *conn = user;
    if (conn)
        cg_lock(&conn->lock);
    stream->fin = true;
    cg_cond_broadcast(&stream->cond);
    if (conn)
        cg_unlock(&conn->lock);
    return 0;
}

static int http_stop_sending(nghttp3_conn *http, int64_t stream_id, uint64_t code, void *user,
                             void *stream_user) {
    h3_conn *conn = user;
    if (conn && conn->quic)
        ngtcp2_conn_shutdown_stream_read(conn->quic, 0, stream_id, code);
    return 0;
}

static int http_reset_stream(nghttp3_conn *http, int64_t stream_id, uint64_t code, void *user,
                             void *stream_user) {
    h3_conn *conn = user;
    if (conn && conn->quic)
        ngtcp2_conn_shutdown_stream_write(conn->quic, 0, stream_id, code);
    return 0;
}

static int http_acked_stream_data(nghttp3_conn *http, int64_t stream_id, uint64_t len, void *user,
                                  void *stream_user) {
    return 0;
}

/* GOAWAY: no new request on this connection. */
static int http_shutdown(nghttp3_conn *http, int64_t id, void *user) {
    h3_conn *conn = user;
    if (!conn)
        return 0;
    cg_lock(&conn->lock);
    conn->goaway = true;
    conn->dead = true;
    cg_unlock(&conn->lock);
    return 0;
}

static void http_rand(uint8_t *dest, size_t len) { ptls_mbedtls_random_bytes(dest, len); }

static const nghttp3_callbacks http_callbacks = {
    .acked_stream_data = http_acked_stream_data,
    .recv_data = http_recv_data,
    .deferred_consume = http_deferred_consume,
    .begin_headers = http_begin_headers,
    .recv_header = http_recv_header,
    .end_headers = http_end_headers,
    .end_stream = http_end_stream,
    .stop_sending = http_stop_sending,
    .reset_stream = http_reset_stream,
    .shutdown = http_shutdown,
    .rand = http_rand,
};

static void http_settings(nghttp3_settings *settings) {
    nghttp3_settings_default(settings);
    settings->max_field_section_size = CG_H3_MAX_FIELD_SECTION_SIZE;
    settings->qpack_max_dtable_capacity = 4096;
    settings->qpack_blocked_streams = 100;
}

/* ======================================================================================
 * request bodies (nghttp3 data reader: the whole body at once)
 * ==================================================================================== */

static nghttp3_ssize read_body(nghttp3_conn *http, int64_t stream_id, nghttp3_vec *vec, size_t count,
                               uint32_t *flags, void *user, void *stream_user) {
    cg_h3_stream *stream = stream_of(stream_user);
    *flags |= NGHTTP3_DATA_FLAG_EOF;
    if (!stream || stream->body_given || stream->body_len == 0 || count == 0)
        return 0;
    stream->body_given = true;
    vec[0].base = stream->body;
    vec[0].len = stream->body_len;
    return 1;
}

/* ======================================================================================
 * ngtcp2 callbacks (connection thread)
 * ==================================================================================== */

static ngtcp2_conn *get_conn(ngtcp2_crypto_conn_ref *ref) {
    h3_conn *conn = ref->user_data;
    return conn->quic;
}

static void quic_rand(uint8_t *dest, size_t len, const ngtcp2_rand_ctx *ctx) {
    (void)ctx;
    ptls_mbedtls_random_bytes(dest, len);
}

static int quic_new_cid(ngtcp2_conn *quic, ngtcp2_cid *cid, ngtcp2_stateless_reset_token *token, size_t len,
                        void *user) {
    ptls_mbedtls_random_bytes(cid->data, len);
    cid->datalen = len;
    ptls_mbedtls_random_bytes(token->data, sizeof token->data);
    return 0;
}

static int quic_handshake_completed(ngtcp2_conn *quic, void *user) {
    h3_conn *conn = user;
    conn->handshake_done = true;
    return 0;
}

static int quic_recv_stream_data(ngtcp2_conn *quic, uint32_t flags, int64_t stream_id, uint64_t offset,
                                 const uint8_t *data, size_t len, void *user, void *stream_user) {
    h3_conn *conn = user;
    if (!conn->http)
        return 0;
    nghttp3_ssize consumed = nghttp3_conn_read_stream2(conn->http, stream_id, data, len,
                                                       (flags & NGTCP2_STREAM_DATA_FLAG_FIN) != 0, now_ns());
    if (consumed < 0) {
        ngtcp2_ccerr_set_application_error(&conn->last_error,
                                           nghttp3_err_infer_quic_app_error_code((int)consumed), NULL, 0);
        conn->fatal = true;
        return NGTCP2_ERR_CALLBACK_FAILURE;
    }
    ngtcp2_conn_extend_max_stream_offset(quic, stream_id, (uint64_t)consumed);
    ngtcp2_conn_extend_max_offset(quic, (uint64_t)consumed);
    return 0;
}

static int quic_acked_stream_data_offset(ngtcp2_conn *quic, int64_t stream_id, uint64_t offset, uint64_t len,
                                         void *user, void *stream_user) {
    h3_conn *conn = user;
    if (conn->http && nghttp3_conn_add_ack_offset(conn->http, stream_id, len) != 0)
        return NGTCP2_ERR_CALLBACK_FAILURE;
    return 0;
}

static void stream_closed(h3_conn *conn, int64_t stream_id, stream_error error) {
    cg_lock(&conn->lock);
    for (size_t i = 0; i < conn->stream_len; i++) {
        cg_h3_stream *stream = conn->streams[i];
        if (stream->id != stream_id)
            continue;
        memmove(conn->streams + i, conn->streams + i + 1, (conn->stream_len - i - 1) * sizeof *conn->streams);
        conn->stream_len--;
        stream->closed = true;
        if (!stream->fin && stream->error == STREAM_OK)
            stream->error = error;
        cg_cond_broadcast(&stream->cond);
        stream_unref_locked(stream);
        break;
    }
    cg_unlock(&conn->lock);
}

static int quic_stream_close(ngtcp2_conn *quic, uint32_t flags, int64_t stream_id, uint64_t rx_code,
                             uint64_t tx_code, void *user, void *stream_user) {
    h3_conn *conn = user;
    bool rx_set = (flags & NGTCP2_STREAM_CLOSE2_FLAG_RX_APP_ERROR_CODE_SET) != 0;
    bool tx_set = (flags & NGTCP2_STREAM_CLOSE2_FLAG_TX_APP_ERROR_CODE_SET) != 0;
    if (conn->http) {
        uint32_t http_flags = NGHTTP3_STREAM_CLOSE_FLAG_NONE;
        if (rx_set)
            http_flags |= NGHTTP3_STREAM_CLOSE_FLAG_RX_APP_ERROR_CODE_SET;
        if (tx_set)
            http_flags |= NGHTTP3_STREAM_CLOSE_FLAG_TX_APP_ERROR_CODE_SET;
        int rv = nghttp3_conn_close_stream2(conn->http, http_flags, stream_id, rx_code, tx_code);
        if (rv != 0 && rv != NGHTTP3_ERR_STREAM_NOT_FOUND) {
            ngtcp2_ccerr_set_application_error(&conn->last_error, nghttp3_err_infer_quic_app_error_code(rv),
                                               NULL, 0);
            conn->fatal = true;
            return NGTCP2_ERR_CALLBACK_FAILURE;
        }
    }
    if (ngtcp2_is_bidi_stream(stream_id))
        stream_closed(conn, stream_id, rx_set ? STREAM_RESET : STREAM_CLOSED);
    return 0;
}

static int quic_stream_reset(ngtcp2_conn *quic, int64_t stream_id, uint64_t final_size, uint64_t code,
                             void *user, void *stream_user) {
    h3_conn *conn = user;
    if (conn->http && nghttp3_conn_shutdown_stream_read(conn->http, stream_id) != 0)
        return NGTCP2_ERR_CALLBACK_FAILURE;
    cg_h3_stream *stream = stream_user;
    if (stream) {
        cg_lock(&conn->lock);
        if (!stream->fin && stream->error == STREAM_OK)
            stream->error = STREAM_RESET;
        cg_cond_broadcast(&stream->cond);
        cg_unlock(&conn->lock);
    }
    return 0;
}

static int quic_stream_stop_sending(ngtcp2_conn *quic, int64_t stream_id, uint64_t code, void *user,
                                    void *stream_user) {
    h3_conn *conn = user;
    if (conn->http && nghttp3_conn_shutdown_stream_read(conn->http, stream_id) != 0)
        return NGTCP2_ERR_CALLBACK_FAILURE;
    return 0;
}

static int quic_extend_max_stream_data(ngtcp2_conn *quic, int64_t stream_id, uint64_t max_data, void *user,
                                       void *stream_user) {
    h3_conn *conn = user;
    if (conn->http && nghttp3_conn_unblock_stream(conn->http, stream_id) != 0)
        return NGTCP2_ERR_CALLBACK_FAILURE;
    return 0;
}

static int quic_extend_max_local_streams_bidi(ngtcp2_conn *quic, uint64_t max_streams, void *user) {
    /* Queued requests are opened by the loop. */
    return 0;
}

static const ngtcp2_callbacks quic_callbacks = {
    .client_initial = ngtcp2_crypto_client_initial_cb,
    .recv_crypto_data = ngtcp2_crypto_recv_crypto_data_cb,
    .handshake_completed = quic_handshake_completed,
    .encrypt = ngtcp2_crypto_encrypt_cb,
    .decrypt = ngtcp2_crypto_decrypt_cb,
    .hp_mask = ngtcp2_crypto_hp_mask_cb,
    .recv_stream_data = quic_recv_stream_data,
    .acked_stream_data_offset = quic_acked_stream_data_offset,
    .recv_retry = ngtcp2_crypto_recv_retry_cb,
    .extend_max_local_streams_bidi = quic_extend_max_local_streams_bidi,
    .rand = quic_rand,
    .update_key = ngtcp2_crypto_update_key_cb,
    .stream_reset = quic_stream_reset,
    .extend_max_stream_data = quic_extend_max_stream_data,
    .delete_crypto_aead_ctx = ngtcp2_crypto_delete_crypto_aead_ctx_cb,
    .delete_crypto_cipher_ctx = ngtcp2_crypto_delete_crypto_cipher_ctx_cb,
    .stream_stop_sending = quic_stream_stop_sending,
    .version_negotiation = ngtcp2_crypto_version_negotiation_cb,
    .get_new_connection_id2 = quic_new_cid,
    .get_path_challenge_data2 = ngtcp2_crypto_get_path_challenge_data2_cb,
    .stream_close2 = quic_stream_close,
};

/* ======================================================================================
 * connection thread
 * ==================================================================================== */

static const ptls_iovec_t alpn_h3[] = {{(uint8_t *)"h3", 2}};

/* Creates the QUIC and TLS state for `address`; false with *reason. */
static bool quic_open(h3_conn *conn, const struct addrinfo *address, char **reason) {
    conn->fd = socket(address->ai_family, SOCK_DGRAM, 0);
    if (conn->fd < 0) {
        *reason = cg_fmt("socket: %s", strerror(errno));
        return false;
    }
    fcntl(conn->fd, F_SETFD, FD_CLOEXEC);
    fcntl(conn->fd, F_SETFL, fcntl(conn->fd, F_GETFL, 0) | O_NONBLOCK);
    int size = UDP_RECV_BUFFER;
    setsockopt(conn->fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof size);
    if (connect(conn->fd, address->ai_addr, address->ai_addrlen) != 0) {
        *reason = cg_fmt("connect: %s", strerror(errno));
        return false;
    }
    memcpy(&conn->remote, address->ai_addr, address->ai_addrlen);
    conn->remote_len = address->ai_addrlen;
    conn->local_len = sizeof conn->local;
    if (getsockname(conn->fd, (struct sockaddr *)&conn->local, &conn->local_len) != 0) {
        *reason = cg_fmt("getsockname: %s", strerror(errno));
        return false;
    }
    ptls_context_t *context = cg_h3_tls_context();
    if (!context) {
        *reason = cg_strdup("TLS initialization failed");
        return false;
    }
    ngtcp2_path path = {
        .local = {(struct sockaddr *)&conn->local, conn->local_len},
        .remote = {(struct sockaddr *)&conn->remote, conn->remote_len},
    };
    ngtcp2_cid dcid, scid;
    dcid.datalen = NGTCP2_MIN_INITIAL_DCIDLEN;
    ptls_mbedtls_random_bytes(dcid.data, dcid.datalen);
    scid.datalen = 8;
    ptls_mbedtls_random_bytes(scid.data, scid.datalen);
    ngtcp2_settings settings;
    ngtcp2_settings_default(&settings);
    settings.initial_ts = now_ns();
    settings.max_window = CG_H3_CONNECTION_WINDOW;
    settings.max_stream_window = CG_H3_STREAM_WINDOW;
    ngtcp2_transport_params params;
    ngtcp2_transport_params_default(&params);
    params.initial_max_streams_bidi = 0;
    params.initial_max_streams_uni = 16;
    params.initial_max_stream_data_bidi_local = CG_H3_STREAM_WINDOW;
    params.initial_max_stream_data_uni = CG_H3_STREAM_WINDOW;
    params.initial_max_data = CG_H3_CONNECTION_WINDOW;
    params.max_idle_timeout = (ngtcp2_duration)CG_H3_IDLE_TIMEOUT_MS * NGTCP2_MILLISECONDS;
    int rv = ngtcp2_conn_client_new(&conn->quic, &dcid, &scid, &path, NGTCP2_PROTO_VER_V1, &quic_callbacks,
                                    &settings, &params, NULL, conn);
    if (rv != 0) {
        *reason = cg_fmt("ngtcp2_conn_client_new: %s", ngtcp2_strerror(rv));
        return false;
    }
    ngtcp2_crypto_picotls_ctx_init(&conn->cptls);
    conn->cptls.ptls = ptls_client_new(context);
    if (!conn->cptls.ptls) {
        *reason = cg_strdup("ptls_client_new failed");
        return false;
    }
    conn->conn_ref.get_conn = get_conn;
    conn->conn_ref.user_data = conn;
    *ptls_get_data_ptr(conn->cptls.ptls) = &conn->conn_ref;
    conn->extensions[0].type = UINT16_MAX;
    conn->extensions[1].type = UINT16_MAX;
    conn->cptls.handshake_properties.additional_extensions = conn->extensions;
    if (ngtcp2_crypto_picotls_configure_client_session(&conn->cptls, conn->quic) != 0) {
        *reason = cg_strdup("ngtcp2_crypto_picotls_configure_client_session failed");
        return false;
    }
    conn->cptls.handshake_properties.client.negotiated_protocols.list = (ptls_iovec_t *)alpn_h3;
    conn->cptls.handshake_properties.client.negotiated_protocols.count = 1;
    /* SNI for DNS names only, like rustls. */
    struct in6_addr ip;
    if (inet_pton(AF_INET, conn->server_name, &ip) != 1 && inet_pton(AF_INET6, conn->server_name, &ip) != 1)
        ptls_set_server_name(conn->cptls.ptls, conn->server_name, strlen(conn->server_name));
    ngtcp2_conn_set_tls_native_handle(conn->quic, &conn->cptls);
    ngtcp2_ccerr_default(&conn->last_error);
    return true;
}

/* Frees the QUIC, HTTP/3 and TLS state of an attempt. */
static void quic_close(h3_conn *conn) {
    if (conn->http)
        nghttp3_conn_del(conn->http);
    conn->http = NULL;
    if (conn->cptls.ptls) {
        ngtcp2_crypto_picotls_deconfigure_session(&conn->cptls);
        ptls_free(conn->cptls.ptls);
        conn->cptls.ptls = NULL;
    }
    if (conn->quic)
        ngtcp2_conn_del(conn->quic);
    conn->quic = NULL;
    if (conn->fd >= 0)
        close(conn->fd);
    conn->fd = -1;
    conn->handshake_done = false;
    conn->fatal = false;
}

static ngtcp2_ssize write_one(ngtcp2_conn *quic, ngtcp2_path *path, ngtcp2_pkt_info *info, uint8_t *dest,
                              size_t len, ngtcp2_tstamp ts, void *user) {
    h3_conn *conn = user;
    nghttp3_vec vec[16];
    for (;;) {
        int64_t stream_id = -1;
        int fin = 0;
        nghttp3_ssize count = 0;
        if (conn->http && ngtcp2_conn_get_max_data_left(quic)) {
            count = nghttp3_conn_writev_stream(conn->http, &stream_id, &fin, vec, 16);
            if (count < 0) {
                ngtcp2_ccerr_set_application_error(
                    &conn->last_error, nghttp3_err_infer_quic_app_error_code((int)count), NULL, 0);
                conn->fatal = true;
                return NGTCP2_ERR_CALLBACK_FAILURE;
            }
        }
        ngtcp2_ssize written_data = -1;
        uint32_t flags = NGTCP2_WRITE_STREAM_FLAG_MORE;
        if (fin)
            flags |= NGTCP2_WRITE_STREAM_FLAG_FIN;
        ngtcp2_ssize written =
            ngtcp2_conn_writev_stream(quic, path, info, dest, len, &written_data, flags, stream_id,
                                      (const ngtcp2_vec *)vec, (size_t)count, ts);
        if (written < 0) {
            switch (written) {
            case NGTCP2_ERR_STREAM_DATA_BLOCKED:
                nghttp3_conn_block_stream(conn->http, stream_id);
                continue;
            case NGTCP2_ERR_STREAM_SHUT_WR:
                nghttp3_conn_shutdown_stream_write(conn->http, stream_id);
                continue;
            case NGTCP2_ERR_WRITE_MORE:
                if (nghttp3_conn_add_write_offset(conn->http, stream_id, (size_t)written_data) != 0) {
                    conn->fatal = true;
                    return NGTCP2_ERR_CALLBACK_FAILURE;
                }
                continue;
            default:
                ngtcp2_ccerr_set_liberr(&conn->last_error, (int)written, NULL, 0);
                conn->fatal = true;
                return NGTCP2_ERR_CALLBACK_FAILURE;
            }
        }
        if (written_data >= 0 && conn->http &&
            nghttp3_conn_add_write_offset(conn->http, stream_id, (size_t)written_data) != 0) {
            conn->fatal = true;
            return NGTCP2_ERR_CALLBACK_FAILURE;
        }
        return written;
    }
}

/* Sends what QUIC has to send; false on a fatal error (*reason). */
static bool flush(h3_conn *conn, char **reason) {
    static _Thread_local uint8_t buffer[TX_BUFFER];
    for (int burst = 0; burst < 64; burst++) {
        ngtcp2_path_storage path;
        ngtcp2_path_storage_zero(&path);
        ngtcp2_pkt_info info;
        size_t segment = 0;
        ngtcp2_ssize written = ngtcp2_conn_write_aggregate_pkt(conn->quic, &path.path, &info, buffer,
                                                               sizeof buffer, &segment, write_one, now_ns());
        if (written < 0) {
            *reason = cg_fmt("write: %s", ngtcp2_strerror((int)written));
            return false;
        }
        if (written == 0)
            return true;
        size_t offset = 0;
        while (offset < (size_t)written) {
            size_t len = (size_t)written - offset;
            if (segment && len > segment)
                len = segment;
            ssize_t sent;
            do {
                sent = send(conn->fd, buffer + offset, len, 0);
            } while (sent < 0 && errno == EINTR);
            if (sent < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != ENOBUFS) {
                *reason = cg_fmt("send: %s", strerror(errno));
                return false;
            }
            offset += len;
        }
    }
    return true;
}

/* Reads every pending datagram; false on a fatal error (*reason). */
static bool receive(h3_conn *conn, char **reason) {
    static _Thread_local uint8_t buffer[MAX_DATAGRAM];
    for (int count = 0; count < 1024; count++) {
        ssize_t read = recv(conn->fd, buffer, sizeof buffer, 0);
        if (read < 0) {
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                return true;
            *reason = cg_fmt("recv: %s", strerror(errno));
            return false;
        }
        ngtcp2_path path = {
            .local = {(struct sockaddr *)&conn->local, conn->local_len},
            .remote = {(struct sockaddr *)&conn->remote, conn->remote_len},
        };
        ngtcp2_pkt_info info = {0};
        int rv = ngtcp2_conn_read_pkt(conn->quic, &path, &info, buffer, (size_t)read, now_ns());
        if (rv != 0) {
            if (rv == NGTCP2_ERR_DRAINING || rv == NGTCP2_ERR_CLOSING) {
                *reason = cg_strdup("connection closed by the server");
                return false;
            }
            if (!conn->fatal) {
                if (rv == NGTCP2_ERR_CRYPTO)
                    ngtcp2_ccerr_set_tls_alert(&conn->last_error, ngtcp2_conn_get_tls_alert(conn->quic), NULL,
                                               0);
                else
                    ngtcp2_ccerr_set_liberr(&conn->last_error, rv, NULL, 0);
            }
            conn->fatal = true;
            *reason = cg_fmt("read: %s", ngtcp2_strerror(rv));
            return false;
        }
    }
    return true;
}

/* Waits for the socket or a wake-up until the QUIC timer; false on a fatal error. */
static bool wait_and_process(h3_conn *conn, uint64_t limit_ns, char **reason) {
    uint64_t expiry = ngtcp2_conn_get_expiry(conn->quic);
    if (limit_ns && limit_ns < expiry)
        expiry = limit_ns;
    uint64_t now = now_ns();
    int timeout = 0;
    if (expiry > now) {
        uint64_t ms = (expiry - now + 999999) / 1000000;
        timeout = ms > 1000 ? 1000 : (int)ms;
    }
    struct pollfd fds[2] = {{.fd = conn->fd, .events = POLLIN}, {.fd = conn->wake[0], .events = POLLIN}};
    int ready = poll(fds, 2, timeout);
    if (ready < 0 && errno != EINTR) {
        *reason = cg_fmt("poll: %s", strerror(errno));
        return false;
    }
    if (ready > 0 && (fds[1].revents & POLLIN))
        drain_wake(conn);
    if (ready > 0 && (fds[0].revents & (POLLIN | POLLERR)) && !receive(conn, reason))
        return false;
    if (now_ns() >= ngtcp2_conn_get_expiry(conn->quic)) {
        int rv = ngtcp2_conn_handle_expiry(conn->quic, now_ns());
        if (rv != 0) {
            *reason = cg_fmt("%s", rv == NGTCP2_ERR_IDLE_CLOSE ? "idle timeout" : ngtcp2_strerror(rv));
            if (rv != NGTCP2_ERR_IDLE_CLOSE) {
                ngtcp2_ccerr_set_liberr(&conn->last_error, rv, NULL, 0);
                conn->fatal = true;
            }
            return false;
        }
    }
    return true;
}

/* Handshake to one address until `deadline_ns`; false with *reason. */
static bool handshake(h3_conn *conn, uint64_t deadline_ns, char **reason) {
    for (;;) {
        if (!flush(conn, reason))
            return false;
        if (conn->handshake_done)
            break;
        cg_lock(&conn->lock);
        bool stop = conn->stop;
        cg_unlock(&conn->lock);
        if (stop) {
            *reason = cg_strdup("client closed");
            return false;
        }
        if (now_ns() >= deadline_ns) {
            *reason = cg_strdup("QUIC handshake timed out");
            return false;
        }
        if (!wait_and_process(conn, deadline_ns, reason))
            return false;
    }
    const char *protocol = ptls_get_negotiated_protocol(conn->cptls.ptls);
    if (!protocol || strcmp(protocol, "h3") != 0) {
        *reason = cg_strdup("the server did not negotiate h3");
        return false;
    }
    /* HTTP/3 session: control and QPACK streams. */
    if (ngtcp2_conn_get_streams_uni_left(conn->quic) < 3) {
        *reason = cg_strdup("the server allows fewer than 3 unidirectional streams");
        return false;
    }
    nghttp3_settings settings;
    http_settings(&settings);
    if (nghttp3_conn_client_new(&conn->http, &http_callbacks, &settings, nghttp3_mem_default(), conn) != 0) {
        *reason = cg_strdup("nghttp3_conn_client_new failed");
        return false;
    }
    int64_t control, encoder, decoder;
    if (ngtcp2_conn_open_uni_stream(conn->quic, &control, NULL) != 0 ||
        nghttp3_conn_bind_control_stream(conn->http, control) != 0 ||
        ngtcp2_conn_open_uni_stream(conn->quic, &encoder, NULL) != 0 ||
        ngtcp2_conn_open_uni_stream(conn->quic, &decoder, NULL) != 0 ||
        nghttp3_conn_bind_qpack_streams(conn->http, encoder, decoder) != 0) {
        *reason = cg_strdup("HTTP/3 control streams could not be opened");
        return false;
    }
    return true;
}

/* Opens queued requests, applies read credit, cancels abandoned streams (thread). */
static void service(h3_conn *conn) {
    cg_lock(&conn->lock);
    while (conn->pending_len > 0) {
        cg_h3_stream *stream = conn->pending[0];
        int64_t id;
        int rv = ngtcp2_conn_open_bidi_stream(conn->quic, &id, stream);
        if (rv == NGTCP2_ERR_STREAM_ID_BLOCKED)
            break;
        memmove(conn->pending, conn->pending + 1, (conn->pending_len - 1) * sizeof *conn->pending);
        conn->pending_len--;
        if (rv != 0) {
            stream->unusable = true;
            cg_cond_broadcast(&stream->cond);
            stream_unref_locked(stream);
            continue;
        }
        stream->id = id;
        nghttp3_data_reader reader = {.read_data = read_body};
        rv = nghttp3_conn_submit_request(conn->http, id, stream->nva, stream->nvlen,
                                         stream->body ? &reader : NULL, stream);
        if (rv != 0) {
            ngtcp2_conn_shutdown_stream(conn->quic, 0, id, H3_REQUEST_CANCELLED);
            stream->unusable = true;
            cg_cond_broadcast(&stream->cond);
            stream_unref_locked(stream);
            continue;
        }
        stream->opened = true;
        push_ptr((void ***)&conn->streams, &conn->stream_len, &conn->stream_cap, stream);
        cg_cond_broadcast(&stream->cond);
    }
    for (size_t i = 0; i < conn->stream_len; i++) {
        cg_h3_stream *stream = conn->streams[i];
        if (stream->credit > 0) {
            ngtcp2_conn_extend_max_stream_offset(conn->quic, stream->id, stream->credit);
            stream->credit = 0;
        }
        if (stream->abandoned && !stream->cancelled && !stream->fin && stream->error == STREAM_OK) {
            stream->cancelled = true;
            stream->error = STREAM_CLOSED;
            nghttp3_conn_shutdown_stream_read(conn->http, stream->id);
            ngtcp2_conn_shutdown_stream(conn->quic, 0, stream->id, H3_REQUEST_CANCELLED);
        }
    }
    /* Connection-level credit: every byte read by a caller, or dropped unread. */
    if (conn->connection_credit > 0) {
        ngtcp2_conn_extend_max_offset(conn->quic, conn->connection_credit);
        conn->connection_credit = 0;
    }
    cg_unlock(&conn->lock);
}

/* Fails every stream (connection gone). */
static void fail_all(h3_conn *conn) {
    cg_lock(&conn->lock);
    for (size_t i = 0; i < conn->pending_len; i++) {
        cg_h3_stream *stream = conn->pending[i];
        stream->unusable = true;
        cg_cond_broadcast(&stream->cond);
        stream_unref_locked(stream);
    }
    conn->pending_len = 0;
    for (size_t i = 0; i < conn->stream_len; i++) {
        cg_h3_stream *stream = conn->streams[i];
        stream->closed = true;
        if (!stream->fin && stream->error == STREAM_OK)
            stream->error = STREAM_CLOSED;
        cg_cond_broadcast(&stream->cond);
        stream_unref_locked(stream);
    }
    conn->stream_len = 0;
    conn->state = CONN_CLOSED;
    conn->dead = true;
    cg_cond_broadcast(&conn->cond);
    cg_unlock(&conn->lock);
}

/* Sends CONNECTION_CLOSE (best effort). */
static void send_close(h3_conn *conn) {
    if (!conn->quic || ngtcp2_conn_in_closing_period(conn->quic) ||
        ngtcp2_conn_in_draining_period(conn->quic))
        return;
    uint8_t buffer[1500];
    ngtcp2_path_storage path;
    ngtcp2_path_storage_zero(&path);
    ngtcp2_pkt_info info;
    if (!conn->fatal)
        ngtcp2_ccerr_set_application_error(&conn->last_error, H3_NO_ERROR, NULL, 0);
    ngtcp2_ssize written = ngtcp2_conn_write_connection_close(conn->quic, &path.path, &info, buffer,
                                                              sizeof buffer, &conn->last_error, now_ns());
    if (written > 0) {
        ssize_t sent = send(conn->fd, buffer, (size_t)written, 0);
        (void)sent;
    }
}

static void conn_run(void *arg) {
    h3_conn *conn = arg;
    char *reason = NULL;
    /* Resolve and connect (each address gets half of what is left when there are several). */
    char port[8];
    snprintf(port, sizeof port, "%u", conn->port);
    struct addrinfo hints = {0}, *addresses = NULL;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    uint64_t deadline = now_ns() + conn->connect_timeout_ms * 1000000ull;
    int status = getaddrinfo(conn->server_name, port, &hints, &addresses);
    bool established = false;
    if (status != 0) {
        reason = cg_fmt("failed to lookup address information: %s", gai_strerror(status));
    } else {
        bool multiple = addresses && addresses->ai_next;
        for (struct addrinfo *address = addresses; address && !established; address = address->ai_next) {
            uint64_t now = now_ns();
            if (now >= deadline)
                break;
            uint64_t budget = deadline - now;
            if (multiple)
                budget /= 2;
            free(reason);
            reason = NULL;
            if (quic_open(conn, address, &reason) && handshake(conn, now + budget, &reason)) {
                established = true;
            } else {
                send_close(conn);
                quic_close(conn);
            }
        }
        freeaddrinfo(addresses);
        if (!established && !reason)
            reason = cg_strdup("QUIC handshake timed out");
    }
    if (!established) {
        cg_lock(&conn->lock);
        cg_replace(&conn->failure, reason ? reason : cg_strdup("no connection"));
        reason = NULL;
        cg_unlock(&conn->lock);
        fail_all(conn);
        return;
    }
    atomic_fetch_add(&conn->client->opened, 1);
    cg_lock(&conn->lock);
    conn->state = CONN_READY;
    cg_cond_broadcast(&conn->cond);
    cg_unlock(&conn->lock);
    for (;;) {
        cg_lock(&conn->lock);
        bool stop = conn->stop;
        cg_unlock(&conn->lock);
        if (stop)
            break;
        service(conn);
        if (!flush(conn, &reason))
            break;
        if (!wait_and_process(conn, 0, &reason))
            break;
    }
    send_close(conn);
    free(reason);
    fail_all(conn);
    quic_close(conn);
}

/* ======================================================================================
 * client
 * ==================================================================================== */

cg_h3_client *cg_h3_client_new(const cg_host *host) {
    cg_h3_client *client = cg_calloc(1, sizeof *client);
    client->host = host;
    cg_mutex_init(&client->lock);
    atomic_init(&client->opened, 0);
    return client;
}

size_t cg_h3_opened_connections(cg_h3_client *client) { return atomic_load(&client->opened); }

static h3_conn *conn_new(cg_h3_client *client, const char *key, const char *host, uint16_t port,
                         uint64_t connect_timeout_ms) {
    h3_conn *conn = cg_calloc(1, sizeof *conn);
    conn->client = client;
    conn->key = cg_strdup(key);
    /* The URL host without IPv6 brackets: DNS name, SNI and certificate name. */
    size_t len = strlen(host);
    if (len >= 2 && host[0] == '[' && host[len - 1] == ']')
        conn->server_name = cg_strndup(host + 1, len - 2);
    else
        conn->server_name = cg_strdup(host);
    conn->peer.host = client->host;
    conn->peer.server_name = conn->server_name;
    conn->port = port;
    conn->connect_timeout_ms = connect_timeout_ms;
    conn->fd = -1;
    conn->wake[0] = conn->wake[1] = -1;
    cg_mutex_init(&conn->lock);
    cg_cond_init(&conn->cond);
    conn->refs = 1;
    if (pipe(conn->wake) == 0) {
        for (int i = 0; i < 2; i++) {
            fcntl(conn->wake[i], F_SETFL, fcntl(conn->wake[i], F_GETFL, 0) | O_NONBLOCK);
            fcntl(conn->wake[i], F_SETFD, FD_CLOEXEC);
        }
    }
    return conn;
}

/* A finished connection leaves the list (client lock held): its thread is joined. */
static void conn_retire(h3_conn *conn) {
    if (conn->thread_started)
        cg_join(conn->thread);
    conn->thread_started = false;
    conn_release(conn);
}

static bool conn_usable(h3_conn *conn) {
    cg_lock(&conn->lock);
    bool usable = !conn->dead && conn->state != CONN_CLOSED;
    cg_unlock(&conn->lock);
    return usable;
}

/* Picks the connection for a request (see h3.h); *fresh when created here. Returns a referenced
 * connection with its `active` count raised. */
static h3_conn *pick(cg_h3_client *client, const char *key, const char *host, uint16_t port,
                     size_t max_connections, uint64_t connect_timeout_ms, bool *fresh) {
    if (max_connections == 0)
        max_connections = 1;
    cg_lock(&client->lock);
    h3_conn *best = NULL;
    int best_active = 0;
    size_t same = 0;
    for (size_t i = client->conn_len; i > 0; i--) {
        h3_conn *conn = client->conns[i - 1];
        if (!conn_usable(conn)) {
            cg_lock(&conn->lock);
            bool finished = conn->state == CONN_CLOSED;
            cg_unlock(&conn->lock);
            if (finished) {
                memmove(client->conns + i - 1, client->conns + i,
                        (client->conn_len - i) * sizeof *client->conns);
                client->conn_len--;
                conn_retire(conn);
            }
            continue;
        }
        if (strcmp(conn->key, key) != 0)
            continue;
        same++;
        cg_lock(&conn->lock);
        int active = conn->active;
        cg_unlock(&conn->lock);
        if (!best || active <= best_active) {
            best = conn;
            best_active = active;
        }
    }
    *fresh = false;
    if (!best || (best_active > 0 && same < max_connections)) {
        best = conn_new(client, key, host, port, connect_timeout_ms);
        push_ptr((void ***)&client->conns, &client->conn_len, &client->conn_cap, best);
        *fresh = true;
    }
    cg_lock(&best->lock);
    best->active++;
    best->refs++;
    cg_unlock(&best->lock);
    if (*fresh) {
        if (best->wake[0] < 0 || !cg_spawn_joinable("quic", conn_run, best, &best->thread)) {
            cg_lock(&best->lock);
            cg_replace(&best->failure, cg_strdup("could not start the QUIC thread"));
            best->state = CONN_CLOSED;
            best->dead = true;
            cg_unlock(&best->lock);
        } else {
            best->thread_started = true;
        }
    }
    cg_unlock(&client->lock);
    return best;
}

/* The request is done with the connection (stream released or never created). */
static void conn_unuse(h3_conn *conn) {
    cg_lock(&conn->lock);
    conn->active--;
    cg_unlock(&conn->lock);
    conn_release(conn);
}

void cg_h3_client_free(cg_h3_client *client) {
    if (!client)
        return;
    cg_lock(&client->lock);
    for (size_t i = 0; i < client->conn_len; i++) {
        h3_conn *conn = client->conns[i];
        cg_lock(&conn->lock);
        conn->stop = true;
        cg_unlock(&conn->lock);
        wake(conn);
    }
    for (size_t i = 0; i < client->conn_len; i++)
        conn_retire(client->conns[i]);
    free(client->conns);
    client->conns = NULL;
    client->conn_len = 0;
    cg_unlock(&client->lock);
    cg_mutex_destroy(&client->lock);
    free(client);
}

/* ======================================================================================
 * requests
 * ==================================================================================== */

static void add_nv(cg_h3_stream *stream, size_t *cap, const char *name, const char *value) {
    if (stream->nvlen == *cap) {
        *cap = *cap ? *cap * 2 : 16;
        stream->nva = cg_realloc(stream->nva, *cap * sizeof *stream->nva);
        stream->strings = cg_realloc(stream->strings, *cap * 2 * sizeof *stream->strings);
    }
    char *n = cg_strdup(name), *v = cg_strdup(value);
    stream->strings[stream->string_count++] = n;
    stream->strings[stream->string_count++] = v;
    stream->nva[stream->nvlen++] =
        (nghttp3_nv){(uint8_t *)n, (uint8_t *)v, strlen(n), strlen(v), NGHTTP3_NV_FLAG_NONE};
}

static cg_h3_stream *stream_new(h3_conn *conn, const cg_h3_request *request) {
    cg_h3_stream *stream = cg_calloc(1, sizeof *stream);
    stream->conn = conn;
    stream->refs = 2; /* caller + connection thread */
    stream->id = -1;
    cg_cond_init(&stream->cond);
    size_t cap = 0;
    add_nv(stream, &cap, ":method", request->method);
    add_nv(stream, &cap, ":scheme", "https");
    add_nv(stream, &cap, ":authority", request->authority);
    add_nv(stream, &cap, ":path", request->path);
    for (size_t i = 0; i < request->field_count; i++)
        add_nv(stream, &cap, request->fields[i].name, request->fields[i].value);
    if (request->body && request->body_len > 0) {
        stream->body = cg_malloc(request->body_len);
        memcpy(stream->body, request->body, request->body_len);
        stream->body_len = request->body_len;
    }
    stream->timeout_ms = request->timeout_ms;
    return stream;
}

/* Waits on the stream (conn->lock held) until `done` or the deadline; false on timeout. */
static bool stream_wait(cg_h3_stream *stream, int64_t deadline_ms, bool (*done)(const cg_h3_stream *)) {
    h3_conn *conn = stream->conn;
    while (!done(stream)) {
        int64_t left = deadline_ms - cg_mono_ms();
        if (left <= 0)
            return false;
        cg_cond_wait_ms(&stream->cond, &conn->lock, left);
    }
    return true;
}

static bool opened_or_failed(const cg_h3_stream *stream) {
    return stream->opened || stream->unusable || stream->closed;
}

static bool head_or_failed(const cg_h3_stream *stream) {
    return stream->head || stream->unusable || stream->error != STREAM_OK || stream->closed;
}

static bool conn_settled(h3_conn *conn) { return conn->state != CONN_CONNECTING; }

typedef enum { SENT_HEAD = 0, SENT_UNUSABLE, SENT_FAILED, SENT_TIMEOUT, SENT_TOO_MANY_HEADERS } sent_result;

cg_h3_outcome cg_h3_send(cg_h3_client *client, const cg_h3_request *request, size_t max_connections,
                         cg_h3_response *out, cg_net_error *err, char **reason) {
    memset(out, 0, sizeof *out);
    *reason = NULL;
    char *key = cg_fmt("%s:%u", request->host, request->port);
    uint64_t connect_timeout =
        request->timeout_ms < CG_H3_HANDSHAKE_TIMEOUT_MS ? request->timeout_ms : CG_H3_HANDSHAKE_TIMEOUT_MS;
    for (int attempt = 0; attempt < 2; attempt++) {
        bool fresh;
        h3_conn *conn =
            pick(client, key, request->host, request->port, max_connections, connect_timeout, &fresh);
        /* The handshake (bounded by the connection thread) or its failure. */
        cg_lock(&conn->lock);
        while (!conn_settled(conn))
            cg_cond_wait_ms(&conn->cond, &conn->lock, 1000);
        bool ready = conn->state == CONN_READY && !conn->dead;
        char *failure = conn->failure ? cg_strdup(conn->failure) : NULL;
        cg_unlock(&conn->lock);
        if (!ready) {
            cg_lock(&conn->lock);
            conn->dead = true;
            cg_unlock(&conn->lock);
            conn_unuse(conn);
            if (!fresh && attempt == 0) {
                free(failure);
                continue;
            }
            *reason = cg_fmt("no QUIC connection: %s", failure ? failure : "closed");
            free(failure);
            free(key);
            return CG_H3_FALLBACK;
        }
        free(failure);
        cg_h3_stream *stream = stream_new(conn, request);
        cg_lock(&conn->lock);
        if (conn->state != CONN_READY || conn->dead) stream->unusable = true;
        push_ptr((void ***)&conn->pending, &conn->pending_len, &conn->pending_cap, stream);
        cg_unlock(&conn->lock);
        wake(conn);
        sent_result result;
        cg_lock(&conn->lock);
        if (!stream_wait(stream, cg_mono_ms() + (int64_t)request->timeout_ms, opened_or_failed)) {
            result = SENT_TIMEOUT;
        } else if (stream->unusable) {
            result = SENT_UNUSABLE;
        } else if (!stream_wait(stream, cg_mono_ms() + (int64_t)request->timeout_ms, head_or_failed)) {
            result = SENT_TIMEOUT;
        } else if (stream->head && stream->too_many_headers) {
            result = SENT_TOO_MANY_HEADERS;
        } else if (stream->head) {
            result = SENT_HEAD;
        } else {
            result = SENT_FAILED;
        }
        if (result == SENT_HEAD) {
            out->status = stream->status;
            out->fields = stream->fields;
            out->field_count = stream->field_count;
            stream->fields = NULL;
            stream->field_count = stream->field_cap = 0;
            out->body = stream;
            stream->bodiless =
                strcmp(request->method, "HEAD") == 0 || out->status == 204 || out->status == 304;
            stream->has_remaining =
                stream->bodiless || cg_h3_content_length(out->fields, out->field_count, &stream->remaining);
            if (stream->bodiless)
                stream->remaining = 0;
        }
        cg_unlock(&conn->lock);
        if (result == SENT_HEAD) {
            free(key);
            return CG_H3_OK;
        }
        if (result == SENT_UNUSABLE) {
            /* Not in the pending queue anymore: nothing was sent. */
            cg_lock(&conn->lock);
            conn->dead = true;
            cg_unlock(&conn->lock);
            cg_h3_body_free(stream);
            if (!fresh && attempt == 0)
                continue;
            *reason = cg_strdup("the QUIC connection could not take the request");
            free(key);
            return CG_H3_FALLBACK;
        }
        /* Mark it while the stream still owns a connection reference. Another
         * request can concurrently retire a closed connection from the pool. */
        if (result == SENT_FAILED) {
            cg_lock(&conn->lock);
            conn->dead = true;
            cg_unlock(&conn->lock);
        }
        cg_h3_body_free(stream);
        free(key);
        if (result == SENT_TIMEOUT) {
            cg_net_error_set(err, CG_NET_TIMEOUT, "%s", CG_H3_MESSAGE_TIMEOUT);
            return CG_H3_FAIL;
        }
        if (result == SENT_TOO_MANY_HEADERS) {
            cg_net_error_set(err, CG_NET_NETWORK, "%s", CG_H3_MESSAGE_TOO_MANY_HEADERS);
            return CG_H3_FAIL;
        }
        if (request->idempotent) {
            *reason = cg_strdup("the HTTP/3 request failed before its response");
            return CG_H3_FALLBACK;
        }
        cg_net_error_set(err, CG_NET_NETWORK, "%s", CG_H3_MESSAGE_REQUEST_FAILED);
        return CG_H3_FAIL;
    }
    *reason = cg_fmt("no usable QUIC connection to %s", key);
    free(key);
    return CG_H3_FALLBACK;
}

/* ======================================================================================
 * bodies
 * ==================================================================================== */

static bool data_or_end(const cg_h3_stream *stream) {
    return stream->data_len > 0 || stream->fin || stream->error != STREAM_OK || stream->closed;
}

long cg_h3_body_read(cg_h3_stream *stream, uint8_t *buffer, size_t len, net_io_error *io) {
    if (!stream || len == 0 || stream->finished)
        return 0;
    h3_conn *conn = stream->conn;
    if (stream->bodiless) {
        stream->finished = true;
        return 0;
    }
    cg_lock(&conn->lock);
    if (!stream_wait(stream, cg_mono_ms() + (int64_t)stream->timeout_ms, data_or_end)) {
        cg_unlock(&conn->lock);
        stream->finished = true;
        net_io_set(io, NET_IO_TIMED_OUT, "%s", CG_H3_MESSAGE_TIMEOUT);
        return -1;
    }
    if (stream->data_len > 0) {
        size_t n = stream->data_len < len ? stream->data_len : len;
        if (stream->has_remaining && n > stream->remaining) {
            cg_unlock(&conn->lock);
            stream->finished = true;
            net_io_set(io, NET_IO_OTHER, "%s", CG_H3_MESSAGE_LONG_BODY);
            return -1;
        }
        memcpy(buffer, stream->data + stream->data_start, n);
        stream->data_start += n;
        stream->data_len -= n;
        if (stream->data_len == 0)
            stream->data_start = 0;
        if (stream->has_remaining)
            stream->remaining -= n;
        stream->credit += n;
        conn->connection_credit += n;
        bool give = stream->credit >= CREDIT_STEP || stream->data_len == 0;
        cg_unlock(&conn->lock);
        if (give)
            wake(conn);
        return (long)n;
    }
    stream_error error = stream->error;
    bool fin = stream->fin;
    cg_unlock(&conn->lock);
    stream->finished = true;
    if (fin) {
        if (stream->has_remaining && stream->remaining > 0) {
            net_io_set(io, NET_IO_UNEXPECTED_EOF, "%s", CG_H3_MESSAGE_SHORT_BODY);
            return -1;
        }
        return 0;
    }
    net_io_set(io, NET_IO_OTHER, "%s",
               error == STREAM_RESET      ? CG_H3_MESSAGE_RESET
               : error == STREAM_PROTOCOL ? CG_H3_MESSAGE_PROTOCOL
                                          : CG_H3_MESSAGE_CLOSED);
    return -1;
}

bool cg_h3_body_buffered(cg_h3_stream *stream) {
    if (!stream || stream->finished)
        return false;
    cg_lock(&stream->conn->lock);
    bool buffered = stream->data_len > 0;
    cg_unlock(&stream->conn->lock);
    return buffered;
}

void cg_h3_body_free(cg_h3_stream *stream) {
    if (!stream)
        return;
    h3_conn *conn = stream->conn;
    cg_lock(&conn->lock);
    bool cancel = false;
    if (remove_ptr((void **)conn->pending, &conn->pending_len, stream)) {
        /* Never opened: the thread's reference goes too. */
        stream_unref_locked(stream);
    } else {
        /* Bytes that will never be read give their connection credit back. */
        conn->connection_credit += stream->data_len;
        stream->data_len = 0;
        stream->abandoned = true;
        cancel = true;
    }
    stream_unref_locked(stream);
    cg_unlock(&conn->lock);
    if (cancel)
        wake(conn);
    conn_unuse(conn);
}

void cg_h3_response_clear(cg_h3_response *response) {
    fields_free(response->fields, response->field_count);
    cg_h3_body_free(response->body);
    memset(response, 0, sizeof *response);
}

