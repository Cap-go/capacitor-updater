/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Alt-Svc parsing and the HTTP/3 announcement cache (Rust altsvc.rs), see altsvc.h. */

#include "altsvc.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "rt/json.h"
#include "rt/str.h"

struct cg_altsvc_entry {
    char *origin;
    uint16_t port;
    int64_t expires; /* wall clock, ms since the epoch */
    int64_t stored;  /* expires as last written (0: never) */
};

/* ---- parsing */

static bool is_tchar(uint8_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
           (c && strchr("!#$%&'*+-.^_`|~", c));
}

static bool is_ows(uint8_t c) { return c == ' ' || c == '\t'; }

typedef struct {
    const uint8_t *bytes;
    size_t len, pos;
} cursor;

static int peek(const cursor *at) { return at->pos < at->len ? at->bytes[at->pos] : -1; }

static void skip_ows(cursor *at) {
    while (at->pos < at->len && is_ows(at->bytes[at->pos]))
        at->pos++;
}

/* A token; false when empty. */
static bool token(cursor *at, size_t *start, size_t *len) {
    *start = at->pos;
    while (at->pos < at->len && is_tchar(at->bytes[at->pos]))
        at->pos++;
    *len = at->pos - *start;
    return *len > 0;
}

/* RFC 9110 quoted-string, unescaped into `out` (cleared first). */
static bool quoted(cursor *at, cg_buf *out) {
    out->len = 0;
    if (peek(at) != '"')
        return false;
    at->pos++;
    for (;;) {
        if (at->pos >= at->len)
            return false;
        uint8_t c = at->bytes[at->pos++];
        if (c == '"')
            return true;
        if (c == '\\') {
            if (at->pos >= at->len)
                return false;
            uint8_t escaped = at->bytes[at->pos];
            if (!(escaped == '\t' || escaped == ' ' || (escaped >= 0x21 && escaped <= 0x7e) ||
                  escaped >= 0x80))
                return false;
            at->pos++;
            cg_buf_putc(out, (char)escaped);
        } else if (c == '\t' || c == ' ' || c == 0x21 || (c >= 0x23 && c <= 0x5b) ||
                   (c >= 0x5d && c <= 0x7e) || c >= 0x80) {
            cg_buf_putc(out, (char)c);
        } else {
            return false;
        }
    }
}

/* Digits only, saturating; false when empty or not all digits. */
static bool delta_seconds(const uint8_t *value, size_t len, uint64_t *out) {
    if (len == 0)
        return false;
    uint64_t total = 0;
    for (size_t i = 0; i < len; i++) {
        if (value[i] < '0' || value[i] > '9')
            return false;
        uint64_t digit = (uint64_t)(value[i] - '0');
        total = total > (UINT64_MAX - digit) / 10 ? UINT64_MAX : total * 10 + digit;
    }
    *out = total;
    return true;
}

/* `[host]:port` on `origin_host`, port 1-65535; 0 when not usable. */
static uint16_t same_host_port(const uint8_t *authority, size_t len, const char *origin_host) {
    size_t colon = len;
    for (size_t i = len; i > 0; i--)
        if (authority[i - 1] == ':') {
            colon = i - 1;
            break;
        }
    if (colon == len)
        return 0;
    const uint8_t *port = authority + colon + 1;
    size_t port_len = len - colon - 1;
    if (port_len == 0 || port_len > 5)
        return 0;
    uint32_t value = 0;
    for (size_t i = 0; i < port_len; i++) {
        if (port[i] < '0' || port[i] > '9')
            return 0;
        value = value * 10 + (uint32_t)(port[i] - '0');
    }
    if (value == 0 || value > 65535)
        return 0;
    if (colon > 0) {
        size_t host_len = strlen(origin_host);
        if (colon != host_len || strncasecmp((const char *)authority, origin_host, host_len) != 0)
            return 0;
        /* strncasecmp stops at a NUL: the bytes must match exactly in length and content. */
        if (memchr(authority, 0, colon))
            return 0;
    }
    return (uint16_t)value;
}

