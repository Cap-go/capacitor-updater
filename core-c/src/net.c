/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * HTTP client (Rust net.rs over ureq 2.12 + rustls), see net.h.
 *
 * What ureq does and the engine relies on is reproduced here: request headers (set
 * semantics, Host / Accept defaults, Content-Length, Basic auth from the URL userinfo),
 * HTTP/1.1 keep-alive with an idle pool per client (direct connections only, 64 idle,
 * LIFO, liveness peek, one retry of idempotent requests on a recycled connection),
 * Content-Length / chunked / read-to-close bodies, HTTP proxies (absolute-form requests,
 * CONNECT tunnels), connect / read / write timeouts and the ureq error texts, which the
 * Rust client classifies into NetErrorKind by substring exactly as done here.
 */

#include "net.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <zlib.h>

#include "crypto/checksum.h"
#include "net_internal.h"
#include "net_url.h"
#include "rt/sync.h"

#define DEFAULT_TIMEOUT_MS 20000u
#define DOWNLOAD_MIN_TIMEOUT_MS 60000u
/* ureq: read buffer of the connection, longest header line, most header fields. */
#define CONN_BUFFER (16 * 1024)
#define MAX_HEADER_SIZE (100 * 1024)
#define MAX_HEADER_COUNT 100
#define POOL_MAX_IDLE 64
#define POOL_MAX_IDLE_PER_HOST 64
/* ureq's own user agent (CONNECT requests). */
#define UREQ_USER_AGENT "ureq/2.12.1"
/* Proxy server name given to ureq for host proxies (it shows in DNS errors). */
#define PROXY_PLACEHOLDER "capgo-system-proxy"

/* ======================================================================================
 * io errors and sockets
 * ==================================================================================== */

bool net_io_set(net_io_error *err, net_io_kind kind, const char *format, ...) {
    va_list args;
    va_start(args, format);
    char *message = cg_vfmt(format, args);
    va_end(args);
    cg_replace(&err->message, message);
    err->kind = kind;
    return false;
}

static net_io_kind kind_of_errno(int errnum) {
    switch (errnum) {
    case ETIMEDOUT:
        return NET_IO_TIMED_OUT;
    case EAGAIN:
#if EWOULDBLOCK != EAGAIN
    case EWOULDBLOCK:
#endif
        return NET_IO_WOULD_BLOCK;
    case ECONNRESET:
        return NET_IO_CONNECTION_RESET;
    case ECONNABORTED:
        return NET_IO_CONNECTION_ABORTED;
    default:
        return NET_IO_OTHER;
    }
}

bool net_io_errno(net_io_error *err, int errnum) {
    cg_replace(&err->message, cg_io_message(errnum));
    err->kind = kind_of_errno(errnum);
    return false;
}

void net_io_clear(net_io_error *err) {
    free(err->message);
    err->message = NULL;
    err->kind = NET_IO_OTHER;
}

long net_sock_recv(int fd, uint8_t *buffer, size_t len, net_io_error *err) {
    for (;;) {
        ssize_t read = recv(fd, buffer, len, 0);
        if (read >= 0) return (long)read;
        if (errno == EINTR) continue;
        net_io_errno(err, errno);
        return -1;
    }
}

bool net_sock_send_all(int fd, const uint8_t *data, size_t len, net_io_error *err) {
    while (len > 0) {
#ifdef MSG_NOSIGNAL
        ssize_t sent = send(fd, data, len, MSG_NOSIGNAL);
#else
        ssize_t sent = send(fd, data, len, 0);
#endif
        if (sent < 0) {
            if (errno == EINTR) continue;
            return net_io_errno(err, errno);
        }
        if (sent == 0) return net_io_set(err, NET_IO_OTHER, "failed to write whole buffer");
        data += sent;
        len -= (size_t)sent;
    }
    return true;
}

/* ======================================================================================
 * public error / header / response helpers
 * ==================================================================================== */

bool cg_net_error_set_own(cg_net_error *err, cg_net_error_kind kind, char *message) {
    if (!err) {
        free(message);
        return false;
    }
    free(err->message);
    err->kind = kind;
    err->message = message ? message : cg_strdup("");
    return false;
}

bool cg_net_error_set(cg_net_error *err, cg_net_error_kind kind, const char *format, ...) {
    va_list args;
    va_start(args, format);
    char *message = cg_vfmt(format, args);
    va_end(args);
    return cg_net_error_set_own(err, kind, message);
}

void cg_net_error_clear(cg_net_error *err) {
    if (!err) return;
    free(err->message);
    err->message = NULL;
    err->kind = CG_NET_TIMEOUT;
}

bool cg_net_error_is_timeout(const cg_net_error *err) { return err && err->message && err->kind == CG_NET_TIMEOUT; }

const char *cg_net_error_kind_code(cg_net_error_kind kind) {
    switch (kind) {
    case CG_NET_TIMEOUT:
        return "timeout";
    case CG_NET_NETWORK:
        return "network";
    case CG_NET_TLS:
        return "tls";
    case CG_NET_INVALID_URL:
        return "invalid_url";
    case CG_NET_INSECURE_REDIRECT:
        return "insecure_redirect";
    case CG_NET_IO:
        return "io";
    }
    return "network";
}

const char *cg_net_headers_get(const cg_net_headers *headers, const char *name) {
    for (size_t i = 0; headers && i < headers->len; i++)
        if (strcasecmp(headers->items[i].name, name) == 0) return headers->items[i].value;
    return NULL;
}

void cg_net_headers_push(cg_net_headers *headers, const char *name, const char *value) {
    if (headers->len == headers->cap) {
        headers->cap = headers->cap ? headers->cap * 2 : 8;
        headers->items = cg_realloc(headers->items, headers->cap * sizeof *headers->items);
    }
    headers->items[headers->len].name = cg_strdup(name);
    headers->items[headers->len].value = cg_strdup(value);
    headers->len++;
}

void cg_net_headers_clear(cg_net_headers *headers) {
    for (size_t i = 0; i < headers->len; i++) {
        free(headers->items[i].name);
        free(headers->items[i].value);
    }
    free(headers->items);
    memset(headers, 0, sizeof *headers);
}

const char *cg_net_response_header(const cg_net_response *response, const char *name) {
    return cg_net_headers_get(&response->headers, name);
}

char *cg_net_response_text(const cg_net_response *response) {
    return cg_utf8_lossy(response->body, response->body_len);
}

bool cg_net_response_is_success(const cg_net_response *response) {
    return response->status >= 200 && response->status < 300;
}

cj *cg_net_response_json(const cg_net_response *response) {
    if (!response->body) return NULL;
    return cj_parsen((const char *)response->body, response->body_len, NULL);
}

void cg_net_response_clear(cg_net_response *response) {
    cg_net_headers_clear(&response->headers);
    free(response->body);
    memset(response, 0, sizeof *response);
}

const char *cg_net_stream_head_header(const cg_net_stream_head *head, const char *name) {
    return cg_net_headers_get(&head->headers, name);
}

void cg_net_stream_head_clear(cg_net_stream_head *head) {
    cg_net_headers_clear(&head->headers);
    memset(head, 0, sizeof *head);
}

bool cg_net_redirect_allowed(const char *from_scheme, const char *to_scheme, bool allow_downgrade) {
    return !(cg_eq_nocase(from_scheme, "https") && cg_eq_nocase(to_scheme, "http")) || allow_downgrade;
}

/* ======================================================================================
 * error texts (ureq Error Display, net.rs classification)
 * ==================================================================================== */

typedef enum {
    UREQ_INVALID_URL,
    UREQ_UNKNOWN_SCHEME,
    UREQ_DNS,
    UREQ_CONNECTION_FAILED,
    UREQ_BAD_STATUS,
    UREQ_BAD_HEADER,
    UREQ_IO,
    UREQ_PROXY_CONNECT,
    UREQ_PROXY_UNAUTHORIZED,
} ureq_kind;

static const char *ureq_kind_text(ureq_kind kind) {
    switch (kind) {
    case UREQ_INVALID_URL:
        return "Bad URL";
    case UREQ_UNKNOWN_SCHEME:
        return "Unknown Scheme";
    case UREQ_DNS:
        return "Dns Failed";
    case UREQ_CONNECTION_FAILED:
        return "Connection Failed";
    case UREQ_BAD_STATUS:
        return "Bad Status";
    case UREQ_BAD_HEADER:
        return "Bad Header";
    case UREQ_IO:
        return "Network Error";
    case UREQ_PROXY_CONNECT:
        return "Proxy failed to connect";
    case UREQ_PROXY_UNAUTHORIZED:
        return "Provided proxy credentials are incorrect";
    }
    return "";
}

static bool lower_contains(const char *text, const char *needle) {
    char *lower = cg_lower(text);
    bool found = strstr(lower, needle) != NULL;
    free(lower);
    return found;
}

