/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Port of the parts of the Rust `url` 2.5 parser (parser.rs, host.rs) and of the ASCII-only
 * `idna` 1.1 mapping used by the HTTP client. See net_url.h. */

#include "net_url.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rt/str.h"

/* ---- input: a byte cursor that skips ASCII tab and newline (url Input) */

typedef struct {
    const char *p, *end;
} url_in;

static bool tab_or_newline(unsigned char c) { return c == '\t' || c == '\n' || c == '\r'; }

/* Next char (byte) or -1. */
static int in_next(url_in *in) {
    while (in->p < in->end) {
        unsigned char c = (unsigned char)*in->p++;
        if (!tab_or_newline(c)) return c;
    }
    return -1;
}

static int in_peek(url_in in) { return in_next(&in); }

/* Consumes `prefix` when the input starts with it. */
static bool in_split_prefix(url_in *in, const char *prefix) {
    url_in copy = *in;
    for (const char *c = prefix; *c; c++)
        if (in_next(&copy) != (unsigned char)*c) return false;
    *in = copy;
    return true;
}

/* Last occurrence of c in the first len bytes (memrchr is not portable). */
static const char *last_byte(const char *bytes, int c, size_t len) {
    while (len > 0)
        if (bytes[--len] == (char)c) return bytes + len;
    return NULL;
}

/* ---- percent-encode sets (percent_encoding AsciiSet; non-ASCII is always encoded) */

typedef enum { SET_CONTROLS, SET_FRAGMENT, SET_PATH, SET_USERINFO, SET_QUERY, SET_SPECIAL_QUERY } encode_set;

static bool needs_encoding(encode_set set, unsigned char c) {
    if (c < 0x20 || c >= 0x7F) return true;
    switch (set) {
    case SET_CONTROLS:
        return false;
    case SET_QUERY:
    case SET_SPECIAL_QUERY:
        if (c == ' ' || c == '"' || c == '#' || c == '<' || c == '>') return true;
        return set == SET_SPECIAL_QUERY && c == '\'';
    case SET_FRAGMENT:
    case SET_PATH:
    case SET_USERINFO:
        if (c == ' ' || c == '"' || c == '<' || c == '>' || c == '`') return true;
        if (set == SET_FRAGMENT) return false;
        if (c == '#' || c == '?' || c == '{' || c == '}') return true;
        if (set == SET_PATH) return false;
        return strchr("/:;=@[\\]^|", c) != NULL;
    }
    return false;
}

static void put_encoded(cg_buf *s, encode_set set, unsigned char c) {
    if (needs_encoding(set, c)) {
        static const char hex[] = "0123456789ABCDEF";
        char out[3] = {'%', hex[c >> 4], hex[c & 15]};
        cg_buf_put(s, out, 3);
    } else {
        cg_buf_putc(s, (char)c);
    }
}

/* ---- error names */

const char *cg_url_error_name(cg_url_error error) {
    switch (error) {
    case CG_URL_OK:
        return "Ok";
    case CG_URL_EMPTY_HOST:
        return "EmptyHost";
    case CG_URL_IDNA_ERROR:
        return "IdnaError";
    case CG_URL_INVALID_PORT:
        return "InvalidPort";
    case CG_URL_INVALID_IPV4:
        return "InvalidIpv4Address";
    case CG_URL_INVALID_IPV6:
        return "InvalidIpv6Address";
    case CG_URL_INVALID_DOMAIN_CHARACTER:
        return "InvalidDomainCharacter";
    case CG_URL_RELATIVE_WITHOUT_BASE:
        return "RelativeUrlWithoutBase";
    case CG_URL_RELATIVE_WITH_CANNOT_BE_A_BASE_BASE:
        return "RelativeUrlWithCannotBeABaseBase";
    case CG_URL_OVERFLOW:
        return "Overflow";
    }
    return "";
}

const char *cg_url_error_text(cg_url_error error) {
    switch (error) {
    case CG_URL_OK:
        return "";
    case CG_URL_EMPTY_HOST:
        return "empty host";
    case CG_URL_IDNA_ERROR:
        return "invalid international domain name";
    case CG_URL_INVALID_PORT:
        return "invalid port number";
    case CG_URL_INVALID_IPV4:
        return "invalid IPv4 address";
    case CG_URL_INVALID_IPV6:
        return "invalid IPv6 address";
    case CG_URL_INVALID_DOMAIN_CHARACTER:
        return "invalid domain character";
    case CG_URL_RELATIVE_WITHOUT_BASE:
        return "relative URL without a base";
    case CG_URL_RELATIVE_WITH_CANNOT_BE_A_BASE_BASE:
        return "relative URL with a cannot-be-a-base base";
    case CG_URL_OVERFLOW:
        return "URLs more than 4 GB are not supported";
    }
    return "";
}

/* ---- schemes */

typedef enum { SCHEME_FILE, SCHEME_SPECIAL, SCHEME_NOT_SPECIAL } scheme_type;