cg_altsvc cg_altsvc_parse(const char *value, size_t len, const char *origin_host) {
    cg_altsvc result = {CG_ALTSVC_INVALID, false, 0, 0};
    cursor at = {(const uint8_t *)value, len, 0};
    skip_ows(&at);
    size_t start = at.pos, end = len;
    while (end > start && is_ows(at.bytes[end - 1]))
        end--;
    if (end - start == 5 && memcmp(at.bytes + start, "clear", 5) == 0) {
        result.kind = CG_ALTSVC_CLEAR;
        return result;
    }
    cg_buf authority = {0}, parameter = {0};
    size_t values = 0;
    bool invalid = false;
    for (;;) {
        skip_ows(&at);
        int next = peek(&at);
        if (next < 0)
            break;
        /* Empty list elements are allowed (RFC 9110 5.6.1). */
        if (next == ',') {
            at.pos++;
            continue;
        }
        size_t protocol, protocol_len;
        if (!token(&at, &protocol, &protocol_len) || peek(&at) != '=') {
            invalid = true;
            break;
        }
        at.pos++;
        if (!quoted(&at, &authority)) {
            invalid = true;
            break;
        }
        bool max_age_valid = true, seen_max_age = false;
        uint64_t max_age = CG_ALTSVC_DEFAULT_MAX_AGE_SECONDS;
        for (;;) {
            skip_ows(&at);
            if (peek(&at) != ';')
                break;
            at.pos++;
            skip_ows(&at);
            size_t name, name_len;
            if (!token(&at, &name, &name_len) || peek(&at) != '=') {
                invalid = true;
                break;
            }
            at.pos++;
            size_t token_start, token_len;
            parameter.len = 0;
            if (token(&at, &token_start, &token_len)) {
                cg_buf_put(&parameter, at.bytes + token_start, token_len);
            } else if (!quoted(&at, &parameter)) {
                invalid = true;
                break;
            }
            if (name_len == 2 && strncasecmp((const char *)at.bytes + name, "ma", 2) == 0 && !seen_max_age) {
                seen_max_age = true;
                uint64_t seconds;
                max_age_valid = delta_seconds((const uint8_t *)parameter.data, parameter.len, &seconds);
                if (max_age_valid)
                    max_age =
                        seconds < CG_ALTSVC_MAX_MAX_AGE_SECONDS ? seconds : CG_ALTSVC_MAX_MAX_AGE_SECONDS;
            }
        }
        if (invalid)
            break;
        skip_ows(&at);
        next = peek(&at);
        if (next == ',') {
            at.pos++;
        } else if (next >= 0) {
            invalid = true;
            break;
        }
        values++;
        if (!result.has_h3 && protocol_len == 2 && memcmp(at.bytes + protocol, "h3", 2) == 0 &&
            max_age_valid) {
            uint16_t port = same_host_port((const uint8_t *)(authority.data ? authority.data : ""),
                                           authority.len, origin_host);
            if (port) {
                result.has_h3 = true;
                result.port = port;
                result.max_age_seconds = max_age;
            }
        }
    }
    cg_buf_free(&authority);
    cg_buf_free(&parameter);
    if (invalid || values == 0)
        return (cg_altsvc){CG_ALTSVC_INVALID, false, 0, 0};
    result.kind = CG_ALTSVC_LIST;
    return result;
}

/* ---- cache */

void cg_altsvc_cache_init(cg_altsvc_cache *cache) {
    memset(cache, 0, sizeof *cache);
    cg_mutex_init(&cache->lock);
}

static void entries_free(cg_altsvc_cache *cache) {
    for (size_t i = 0; i < cache->len; i++)
        free(cache->entries[i].origin);
    free(cache->entries);
    cache->entries = NULL;
    cache->len = cache->cap = 0;
}

void cg_altsvc_cache_clear(cg_altsvc_cache *cache) {
    entries_free(cache);
    cg_mutex_destroy(&cache->lock);
}

/* Index of `origin`, or where it goes (sorted, like the Rust BTreeMap). */
static size_t find(const cg_altsvc_cache *cache, const char *origin, bool *found) {
    size_t low = 0, high = cache->len;
    while (low < high) {
        size_t mid = low + (high - low) / 2;
        int order = strcmp(cache->entries[mid].origin, origin);
        if (order == 0) {
            *found = true;
            return mid;
        }
        if (order < 0)
            low = mid + 1;
        else
            high = mid;
    }
    *found = false;
    return low;
}

static void insert_at(cg_altsvc_cache *cache, size_t index, const char *origin, uint16_t port,
                      int64_t expires, int64_t stored) {
    if (cache->len == cache->cap) {
        cache->cap = cache->cap ? cache->cap * 2 : 8;
        cache->entries = cg_realloc(cache->entries, cache->cap * sizeof *cache->entries);
    }
    memmove(cache->entries + index + 1, cache->entries + index,
            (cache->len - index) * sizeof *cache->entries);
    cache->entries[index] = (cg_altsvc_entry){cg_strdup(origin), port, expires, stored};
    cache->len++;
}

static void remove_at(cg_altsvc_cache *cache, size_t index) {
    free(cache->entries[index].origin);
    memmove(cache->entries + index, cache->entries + index + 1,
            (cache->len - index - 1) * sizeof *cache->entries);
    cache->len--;
}