/* net.rs transport_error: a ureq transport error ("[url: ]Kind[: message][: source]"). */
static bool transport_fail(cg_net_error *err, ureq_kind kind, const char *url, const char *message,
                           const char *source) {
    cg_buf text = {0};
    if (url) cg_buf_printf(&text, "%s: ", url);
    cg_buf_puts(&text, ureq_kind_text(kind));
    if (message) cg_buf_printf(&text, ": %s", message);
    if (source) cg_buf_printf(&text, ": %s", source);
    char *display = cg_buf_take(&text);
    cg_net_error_kind net_kind = CG_NET_NETWORK;
    if (kind == UREQ_INVALID_URL || kind == UREQ_UNKNOWN_SCHEME) {
        net_kind = CG_NET_INVALID_URL;
    } else if (kind == UREQ_IO || kind == UREQ_CONNECTION_FAILED) {
        char *lower = cg_lower(display);
        if (strstr(lower, "timed out") || strstr(lower, "timeout")) net_kind = CG_NET_TIMEOUT;
        else if (strstr(lower, "certificate") || strstr(lower, "tls")) net_kind = CG_NET_TLS;
        free(lower);
    }
    return cg_net_error_set_own(err, net_kind, display);
}

/* An io::Error surfaced by ureq (ErrorKind::Io, the error as source). */
static bool io_transport_fail(cg_net_error *err, const char *url, const net_io_error *io) {
    return transport_fail(err, UREQ_IO, url, NULL, io->message ? io->message : "");
}

/* net.rs classify_io (body reads). */
static bool io_fail(cg_net_error *err, const net_io_error *io) {
    const char *message = io->message ? io->message : "";
    cg_net_error_kind kind = CG_NET_NETWORK;
    if (io->kind == NET_IO_TIMED_OUT || io->kind == NET_IO_WOULD_BLOCK) kind = CG_NET_TIMEOUT;
    else if (lower_contains(message, "timed out") || lower_contains(message, "timeout")) kind = CG_NET_TIMEOUT;
    else if (lower_contains(message, "certificate") || lower_contains(message, "tls") ||
             lower_contains(message, "handshake"))
        kind = CG_NET_TLS;
    return cg_net_error_set(err, kind, "%s", message);
}

/* ======================================================================================
 * client
 * ==================================================================================== */

typedef struct net_conn {
    int fd;
    net_tls *tls;
    uint8_t *buf; /* read-ahead (ureq BufReader) */
    size_t pos, len;
    char *pool_key; /* set for direct connections: may go back to the idle pool */
} net_conn;

typedef struct {
    char *host;
    bool permitted;
} cleartext_entry;

struct cg_http {
    const cg_host *host;
    cg_mutex lock; /* everything below */
    char *user_agent;
    uint64_t timeout_ms;
    atomic_bool allow_downgrade;
    /* HTTP proxy from the environment (ureq try_proxy_from_env), read when the agents are built. */
    char *env_proxy_host; /* NULL: none */
    uint16_t env_proxy_port;
    char *env_proxy_auth; /* "user:password" or NULL */
    cleartext_entry *cleartext;
    size_t cleartext_len, cleartext_cap;
    /* Host proxies already announced in the log (Rust: proxied agents cache). */
    cg_strs proxies_seen;
    net_conn **pool; /* idle connections, oldest first */
    size_t pool_len, pool_cap;
};

static void conn_close(net_conn *conn) {
    if (!conn) return;
    net_tls_free(conn->tls);
    if (conn->fd >= 0) close(conn->fd);
    free(conn->buf);
    free(conn->pool_key);
    free(conn);
}

/* Proxy::new for an environment value; false when unusable (or not an HTTP proxy). */
static bool parse_env_proxy(const char *value, char **host, uint16_t *port, char **auth) {
    char *proxy = cg_strdup(value);
    size_t len = strlen(proxy);
    while (len > 0 && proxy[len - 1] == '/') proxy[--len] = 0;
    char *rest = proxy;
    char *scheme_end = strstr(proxy, "://");
    if (scheme_end) {
        *scheme_end = 0;
        /* socks proxies need ureq's socks-proxy feature, which the Rust build does not have. */
        if (strcmp(proxy, "http") != 0) {
            free(proxy);
            return false;
        }
        rest = scheme_end + 3;
    }
    char *credentials = NULL;
    char *at = strrchr(rest, '@');
    if (at) {
        *at = 0;
        credentials = rest;
        rest = at + 1;
        if (!strchr(credentials, ':')) {
            free(proxy);
            return false;
        }
    }
    char *colon = strchr(rest, ':');
    unsigned long parsed_port = 80;
    if (colon) {
        *colon = 0;
        char *port_text = colon + 1;
        char *next = strchr(port_text, ':');
        if (next) *next = 0;
        uint64_t number;
        if (cg_parse_u64(port_text, &number) && number <= UINT32_MAX) parsed_port = (unsigned long)number;
    }
    if (parsed_port > 65535) {
        free(proxy);
        return false;
    }
    *host = cg_strdup(rest);
    *port = (uint16_t)parsed_port;
    *auth = credentials ? cg_strdup(credentials) : NULL;
    free(proxy);
    return true;
}

/* Caller holds the lock. */
static void load_env_proxy(cg_http *http) {
    free(http->env_proxy_host);
    free(http->env_proxy_auth);
    http->env_proxy_host = http->env_proxy_auth = NULL;
    static const char *const names[] = {"ALL_PROXY", "all_proxy", "HTTPS_PROXY", "https_proxy", "HTTP_PROXY",
                                        "http_proxy"};
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        const char *value = getenv(names[i]);
        if (value && parse_env_proxy(value, &http->env_proxy_host, &http->env_proxy_port, &http->env_proxy_auth))
            return;
    }
}

/* Caller holds the lock; returns the closed connections' list for closing outside of it. */
static net_conn **pool_drain(cg_http *http, size_t *count) {
    net_conn **items = http->pool;
    *count = http->pool_len;
    http->pool = NULL;
    http->pool_len = http->pool_cap = 0;
    return items;
}

static void close_all(net_conn **items, size_t count) {
    for (size_t i = 0; i < count; i++) conn_close(items[i]);
    free(items);
}

cg_http *cg_http_new(const cg_host *host, const char *user_agent, uint64_t timeout_ms) {
    cg_http *http = cg_calloc(1, sizeof *http);
    http->host = host;
    cg_mutex_init(&http->lock);
    http->user_agent = cg_strdup(cg_or_empty(user_agent));
    http->timeout_ms = timeout_ms ? timeout_ms : DEFAULT_TIMEOUT_MS;
    atomic_init(&http->allow_downgrade, false);
    load_env_proxy(http);
    return http;
}

void cg_http_free(cg_http *http) {
    if (!http) return;
    size_t count;
    net_conn **idle = pool_drain(http, &count);
    close_all(idle, count);
    free(http->user_agent);
    free(http->env_proxy_host);
    free(http->env_proxy_auth);
    for (size_t i = 0; i < http->cleartext_len; i++) free(http->cleartext[i].host);
    free(http->cleartext);
    cg_strs_free(&http->proxies_seen);
    cg_mutex_destroy(&http->lock);
    free(http);
}

void cg_http_set_user_agent(cg_http *http, const char *user_agent) {
    cg_lock(&http->lock);
    cg_replace(&http->user_agent, cg_strdup(cg_or_empty(user_agent)));
    cg_unlock(&http->lock);
}

char *cg_http_get_user_agent(cg_http *http) {
    cg_lock(&http->lock);
    char *user_agent = cg_strdup(http->user_agent);
    cg_unlock(&http->lock);
    return user_agent;
}

void cg_http_set_timeout(cg_http *http, uint64_t timeout_ms) {
    if (timeout_ms == 0) timeout_ms = DEFAULT_TIMEOUT_MS;
    cg_lock(&http->lock);
    if (http->timeout_ms == timeout_ms) {
        cg_unlock(&http->lock);
        return;
    }
    /* Rust rebuilds its agents: new pools, proxy from the environment read again. */
    http->timeout_ms = timeout_ms;
    load_env_proxy(http);
    cg_strs_free(&http->proxies_seen);
    size_t count;
    net_conn **idle = pool_drain(http, &count);
    cg_unlock(&http->lock);
    close_all(idle, count);
}

void cg_http_set_allow_https_to_http_redirect(cg_http *http, bool allow) {
    atomic_store(&http->allow_downgrade, allow);
}

/* ---- idle pool (ureq ConnectionPool) */

static net_conn *pool_take(cg_http *http, const char *key) {
    cg_lock(&http->lock);
    net_conn *found = NULL;
    for (size_t i = http->pool_len; i > 0; i--) {
        if (strcmp(http->pool[i - 1]->pool_key, key) == 0) {
            found = http->pool[i - 1];
            memmove(http->pool + i - 1, http->pool + i, (http->pool_len - i) * sizeof *http->pool);
            http->pool_len--;
            break;
        }
    }
    cg_unlock(&http->lock);
    return found;
}