static scheme_type scheme_type_of(const char *scheme, size_t len) {
    static const char *const special[] = {"http", "https", "ws", "wss", "ftp"};
    for (size_t i = 0; i < sizeof special / sizeof *special; i++)
        if (strlen(special[i]) == len && memcmp(special[i], scheme, len) == 0) return SCHEME_SPECIAL;
    if (len == 4 && memcmp(scheme, "file", 4) == 0) return SCHEME_FILE;
    return SCHEME_NOT_SPECIAL;
}

static int default_port(const char *scheme, size_t len) {
    if ((len == 4 && memcmp(scheme, "http", 4) == 0) || (len == 2 && memcmp(scheme, "ws", 2) == 0)) return 80;
    if ((len == 5 && memcmp(scheme, "https", 5) == 0) || (len == 3 && memcmp(scheme, "wss", 3) == 0)) return 443;
    if (len == 3 && memcmp(scheme, "ftp", 3) == 0) return 21;
    return -1;
}

/* ---- IDNA (idna 1.1 Uts46::to_ascii with the ASCII-only idna_adapter 1.0.0, AsciiDenyList::URL,
 * Hyphens::Allow, DnsLength::Ignore, fail fast) */

/* Glyphless ASCII (<= space, DEL), upper case (mapped to lower case) and "%#/:<>?@[\\]^|". */
static bool url_denied(unsigned char c) {
    return c <= ' ' || c == 0x7F || (c >= 'A' && c <= 'Z') || strchr("%#/:<>?@[\\]^|", c) != NULL;
}

/* RFC 3492 decoder (idna punycode.rs, internal caller: basic code points lower-cased). Writes code
 * points to out (capacity cap). Returns the count or -1. */
static long punycode_decode(const unsigned char *input, size_t len, uint32_t *out, size_t cap) {
    enum { BASE = 36, T_MIN = 1, T_MAX = 26, SKEW = 38, DAMP = 700, INITIAL_BIAS = 72, INITIAL_N = 0x80 };
    size_t delimiter = len;
    for (size_t i = len; i > 0; i--)
        if (input[i - 1] == '-') {
            delimiter = i - 1;
            break;
        }
    size_t base_len = 0, start = 0;
    if (delimiter < len) {
        base_len = delimiter;
        start = delimiter > 0 ? delimiter + 1 : 0;
    }
    if (base_len > cap) return -1;
    size_t length = 0;
    for (size_t i = 0; i < base_len; i++) {
        unsigned char c = input[i];
        out[length++] = (c >= 'A' && c <= 'Z') ? (uint32_t)(c + 32) : c;
    }
    uint32_t code_point = INITIAL_N, bias = INITIAL_BIAS, i = 0;
    size_t pos = start;
    while (pos < len) {
        uint32_t previous_i = i, weight = 1, k = BASE;
        for (;;) {
            if (pos >= len) return -1;
            unsigned char byte = input[pos++];
            uint32_t digit;
            if (byte >= '0' && byte <= '9') digit = byte - '0' + 26;
            else if (byte >= 'A' && byte <= 'Z') digit = byte - 'A';
            else if (byte >= 'a' && byte <= 'z') digit = byte - 'a';
            else return -1;
            uint64_t product = (uint64_t)digit * weight;
            if (product > UINT32_MAX || (uint64_t)i + product > UINT32_MAX) return -1;
            i += (uint32_t)product;
            uint32_t t = k <= bias ? T_MIN : (k >= bias + T_MAX ? T_MAX : k - bias);
            if (digit < t) break;
            uint64_t next_weight = (uint64_t)weight * (BASE - t);
            if (next_weight > UINT32_MAX) return -1;
            weight = (uint32_t)next_weight;
            k += BASE;
        }
        /* adapt */
        uint32_t delta = i - previous_i, num_points = (uint32_t)length + 1;
        delta /= previous_i == 0 ? DAMP : 2;
        delta += delta / num_points;
        uint32_t kk = 0;
        while (delta > ((BASE - T_MIN) * T_MAX) / 2) {
            delta /= BASE - T_MIN;
            kk += BASE;
        }
        bias = kk + (((BASE - T_MIN + 1) * delta) / (delta + SKEW));
        uint64_t next_cp = (uint64_t)code_point + i / ((uint32_t)length + 1);
        if (next_cp > UINT32_MAX) return -1;
        code_point = (uint32_t)next_cp;
        i %= (uint32_t)length + 1;
        if (code_point > 0x10FFFF || (code_point >= 0xD800 && code_point <= 0xDFFF)) return -1;
        if (length >= cap) return -1;
        memmove(out + i + 1, out + i, (length - i) * sizeof *out);
        out[i] = code_point;
        length++;
        i++;
    }
    return (long)length;
}

