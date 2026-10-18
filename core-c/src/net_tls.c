/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * TLS 1.2 / 1.3 client over Mbed TLS (Rust net.rs RustlsConnector + HostVerifier).
 *
 * There are no CA roots: chain trust is the host's decision (Android X509TrustManager,
 * iOS SecTrust) through cg_host_verify_certificate, and the host name is checked here
 * (webpki rules: subjectAltName DNS names with left-most `*` wildcards, IP addresses; no
 * common name fallback). Mbed TLS verifies the handshake signatures with the leaf key; the
 * chain is judged right after the handshake, before any application byte is written, and
 * every failure (rejection, no verifier, name mismatch, oversized chain) closes the
 * connection. No session resumption: every connection is verified.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#include "mbedtls/error.h"
#include "mbedtls/oid.h"
#include "mbedtls/psa_util.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "net_internal.h"
#include "psa/crypto.h"
#include "rt/str.h"

/* Ciphertext read-ahead: whole records (and several of them) per recv. */
#define TLS_SOCKET_BUFFER (64 * 1024)
/* Longest server certificate chain passed to the host verifier (Rust MAX_CERTIFICATE_CHAIN). */
#define MAX_CERTIFICATE_CHAIN 32
/* BIO failure codes; the socket error itself is kept in net_tls.io. */
#define BIO_RECV_FAILED (-0x004C)
#define BIO_SEND_FAILED (-0x004E)

struct net_tls {
    int fd;
    mbedtls_ssl_context ssl;
    uint8_t *sbuf;
    size_t spos, slen;
    net_io_error io; /* socket error seen by the BIO */
};

/* ---- shared configuration (read-only after initialization, shared by all connections) */

static pthread_once_t tls_once = PTHREAD_ONCE_INIT;
static mbedtls_ssl_config tls_conf;
static bool tls_ready;

/* rustls defaults with the ring provider: AEAD suites only, X25519 / P-256 / P-384. */
static const int tls_suites[] = {
    MBEDTLS_TLS1_3_AES_256_GCM_SHA384,
    MBEDTLS_TLS1_3_AES_128_GCM_SHA256,
    MBEDTLS_TLS1_3_CHACHA20_POLY1305_SHA256,
    MBEDTLS_TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
    MBEDTLS_TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
    MBEDTLS_TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
    MBEDTLS_TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
    MBEDTLS_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
    MBEDTLS_TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
    0,
};

static const uint16_t tls_groups[] = {
    MBEDTLS_SSL_IANA_TLS_GROUP_X25519,
    MBEDTLS_SSL_IANA_TLS_GROUP_SECP256R1,
    MBEDTLS_SSL_IANA_TLS_GROUP_SECP384R1,
    MBEDTLS_SSL_IANA_TLS_GROUP_NONE,
};