static void pool_put(cg_http *http, net_conn *conn) {
    net_conn *evicted[2] = {NULL, NULL};
    cg_lock(&http->lock);
    if (http->pool_len == http->pool_cap) {
        http->pool_cap = http->pool_cap ? http->pool_cap * 2 : 8;
        http->pool = cg_realloc(http->pool, http->pool_cap * sizeof *http->pool);
    }
    http->pool[http->pool_len++] = conn;
    size_t same = 0, oldest_same = 0;
    for (size_t i = http->pool_len; i > 0; i--)
        if (strcmp(http->pool[i - 1]->pool_key, conn->pool_key) == 0) {
            same++;
            oldest_same = i - 1;
        }
    if (same > POOL_MAX_IDLE_PER_HOST) {
        evicted[0] = http->pool[oldest_same];
        memmove(http->pool + oldest_same, http->pool + oldest_same + 1,
                (http->pool_len - oldest_same - 1) * sizeof *http->pool);
        http->pool_len--;
    }
    if (http->pool_len > POOL_MAX_IDLE) {
        evicted[1] = http->pool[0];
        memmove(http->pool, http->pool + 1, (http->pool_len - 1) * sizeof *http->pool);
        http->pool_len--;
    }
    cg_unlock(&http->lock);
    conn_close(evicted[0]);
    conn_close(evicted[1]);
}