static void remove_expired(cg_altsvc_cache *cache, int64_t now_ms) {
    for (size_t i = cache->len; i > 0; i--)
        if (cache->entries[i - 1].expires <= now_ms)
            remove_at(cache, i - 1);
}

/* Caller holds the lock. */
static void load(cg_altsvc_cache *cache, const cg_host *host) {
    if (cache->loaded)
        return;
    cache->loaded = true;
    char *text = cg_host_kv_get(host, CG_ALTSVC_STORAGE_KEY, NULL);
    if (!text)
        return;
    cj *stored = cj_parse(text, NULL);
    free(text);
    if (!cj_is_obj(stored)) {
        cj_free(stored);
        return;
    }
    for (size_t i = 0; i < cj_len(stored) && cache->len < CG_ALTSVC_MAX_ENTRIES; i++) {
        const cj *value = cj_value_at(stored, i);
        uint64_t port;
        int64_t expires;
        if (!cj_as_u64(cj_get(value, "port"), &port) || port < 1 || port > 65535)
            continue;
        if (!cj_as_i64(cj_get(value, "expires"), &expires))
            continue;
        bool found;
        size_t index = find(cache, cj_key_at(stored, i), &found);
        if (found)
            continue;
        insert_at(cache, index, cj_key_at(stored, i), (uint16_t)port, expires, expires);
    }
    cj_free(stored);
}

/* Caller holds the lock. */
static void save(cg_altsvc_cache *cache, const cg_host *host, int64_t now_ms) {
    remove_expired(cache, now_ms);
    if (cache->len == 0) {
        cg_host_kv_set(host, CG_ALTSVC_STORAGE_KEY, NULL);
        return;
    }
    cj *stored = cj_obj();
    for (size_t i = 0; i < cache->len; i++) {
        cg_altsvc_entry *entry = &cache->entries[i];
        entry->stored = entry->expires;
        cj_set(stored, entry->origin,
               cj_objv("port", cj_u64(entry->port), "expires", cj_i64(entry->expires), NULL));
    }
    char *text = cj_print(stored);
    cj_free(stored);
    cg_host_kv_set(host, CG_ALTSVC_STORAGE_KEY, text);
    free(text);
}

uint16_t cg_altsvc_lookup(cg_altsvc_cache *cache, const cg_host *host, const char *origin, int64_t now_ms) {
    cg_lock(&cache->lock);
    load(cache, host);
    bool found;
    size_t index = find(cache, origin, &found);
    uint16_t port = found && cache->entries[index].expires > now_ms ? cache->entries[index].port : 0;
    cg_unlock(&cache->lock);
    return port;
}

void cg_altsvc_update(cg_altsvc_cache *cache, const cg_host *host, const char *origin, cg_altsvc value,
                      int64_t now_ms) {
    cg_lock(&cache->lock);
    load(cache, host);
    bool found;
    size_t index = find(cache, origin, &found);
    bool changed = false;
    if (value.kind == CG_ALTSVC_CLEAR || (value.kind == CG_ALTSVC_LIST && !value.has_h3)) {
        if (found) {
            remove_at(cache, index);
            changed = true;
        }
    } else if (value.kind == CG_ALTSVC_LIST) {
        int64_t age_ms = value.max_age_seconds > (uint64_t)INT64_MAX / 1000
                             ? INT64_MAX
                             : (int64_t)value.max_age_seconds * 1000;
        int64_t expires = now_ms > INT64_MAX - age_ms ? INT64_MAX : now_ms + age_ms;
        if (expires <= now_ms) {
            if (found) {
                remove_at(cache, index);
                changed = true;
            }
        } else if (found) {
            cg_altsvc_entry *entry = &cache->entries[index];
            bool port_changed = entry->port != value.port;
            entry->port = value.port;
            entry->expires = expires;
            int64_t moved = entry->stored < 0 && expires > INT64_MAX + entry->stored
                                ? INT64_MAX
                                : expires - entry->stored;
            changed = port_changed || moved >= CG_ALTSVC_PERSIST_SLACK_MS;
        } else {
            if (cache->len >= CG_ALTSVC_MAX_ENTRIES)
                remove_expired(cache, now_ms);
            if (cache->len >= CG_ALTSVC_MAX_ENTRIES) {
                /* The soonest to expire goes (the first in origin order on a tie). */
                size_t oldest = 0;
                for (size_t i = 1; i < cache->len; i++)
                    if (cache->entries[i].expires < cache->entries[oldest].expires)
                        oldest = i;
                remove_at(cache, oldest);
            }
            index = find(cache, origin, &found);
            insert_at(cache, index, origin, value.port, expires, 0);
            changed = true;
        }
    }
    if (changed)
        save(cache, host, now_ms);
    cg_unlock(&cache->lock);
}
