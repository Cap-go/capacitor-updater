/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#include "fuzz_support.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

const char FZ_PUBLIC_KEY[] =
    "-----BEGIN RSA PUBLIC KEY-----\n"
    "MIIBCgKCAQEAxog7suMG1F2Y/e6CLNpWU0Kp5eNXPYSE+lY4Nzrxq8Mdi0nKR8tK\n"
    "qWHxCgNQJrfhE9CjSwuu9w656i3P32zIGRSu/nDgUkDd4Z2EGiq+Eu3ooR9SnUTC\n"
    "/yjCksNdbu47RHTvCtHbDEczqfpIDZMgRgYbRePQAxVHWJehfetO80yDoNdiRDrD\n"
    "c0UYgNQf/H5ko2KWiQs7yjsU22zPLfwZ8NEkuD2hTXZeOj/pBUborVAykI9bI59I\n"
    "PfQPVKEdW9RAggpR2FcYbnTMaYSc9yVIxu4VxWB7DfvPKJOrz4HOJIwfTwuFGeQs\n"
    "wUcG10QvXok+NHjaHHc+iBe2hk24XDUnGQIDAQAB\n"
    "-----END RSA PUBLIC KEY-----\n";

void fz_fail(const char *format, ...) {
    va_list args;
    va_start(args, format);
    fputs("fuzz invariant broken: ", stderr);
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    va_end(args);
    abort();
}

/* ---- files */

static pthread_once_t scratch_once = PTHREAD_ONCE_INIT;
static char scratch[512];

static void scratch_init(void) {
    const char *base = getenv("TMPDIR");
    snprintf(scratch, sizeof scratch, "%s/capgo-fuzz-c-XXXXXX", base && *base ? base : "/tmp");
    if (!mkdtemp(scratch)) fz_fail("mkdtemp: %s", strerror(errno));
}

const char *fz_scratch_dir(void) {
    pthread_once(&scratch_once, scratch_init);
    return scratch;
}

static int remove_entry(const char *path, const struct stat *st, int flag, struct FTW *ftw) {
    (void)st;
    (void)flag;
    (void)ftw;
    remove(path);
    return 0;
}

void fz_remove_tree(const char *path) { nftw(path, remove_entry, 16, FTW_DEPTH | FTW_PHYS); }

void fz_write_file(const char *path, const uint8_t *data, size_t len) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) fz_fail("open %s: %s", path, strerror(errno));
    while (len > 0) {
        ssize_t written = write(fd, data, len);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) fz_fail("write %s: %s", path, strerror(errno));
        data += written;
        len -= (size_t)written;
    }
    close(fd);
}

/* ---- loopback server */

static pthread_mutex_t response_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t *response_bytes;
static size_t response_len;
static pthread_once_t server_once = PTHREAD_ONCE_INIT;
static int listener = -1;
static uint16_t listener_port;

void fz_server_set_response(const uint8_t *data, size_t len) {
    uint8_t *copy = malloc(len ? len : 1);
    if (!copy) abort();
    if (len) memcpy(copy, data, len);
    pthread_mutex_lock(&response_lock);
    free(response_bytes);
    response_bytes = copy;
    response_len = len;
    pthread_mutex_unlock(&response_lock);
}

/* Reads the request head and its Content-Length body (an unread request would turn the close
 * into a reset that hides the response). Gives up after 2 s or 1 MiB. */
static void drain_request(int fd) {
    char head[16384];
    size_t used = 0;
    long body = -1;
    for (;;) {
        struct pollfd poller = {fd, POLLIN, 0};
        if (poll(&poller, 1, 2000) <= 0) return;
        char buffer[4096];
        ssize_t got = recv(fd, buffer, sizeof buffer, 0);
        if (got <= 0) return;
        if (body >= 0) {
            body -= got;
            if (body <= 0) return;
            continue;
        }
        size_t take = (size_t)got < sizeof head - 1 - used ? (size_t)got : sizeof head - 1 - used;
        memcpy(head + used, buffer, take);
        used += take;
        head[used] = 0;
        char *end = strstr(head, "\r\n\r\n");
        if (!end) {
            if (used >= sizeof head - 1) return;
            continue;
        }
        long length = 0;
        for (char *line = head; line && line < end; line = strstr(line, "\r\n") ? strstr(line, "\r\n") + 2 : NULL) {
            if (strncasecmp(line, "content-length:", 15) == 0) length = strtol(line + 15, NULL, 10);
        }
        if (length < 0 || length > (1 << 20)) length = 0;
        long have = (long)(head + used - (end + 4));
        body = length - have;
        if (body <= 0) return;
    }
}

static void *serve(void *arg) {
    int fd = (int)(intptr_t)arg;
    drain_request(fd);
    pthread_mutex_lock(&response_lock);
    size_t len = response_len;
    uint8_t *copy = malloc(len ? len : 1);
    if (!copy) abort();
    if (len) memcpy(copy, response_bytes, len);
    pthread_mutex_unlock(&response_lock);
    size_t sent = 0;
    while (sent < len) {
        ssize_t wrote = send(fd, copy + sent, len - sent, 0);
        if (wrote <= 0) break;
        sent += (size_t)wrote;
    }
    free(copy);
    shutdown(fd, SHUT_WR);
    /* Wait for the client to close (it frees its connection pool at the end of each run). */
    for (;;) {
        struct pollfd poller = {fd, POLLIN, 0};
        if (poll(&poller, 1, 1000) <= 0) break;
        char buffer[4096];
        if (recv(fd, buffer, sizeof buffer, 0) <= 0) break;
    }
    /* No TIME_WAIT: thousands of connections a second would exhaust the ports. */
    struct linger linger = {1, 0};
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, sizeof linger);
    close(fd);
    return NULL;
}