/* Stream::server_closed: an idle connection that has data or EOF pending was closed (or broken). */
static bool conn_server_closed(net_conn *conn) {
    if (conn->tls && net_tls_buffered(conn->tls)) return true;
    uint8_t byte;
    ssize_t peeked;
    do {
        peeked = recv(conn->fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
    } while (peeked < 0 && errno == EINTR);
    return !(peeked < 0 && (errno == EAGAIN || errno == EWOULDBLOCK));
}

/* ---- cleartext policy */

/* net.rs check_cleartext. */
static bool check_cleartext(cg_http *http, const char *url_text, cg_net_error *err) {
    cg_url url;
    if (cg_url_parse(url_text, NULL, &url) != CG_URL_OK) return true;
    if (!cg_url_scheme_is(&url, "http")) {
        cg_url_clear(&url);
        return true;
    }
    char *raw_host = cg_url_host_str(&url);
    char *host = cg_lower(cg_or_empty(raw_host));
    free(raw_host);
    cg_url_clear(&url);
    int permitted = -1;
    cg_lock(&http->lock);
    for (size_t i = 0; i < http->cleartext_len; i++)
        if (strcmp(http->cleartext[i].host, host) == 0) permitted = http->cleartext[i].permitted;
    cg_unlock(&http->lock);
    if (permitted < 0) {
        /* No answer (no policy hook, hook error): fail closed, as the OS HTTP stacks do. */
        int answer = cg_host_cleartext_permitted(http->host, host);
        if (answer >= 0) {
            cg_lock(&http->lock);
            if (http->cleartext_len == http->cleartext_cap) {
                http->cleartext_cap = http->cleartext_cap ? http->cleartext_cap * 2 : 4;
                http->cleartext = cg_realloc(http->cleartext, http->cleartext_cap * sizeof *http->cleartext);
            }
            http->cleartext[http->cleartext_len].host = cg_strdup(host);
            http->cleartext[http->cleartext_len].permitted = answer == 1;
            http->cleartext_len++;
            cg_unlock(&http->lock);
        }
        permitted = answer == 1;
    }
    if (!permitted) {
        cg_net_error_set(err, CG_NET_INVALID_URL,
                         "Cleartext HTTP traffic to %s is not permitted by the app's network security policy", host);
        free(host);
        return false;
    }
    free(host);
    return true;
}

/* ---- routes: direct, host proxy or environment proxy (net.rs agent_for) */

typedef struct {
    bool download;
    uint64_t timeout_ms;
    bool proxy;      /* through an HTTP proxy */
    bool host_proxy; /* the host's proxy (else the environment's) */
    char *proxy_host;
    uint16_t proxy_port;
    char *proxy_auth;
    char *user_agent;
} net_route;

static void route_clear(net_route *route) {
    free(route->proxy_host);
    free(route->proxy_auth);
    free(route->user_agent);
    memset(route, 0, sizeof *route);
}

static void route_for(cg_http *http, bool download, const char *url, net_route *route) {
    memset(route, 0, sizeof *route);
    route->download = download;
    cg_http_proxy proxy = {0};
    bool found = cg_host_proxy_for_url(http->host, url, &proxy);
    cg_lock(&http->lock);
    route->timeout_ms = http->timeout_ms;
    if (download && route->timeout_ms < DOWNLOAD_MIN_TIMEOUT_MS) route->timeout_ms = DOWNLOAD_MIN_TIMEOUT_MS;
    route->user_agent = cg_strdup(http->user_agent);
    bool announce = false;
    if (found) {
        route->proxy = route->host_proxy = true;
        route->proxy_host = proxy.host;
        route->proxy_port = proxy.port;
        char *key = cg_fmt("%d|%s|%u", download ? 1 : 0, proxy.host, proxy.port);
        if (!cg_strs_contains(&http->proxies_seen, key)) {
            cg_strs_push(&http->proxies_seen, key);
            announce = true;
        } else {
            free(key);
        }
    } else if (http->env_proxy_host) {
        route->proxy = true;
        route->proxy_host = cg_strdup(http->env_proxy_host);
        route->proxy_port = http->env_proxy_port;
        route->proxy_auth = cg_strdup(http->env_proxy_auth);
    }
    cg_unlock(&http->lock);
    if (announce) cg_debug(http->host, "Using system HTTP proxy %s:%u", route->proxy_host, route->proxy_port);
}

/* ======================================================================================
 * connecting
 * ==================================================================================== */

static uint64_t now_ms(void) { return (uint64_t)cg_mono_ms(); }

static void set_socket_timeouts(int fd, uint64_t timeout_ms) {
    struct timeval tv;
    tv.tv_sec = (time_t)(timeout_ms / 1000);
    tv.tv_usec = (suseconds_t)((timeout_ms % 1000) * 1000);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

/* TcpStream::connect_timeout. -1 with *io on failure. */
static int connect_timeout(const struct addrinfo *address, uint64_t timeout_ms, net_io_error *io) {
    int fd = socket(address->ai_family, SOCK_STREAM, 0);
    if (fd < 0) {
        net_io_errno(io, errno);
        return -1;
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int result = connect(fd, address->ai_addr, address->ai_addrlen);
    if (result != 0 && errno != EINPROGRESS && errno != EINTR) {
        net_io_errno(io, errno);
        close(fd);
        return -1;
    }
    if (result != 0) {
        uint64_t deadline = now_ms() + timeout_ms;
        for (;;) {
            uint64_t now = now_ms();
            if (now >= deadline) {
                net_io_set(io, NET_IO_TIMED_OUT, "connection timed out");
                close(fd);
                return -1;
            }
            uint64_t wait = deadline - now;
            struct pollfd poll_fd = {.fd = fd, .events = POLLOUT};
            int ready = poll(&poll_fd, 1, wait > INT32_MAX ? INT32_MAX : (int)wait);
            if (ready < 0) {
                if (errno == EINTR) continue;
                net_io_errno(io, errno);
                close(fd);
                return -1;
            }
            if (ready == 0) continue;
            int error = 0;
            socklen_t len = sizeof error;
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len) != 0) error = errno;
            if (error != 0) {
                net_io_errno(io, error);
                close(fd);
                return -1;
            }
            if (poll_fd.revents & (POLLHUP | POLLERR)) {
                net_io_set(io, NET_IO_OTHER, "no error set after POLLHUP");
                close(fd);
                return -1;
            }
            break;
        }
    }
    fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
    return fd;
}

/* std to_socket_addrs (getaddrinfo, any family, stream sockets). NULL with *error. */
static struct addrinfo *resolve(const char *name, uint16_t port, char **error) {
    struct addrinfo hints = {0}, *result = NULL;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char service[8];
    snprintf(service, sizeof service, "%u", port);
    int status = getaddrinfo(name, service, &hints, &result);
    if (status != 0) {
        if (status == EAI_SYSTEM) *error = cg_io_message(errno);
        else *error = cg_fmt("failed to lookup address information: %s", gai_strerror(status));
        return NULL;
    }
    return result;
}

/* ---- responses (ureq Response) */

typedef struct {
    char *name;
    char *value; /* trimmed */
    bool valid;  /* ureq Header::value() is Some: UTF-8, visible ASCII, spaces and tabs only */
} raw_header;

typedef enum { BODY_LENGTH, BODY_CHUNKED, BODY_CLOSE } body_type;

typedef struct {
    cg_http *http;
    net_conn *conn; /* NULL once the body is done (connection pooled or closed) */
    uint16_t status;
    raw_header *headers;
    size_t header_count, header_cap;
    body_type body;
    uint64_t remaining;  /* BODY_LENGTH */
    bool chunk_open;     /* BODY_CHUNKED: inside a chunk */
    uint64_t chunk_left; /* BODY_CHUNKED */
    bool finished;
    bool keep_alive;
} net_response;

static bool read_head(net_conn *conn, const char *method, const char *url_text, net_response *response,
                      net_io_error *io, cg_net_error *err);
static void response_free(net_response *response);
static void base64_put(cg_buf *out, const char *text);

/* ureq connect_host: socket to the target or the proxy, timeouts, CONNECT tunnel for HTTPS. */
static int connect_host(cg_http *http, const net_route *route, bool https, const char *url_text,
                        const char *hostname, uint16_t port, cg_net_error *err) {
    char *netloc;
    char *name;
    uint16_t connect_port;
    if (route->proxy) {
        netloc = cg_fmt("%s:%u", route->host_proxy ? PROXY_PLACEHOLDER : route->proxy_host, route->proxy_port);
        name = cg_strdup(route->proxy_host);
        connect_port = route->proxy_port;
    } else {
        netloc = cg_fmt("%s:%u", hostname, port);
        /* IPv6 literals resolve without their brackets. */
        size_t len = strlen(hostname);
        if (len >= 2 && hostname[0] == '[' && hostname[len - 1] == ']') name = cg_strndup(hostname + 1, len - 2);
        else name = cg_strdup(hostname);
        connect_port = port;
    }
    char *detail = NULL;
    struct addrinfo *addresses = resolve(name, connect_port, &detail);
    free(name);
    if (!addresses) {
        char *message = cg_fmt("resolve dns name '%s'", netloc);
        transport_fail(err, UREQ_DNS, url_text, message, detail);
        free(message);
        free(detail);
        free(netloc);
        return -1;
    }
    free(netloc);
    bool multiple = addresses->ai_next != NULL;
    uint64_t deadline = now_ms() + route->timeout_ms;
    net_io_error io = {0};
    int fd = -1;
    for (struct addrinfo *address = addresses; address; address = address->ai_next) {
        uint64_t now = now_ms();
        if (now >= deadline) {
            net_io_set(&io, NET_IO_TIMED_OUT, "timed out reading response");
            freeaddrinfo(addresses);
            io_transport_fail(err, url_text, &io);
            net_io_clear(&io);
            return -1;
        }
        uint64_t timeout = deadline - now;
        if (multiple) timeout /= 2;
        if (timeout == 0) timeout = 1;
        fd = connect_timeout(address, timeout, &io);
        if (fd >= 0) break;
    }
    freeaddrinfo(addresses);
    if (fd < 0) {
        transport_fail(err, UREQ_CONNECTION_FAILED, url_text, "Connect error", io.message ? io.message : "");
        net_io_clear(&io);
        return -1;
    }
    net_io_clear(&io);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    set_socket_timeouts(fd, route->timeout_ms);
    if (route->proxy && https) {
        cg_buf connect_request = {0};
        cg_buf_printf(&connect_request,
                      "CONNECT %s:%u HTTP/1.1\r\nHost: %s:%u\r\nUser-Agent: " UREQ_USER_AGENT
                      "\r\nProxy-Connection: Keep-Alive\r\n",
                      hostname, port, hostname, port);
        if (route->proxy_auth) {
            cg_buf_puts(&connect_request, "Proxy-Authorization: basic ");
            base64_put(&connect_request, route->proxy_auth);
            cg_buf_puts(&connect_request, "\r\n");
        }
        cg_buf_puts(&connect_request, "\r\n");
        bool sent = net_sock_send_all(fd, (const uint8_t *)connect_request.data, connect_request.len, &io);
        cg_buf_free(&connect_request);
        if (!sent) {
            io_transport_fail(err, url_text, &io);
            net_io_clear(&io);
            close(fd);
            return -1;
        }
        /* ureq reads the answer through its own buffer: bytes after the head are dropped. */
        net_conn tunnel = {.fd = fd, .buf = cg_malloc(CONN_BUFFER)};
        net_response response = {0};
        bool ok = read_head(&tunnel, "GET", url_text, &response, &io, err);
        free(tunnel.buf);
        net_io_clear(&io);
        uint16_t status = response.status;
        response_free(&response);
        if (!ok) {
            close(fd);
            return -1;
        }
        if (status != 200) {
            transport_fail(err, (status == 401 || status == 407) ? UREQ_PROXY_UNAUTHORIZED : UREQ_PROXY_CONNECT,
                           url_text, NULL, NULL);
            close(fd);
            return -1;
        }
    }
    return fd;
}

/* ======================================================================================
 * reading (ureq DeadlineStream over a BufReader)
 * ==================================================================================== */

/* Raw read; a socket read timeout becomes ureq's "timed out reading response". */
static long conn_read_raw(net_conn *conn, uint8_t *buffer, size_t len, net_io_error *io) {
    long read = conn->tls ? net_tls_read(conn->tls, buffer, len, io) : net_sock_recv(conn->fd, buffer, len, io);
    if (read < 0 && io->kind == NET_IO_WOULD_BLOCK) net_io_set(io, NET_IO_TIMED_OUT, "timed out reading response");
    return read;
}

/* Buffered read: bytes, 0 at EOF, -1 on error. Large reads bypass the buffer. */
static long conn_read(net_conn *conn, uint8_t *buffer, size_t len, net_io_error *io) {
    if (conn->pos == conn->len) {
        if (len >= CONN_BUFFER) return conn_read_raw(conn, buffer, len, io);
        long read = conn_read_raw(conn, conn->buf, CONN_BUFFER, io);
        if (read <= 0) return read;
        conn->pos = 0;
        conn->len = (size_t)read;
    }
    size_t available = conn->len - conn->pos;
    size_t n = available < len ? available : len;
    memcpy(buffer, conn->buf + conn->pos, n);
    conn->pos += n;
    return (long)n;
}

/* More data can be read without waiting on the socket. */
static bool conn_buffered(net_conn *conn) {
    return conn->pos < conn->len || (conn->tls && net_tls_buffered(conn->tls));
}

/* One byte: 0..255, -1 at EOF, -2 on error. */
static int conn_byte(net_conn *conn, net_io_error *io) {
    uint8_t byte;
    long read = conn_read(conn, &byte, 1, io);
    if (read < 0) return -2;
    if (read == 0) return -1;
    return byte;
}

/* ureq read_next_line: a header line without its line end. */
static bool read_line(net_conn *conn, const char *context, cg_buf *line, net_io_error *io) {
    line->len = 0;
    if (line->data) line->data[0] = 0;
    size_t total = 0;
    bool newline = false;
    while (!newline && total < MAX_HEADER_SIZE + 1) {
        if (conn->pos == conn->len) {
            long read = conn_read_raw(conn, conn->buf, CONN_BUFFER, io);
            if (read < 0) {
                char *inner = io->message;
                io->message = cg_fmt("Network Error: Error encountered in %s: %s", context, inner ? inner : "");
                free(inner);
                return false;
            }
            if (read == 0) break;
            conn->pos = 0;
            conn->len = (size_t)read;
        }
        size_t available = conn->len - conn->pos;
        size_t limit = MAX_HEADER_SIZE + 1 - total;
        size_t n = available < limit ? available : limit;
        uint8_t *start = conn->buf + conn->pos;
        uint8_t *end = memchr(start, '\n', n);
        if (end) {
            n = (size_t)(end - start) + 1;
            newline = true;
        }
        cg_buf_put(line, start, n);
        conn->pos += n;
        total += n;
    }
    if (total == 0) return net_io_set(io, NET_IO_CONNECTION_ABORTED, "Unexpected EOF");
    if (total > MAX_HEADER_SIZE)
        return net_io_set(io, NET_IO_OTHER, "header field longer than %d bytes", MAX_HEADER_SIZE);
    if (!newline) {
        cg_buf text = {0};
        cg_buf_puts(&text, "Header field didn't end with \\n: [");
        for (size_t i = 0; i < line->len; i++) cg_buf_printf(&text, "%s%u", i ? ", " : "", (uint8_t)line->data[i]);
        cg_buf_putc(&text, ']');
        io->kind = NET_IO_INVALID_INPUT;
        cg_replace(&io->message, cg_buf_take(&text));
        return false;
    }
    line->len--;
    if (line->len > 0 && line->data[line->len - 1] == '\r') line->len--;
    line->data[line->len] = 0;
    return true;
}

static bool is_tchar(uint8_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
           (c && strchr("!#$%&'*+-.^_`|~", c));
}

static bool is_field_char(uint8_t c) { return c == ' ' || c == '\t' || (c >= 0x21 && c <= 0x7E); }

/* ureq get_header: the first header with that name, if its value is valid. */
static const char *response_header(const net_response *response, const char *name) {
    for (size_t i = 0; i < response->header_count; i++)
        if (strcasecmp(response->headers[i].name, name) == 0)
            return response->headers[i].valid ? response->headers[i].value : NULL;
    return NULL;
}

static void response_add_header(net_response *response, const char *line, size_t len) {
    size_t index = 0;
    while (index < len && line[index] != ':') {
        if (!is_tchar((uint8_t)line[index])) return; /* ureq skips invalid header lines */
        index++;
    }
    if (index == len) return;
    if (response->header_count == response->header_cap) {
        response->header_cap = response->header_cap ? response->header_cap * 2 : 16;
        response->headers = cg_realloc(response->headers, response->header_cap * sizeof *response->headers);
    }
    raw_header *header = &response->headers[response->header_count++];
    header->name = cg_strndup(line, index);
    const char *raw = line + index + 1;
    size_t raw_len = len - index - 1;
    char *copy = cg_strndup(raw, raw_len);
    header->value = cg_trim(copy);
    free(copy);
    header->valid = cg_utf8_valid(raw, raw_len) && memchr(raw, 0, raw_len) == NULL;
    for (const char *c = header->value; header->valid && *c; c++)
        if (!is_field_char((uint8_t)*c)) header->valid = false;
}

static void response_free(net_response *response) {
    conn_close(response->conn);
    for (size_t i = 0; i < response->header_count; i++) {
        free(response->headers[i].name);
        free(response->headers[i].value);
    }
    free(response->headers);
    memset(response, 0, sizeof *response);
}

/* ureq parse_status_line; NULL or the error text (in `scratch`). */
static const char *parse_status_line(const char *line, uint16_t *status, bool *http10, char *scratch,
                                     size_t scratch_len) {
    for (const char *c = line; *c; c++)
        if ((uint8_t)*c >= 0x80) return "Status line not ASCII";
    const char *first = strchr(line, ' ');
    if (!first) return "Wrong number of tokens in status line";
    const char *second = strchr(first + 1, ' ');
    size_t version_len = (size_t)(first - line);
    size_t code_len = second ? (size_t)(second - first - 1) : strlen(first + 1);
    if (version_len < 5 || strncmp(line, "HTTP/", 5) != 0) return "HTTP version did not start with HTTP/";
    if (version_len != 8) return "HTTP version was wrong length";
    if (line[5] < '0' || line[5] > '9' || line[7] < '0' || line[7] > '9') return "HTTP version did not match format";
    if (code_len != 3) return "Status code was wrong length";
    const char *code = first + 1;
    const char *digits = code[0] == '+' ? code + 1 : code;
    size_t digit_count = (size_t)(code + 3 - digits);
    unsigned value = 0;
    bool valid = digit_count > 0;
    for (size_t i = 0; valid && i < digit_count; i++) {
        if (digits[i] < '0' || digits[i] > '9') valid = false;
        else value = value * 10 + (unsigned)(digits[i] - '0');
    }
    if (!valid) {
        snprintf(scratch, scratch_len, "unable to parse status as u16 (%.3s)", code);
        return scratch;
    }
    *status = (uint16_t)value;
    *http10 = strncasecmp(line, "HTTP/1.0", 8) == 0;
    return NULL;
}

/* Response::do_from_stream: status line and headers, body framing. On failure *err is the ureq
 * error and *io the underlying io error, when there is one (retry decisions). */
static bool read_head(net_conn *conn, const char *method, const char *url_text, net_response *response,
                      net_io_error *io, cg_net_error *err) {
    cg_buf line = {0};
    if (!read_line(conn, "the status line", &line, io)) {
        io_transport_fail(err, url_text, io);
        cg_buf_free(&line);
        return false;
    }
    char *status_line = cg_utf8_lossy((const uint8_t *)line.data, line.len);
    bool http10 = false;
    char scratch[64];
    const char *bad = parse_status_line(status_line, &response->status, &http10, scratch, sizeof scratch);
    free(status_line);
    if (bad) {
        transport_fail(err, UREQ_BAD_STATUS, url_text, bad, NULL);
        cg_buf_free(&line);
        return false;
    }
    while (response->header_count <= MAX_HEADER_COUNT) {
        if (!read_line(conn, "a header", &line, io)) {
            io_transport_fail(err, url_text, io);
            cg_buf_free(&line);
            return false;
        }
        if (line.len == 0) break;
        response_add_header(response, line.data, line.len);
    }
    cg_buf_free(&line);
    if (response->header_count > MAX_HEADER_COUNT) {
        char message[64];
        snprintf(message, sizeof message, "more than %d header fields in response", MAX_HEADER_COUNT);
        return transport_fail(err, UREQ_BAD_HEADER, url_text, message, NULL);
    }
    const char *connection = response_header(response, "connection");
    if (http10) response->keep_alive = connection && strcasecmp(connection, "keep-alive") == 0;
    else response->keep_alive = !(connection && strcasecmp(connection, "close") == 0);
    bool no_body = strcasecmp(method, "HEAD") == 0 || response->status == 204 || response->status == 304;
    const char *transfer_encoding = response_header(response, "transfer-encoding");
    uint64_t length;
    if (no_body) {
        response->body = BODY_LENGTH;
        response->remaining = 0;
    } else if (!http10 && transfer_encoding && *transfer_encoding) {
        response->body = BODY_CHUNKED;
    } else if (cg_parse_u64(response_header(response, "content-length"), &length)) {
        response->body = BODY_LENGTH;
        response->remaining = length;
    } else {
        response->body = BODY_CLOSE;
    }
    return true;
}

/* The body is complete: the connection goes back to the pool (keep-alive) or is closed. */
static void response_done(net_response *response) {
    response->finished = true;
    net_conn *conn = response->conn;
    response->conn = NULL;
    if (!conn) return;
    if (response->keep_alive && conn->pool_key && response->http) pool_put(response->http, conn);
    else conn_close(conn);
}

static long chunk_error(net_io_error *io) {
    net_io_set(io, NET_IO_INVALID_INPUT, "Error while decoding chunks");
    return -1;
}

/* ureq chunked Decoder. */
static long read_chunked(net_response *response, uint8_t *buffer, size_t len, net_io_error *io) {
    net_conn *conn = response->conn;
    if (!response->chunk_open) {
        cg_buf size_text = {0};
        bool extension = false;
        for (;;) {
            int byte = conn_byte(conn, io);
            if (byte < 0) {
                cg_buf_free(&size_text);
                return byte == -2 ? -1 : chunk_error(io);
            }
            if (byte == '\r') break;
            if (byte == ';') {
                extension = true;
                break;
            }
            cg_buf_putc(&size_text, (char)byte);
        }
        if (extension) {
            for (;;) {
                int byte = conn_byte(conn, io);
                if (byte < 0) {
                    cg_buf_free(&size_text);
                    return byte == -2 ? -1 : chunk_error(io);
                }
                if (byte == '\r') break;
            }
        }
        net_io_error ignored = {0};
        int line_feed = conn_byte(conn, &ignored);
        net_io_clear(&ignored);
        bool utf8 = cg_utf8_valid(size_text.data ? size_text.data : "", size_text.len);
        char *trimmed = cg_trim(size_text.data ? size_text.data : "");
        cg_buf_free(&size_text);
        const char *digits = trimmed[0] == '+' ? trimmed + 1 : trimmed;
        bool valid = utf8 && *digits && line_feed == '\n';
        uint64_t size = 0;
        for (const char *c = digits; valid && *c; c++) {
            int digit = (*c >= '0' && *c <= '9')   ? *c - '0'
                        : (*c >= 'a' && *c <= 'f') ? *c - 'a' + 10
                        : (*c >= 'A' && *c <= 'F') ? *c - 'A' + 10
                                                   : -1;
            if (digit < 0 || size > (UINT64_MAX >> 4)) valid = false;
            else size = size * 16 + (uint64_t)digit;
        }
        free(trimmed);
        if (!valid) return chunk_error(io);
        if (size == 0) {
            /* read_end: "\r\n", or the end of the stream. */
            for (int i = 0; i < 2; i++) {
                net_io_error end_error = {0};
                int byte = conn_byte(conn, &end_error);
                bool closed = byte == -2 && (end_error.kind == NET_IO_CONNECTION_RESET ||
                                             end_error.kind == NET_IO_CONNECTION_ABORTED);
                bool failed = byte == -2 && !closed;
                net_io_clear(&end_error);
                if (failed) return chunk_error(io);
                if (byte == -1 || closed) break;
                if (byte != (i == 0 ? '\r' : '\n')) return chunk_error(io);
            }
            response_done(response);
            return 0;
        }
        response->chunk_open = true;
        response->chunk_left = size;
    }
    size_t want = len < response->chunk_left ? len : (size_t)response->chunk_left;
    long read = conn_read(conn, buffer, want, io);
    if (read < 0) return -1;
    /* ureq: a stream ending inside a chunk reads as the end of the body. */
    if (read == 0) {
        response->finished = true;
        conn_close(response->conn);
        response->conn = NULL;
        return 0;
    }
    response->chunk_left -= (uint64_t)read;
    if (response->chunk_left == 0) {
        net_io_error ignored = {0};
        int cr = conn_byte(conn, &ignored);
        int lf = cr == '\r' ? conn_byte(conn, &ignored) : -1;
        net_io_clear(&ignored);
        if (cr != '\r' || lf != '\n') return chunk_error(io);
        response->chunk_open = false;
    }
    return read;
}

/* Body read: bytes, 0 at the end, -1 with *io. */
static long response_read(net_response *response, uint8_t *buffer, size_t len, net_io_error *io) {
    if (response->finished || !response->conn || len == 0) return 0;
    switch (response->body) {
    case BODY_LENGTH: {
        if (response->remaining == 0) {
            response_done(response);
            return 0;
        }
        size_t want = len < response->remaining ? len : (size_t)response->remaining;
        long read = conn_read(response->conn, buffer, want, io);
        if (read < 0) return -1;
        if (read == 0) {
            net_io_set(io, NET_IO_UNEXPECTED_EOF, "response body closed before all bytes were read");
            return -1;
        }
        response->remaining -= (uint64_t)read;
        if (response->remaining == 0) response_done(response);
        return read;
    }
    case BODY_CHUNKED:
        return read_chunked(response, buffer, len, io);
    case BODY_CLOSE: {
        long read = conn_read(response->conn, buffer, len, io);
        if (read == 0) response_done(response);
        return read;
    }
    }
    return 0;
}

/* ======================================================================================
 * requests (ureq Request::call / send_bytes, one hop)
 * ==================================================================================== */

typedef struct {
    char *name;
    char *value;
} req_header;

typedef struct {
    req_header *items;
    size_t len, cap;
} req_headers;

static void headers_free(req_headers *headers) {
    for (size_t i = 0; i < headers->len; i++) {
        free(headers->items[i].name);
        free(headers->items[i].value);
    }
    free(headers->items);
    memset(headers, 0, sizeof *headers);
}

static void headers_push(req_headers *headers, const char *name, const char *value) {
    if (headers->len == headers->cap) {
        headers->cap = headers->cap ? headers->cap * 2 : 8;
        headers->items = cg_realloc(headers->items, headers->cap * sizeof *headers->items);
    }
    headers->items[headers->len].name = cg_strdup(name);
    headers->items[headers->len].value = cg_strdup(value);
    headers->len++;
}

/* Request::set (header::add_header): replaces headers of the exact same name, except x-*. */
static void headers_set(req_headers *headers, const char *name, const char *value) {
    if (strncmp(name, "x-", 2) != 0 && strncmp(name, "X-", 2) != 0) {
        size_t kept = 0;
        for (size_t i = 0; i < headers->len; i++) {
            if (strcmp(headers->items[i].name, name) == 0) {
                free(headers->items[i].name);
                free(headers->items[i].value);
            } else {
                headers->items[kept++] = headers->items[i];
            }
        }
        headers->len = kept;
    }
    headers_push(headers, name, value);
}

/* has_header: the first header of that name has a valid value. */
static bool headers_has(const req_headers *headers, const char *name) {
    for (size_t i = 0; i < headers->len; i++)
        if (strcasecmp(headers->items[i].name, name) == 0) {
            for (const char *c = headers->items[i].value; *c; c++)
                if (!is_field_char((uint8_t)*c)) return false;
            return true;
        }
    return false;
}

static bool header_valid(const req_header *header) {
    if (!*header->name) return false;
    for (const char *c = header->name; *c; c++)
        if (!is_tchar((uint8_t)*c)) return false;
    for (const char *c = header->value; *c; c++)
        if (!is_field_char((uint8_t)*c)) return false;
    return true;
}

static void base64_put(cg_buf *out, const char *text) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *in = (const unsigned char *)text;
    size_t len = strlen(text);
    for (size_t i = 0; i < len; i += 3) {
        uint32_t chunk = (uint32_t)in[i] << 16 | (i + 1 < len ? (uint32_t)in[i + 1] << 8 : 0) |
                         (i + 2 < len ? in[i + 2] : 0);
        cg_buf_putc(out, alphabet[(chunk >> 18) & 63]);
        cg_buf_putc(out, alphabet[(chunk >> 12) & 63]);
        cg_buf_putc(out, i + 1 < len ? alphabet[(chunk >> 6) & 63] : '=');
        cg_buf_putc(out, i + 2 < len ? alphabet[chunk & 63] : '=');
    }
}