static void tls_init(void) {
    if (psa_crypto_init() != PSA_SUCCESS) return;
    mbedtls_ssl_config_init(&tls_conf);
    if (mbedtls_ssl_config_defaults(&tls_conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM,
                                    MBEDTLS_SSL_PRESET_DEFAULT) != 0)
        return;
    /* The chain is judged by the host after the handshake (see the file comment). */
    mbedtls_ssl_conf_authmode(&tls_conf, MBEDTLS_SSL_VERIFY_NONE);
    mbedtls_ssl_conf_rng(&tls_conf, mbedtls_psa_get_random, MBEDTLS_PSA_RANDOM_STATE);
    mbedtls_ssl_conf_min_tls_version(&tls_conf, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_max_tls_version(&tls_conf, MBEDTLS_SSL_VERSION_TLS1_3);
    mbedtls_ssl_conf_ciphersuites(&tls_conf, tls_suites);
    mbedtls_ssl_conf_groups(&tls_conf, tls_groups);
    tls_ready = true;
}

/* ---- BIO over the blocking socket */

static int bio_send(void *context, const unsigned char *data, size_t len) {
    net_tls *tls = context;
    if (len > INT_MAX) len = INT_MAX;
    for (;;) {
#ifdef MSG_NOSIGNAL
        ssize_t sent = send(tls->fd, data, len, MSG_NOSIGNAL);
#else
        ssize_t sent = send(tls->fd, data, len, 0);
#endif
        if (sent >= 0) return (int)sent;
        if (errno == EINTR) continue;
        net_io_errno(&tls->io, errno);
        return BIO_SEND_FAILED;
    }
}

static int bio_recv(void *context, unsigned char *buffer, size_t len) {
    net_tls *tls = context;
    if (len > INT_MAX) len = INT_MAX;
    if (tls->spos == tls->slen) {
        tls->spos = tls->slen = 0;
        if (len >= TLS_SOCKET_BUFFER) {
            long direct = net_sock_recv(tls->fd, buffer, len, &tls->io);
            return direct < 0 ? BIO_RECV_FAILED : (int)direct;
        }
        long read = net_sock_recv(tls->fd, tls->sbuf, TLS_SOCKET_BUFFER, &tls->io);
        if (read <= 0) return read < 0 ? BIO_RECV_FAILED : 0;
        tls->slen = (size_t)read;
    }
    size_t available = tls->slen - tls->spos;
    size_t n = available < len ? available : len;
    memcpy(buffer, tls->sbuf + tls->spos, n);
    tls->spos += n;
    return (int)n;
}

/* ---- errors */

static const char *alert_name(unsigned char alert) {
    switch (alert) {
    case 0: return "CloseNotify";
    case 10: return "UnexpectedMessage";
    case 20: return "BadRecordMac";
    case 21: return "DecryptionFailed";
    case 22: return "RecordOverflow";
    case 30: return "DecompressionFailure";
    case 40: return "HandshakeFailure";
    case 41: return "NoCertificate";
    case 42: return "BadCertificate";
    case 43: return "UnsupportedCertificate";
    case 44: return "CertificateRevoked";
    case 45: return "CertificateExpired";
    case 46: return "CertificateUnknown";
    case 47: return "IllegalParameter";
    case 48: return "UnknownCA";
    case 49: return "AccessDenied";
    case 50: return "DecodeError";
    case 51: return "DecryptError";
    case 60: return "ExportRestriction";
    case 70: return "ProtocolVersion";
    case 71: return "InsufficientSecurity";
    case 80: return "InternalError";
    case 86: return "InappropriateFallback";
    case 90: return "UserCanceled";
    case 100: return "NoRenegotiation";
    case 109: return "MissingExtension";
    case 110: return "UnsupportedExtension";
    case 112: return "UnrecognisedName";
    case 115: return "UnknownPSKIdentity";
    case 116: return "CertificateRequired";
    case 120: return "NoApplicationProtocol";
    default: return NULL;
    }
}

/* An Mbed TLS failure as the io::Error rustls would have produced. */
static void tls_failure(net_tls *tls, int ret, bool handshaking, net_io_error *err) {
    if ((ret == BIO_RECV_FAILED || ret == BIO_SEND_FAILED) && tls->io.message) {
        err->kind = tls->io.kind;
        cg_replace(&err->message, tls->io.message);
        tls->io.message = NULL;
        return;
    }
    if (ret == MBEDTLS_ERR_SSL_CONN_EOF) {
        if (handshaking) net_io_set(err, NET_IO_UNEXPECTED_EOF, "unexpected end of file");
        else
            net_io_set(err, NET_IO_UNEXPECTED_EOF,
                       "peer closed connection without sending TLS close_notify: "
                       "https://docs.rs/rustls/latest/rustls/manual/_03_howto/index.html#unexpected-eof");
        return;
    }
    if (ret == MBEDTLS_ERR_SSL_FATAL_ALERT_MESSAGE) {
        unsigned char alert = tls->ssl.MBEDTLS_PRIVATE(in_msg) ? tls->ssl.MBEDTLS_PRIVATE(in_msg)[1] : 0;
        const char *name = alert_name(alert);
        if (name) net_io_set(err, NET_IO_INVALID_DATA, "received fatal alert: %s", name);
        else net_io_set(err, NET_IO_INVALID_DATA, "received fatal alert: Unknown(%u)", alert);
        return;
    }
    char detail[200];
    mbedtls_strerror(ret, detail, sizeof detail);
    net_io_set(err, NET_IO_INVALID_DATA, "peer misbehaved: %s", detail);
}

/* ---- host names (rustls-pki-types / rustls-webpki rules) */

bool net_tls_valid_dns_name(const char *name) {
    size_t len = strlen(name);
    if (len == 0 || len > 253) return false;
    enum { START, HAS_LETTER, ALL_NUMERIC, ENDS_IN_HYPHEN } state = START;
    size_t start = 0, idx = 0;
    for (;;) {
        int ch = idx < len ? (unsigned char)name[idx] : -1;
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_') {
            state = HAS_LETTER;
        } else if (ch >= '0' && ch <= '9') {
            state = (state == START || state == ALL_NUMERIC) ? ALL_NUMERIC : HAS_LETTER;
        } else if (ch == '.' || ch < 0) {
            size_t label = idx - start;
            if (label == 0 || label > 63 || state == ENDS_IN_HYPHEN) return false;
            if (idx + 1 >= len) break;
            idx++;
            start = idx;
            state = START;
            continue;
        } else if (ch == '-') {
            if (idx == start) return false;
            state = ENDS_IN_HYPHEN;
        } else {
            return false;
        }
        idx++;
    }
    return state != ALL_NUMERIC;
}