/* Checks one label of a host already known to be ASCII. */
static bool idna_label_ok(const unsigned char *label, size_t len) {
    bool punycode = len >= 4 && (label[0] | 0x20) == 'x' && (label[1] | 0x20) == 'n' && label[2] == '-' &&
                    label[3] == '-';
    if (!punycode) {
        for (size_t i = 0; i < len; i++)
            if (url_denied(label[i]) && !(label[i] >= 'A' && label[i] <= 'Z')) return false;
        return true;
    }
    enum { PUNYCODE_DECODE_MAX_INPUT_LENGTH = 2000, PUNYCODE_ENCODE_MAX_INPUT_LENGTH = 1000 };
    if (label[len - 1] == '-' || len - 4 > PUNYCODE_DECODE_MAX_INPUT_LENGTH) return false;
    size_t cap = len; /* decoded length <= encoded length */
    uint32_t *decoded = cg_malloc(cap * sizeof *decoded);
    long count = punycode_decode(label + 4, len - 4, decoded, cap);
    bool ok = count >= 0;
    bool non_ascii = false;
    for (long i = 0; ok && i < count; i++) {
        uint32_t c = decoded[i];
        if (c < 0x80) {
            if (url_denied((unsigned char)c) || c == '.') ok = false;
        } else {
            non_ascii = true;
        }
        /* ContextJ: the adapter reports every character as a virama, so only a leading joiner fails. */
        if ((c == 0x200C || c == 0x200D) && i == 0) ok = false;
    }
    if (ok && non_ascii && count > PUNYCODE_ENCODE_MAX_INPUT_LENGTH) ok = false;
    free(decoded);
    return ok;
}

/* domain_to_ascii_cow: lower-cased ASCII domain (malloc'd) or NULL. */
static char *idna_to_ascii(const unsigned char *domain, size_t len) {
    bool fast = true;
    for (size_t i = 0; i < len; i++) {
        if (domain[i] >= 0x80) return NULL;
        if (!((domain[i] >= 'a' && domain[i] <= 'z') || domain[i] == '.')) fast = false;
    }
    if (!fast) {
        size_t start = 0;
        for (size_t i = 0; i <= len; i++) {
            if (i == len || domain[i] == '.') {
                if (!idna_label_ok(domain + start, i - start)) return NULL;
                start = i + 1;
            }
        }
    }
    char *out = cg_malloc(len + 1);
    for (size_t i = 0; i < len; i++) {
        unsigned char c = domain[i];
        out[i] = (char)((c >= 'A' && c <= 'Z') ? c + 32 : c);
    }
    out[len] = 0;
    return out;
}

/* ---- IPv4 / IPv6 (host.rs) */

/* 1: number, 0: overflow (Ok(None)), -1: not a number. */
static int parse_ipv4number(const char *input, size_t len, uint32_t *out) {
    if (len == 0) return -1;
    int radix = 10;
    if (len >= 2 && input[0] == '0' && (input[1] == 'x' || input[1] == 'X')) {
        input += 2;
        len -= 2;
        radix = 16;
    } else if (len >= 2 && input[0] == '0') {
        input += 1;
        len -= 1;
        radix = 8;
    }
    if (len == 0) {
        *out = 0;
        return 1;
    }
    uint64_t value = 0;
    bool overflow = false;
    for (size_t i = 0; i < len; i++) {
        char c = input[i];
        int digit;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
        else return -1;
        if (digit >= radix) return -1;
        if (!overflow) {
            value = value * (uint64_t)radix + (uint64_t)digit;
            if (value > UINT32_MAX) overflow = true;
        }
    }
    if (overflow) return 0;
    *out = (uint32_t)value;
    return 1;
}

static bool ends_in_a_number(const char *input) {
    size_t len = strlen(input);
    const char *last_start;
    size_t last_len;
    const char *dot = len ? last_byte(input, '.', len) : NULL;
    if (dot) {
        last_start = dot + 1;
        last_len = (size_t)(input + len - last_start);
    } else {
        last_start = input;
        last_len = len;
    }
    if (last_len == 0) {
        if (!dot) return false;
        size_t before = (size_t)(dot - input);
        const char *prev = before ? last_byte(input, '.', before) : NULL;
        last_start = prev ? prev + 1 : input;
        last_len = (size_t)(dot - last_start);
    }
    if (last_len > 0) {
        bool digits = true;
        for (size_t i = 0; i < last_len; i++)
            if (last_start[i] < '0' || last_start[i] > '9') digits = false;
        if (digits) return true;
    }
    uint32_t ignored;
    return parse_ipv4number(last_start, last_len, &ignored) >= 0;
}

static cg_url_error parse_ipv4addr(const char *input, uint32_t *out) {
    size_t len = strlen(input);
    const char *parts[5];
    size_t lens[5], count = 0;
    size_t start = 0;
    for (size_t i = 0; i <= len; i++) {
        if (i == len || input[i] == '.') {
            if (count == 5) return CG_URL_INVALID_IPV4;
            parts[count] = input + start;
            lens[count] = i - start;
            count++;
            start = i + 1;
        }
    }
    if (count > 0 && lens[count - 1] == 0) count--;
    if (count > 4 || count == 0) return CG_URL_INVALID_IPV4;
    uint32_t numbers[4];
    for (size_t i = 0; i < count; i++)
        if (parse_ipv4number(parts[i], lens[i], &numbers[i]) != 1) return CG_URL_INVALID_IPV4;
    uint32_t ipv4 = numbers[count - 1];
    size_t others = count - 1;
    if (others > 0 && ipv4 > (UINT32_MAX >> (8 * others))) return CG_URL_INVALID_IPV4;
    for (size_t i = 0; i < others; i++)
        if (numbers[i] > 255) return CG_URL_INVALID_IPV4;
    for (size_t i = 0; i < others; i++) ipv4 += numbers[i] << (8 * (3 - i));
    *out = ipv4;
    return CG_URL_OK;
}