static bool idempotent(const char *method) {
    static const char *const methods[] = {"DELETE", "GET", "HEAD", "OPTIONS", "PUT", "TRACE"};
    for (size_t i = 0; i < sizeof methods / sizeof *methods; i++)
        if (strcmp(method, methods[i]) == 0) return true;
    return false;
}

static bool conn_write(net_conn *conn, const uint8_t *data, size_t len, net_io_error *io) {
    return conn->tls ? net_tls_write_all(conn->tls, data, len, io) : net_sock_send_all(conn->fd, data, len, io);
}

/* A new connection (ureq connect_http / connect_https). */
static net_conn *open_connection(cg_http *http, const net_route *route, bool https, const char *url_text,
                                 const char *hostname, uint16_t port, const char *pool_key, cg_net_error *err) {
    int fd = connect_host(http, route, https, url_text, hostname, port, err);
    if (fd < 0) return NULL;
    net_conn *conn = cg_calloc(1, sizeof *conn);
    conn->fd = fd;
    conn->buf = cg_malloc(CONN_BUFFER);
    if (https) {
        net_io_error io = {0};
        conn->tls = net_tls_connect(fd, http->host, hostname, &io);
        if (!conn->tls) {
            io_transport_fail(err, url_text, &io);
            net_io_clear(&io);
            conn_close(conn);
            return NULL;
        }
    }
    conn->pool_key = cg_strdup(pool_key);
    return conn;
}