static void *accept_loop(void *arg) {
    (void)arg;
    for (;;) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR || errno == ECONNABORTED || errno == EMFILE || errno == ENFILE) {
                if (errno == EMFILE || errno == ENFILE) usleep(1000);
                continue;
            }
            fz_fail("accept: %s", strerror(errno));
        }
        pthread_t thread;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&thread, &attr, serve, (void *)(intptr_t)fd) != 0) close(fd);
        pthread_attr_destroy(&attr);
    }
    return NULL;
}

static void server_init(void) {
    listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) fz_fail("socket: %s", strerror(errno));
    int one = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&address, sizeof address) != 0) fz_fail("bind: %s", strerror(errno));
    if (listen(listener, 512) != 0) fz_fail("listen: %s", strerror(errno));
    socklen_t length = sizeof address;
    getsockname(listener, (struct sockaddr *)&address, &length);
    listener_port = ntohs(address.sin_port);
    fz_server_set_response((const uint8_t *)"", 0);
    pthread_t thread;
    if (pthread_create(&thread, NULL, accept_loop, NULL) != 0) fz_fail("pthread_create");
    pthread_detach(thread);
}

uint16_t fz_server_port(void) {
    pthread_once(&server_once, server_init);
    return listener_port;
}

/* ---- host */

typedef struct kv_entry {
    char *key;
    char *value;
    struct kv_entry *next;
} kv_entry;

typedef struct {
    pthread_mutex_t lock;
    kv_entry *entries;
} fz_store;

static char *dup_text(const char *text) {
    size_t len = strlen(text);
    char *copy = malloc(len + 1);
    if (!copy) abort();
    memcpy(copy, text, len + 1);
    return copy;
}

static void host_log(void *context, int level, const char *message) {
    (void)context;
    (void)level;
    (void)message;
}

static char *host_kv_get(void *context, const char *key) {
    fz_store *store = context;
    char *value = NULL;
    pthread_mutex_lock(&store->lock);
    for (kv_entry *entry = store->entries; entry; entry = entry->next) {
        if (strcmp(entry->key, key) == 0) {
            value = dup_text(entry->value);
            break;
        }
    }
    pthread_mutex_unlock(&store->lock);
    return value;
}

static void host_kv_set(void *context, const char *key, const char *value) {
    fz_store *store = context;
    pthread_mutex_lock(&store->lock);
    kv_entry **link = &store->entries;
    while (*link && strcmp((*link)->key, key) != 0) link = &(*link)->next;
    if (*link) {
        kv_entry *entry = *link;
        if (value) {
            free(entry->value);
            entry->value = dup_text(value);
        } else {
            *link = entry->next;
            free(entry->key);
            free(entry->value);
            free(entry);
        }
    } else if (value) {
        kv_entry *entry = malloc(sizeof *entry);
        if (!entry) abort();
        entry->key = dup_text(key);
        entry->value = dup_text(value);
        entry->next = NULL;
        *link = entry;
    }
    pthread_mutex_unlock(&store->lock);
}

static char *host_kv_keys(void *context) {
    (void)context;
    return dup_text("[]");
}

static void host_emit(void *context, const char *event, const char *payload) {
    (void)context;
    (void)event;
    (void)payload;
}

static void host_free_string(void *context, char *value) {
    (void)context;
    free(value);
}

static char *host_hook(void *context, const char *name, const char *payload) {
    (void)context;
    (void)payload;
    char reply[128];
    if (strcmp(name, "proxyForUrl") == 0) {
        snprintf(reply, sizeof reply, "{\"type\":\"http\",\"host\":\"127.0.0.1\",\"port\":%u}",
                 (unsigned)fz_server_port());
        return dup_text(reply);
    }
    if (strcmp(name, "cleartextPermitted") == 0) return dup_text("{\"permitted\":true}");
    return NULL;
}

static void host_release(void *context) {
    fz_store *store = context;
    kv_entry *entry = store->entries;
    while (entry) {
        kv_entry *next = entry->next;
        free(entry->key);
        free(entry->value);
        free(entry);
        entry = next;
    }
    pthread_mutex_destroy(&store->lock);
    free(store);
}

CapgoHostCallbacks fz_host_callbacks(void) {
    fz_store *store = calloc(1, sizeof *store);
    if (!store) abort();
    pthread_mutex_init(&store->lock, NULL);
    CapgoHostCallbacks callbacks;
    memset(&callbacks, 0, sizeof callbacks);
    callbacks.context = store;
    callbacks.log = host_log;
    callbacks.kv_get = host_kv_get;
    callbacks.kv_set = host_kv_set;
    callbacks.kv_keys = host_kv_keys;
    callbacks.emit = host_emit;
    callbacks.free_string = host_free_string;
    callbacks.hook = host_hook;
    callbacks.release = host_release;
    callbacks.verify_server_certificate = NULL;
    return callbacks;
}
