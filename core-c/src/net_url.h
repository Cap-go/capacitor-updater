/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * URL parsing with the semantics of the Rust `url` crate (WHATWG URL Standard) as the
 * HTTP client uses it: http(s) and the other special schemes are parsed exactly
 * (percent-encoding, dot segments, IPv4 / IPv6 hosts, default ports, relative
 * references), host names go through the ASCII-only IDNA mapping the Rust build pins
 * (idna_adapter 1.0.0: Unicode host names fail, punycode `xn--` labels are accepted).
 * Other schemes are only recognized (the client refuses them anyway).
 */
#ifndef CG_NET_URL_H
#define CG_NET_URL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    CG_URL_OK = 0,
    CG_URL_EMPTY_HOST,
    CG_URL_IDNA_ERROR,
    CG_URL_INVALID_PORT,
    CG_URL_INVALID_IPV4,
    CG_URL_INVALID_IPV6,
    CG_URL_INVALID_DOMAIN_CHARACTER,
    CG_URL_RELATIVE_WITHOUT_BASE,
    CG_URL_RELATIVE_WITH_CANNOT_BE_A_BASE_BASE,
    CG_URL_OVERFLOW,
} cg_url_error;

typedef enum { CG_URL_HOST_NONE = 0, CG_URL_HOST_DOMAIN, CG_URL_HOST_IPV4, CG_URL_HOST_IPV6 } cg_url_host;

typedef struct {
    char *serialization; /* the URL text (Display) */
    size_t len;
    size_t scheme_end, username_end, host_start, host_end, path_start;
    long query_start, fragment_start; /* -1: none */
    cg_url_host host;
    uint32_t ipv4;
    uint16_t ipv6[8];
    int port;     /* explicit non-default port, -1: none */
    bool special; /* parsed as a special (http-like) URL */
    bool opaque;  /* other schemes: only the scheme and whether there is a host are known */
} cg_url;

/* Parses `input` (resolved against `base` when not NULL). On error *out is zeroed. */
cg_url_error cg_url_parse(const char *input, const cg_url *base, cg_url *out);
void cg_url_clear(cg_url *url);

/* ParseError Debug name ("EmptyHost") and Display text ("empty host"). */
const char *cg_url_error_name(cg_url_error error);
const char *cg_url_error_text(cg_url_error error);

/* Parts (malloc'd copies). */
char *cg_url_scheme(const cg_url *url);
/* Serialized host ("example.com", "127.0.0.1", "[::1]"), NULL without host. */
char *cg_url_host_str(const cg_url *url);
char *cg_url_username(const cg_url *url);
/* NULL when there is no password. */
char *cg_url_password(const cg_url *url);
char *cg_url_path(const cg_url *url);
/* NULL when there is no query ("" for a trailing "?"). */
char *cg_url_query(const cg_url *url);
bool cg_url_scheme_is(const cg_url *url, const char *scheme);
/* Explicit port or the scheme default (http 80, https 443, ...), -1 when unknown. */
int cg_url_port_or_default(const cg_url *url);

#endif