/* One request without redirects. On success *response holds the head and the connection. */
static bool request_once(cg_http *http, const net_route *route, const char *method, const char *url_text,
                         const cg_net_header *extra, size_t extra_count, const uint8_t *body, size_t body_len,
                         net_response *response, cg_net_error *err) {
    /* Request::set: the client's User-Agent, then the caller's headers. */
    req_headers headers = {0};
    headers_set(&headers, "User-Agent", route->user_agent);
    for (size_t i = 0; i < extra_count; i++) headers_set(&headers, extra[i].name, extra[i].value);
    for (size_t i = 0; i < headers.len; i++) {
        if (!header_valid(&headers.items[i])) {
            char *line = cg_fmt("invalid header '%s: %s'", headers.items[i].name, headers.items[i].value);
            transport_fail(err, UREQ_BAD_HEADER, NULL, line, NULL);
            free(line);
            headers_free(&headers);
            return false;
        }
    }
    cg_url url;
    cg_url_error parse_error = cg_url_parse(url_text, NULL, &url);
    if (parse_error == CG_URL_OK && url.host == CG_URL_HOST_NONE) {
        cg_url_clear(&url);
        parse_error = CG_URL_EMPTY_HOST;
    }
    if (parse_error != CG_URL_OK) {
        char *message = cg_fmt("failed to parse URL: %s", cg_url_error_name(parse_error));
        transport_fail(err, UREQ_INVALID_URL, NULL, message, cg_url_error_text(parse_error));
        free(message);
        headers_free(&headers);
        return false;
    }
    const char *shown_url = url.serialization;
    /* Unit::new: Content-Length for a sized body, Basic auth from the URL userinfo. */
    if (body && !headers_has(&headers, "content-length") && !headers_has(&headers, "transfer-encoding")) {
        char length[32];
        snprintf(length, sizeof length, "%zu", body_len);
        headers_push(&headers, "Content-Length", length);
    }
    char *username = cg_url_username(&url);
    char *password = cg_url_password(&url);
    if ((*username || (password && *password)) && !headers_has(&headers, "authorization")) {
        char *credentials = cg_fmt("%s:%s", username, password ? password : "");
        cg_buf value = {0};
        cg_buf_puts(&value, "Basic ");
        base64_put(&value, credentials);
        headers_push(&headers, "Authorization", value.data);
        cg_buf_free(&value);
        free(credentials);
    }
    free(username);
    free(password);
    bool https = cg_url_scheme_is(&url, "https");
    if (!https && !cg_url_scheme_is(&url, "http")) {
        char *scheme = cg_url_scheme(&url);
        char *message = cg_fmt("unknown scheme '%s'", scheme);
        transport_fail(err, UREQ_UNKNOWN_SCHEME, shown_url, message, NULL);
        free(message);
        free(scheme);
        cg_url_clear(&url);
        headers_free(&headers);
        return false;
    }
    char *hostname = cg_url_host_str(&url);
    uint16_t port = (uint16_t)cg_url_port_or_default(&url);
    /* send_prelude */
    char *path = cg_url_path(&url);
    char *query = cg_url_query(&url);
    cg_buf prelude = {0};
    cg_buf_printf(&prelude, "%s ", method);
    if (route->proxy) {
        /* HTTP proxies take the absolute form (CONNECT tunnels too, as ureq does). */
        cg_buf_printf(&prelude, "%s://%s", https ? "https" : "http", hostname);
        if (url.port >= 0) cg_buf_printf(&prelude, ":%d", url.port);
    }
    cg_buf_puts(&prelude, path);
    if (query && *query) cg_buf_printf(&prelude, "?%s", query);
    cg_buf_puts(&prelude, " HTTP/1.1\r\n");
    if (!headers_has(&headers, "host")) {
        if (url.port >= 0) cg_buf_printf(&prelude, "Host: %s:%d\r\n", hostname, url.port);
        else cg_buf_printf(&prelude, "Host: %s\r\n", hostname);
    }
    if (!headers_has(&headers, "user-agent")) cg_buf_puts(&prelude, "User-Agent: " UREQ_USER_AGENT "\r\n");
    if (!headers_has(&headers, "accept")) cg_buf_puts(&prelude, "Accept: */*\r\n");
    for (size_t i = 0; i < headers.len; i++) {
        char *value = cg_trim(headers.items[i].value);
        cg_buf_printf(&prelude, "%s: %s\r\n", headers.items[i].name, value);
        free(value);
    }
    cg_buf_puts(&prelude, "\r\n");
    free(path);
    free(query);
    headers_free(&headers);

    /* ureq pools direct connections only (its proxied pool keys never match). */
    char *pool_key = route->proxy ? NULL
                                  : cg_fmt("%d|%s|%s|%u", route->download ? 1 : 0, https ? "https" : "http",
                                           hostname, port);
    bool retryable = idempotent(method) && (!body || body_len == 0);
    bool use_pooled = pool_key != NULL;
    bool ok = false;
    for (;;) {
        net_conn *conn = NULL;
        bool recycled = false;
        while (use_pooled && (conn = pool_take(http, pool_key))) {
            if (!conn_server_closed(conn)) {
                recycled = true;
                break;
            }
            conn_close(conn);
            conn = NULL;
        }
        if (!conn) conn = open_connection(http, route, https, shown_url, hostname, port, pool_key, err);
        if (!conn) break;
        set_socket_timeouts(conn->fd, route->timeout_ms);
        net_io_error io = {0};
        bool sent = conn_write(conn, (const uint8_t *)prelude.data, prelude.len, &io);
        if (!sent && recycled) {
            /* The server closed the idle connection: once more on a new one. */
            net_io_clear(&io);
            conn_close(conn);
            use_pooled = false;
            continue;
        }
        if (sent && body && body_len > 0) sent = conn_write(conn, body, body_len, &io);
        if (!sent) {
            io_transport_fail(err, shown_url, &io);
            net_io_clear(&io);
            conn_close(conn);
            break;
        }
        memset(response, 0, sizeof *response);
        if (!read_head(conn, method, shown_url, response, &io, err)) {
            bool closed =
                io.message && (io.kind == NET_IO_CONNECTION_ABORTED || io.kind == NET_IO_CONNECTION_RESET);
            net_io_clear(&io);
            response_free(response);
            conn_close(conn);
            if (closed && retryable && recycled) {
                cg_net_error_clear(err);
                use_pooled = false;
                continue;
            }
            break;
        }
        net_io_clear(&io);
        response->http = http;
        response->conn = conn;
        if (response->body == BODY_LENGTH && response->remaining == 0) response_done(response);
        ok = true;
        break;
    }
    free(pool_key);
    free(hostname);
    cg_buf_free(&prelude);
    cg_url_clear(&url);
    return ok;
}