static int hex_digit(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static cg_url_error parse_ipv6addr(const unsigned char *input, size_t len, uint16_t pieces[8]) {
    memset(pieces, 0, 8 * sizeof *pieces);
    bool is_ipv4 = false;
    size_t piece_pointer = 0, i = 0;
    long compress_pointer = -1;
    if (len < 2) return CG_URL_INVALID_IPV6;
    if (input[0] == ':') {
        if (input[1] != ':') return CG_URL_INVALID_IPV6;
        i = 2;
        piece_pointer = 1;
        compress_pointer = 1;
    }
    while (i < len) {
        if (piece_pointer == 8) return CG_URL_INVALID_IPV6;
        if (input[i] == ':') {
            if (compress_pointer >= 0) return CG_URL_INVALID_IPV6;
            i++;
            piece_pointer++;
            compress_pointer = (long)piece_pointer;
            continue;
        }
        size_t start = i, end = start + 4 < len ? start + 4 : len;
        uint16_t value = 0;
        while (i < end) {
            int digit = hex_digit(input[i]);
            if (digit < 0) break;
            value = (uint16_t)(value * 0x10 + digit);
            i++;
        }
        if (i < len) {
            if (input[i] == '.') {
                if (i == start) return CG_URL_INVALID_IPV6;
                i = start;
                if (piece_pointer > 6) return CG_URL_INVALID_IPV6;
                is_ipv4 = true;
            } else if (input[i] == ':') {
                i++;
                if (i == len) return CG_URL_INVALID_IPV6;
            } else {
                return CG_URL_INVALID_IPV6;
            }
        }
        if (is_ipv4) break;
        pieces[piece_pointer++] = value;
    }
    if (is_ipv4) {
        if (piece_pointer > 6) return CG_URL_INVALID_IPV6;
        int numbers_seen = 0;
        while (i < len) {
            if (numbers_seen > 0) {
                if (numbers_seen < 4 && i < len && input[i] == '.') i++;
                else return CG_URL_INVALID_IPV6;
            }
            int ipv4_piece = -1;
            while (i < len && input[i] >= '0' && input[i] <= '9') {
                int digit = input[i] - '0';
                if (ipv4_piece < 0) ipv4_piece = digit;
                else if (ipv4_piece == 0) return CG_URL_INVALID_IPV6;
                else {
                    ipv4_piece = ipv4_piece * 10 + digit;
                    if (ipv4_piece > 255) return CG_URL_INVALID_IPV6;
                }
                i++;
            }
            if (ipv4_piece < 0) return CG_URL_INVALID_IPV6;
            pieces[piece_pointer] = (uint16_t)(pieces[piece_pointer] * 0x100 + ipv4_piece);
            numbers_seen++;
            if (numbers_seen == 2 || numbers_seen == 4) piece_pointer++;
        }
        if (numbers_seen != 4) return CG_URL_INVALID_IPV6;
    }
    if (i < len) return CG_URL_INVALID_IPV6;
    if (compress_pointer >= 0) {
        size_t swaps = piece_pointer - (size_t)compress_pointer;
        piece_pointer = 7;
        while (swaps > 0) {
            uint16_t tmp = pieces[piece_pointer];
            pieces[piece_pointer] = pieces[(size_t)compress_pointer + swaps - 1];
            pieces[(size_t)compress_pointer + swaps - 1] = tmp;
            swaps--;
            piece_pointer--;
        }
    } else if (piece_pointer != 8) {
        return CG_URL_INVALID_IPV6;
    }
    return CG_URL_OK;
}

static void write_ipv6(cg_buf *s, const uint16_t pieces[8]) {
    /* longest_zero_sequence */
    int longest = -1, longest_length = -1, start = -1;
    for (int i = 0; i <= 8; i++) {
        if (i < 8 && pieces[i] == 0) {
            if (start < 0) start = i;
        } else {
            if (start >= 0 && i - start > longest_length) {
                longest = start;
                longest_length = i - start;
            }
            start = -1;
        }
    }
    int compress_start = -1, compress_end = -2;
    if (longest_length >= 2) {
        compress_start = longest;
        compress_end = longest + longest_length;
    }
    cg_buf_putc(s, '[');
    int i = 0;
    while (i < 8) {
        if (i == compress_start) {
            cg_buf_putc(s, ':');
            if (i == 0) cg_buf_putc(s, ':');
            if (compress_end < 8) i = compress_end;
            else break;
        }
        cg_buf_printf(s, "%x", pieces[i]);
        if (i < 7) cg_buf_putc(s, ':');
        i++;
    }
    cg_buf_putc(s, ']');
}

/* Host::parse_cow for special schemes; writes the host serialization. */
static cg_url_error parse_special_host(const char *input, size_t len, cg_buf *s, cg_url *url) {
    if (len > 0 && input[0] == '[') {
        if (len < 2 || input[len - 1] != ']') return CG_URL_INVALID_IPV6;
        cg_url_error error = parse_ipv6addr((const unsigned char *)input + 1, len - 2, url->ipv6);
        if (error) return error;
        url->host = CG_URL_HOST_IPV6;
        write_ipv6(s, url->ipv6);
        return CG_URL_OK;
    }
    /* percent_decode */
    unsigned char *decoded = cg_malloc(len + 1);
    size_t n = 0;
    for (size_t i = 0; i < len; i++) {
        if (input[i] == '%' && i + 2 < len) {
            int high = hex_digit((unsigned char)input[i + 1]);
            int low = hex_digit((unsigned char)input[i + 2]);
            if (high >= 0 && low >= 0) {
                decoded[n++] = (unsigned char)(high * 16 + low);
                i += 2;
                continue;
            }
        }
        decoded[n++] = (unsigned char)input[i];
    }
    char *domain = idna_to_ascii(decoded, n);
    free(decoded);
    if (!domain) return CG_URL_IDNA_ERROR;
    if (!*domain) {
        free(domain);
        return CG_URL_EMPTY_HOST;
    }
    if (ends_in_a_number(domain)) {
        cg_url_error error = parse_ipv4addr(domain, &url->ipv4);
        free(domain);
        if (error) return error;
        url->host = CG_URL_HOST_IPV4;
        cg_buf_printf(s, "%u.%u.%u.%u", url->ipv4 >> 24, (url->ipv4 >> 16) & 255, (url->ipv4 >> 8) & 255,
                      url->ipv4 & 255);
        return CG_URL_OK;
    }
    url->host = CG_URL_HOST_DOMAIN;
    cg_buf_puts(s, domain);
    free(domain);
    return CG_URL_OK;
}

/* ---- parser (special, non-file schemes) */

typedef struct {
    cg_buf s;
    const cg_url *base;
} parser;

static cg_url_error parse_query_and_fragment(parser *p, url_in in, cg_url *url) {
    url->query_start = -1;
    url->fragment_start = -1;
    int c = in_next(&in);
    if (c < 0) return CG_URL_OK;
    if (c == '?') {
        url->query_start = (long)p->s.len;
        cg_buf_putc(&p->s, '?');
        for (;;) {
            c = in_next(&in);
            if (c < 0) return CG_URL_OK;
            if (c == '#') break;
            put_encoded(&p->s, SET_SPECIAL_QUERY, (unsigned char)c);
        }
    }
    /* c == '#' */
    url->fragment_start = (long)p->s.len;
    cg_buf_putc(&p->s, '#');
    while ((c = in_next(&in)) >= 0) put_encoded(&p->s, SET_FRAGMENT, (unsigned char)c);
    return CG_URL_OK;
}

static bool last_slash_can_be_removed(const cg_buf *s, size_t path_start) {
    size_t before = s->len - 1;
    const char *slash = before ? last_byte(s->data, '/', before) : NULL;
    return slash && (size_t)(slash - s->data) >= path_start;
}

static void pop_path(cg_buf *s, size_t path_start) {
    if (s->len > path_start) {
        const char *slash = last_byte(s->data + path_start, '/', s->len - path_start);
        size_t segment_start = (size_t)(slash - s->data) + 1;
        s->len = segment_start;
        s->data[s->len] = 0;
    }
}

static void shorten_path(cg_buf *s, size_t path_start) {
    if (s->len == path_start) return;
    pop_path(s, path_start);
}

static bool ends_with_slash(const cg_buf *s) { return s->len > 0 && s->data[s->len - 1] == '/'; }

static bool segment_is(const char *segment, size_t len, const char *const *options) {
    for (; *options; options++)
        if (strlen(*options) == len && memcmp(*options, segment, len) == 0) return true;
    return false;
}

static url_in parse_path(parser *p, size_t path_start, url_in in) {
    static const char *const double_dot[] = {"..",   "%2e%2e", "%2e%2E", "%2E%2e", "%2E%2E",
                                             "%2e.", "%2E.",   ".%2e",   ".%2E",   NULL};
    static const char *const single_dot[] = {".", "%2e", "%2E", NULL};
    cg_buf *s = &p->s;
    for (;;) {
        size_t segment_start = s->len;
        bool slash = false;
        for (;;) {
            url_in before = in;
            int c = in_next(&in);
            if (c < 0) break;
            if (c == '/' || c == '\\') {
                cg_buf_putc(s, '/');
                slash = true;
                break;
            }
            if (c == '?' || c == '#') {
                in = before;
                break;
            }
            put_encoded(s, SET_PATH, (unsigned char)c);
        }
        size_t segment_len = s->len - segment_start - (slash ? 1 : 0);
        const char *segment = s->data ? s->data + segment_start : "";
        if (segment_is(segment, segment_len, double_dot)) {
            s->len = segment_start;
            s->data[s->len] = 0;
            if (ends_with_slash(s) && last_slash_can_be_removed(s, path_start)) {
                s->len--;
                s->data[s->len] = 0;
            }
            shorten_path(s, path_start);
            if (slash && !ends_with_slash(s)) cg_buf_putc(s, '/');
        } else if (segment_is(segment, segment_len, single_dot)) {
            s->len = segment_start;
            s->data[s->len] = 0;
            if (!ends_with_slash(s)) cg_buf_putc(s, '/');
        }
        if (!slash) break;
    }
    return in;
}

static url_in parse_path_start(parser *p, url_in in) {
    size_t path_start = p->s.len;
    url_in rest = in;
    int c = in_next(&rest);
    if (!ends_with_slash(&p->s)) {
        cg_buf_putc(&p->s, '/');
        if (c == '/' || c == '\\') return parse_path(p, path_start, rest);
    }
    return parse_path(p, path_start, in);
}

static cg_url_error parse_userinfo(parser *p, url_in *in, size_t *username_end) {
    url_in scan = *in, after_at = *in;
    long last_at = -1, count = 0;
    int c;
    while ((c = in_next(&scan)) >= 0) {
        if (c == '@') {
            last_at = count;
            after_at = scan;
        } else if (c == '/' || c == '?' || c == '#' || c == '\\') {
            break;
        }
        count++;
    }
    if (last_at < 0) {
        *username_end = p->s.len;
        return CG_URL_OK;
    }
    if (last_at == 0) {
        int next = in_peek(after_at);
        if (next == '/' || next == '?' || next == '#' || next == '\\') return CG_URL_EMPTY_HOST;
        *username_end = p->s.len;
        *in = after_at;
        return CG_URL_OK;
    }
    long remaining = last_at;
    long user_end = -1;
    bool has_password = false, has_username = false;
    url_in read = *in;
    while (remaining > 0) {
        c = in_next(&read);
        remaining--;
        if (c == ':' && user_end < 0) {
            user_end = (long)p->s.len;
            if (remaining > 0) {
                cg_buf_putc(&p->s, ':');
                has_password = true;
            }
        } else {
            if (!has_password) has_username = true;
            put_encoded(&p->s, SET_USERINFO, (unsigned char)c);
        }
    }
    *username_end = user_end >= 0 ? (size_t)user_end : p->s.len;
    if (has_username || has_password) cg_buf_putc(&p->s, '@');
    *in = after_at;
    return CG_URL_OK;
}

static cg_url_error parse_host_and_port(parser *p, url_in *in, size_t scheme_end, cg_url *url) {
    /* Host end: ':' outside brackets, '\', '/', '?', '#'; tabs and newlines are ignored. */
    cg_buf host = {0};
    bool inside_brackets = false;
    const char *q = in->p;
    for (; q < in->end; q++) {
        unsigned char c = (unsigned char)*q;
        if (c == ':' && !inside_brackets) break;
        if (c == '\\' || c == '/' || c == '?' || c == '#') break;
        if (tab_or_newline(c)) continue;
        if (c == '[') inside_brackets = true;
        if (c == ']') inside_brackets = false;
        cg_buf_putc(&host, (char)c);
    }
    in->p = q;
    if (host.len == 0) {
        cg_buf_free(&host);
        return CG_URL_EMPTY_HOST;
    }
    cg_url_error error = parse_special_host(host.data, host.len, &p->s, url);
    cg_buf_free(&host);
    if (error) return error;
    url->host_end = p->s.len;
    url->port = -1;
    url_in rest = *in;
    if (in_next(&rest) == ':') {
        *in = rest;
        unsigned long port = 0;
        bool any_digit = false;
        for (;;) {
            url_in next = *in;
            int c = in_next(&next);
            if (c < 0) break;
            if (c >= '0' && c <= '9') {
                port = port * 10 + (unsigned long)(c - '0');
                if (port > 65535) return CG_URL_INVALID_PORT;
                any_digit = true;
            } else if (c != '/' && c != '\\' && c != '?' && c != '#') {
                return CG_URL_INVALID_PORT;
            } else {
                break;
            }
            *in = next;
        }
        if (any_digit && (int)port != default_port(p->s.data, scheme_end)) {
            url->port = (int)port;
            cg_buf_printf(&p->s, ":%lu", port);
        }
    }
    return CG_URL_OK;
}

static cg_url_error after_double_slash(parser *p, url_in in, size_t scheme_end, cg_url *url) {
    cg_buf_puts(&p->s, "//");
    cg_url_error error = parse_userinfo(p, &in, &url->username_end);
    if (error) return error;
    url->host_start = p->s.len;
    error = parse_host_and_port(p, &in, scheme_end, url);
    if (error) return error;
    url->path_start = p->s.len;
    in = parse_path_start(p, in);
    url->scheme_end = scheme_end;
    return parse_query_and_fragment(p, in, url);
}

/* Copies the base layout (scheme to path start) into url. */
static void inherit(cg_url *url, const cg_url *base) {
    url->scheme_end = base->scheme_end;
    url->username_end = base->username_end;
    url->host_start = base->host_start;
    url->host_end = base->host_end;
    url->host = base->host;
    url->ipv4 = base->ipv4;
    memcpy(url->ipv6, base->ipv6, sizeof url->ipv6);
    url->port = base->port;
    url->path_start = base->path_start;
}

static size_t before_query(const cg_url *base) {
    if (base->query_start >= 0) return (size_t)base->query_start;
    if (base->fragment_start >= 0) return (size_t)base->fragment_start;
    return base->len;
}

static cg_url_error fragment_only(parser *p, const cg_url *base, url_in in, cg_url *url) {
    size_t before = base->fragment_start >= 0 ? (size_t)base->fragment_start : base->len;
    cg_buf_put(&p->s, base->serialization, before);
    inherit(url, base);
    url->query_start = base->query_start;
    url->fragment_start = (long)before;
    cg_buf_putc(&p->s, '#');
    in_next(&in); /* '#' */
    int c;
    while ((c = in_next(&in)) >= 0) put_encoded(&p->s, SET_FRAGMENT, (unsigned char)c);
    return CG_URL_OK;
}

static cg_url_error parse_relative(parser *p, url_in in, const cg_url *base, cg_url *url) {
    url_in after_first = in;
    int first = in_next(&after_first);
    if (first < 0) {
        size_t before = base->fragment_start >= 0 ? (size_t)base->fragment_start : base->len;
        cg_buf_put(&p->s, base->serialization, before);
        inherit(url, base);
        url->query_start = base->query_start;
        url->fragment_start = -1;
        return CG_URL_OK;
    }
    if (first == '?') {
        cg_buf_put(&p->s, base->serialization, before_query(base));
        inherit(url, base);
        return parse_query_and_fragment(p, in, url);
    }
    if (first == '#') return fragment_only(p, base, in, url);
    if (first == '/' || first == '\\') {
        url_in remaining = in;
        int slashes = 0;
        for (;;) {
            url_in next = remaining;
            int c = in_next(&next);
            if (c != '/' && c != '\\') break;
            remaining = next;
            slashes++;
        }
        if (slashes >= 2) {
            cg_buf_put(&p->s, base->serialization, base->scheme_end + 1);
            url_in after_prefix = in;
            if (in_split_prefix(&after_prefix, "//")) return after_double_slash(p, after_prefix, base->scheme_end, url);
            return after_double_slash(p, remaining, base->scheme_end, url);
        }
        cg_buf_put(&p->s, base->serialization, base->path_start);
        cg_buf_putc(&p->s, '/');
        inherit(url, base);
        url_in rest = parse_path(p, base->path_start, after_first);
        return parse_query_and_fragment(p, rest, url);
    }
    cg_buf_put(&p->s, base->serialization, before_query(base));
    pop_path(&p->s, base->path_start);
    if (p->s.len == base->path_start) cg_buf_putc(&p->s, '/');
    inherit(url, base);
    url_in rest = parse_path(p, base->path_start, in);
    return parse_query_and_fragment(p, rest, url);
}

/* Other schemes: the client refuses them; keep the text and whether a host is present. */
static cg_url_error parse_opaque(parser *p, url_in in, size_t scheme_end, scheme_type type, cg_url *url) {
    url->opaque = true;
    url->scheme_end = scheme_end;
    url->query_start = url->fragment_start = -1;
    url->port = -1;
    url_in rest = in;
    bool authority = type == SCHEME_FILE ? false : in_split_prefix(&rest, "//");
    if (type == SCHEME_FILE) {
        int a = in_next(&rest), b = in_next(&rest);
        authority = (a == '/' || a == '\\') && (b == '/' || b == '\\');
    }
    url->host = CG_URL_HOST_NONE;
    if (authority) {
        cg_buf host = {0};
        int c;
        bool brackets = false;
        while ((c = in_next(&rest)) >= 0) {
            if (c == '/' || c == '?' || c == '#' || (type == SCHEME_FILE && c == '\\')) break;
            if (c == '@' && type != SCHEME_FILE) {
                host.len = 0;
                continue;
            }
            if (c == '[') brackets = true;
            if (c == ']') brackets = false;
            if (c == ':' && !brackets && type != SCHEME_FILE) break;
            cg_buf_putc(&host, (char)c);
        }
        bool present = host.len > 0;
        if (type == SCHEME_FILE && host.len == 9 && strncasecmp(host.data, "localhost", 9) == 0) present = false;
        if (present) url->host = CG_URL_HOST_DOMAIN;
        cg_buf_free(&host);
    }
    int c;
    while ((c = in_next(&in)) >= 0) cg_buf_putc(&p->s, (char)c);
    url->username_end = url->host_start = url->host_end = url->path_start = scheme_end + 1;
    return CG_URL_OK;
}

static cg_url_error parse_with_scheme(parser *p, url_in in, cg_url *url) {
    size_t scheme_end = p->s.len;
    scheme_type type = scheme_type_of(p->s.data, scheme_end);
    cg_buf_putc(&p->s, ':');
    if (type != SCHEME_SPECIAL) return parse_opaque(p, in, scheme_end, type, url);
    url->special = true;
    url_in remaining = in;
    int slashes = 0;
    for (;;) {
        url_in next = remaining;
        int c = in_next(&next);
        if (c != '/' && c != '\\') break;
        remaining = next;
        slashes++;
    }
    const cg_url *base = p->base;
    if (base && slashes < 2 && base->scheme_end == scheme_end &&
        memcmp(base->serialization, p->s.data, scheme_end) == 0) {
        p->s.len = 0;
        if (p->s.data) p->s.data[0] = 0;
        return parse_relative(p, in, base, url);
    }
    return after_double_slash(p, remaining, scheme_end, url);
}

/* parse_scheme: true and *in advanced past ':' when the input starts with a scheme. */
static bool parse_scheme(parser *p, url_in *in) {
    url_in scan = *in;
    int c = in_peek(scan);
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return false;
    while ((c = in_next(&scan)) >= 0) {
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.') {
            cg_buf_putc(&p->s, (char)c);
        } else if (c >= 'A' && c <= 'Z') {
            cg_buf_putc(&p->s, (char)(c + 32));
        } else if (c == ':') {
            *in = scan;
            return true;
        } else {
            break;
        }
    }
    p->s.len = 0;
    if (p->s.data) p->s.data[0] = 0;
    return false;
}

