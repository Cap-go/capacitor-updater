/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * HTTP/3 discovery (Rust altsvc.rs): Alt-Svc (RFC 7838) parsing and the per-origin cache,
 * persisted in the host's key-value storage. An origin is only reached over HTTP/3 after
 * one of its responses announced `h3` on the same host.
 */
#ifndef CG_ALTSVC_H
#define CG_ALTSVC_H

#include <stdbool.h>
#include <stdint.h>

#include "host.h"
#include "rt/sync.h"

#define CG_ALTSVC_STORAGE_KEY "CapacitorUpdater.altSvc"
#define CG_ALTSVC_MAX_ENTRIES 16
#define CG_ALTSVC_DEFAULT_MAX_AGE_SECONDS 86400u
#define CG_ALTSVC_MAX_MAX_AGE_SECONDS (7u * 86400u)
#define CG_ALTSVC_PERSIST_SLACK_MS 3600000

typedef enum {
    CG_ALTSVC_INVALID = 0, /* not valid syntax: ignored */
    CG_ALTSVC_CLEAR,       /* `clear`: forget the origin */
    CG_ALTSVC_LIST,        /* a valid list: `has_h3` tells whether it has a usable h3 alternative */
} cg_altsvc_kind;

typedef struct {
    cg_altsvc_kind kind;
    bool has_h3;
    uint16_t port;
    uint64_t max_age_seconds;
} cg_altsvc;

/* Parses an Alt-Svc field value (`len` bytes) received from `origin_host` (the URL host, IPv6
 * in brackets). Strict syntax: any error gives CG_ALTSVC_INVALID. The first `h3` alternative
 * on the same host with a valid `ma` wins. */
cg_altsvc cg_altsvc_parse(const char *value, size_t len, const char *origin_host);

typedef struct cg_altsvc_entry cg_altsvc_entry;

typedef struct {
    cg_mutex lock;
    bool loaded;
    cg_altsvc_entry *entries; /* sorted by origin */
    size_t len, cap;
} cg_altsvc_cache;

void cg_altsvc_cache_init(cg_altsvc_cache *cache);
void cg_altsvc_cache_clear(cg_altsvc_cache *cache);
/* The announced HTTP/3 port of `origin` (`https://host:port`) while fresh, 0 when none. */
uint16_t cg_altsvc_lookup(cg_altsvc_cache *cache, const cg_host *host, const char *origin, int64_t now_ms);
/* Applies a parsed announcement from `origin`; writes the storage when the set of origins or a
 * port changed, or an expiry moved by CG_ALTSVC_PERSIST_SLACK_MS or more. */
void cg_altsvc_update(cg_altsvc_cache *cache, const cg_host *host, const char *origin, cg_altsvc value,
                      int64_t now_ms);

#endif