/* net.rs execute: up to 5 redirects; HTTPS -> HTTP refused unless allowed. */
static bool execute(cg_http *http, bool download, const char *method_in, const char *url,
                    const cg_net_header *headers, size_t header_count, const uint8_t *body_in, size_t body_len,
                    net_response *response, cg_net_error *err) {
    cg_release_method_lane();
    char *current = cg_strdup(url);
    char *method = cg_strdup(method_in);
    const uint8_t *body = body_in;
    bool ok = false;
    for (int hop = 0; hop <= CG_NET_MAX_REDIRECTS; hop++) {
        if (!check_cleartext(http, current, err)) goto done;
        net_route route;
        route_for(http, download, current, &route);
        bool sent = request_once(http, &route, method, current, headers, header_count, body, body_len, response, err);
        route_clear(&route);
        if (!sent) goto done;
        uint16_t status = response->status;
        if (status < 300 || status >= 400 || status == 304) {
            ok = true;
            goto done;
        }
        const char *location = response_header(response, "Location");
        if (!location) {
            ok = true;
            goto done;
        }
        cg_url base, next;
        cg_url_error error = cg_url_parse(current, NULL, &base);
        if (error == CG_URL_OK) {
            error = cg_url_parse(location, &base, &next);
            if (error != CG_URL_OK) cg_url_clear(&base);
        }
        if (error != CG_URL_OK) {
            cg_net_error_set(err, CG_NET_INVALID_URL, "%s", cg_url_error_text(error));
            response_free(response);
            goto done;
        }
        char *from = cg_url_scheme(&base), *to = cg_url_scheme(&next);
        bool allowed = cg_net_redirect_allowed(from, to, atomic_load(&http->allow_downgrade));
        free(from);
        free(to);
        cg_url_clear(&base);
        if (!allowed) {
            cg_net_error_set(err, CG_NET_INSECURE_REDIRECT, "Refused redirect from HTTPS to HTTP: %s",
                             next.serialization);
            cg_url_clear(&next);
            response_free(response);
            goto done;
        }
        /* 303 (and 301/302 for POST, like browsers) switch to GET without a body. */
        if (status == 303 ||
            ((status == 301 || status == 302) && strcmp(method, "GET") != 0 && strcmp(method, "HEAD") != 0)) {
            cg_replace(&method, cg_strdup("GET"));
            body = NULL;
            body_len = 0;
        }
        cg_replace(&current, next.serialization);
        next.serialization = NULL;
        cg_url_clear(&next);
        response_free(response);
    }
    cg_net_error_set(err, CG_NET_NETWORK, "Too many redirects");
done:
    free(current);
    free(method);
    return ok;
}

/* `headers` plus `Accept-Encoding: <value>` unless the caller set one. */
static cg_net_header *with_accept_encoding(const cg_net_header *headers, size_t count, const char *value,
                                           size_t *out_count) {
    cg_net_header *all = cg_malloc((count + 1) * sizeof *all);
    bool present = false;
    for (size_t i = 0; i < count; i++) {
        all[i] = headers[i];
        if (strcasecmp(headers[i].name, "Accept-Encoding") == 0) present = true;
    }
    *out_count = count;
    if (!present) all[(*out_count)++] = (cg_net_header){"Accept-Encoding", value};
    return all;
}

/* net.rs headers_of: lower-cased names, each with the first value of that name. */
static void headers_of(const net_response *response, cg_net_headers *out) {
    for (size_t i = 0; i < response->header_count; i++) {
        char *name = cg_lower(response->headers[i].name);
        const char *value = response_header(response, name);
        if (value) cg_net_headers_push(out, name, value);
        free(name);
    }
}

/* ======================================================================================
 * gzip (flate2 MultiGzDecoder, output capped like Read::take)
 * ==================================================================================== */