cg_url_error cg_url_parse(const char *input, const cg_url *base, cg_url *out) {
    memset(out, 0, sizeof *out);
    out->query_start = out->fragment_start = -1;
    out->port = -1;
    const char *start = input ? input : "";
    const char *end = start + strlen(start);
    while (start < end && (unsigned char)*start <= ' ') start++;
    while (end > start && (unsigned char)end[-1] <= ' ') end--;
    if ((size_t)(end - start) > UINT32_MAX) return CG_URL_OVERFLOW;
    parser p = {.s = {0}, .base = base};
    url_in in = {start, end};
    cg_url_error error;
    if (parse_scheme(&p, &in)) {
        error = parse_with_scheme(&p, in, out);
    } else if (base) {
        if (in_peek(in) == '#') error = fragment_only(&p, base, in, out);
        else if (base->opaque) error = CG_URL_RELATIVE_WITH_CANNOT_BE_A_BASE_BASE;
        else {
            out->special = true;
            error = parse_relative(&p, in, base, out);
        }
        if (!error) out->opaque = base->opaque, out->special = base->special;
    } else {
        error = CG_URL_RELATIVE_WITHOUT_BASE;
    }
    if (error) {
        cg_buf_free(&p.s);
        memset(out, 0, sizeof *out);
        out->query_start = out->fragment_start = -1;
        out->port = -1;
        return error;
    }
    out->len = p.s.len;
    out->serialization = cg_buf_take(&p.s);
    return CG_URL_OK;
}