/* webpki is_valid_dns_id (roles: reference or presented). */
static bool valid_dns_id(const uint8_t *name, size_t len, bool presented, bool allow_wildcards) {
    if (len > 253) return false;
    size_t pos = 0;
    int dot_count = 0;
    size_t label_length = 0;
    bool label_is_all_numeric = false, label_ends_with_hyphen = false;
    bool is_wildcard = allow_wildcards && len > 0 && name[0] == '*';
    bool is_first_byte = !is_wildcard;
    if (is_wildcard) {
        if (len < 2 || name[1] != '.') return false;
        pos = 2;
        dot_count++;
    }
    for (;;) {
        if (pos >= len) return false; /* read_byte on an empty input */
        uint8_t b = name[pos++];
        if (b == '-') {
            if (label_length == 0) return false;
            label_is_all_numeric = false;
            label_ends_with_hyphen = true;
            if (++label_length > 63) return false;
        } else if (b >= '0' && b <= '9') {
            if (label_length == 0) label_is_all_numeric = true;
            label_ends_with_hyphen = false;
            if (++label_length > 63) return false;
        } else if ((b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_') {
            label_is_all_numeric = false;
            label_ends_with_hyphen = false;
            if (++label_length > 63) return false;
        } else if (b == '.') {
            dot_count++;
            if (label_length == 0) return false;
            if (label_ends_with_hyphen) return false;
            label_length = 0;
        } else {
            return false;
        }
        is_first_byte = false;
        if (pos >= len) break;
    }
    (void)is_first_byte;
    if (label_length == 0 && presented) return false;
    if (label_ends_with_hyphen) return false;
    if (label_is_all_numeric) return false;
    if (is_wildcard) {
        int label_count = label_length == 0 ? dot_count : dot_count + 1;
        if (label_count < 3) return false;
    }
    return true;
}

static uint8_t ascii_lower(uint8_t b) { return (b >= 'A' && b <= 'Z') ? (uint8_t)(b + 32) : b; }

/* webpki presented_id_matches_reference_id (reference role); malformed ids never match. */
static bool dns_name_matches(const uint8_t *presented, size_t plen, const uint8_t *reference, size_t rlen) {
    if (!valid_dns_id(presented, plen, true, true)) return false;
    if (!valid_dns_id(reference, rlen, false, false)) return false;
    size_t p = 0, r = 0;
    if (plen > 0 && presented[0] == '*') {
        p = 1;
        for (;;) {
            if (r >= rlen) return false;
            r++;
            if (r < rlen && reference[r] == '.') break;
        }
    }
    for (;;) {
        if (p >= plen || r >= rlen) return false;
        uint8_t pb = presented[p++], rb = reference[r++];
        if (ascii_lower(pb) != ascii_lower(rb)) return false;
        if (p >= plen) {
            if (pb == '.') return false;
            break;
        }
    }
    if (r < rlen) {
        if (reference[r++] != '.') return false;
        if (r < rlen) return false;
    }
    return true;
}

/* GeneralName Debug (webpki) of one subjectAltName entry. */
static void describe_name(cg_buf *out, const mbedtls_x509_buf *name) {
    int tag = name->tag;
    if (tag == (MBEDTLS_ASN1_CONTEXT_SPECIFIC | 2)) {
        char *text = cg_utf8_lossy(name->p, name->len);
        cg_buf_printf(out, "DnsName(\"%s\")", text);
        free(text);
    } else if (tag == (MBEDTLS_ASN1_CONTEXT_SPECIFIC | MBEDTLS_ASN1_CONSTRUCTED | 4)) {
        cg_buf_puts(out, "DirectoryName");
    } else if (tag == (MBEDTLS_ASN1_CONTEXT_SPECIFIC | 7)) {
        cg_buf_puts(out, "IpAddress(");
        if (name->len == 4) {
            cg_buf_printf(out, "%u.%u.%u.%u", name->p[0], name->p[1], name->p[2], name->p[3]);
        } else if (name->len == 16) {
            bool first = true, skipping = false;
            for (size_t i = 0; i < 16; i += 2) {
                bool zero = name->p[i] == 0 && name->p[i + 1] == 0;
                if (first) {
                    first = false;
                } else if (zero) {
                    skipping = true;
                    continue;
                } else if (!skipping) {
                    cg_buf_putc(out, ':');
                } else {
                    skipping = false;
                    cg_buf_puts(out, "::");
                }
                if (name->p[i] != 0) cg_buf_printf(out, "%x", name->p[i]);
                if (name->p[i] == 0) cg_buf_printf(out, "%x", name->p[i + 1]);
                else cg_buf_printf(out, "%02x", name->p[i + 1]);
            }
        } else {
            cg_buf_puts(out, "[invalid: ");
            for (size_t i = 0; i < name->len; i++) cg_buf_printf(out, "%s%02x", i ? ", " : "", name->p[i]);
            cg_buf_putc(out, ']');
        }
        cg_buf_putc(out, ')');
    } else if (tag == (MBEDTLS_ASN1_CONTEXT_SPECIFIC | 6)) {
        char *text = cg_utf8_lossy(name->p, name->len);
        cg_buf_printf(out, "UniformResourceIdentifier(\"%s\")", text);
        free(text);
    } else {
        cg_buf_printf(out, "Unsupported(0x%02x)", tag & 0x1F);
    }
}

/* verify_server_name: NULL when the leaf covers the name, else the rustls error text. */
static char *check_server_name(const mbedtls_x509_crt *leaf, const char *name, bool is_ip, const uint8_t *ip,
                               size_t ip_len) {
    bool has_san = (leaf->MBEDTLS_PRIVATE(ext_types) & MBEDTLS_X509_EXT_SUBJECT_ALT_NAME) != 0;
    const mbedtls_x509_sequence *san = has_san ? &leaf->subject_alt_names : NULL;
    for (const mbedtls_x509_sequence *cur = san; cur && cur->buf.p; cur = cur->next) {
        if (is_ip) {
            if (cur->buf.tag == (MBEDTLS_ASN1_CONTEXT_SPECIFIC | 7) && cur->buf.len == ip_len &&
                memcmp(cur->buf.p, ip, ip_len) == 0)
                return NULL;
        } else if (cur->buf.tag == (MBEDTLS_ASN1_CONTEXT_SPECIFIC | 2) &&
                   dns_name_matches(cur->buf.p, cur->buf.len, (const uint8_t *)name, strlen(name))) {
            return NULL;
        }
    }
    cg_buf out = {0};
    cg_buf_printf(&out, "invalid peer certificate: certificate not valid for name \"%s\"; certificate ", name);
    size_t count = 0;
    for (const mbedtls_x509_sequence *cur = san; cur && cur->buf.p; cur = cur->next) count++;
    if (count == 0) {
        cg_buf_puts(&out, "is not valid for any names (according to its subjectAltName extension)");
    } else {
        cg_buf_puts(&out, "is only valid for ");
        size_t i = 0;
        for (const mbedtls_x509_sequence *cur = san; cur && cur->buf.p; cur = cur->next, i++) {
            if (i > 0) cg_buf_puts(&out, i == count - 1 ? " or " : ", ");
            describe_name(&out, &cur->buf);
        }
    }
    return cg_buf_take(&out);
}

/* HostVerifier::verify_server_cert after the handshake. */
static bool verify_peer(net_tls *tls, const cg_host *host, const char *name, bool is_ip, const uint8_t *ip,
                        size_t ip_len, net_io_error *err) {
    const mbedtls_x509_crt *leaf = mbedtls_ssl_get_peer_cert(&tls->ssl);
    size_t count = 0;
    for (const mbedtls_x509_crt *cert = leaf; cert && cert->raw.p; cert = cert->next) count++;
    if (count == 0) return net_io_set(err, NET_IO_INVALID_DATA, "peer sent no certificates");
    /* A server can send thousands of certificates: refused before the host sees them. */
    if (count - 1 >= MAX_CERTIFICATE_CHAIN)
        return net_io_set(err, NET_IO_INVALID_DATA,
                          "invalid peer certificate: Certificate chain longer than %d certificates",
                          MAX_CERTIFICATE_CHAIN);
    const uint8_t *chain[MAX_CERTIFICATE_CHAIN];
    size_t lengths[MAX_CERTIFICATE_CHAIN];
    size_t i = 0;
    for (const mbedtls_x509_crt *cert = leaf; cert && cert->raw.p; cert = cert->next, i++) {
        chain[i] = cert->raw.p;
        lengths[i] = cert->raw.len;
    }
    char *reason = NULL;
    int verdict = cg_host_verify_certificate(host, chain, lengths, count, name, &reason);
    if (verdict == -1) {
        free(reason);
        return net_io_set(err, NET_IO_INVALID_DATA, "invalid peer certificate: No certificate verifier available");
    }
    if (verdict != 1) {
        net_io_set(err, NET_IO_INVALID_DATA, "invalid peer certificate: %s", reason ? reason : "");
        free(reason);
        return false;
    }
    free(reason);
    /* The host checked the chain; the name is always checked here too. */
    char *mismatch = check_server_name(leaf, name, is_ip, ip, ip_len);
    if (mismatch) {
        err->kind = NET_IO_INVALID_DATA;
        cg_replace(&err->message, mismatch);
        return false;
    }
    return true;
}

/* ---- connections */

net_tls *net_tls_connect(int fd, const cg_host *host, const char *server_name, net_io_error *err) {
    pthread_once(&tls_once, tls_init);
    /* ureq passes the URL host; IPv6 literals lose their brackets. */
    const char *start = server_name;
    while (*start == '[') start++;
    size_t len = strlen(start);
    while (len > 0 && start[len - 1] == ']') len--;
    char *name = cg_strndup(start, len);
    uint8_t ip[16];
    size_t ip_len = 0;
    if (inet_pton(AF_INET, name, ip) == 1) ip_len = 4;
    else if (inet_pton(AF_INET6, name, ip) == 1) ip_len = 16;
    bool is_ip = ip_len > 0;
    if (!is_ip && !net_tls_valid_dns_name(name)) {
        net_io_set(err, NET_IO_INVALID_INPUT, "invalid TLS server name %s", name);
        free(name);
        return NULL;
    }
    /* The name the host verifier sees: the DNS name as given, or the address (Rust IpAddr Display). */
    char display[INET6_ADDRSTRLEN];
    const char *verified_name = name;
    if (is_ip && inet_ntop(ip_len == 4 ? AF_INET : AF_INET6, ip, display, sizeof display)) verified_name = display;
    if (!tls_ready) {
        net_io_set(err, NET_IO_OTHER, "TLS initialization failed");
        free(name);
        return NULL;
    }
    net_tls *tls = cg_calloc(1, sizeof *tls);
    tls->fd = fd;
    tls->sbuf = cg_malloc(TLS_SOCKET_BUFFER);
    mbedtls_ssl_init(&tls->ssl);
    int ret = mbedtls_ssl_setup(&tls->ssl, &tls_conf);
    if (ret == 0) {
        /* SNI for DNS names only (like rustls), without a trailing dot. */
        if (is_ip) {
            ret = mbedtls_ssl_set_hostname(&tls->ssl, NULL);
        } else {
            char *sni = cg_strdup(name);
            size_t sni_len = strlen(sni);
            if (sni_len > 0 && sni[sni_len - 1] == '.') sni[sni_len - 1] = 0;
            ret = mbedtls_ssl_set_hostname(&tls->ssl, sni);
            free(sni);
        }
    }
    if (ret != 0) {
        char detail[200];
        mbedtls_strerror(ret, detail, sizeof detail);
        net_io_set(err, NET_IO_OTHER, "%s", detail);
        net_tls_free(tls);
        free(name);
        return NULL;
    }
    mbedtls_ssl_set_bio(&tls->ssl, tls, bio_send, bio_recv, NULL);
    do {
        ret = mbedtls_ssl_handshake(&tls->ssl);
    } while (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE);
    bool ok = ret == 0;
    if (!ok) tls_failure(tls, ret, true, err);
    else ok = verify_peer(tls, host, verified_name, is_ip, ip, ip_len, err);
    free(name);
    if (!ok) {
        if (ret == 0)
            mbedtls_ssl_send_alert_message(&tls->ssl, MBEDTLS_SSL_ALERT_LEVEL_FATAL,
                                           MBEDTLS_SSL_ALERT_MSG_CERT_UNKNOWN);
        net_tls_free(tls);
        return NULL;
    }
    return tls;
}

long net_tls_read(net_tls *tls, uint8_t *buffer, size_t len, net_io_error *err) {
    if (len > INT_MAX) len = INT_MAX;
    for (;;) {
        int ret = mbedtls_ssl_read(&tls->ssl, buffer, len);
        if (ret > 0) return ret;
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE ||
            ret == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET)
            continue;
        if (ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return 0;
        tls_failure(tls, ret == 0 ? MBEDTLS_ERR_SSL_CONN_EOF : ret, false, err);
        return -1;
    }
}

bool net_tls_write_all(net_tls *tls, const uint8_t *data, size_t len, net_io_error *err) {
    while (len > 0) {
        int ret = mbedtls_ssl_write(&tls->ssl, data, len);
        if (ret > 0) {
            data += ret;
            len -= (size_t)ret;
            continue;
        }
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE ||
            ret == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET)
            continue;
        tls_failure(tls, ret, false, err);
        return false;
    }
    return true;
}

bool net_tls_buffered(net_tls *tls) {
    return tls->slen > tls->spos || mbedtls_ssl_get_bytes_avail(&tls->ssl) > 0 ||
           mbedtls_ssl_check_pending(&tls->ssl);
}

void net_tls_free(net_tls *tls) {
    if (!tls) return;
    mbedtls_ssl_free(&tls->ssl);
    free(tls->sbuf);
    net_io_clear(&tls->io);
    free(tls);
}