static bool gunzip(const uint8_t *in, size_t len, size_t cap, cg_buf *out, net_io_error *io) {
    enum { FHCRC = 2, FEXTRA = 4, FNAME = 8, FCOMMENT = 16, FRESERVED = 0xE0, MAX_HEADER_BUF = 65535 };
    size_t pos = 0;
    bool first = true;
    while (first || pos < len) {
        first = false;
        /* member header */
        if (len - pos < 10) return net_io_set(io, NET_IO_UNEXPECTED_EOF, "unexpected end of file");
        const uint8_t *header = in + pos;
        if (header[0] != 0x1f || header[1] != 0x8b || header[2] != 8 || (header[3] & FRESERVED))
            return net_io_set(io, NET_IO_INVALID_INPUT, "invalid gzip header");
        uint8_t flags = header[3];
        size_t start = pos;
        pos += 10;
        if (flags & FEXTRA) {
            if (len - pos < 2) return net_io_set(io, NET_IO_UNEXPECTED_EOF, "unexpected end of file");
            size_t xlen = (size_t)in[pos] | (size_t)in[pos + 1] << 8;
            pos += 2;
            if (len - pos < xlen) return net_io_set(io, NET_IO_UNEXPECTED_EOF, "unexpected end of file");
            pos += xlen;
        }
        for (int field = 0; field < 2; field++) {
            if (!(flags & (field == 0 ? FNAME : FCOMMENT))) continue;
            size_t field_len = 0;
            for (;;) {
                if (pos >= len) return net_io_set(io, NET_IO_UNEXPECTED_EOF, "unexpected end of file");
                if (in[pos++] == 0) break;
                if (field_len == MAX_HEADER_BUF)
                    return net_io_set(io, NET_IO_INVALID_INPUT, "gzip header field too long");
                field_len++;
            }
        }
        if (flags & FHCRC) {
            if (len - pos < 2) return net_io_set(io, NET_IO_UNEXPECTED_EOF, "unexpected end of file");
            uint32_t crc = (uint32_t)crc32(0L, in + start, (uInt)(pos - start));
            uint16_t stored = (uint16_t)(in[pos] | in[pos + 1] << 8);
            if (stored != (uint16_t)crc)
                return net_io_set(io, NET_IO_INVALID_INPUT, "corrupt gzip stream does not have a matching checksum");
            pos += 2;
        }
        /* deflate data */
        z_stream stream;
        memset(&stream, 0, sizeof stream);
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return net_io_set(io, NET_IO_OTHER, "inflate init failed");
        uLong crc = crc32(0L, Z_NULL, 0);
        uint64_t member_size = 0;
        bool ended = false;
        while (!ended) {
            if (out->len >= cap) {
                inflateEnd(&stream);
                return true; /* Read::take: the cap ends the body */
            }
            size_t room = cap - out->len;
            if (room > 256 * 1024) room = 256 * 1024;
            cg_buf_reserve(out, room);
            size_t remaining_in = len - pos;
            uInt avail_in = remaining_in > UINT32_MAX ? UINT32_MAX : (uInt)remaining_in;
            stream.next_in = (Bytef *)(in + pos);
            stream.avail_in = avail_in;
            stream.next_out = (Bytef *)(out->data + out->len);
            stream.avail_out = (uInt)room;
            int ret = inflate(&stream, Z_NO_FLUSH);
            size_t consumed = avail_in - stream.avail_in;
            size_t produced = room - stream.avail_out;
            pos += consumed;
            if (produced) crc = crc32(crc, (const Bytef *)(out->data + out->len), (uInt)produced);
            out->len += produced;
            out->data[out->len] = 0;
            member_size += produced;
            if (ret == Z_STREAM_END) {
                ended = true;
            } else if (ret == Z_OK || ret == Z_BUF_ERROR) {
                if (produced == 0 && consumed == 0 && pos >= len) {
                    inflateEnd(&stream);
                    return net_io_set(io, NET_IO_UNEXPECTED_EOF, "incomplete deflate stream");
                }
            } else {
                inflateEnd(&stream);
                return net_io_set(io, NET_IO_INVALID_INPUT, "corrupt deflate stream");
            }
        }
        inflateEnd(&stream);
        /* trailer: CRC-32 and size */
        if (len - pos < 8) return net_io_set(io, NET_IO_UNEXPECTED_EOF, "unexpected end of file");
        uint32_t stored_crc = (uint32_t)in[pos] | (uint32_t)in[pos + 1] << 8 | (uint32_t)in[pos + 2] << 16 |
                              (uint32_t)in[pos + 3] << 24;
        uint32_t stored_size = (uint32_t)in[pos + 4] | (uint32_t)in[pos + 5] << 8 | (uint32_t)in[pos + 6] << 16 |
                               (uint32_t)in[pos + 7] << 24;
        pos += 8;
        if (stored_crc != (uint32_t)crc || stored_size != (uint32_t)member_size)
            return net_io_set(io, NET_IO_INVALID_INPUT, "corrupt gzip stream does not have a matching checksum");
    }
    return true;
}

/* ======================================================================================
 * public requests
 * ==================================================================================== */

bool cg_http_send(cg_http *http, const char *method, const char *url, const cg_net_header *headers,
                  size_t header_count, const uint8_t *body, size_t body_len, cg_net_response *out,
                  cg_net_error *err) {
    memset(out, 0, sizeof *out);
    /* Transparent gzip, as OkHttp and URLSession did for API calls. */
    size_t count;
    cg_net_header *all = with_accept_encoding(headers, header_count, "gzip", &count);
    net_response response = {0};
    bool ok = execute(http, false, method, url, all, count, body, body_len, &response, err);
    free(all);
    if (!ok) return false;
    out->status = response.status;
    headers_of(&response, &out->headers);
    const char *encoding = response_header(&response, "Content-Encoding");
    bool gzip = false;
    if (encoding) {
        char *trimmed = cg_trim(encoding);
        gzip = strcasecmp(trimmed, "gzip") == 0 || strcasecmp(trimmed, "x-gzip") == 0;
        free(trimmed);
    }
    cg_buf buffer = {0};
    net_io_error io = {0};
    while (buffer.len < CG_NET_MAX_API_BODY_BYTES) {
        size_t want = CG_NET_MAX_API_BODY_BYTES - buffer.len;
        if (want > 64 * 1024) want = 64 * 1024;
        cg_buf_reserve(&buffer, want);
        long read = response_read(&response, (uint8_t *)buffer.data + buffer.len, want, &io);
        if (read < 0) {
            io_fail(err, &io);
            net_io_clear(&io);
            cg_buf_free(&buffer);
            response_free(&response);
            cg_net_response_clear(out);
            return false;
        }
        if (read == 0) break;
        buffer.len += (size_t)read;
        buffer.data[buffer.len] = 0;
    }
    response_free(&response);
    if (gzip) {
        /* The decoded size is capped too (gzip bomb). */
        cg_buf decoded = {0};
        if (buffer.len > 0 &&
            !gunzip((const uint8_t *)buffer.data, buffer.len, CG_NET_MAX_API_BODY_BYTES, &decoded, &io)) {
            io_fail(err, &io);
            net_io_clear(&io);
            cg_buf_free(&decoded);
            cg_buf_free(&buffer);
            cg_net_response_clear(out);
            return false;
        }
        cg_buf_free(&buffer);
        buffer = decoded;
        size_t kept = 0;
        for (size_t i = 0; i < out->headers.len; i++) {
            cg_net_header_own *header = &out->headers.items[i];
            if (strcasecmp(header->name, "Content-Encoding") == 0 ||
                strcasecmp(header->name, "Content-Length") == 0) {
                free(header->name);
                free(header->value);
            } else {
                out->headers.items[kept++] = *header;
            }
        }
        out->headers.len = kept;
    }
    out->body_len = buffer.len;
    out->body = buffer.data ? (uint8_t *)buffer.data : (uint8_t *)cg_calloc(1, 1);
    return true;
}

bool cg_http_get(cg_http *http, const char *url, cg_net_response *out, cg_net_error *err) {
    return cg_http_send(http, "GET", url, NULL, 0, NULL, 0, out, err);
}

bool cg_http_post_json(cg_http *http, const char *url, const cj *body, cg_net_response *out, cg_net_error *err) {
    return cg_http_send_json(http, "POST", url, body, out, err);
}

bool cg_http_send_json(cg_http *http, const char *method, const char *url, const cj *body, cg_net_response *out,
                       cg_net_error *err) {
    char *bytes = cj_print(body);
    static const cg_net_header headers[] = {
        {"Content-Type", "application/json; charset=utf-8"},
        {"Accept", "application/json"},
    };
    bool ok = cg_http_send(http, method, url, headers, 2, (const uint8_t *)bytes, strlen(bytes), out, err);
    free(bytes);
    return ok;
}

bool cg_http_download(cg_http *http, const char *url, const cg_net_header *headers, size_t header_count,
                      cg_net_stream_handler handler, void *context, cg_net_stream_head *head_out,
                      cg_net_error *err) {
    if (head_out) memset(head_out, 0, sizeof *head_out);
    /* Bundle files are stored byte for byte (checksums, Range resume): no content coding. */
    size_t count;
    cg_net_header *all = with_accept_encoding(headers, header_count, "identity", &count);
    net_response response = {0};
    bool ok = execute(http, true, "GET", url, all, count, NULL, 0, &response, err);
    free(all);
    if (!ok) return false;
    cg_net_stream_head head = {0};
    head.status = response.status;
    headers_of(&response, &head.headers);
    const char *length = response_header(&response, "Content-Length");
    if (length) {
        char *trimmed = cg_trim(length);
        head.has_content_length = cg_parse_u64(trimmed, &head.content_length);
        free(trimmed);
    }
    cg_net_stream event = {.kind = CG_NET_STREAM_HEAD, .head = &head};
    if (!handler(context, &event, err)) {
        response_free(&response);
        cg_net_stream_head_clear(&head);
        return false;
    }
    uint8_t *buffer = cg_malloc(CG_IO_BUFFER_BYTES);
    net_io_error io = {0};
    bool failed = false;
    while (!failed) {
        long read = response_read(&response, buffer, CG_IO_BUFFER_BYTES, &io);
        /* Hand over bigger chunks when more data is already there (TLS records, read-ahead); a
         * failure there is reported after the bytes read so far, like the next read would. */
        while (read > 0 && (size_t)read < CG_IO_BUFFER_BYTES && response.conn && response.body != BODY_CHUNKED &&
               conn_buffered(response.conn)) {
            long more = response_read(&response, buffer + read, CG_IO_BUFFER_BYTES - (size_t)read, &io);
            if (more < 0) failed = true;
            if (more <= 0) break;
            read += more;
        }
        if (read < 0) failed = true;
        if (read > 0) {
            event = (cg_net_stream){.kind = CG_NET_STREAM_CHUNK, .data = buffer, .len = (size_t)read};
            if (!handler(context, &event, err)) {
                ok = false;
                break;
            }
        }
        if (failed) {
            io_fail(err, &io);
            ok = false;
        }
        if (read == 0) break;
    }
    free(buffer);
    net_io_clear(&io);
    response_free(&response);
    if (ok && head_out) *head_out = head;
    else cg_net_stream_head_clear(&head);
    return ok;
}
