/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Internals shared by net.c (HTTP) and net_tls.c (TLS over a connected socket). */
#ifndef CG_NET_INTERNAL_H
#define CG_NET_INTERNAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "host.h"
#include "net_url.h"

/* std::io::ErrorKind subset the client distinguishes (timeouts, closed connections). */
typedef enum {
    NET_IO_OTHER = 0,
    NET_IO_TIMED_OUT,
    NET_IO_WOULD_BLOCK,
    NET_IO_UNEXPECTED_EOF,
    NET_IO_CONNECTION_ABORTED,
    NET_IO_CONNECTION_RESET,
    NET_IO_INVALID_INPUT,
    NET_IO_INVALID_DATA,
} net_io_kind;

/* A std::io::Error: kind + Display text. */
typedef struct {
    net_io_kind kind;
    char *message; /* NULL: no error */
} net_io_error;

bool net_io_set(net_io_error *err, net_io_kind kind, const char *format, ...) CG_PRINTF(3, 4);
/* From errno: Rust's "<strerror> (os error N)" with the matching kind. */
bool net_io_errno(net_io_error *err, int errnum);
void net_io_clear(net_io_error *err);

/* Blocking socket I/O (timeouts are SO_RCVTIMEO / SO_SNDTIMEO). recv: bytes, 0 at EOF, -1 on error. */
long net_sock_recv(int fd, uint8_t *buffer, size_t len, net_io_error *err);
bool net_sock_send_all(int fd, const uint8_t *data, size_t len, net_io_error *err);

/* ---- TLS (net_tls.c) */
typedef struct net_tls net_tls;

/* Handshake on a connected socket, then the host trust decision and the name check (rustls
 * HostVerifier). `server_name` is the URL host ("example.com", "127.0.0.1", "[::1]"). NULL with
 * *err (Rust io::Error display) on failure; nothing has been sent but the handshake. */
net_tls *net_tls_connect(int fd, const cg_host *host, const char *server_name, net_io_error *err);
/* Plaintext read: bytes, 0 at the end of the stream (close_notify), -1 on error. */
long net_tls_read(net_tls *tls, uint8_t *buffer, size_t len, net_io_error *err);
bool net_tls_write_all(net_tls *tls, const uint8_t *data, size_t len, net_io_error *err);
/* Plaintext or ciphertext already buffered (a read would not block). */
bool net_tls_buffered(net_tls *tls);
void net_tls_free(net_tls *tls);

/* rustls ServerName::try_from for a DNS name (pki-types validate). */
bool net_tls_valid_dns_name(const char *name);

#endif