void cg_url_clear(cg_url *url) {
    free(url->serialization);
    memset(url, 0, sizeof *url);
    url->query_start = url->fragment_start = -1;
    url->port = -1;
}

/* ---- accessors */

char *cg_url_scheme(const cg_url *url) { return cg_strndup(url->serialization, url->scheme_end); }

bool cg_url_scheme_is(const cg_url *url, const char *scheme) {
    return url->serialization && strlen(scheme) == url->scheme_end &&
           memcmp(url->serialization, scheme, url->scheme_end) == 0;
}

char *cg_url_host_str(const cg_url *url) {
    if (url->host == CG_URL_HOST_NONE) return NULL;
    if (url->opaque) return cg_strdup("");
    return cg_strndup(url->serialization + url->host_start, url->host_end - url->host_start);
}

static bool has_authority(const cg_url *url) {
    return !url->opaque && url->len >= url->scheme_end + 3 &&
           memcmp(url->serialization + url->scheme_end, "://", 3) == 0;
}

char *cg_url_username(const cg_url *url) {
    if (has_authority(url) && url->username_end > url->scheme_end + 3)
        return cg_strndup(url->serialization + url->scheme_end + 3, url->username_end - url->scheme_end - 3);
    return cg_strdup("");
}

char *cg_url_password(const cg_url *url) {
    if (has_authority(url) && url->username_end < url->len && url->serialization[url->username_end] == ':')
        return cg_strndup(url->serialization + url->username_end + 1, url->host_start - url->username_end - 2);
    return NULL;
}

char *cg_url_path(const cg_url *url) {
    size_t end = url->query_start >= 0 ? (size_t)url->query_start
                 : url->fragment_start >= 0 ? (size_t)url->fragment_start
                                            : url->len;
    return cg_strndup(url->serialization + url->path_start, end - url->path_start);
}

char *cg_url_query(const cg_url *url) {
    if (url->query_start < 0) return NULL;
    size_t end = url->fragment_start >= 0 ? (size_t)url->fragment_start : url->len;
    return cg_strndup(url->serialization + url->query_start + 1, end - (size_t)url->query_start - 1);
}

int cg_url_port_or_default(const cg_url *url) {
    if (url->port >= 0) return url->port;
    return default_port(url->serialization, url->scheme_end);
}
