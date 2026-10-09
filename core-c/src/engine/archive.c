/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Bundle archive extraction: zip-slip safe, CRC checked, symlinks only when
 * they stay inside their own directory, then the single-folder unwrap rule.
 *
 * Rust reads archives with the `zip` crate (2.4): the reader below follows its
 * rules (end record search, ZIP64, central and local headers, extra fields,
 * unicode names, duplicate names) and its error messages, which end up in the
 * "Failed to unzip <path>: <error>" messages. */

#include "engine/archive.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#include "crypto/checksum.h"
#include "paths.h"
#include "rt/sync.h"

#if defined(__aarch64__) || defined(__arm64__)
#include <arm_acle.h>
#define CG_ARM_CRC 1
#if !defined(__APPLE__)
#include <sys/auxv.h>
#ifndef HWCAP_CRC32
#define HWCAP_CRC32 (1 << 7)
#endif
#endif
#if defined(__clang__)
#define CG_TARGET_CRC __attribute__((target("crc")))
#else
#define CG_TARGET_CRC __attribute__((target("+crc")))
#endif
#endif

/* Read buffer around the archive: large sequential reads for inflate. */
#define ARCHIVE_READ_BUFFER (1024 * 1024)
/* Output batched into large writes (Rust BufWriter capacity). */
#define ARCHIVE_WRITE_BUFFER (1024 * 1024)
/* Longest symlink target accepted (PATH_MAX on Linux and Android). */
#define MAX_SYMLINK_TARGET 4096
/* Regular files are written by this many threads at most (storage is the limit). */
#define MAX_EXTRACT_WORKERS 4
/* Smallest central directory record (signature + fixed fields, empty name). */
#define MIN_CENTRAL_RECORD 46

#define SIG_LOCAL 0x04034b50u
#define SIG_CENTRAL 0x02014b50u
#define SIG_EOCD 0x06054b50u
#define SIG_EOCD64 0x06064b50u
#define SIG_LOCATOR 0x07064b50u

/* ---- CRC-32 */

#ifdef CG_ARM_CRC
CG_TARGET_CRC static uint32_t crc32_arm(uint32_t crc, const uint8_t *p, size_t n) {
    crc = ~crc;
    while (n && ((uintptr_t)p & 7)) {
        crc = __crc32b(crc, *p++);
        n--;
    }
    while (n >= 32) {
        uint64_t a, b, c, d;
        memcpy(&a, p, 8);
        memcpy(&b, p + 8, 8);
        memcpy(&c, p + 16, 8);
        memcpy(&d, p + 24, 8);
        crc = __crc32d(crc, a);
        crc = __crc32d(crc, b);
        crc = __crc32d(crc, c);
        crc = __crc32d(crc, d);
        p += 32;
        n -= 32;
    }
    while (n >= 8) {
        uint64_t a;
        memcpy(&a, p, 8);
        crc = __crc32d(crc, a);
        p += 8;
        n -= 8;
    }
    while (n--) crc = __crc32b(crc, *p++);
    return ~crc;
}

static bool arm_crc_available(void) {
#if defined(__APPLE__)
    return true;
#else
    static atomic_int cached = -1;
    int value = atomic_load_explicit(&cached, memory_order_relaxed);
    if (value < 0) {
        value = (getauxval(AT_HWCAP) & HWCAP_CRC32) ? 1 : 0;
        atomic_store_explicit(&cached, value, memory_order_relaxed);
    }
    return value == 1;
#endif
}
#endif

uint32_t cg_archive_crc32(uint32_t crc, const uint8_t *bytes, size_t len) {
#ifdef CG_ARM_CRC
    if (arm_crc_available()) return crc32_arm(crc, bytes, len);
#endif
    while (len) {
        uInt chunk = len > (1u << 30) ? (1u << 30) : (uInt)len;
        crc = (uint32_t)crc32(crc, bytes, chunk);
        bytes += chunk;
        len -= chunk;
    }
    return crc;
}

/* ---- little endian */

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t le64(const uint8_t *p) { return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32; }

static uint64_t sat_add(uint64_t a, uint64_t b) { return a + b < a ? UINT64_MAX : a + b; }
static uint64_t sat_mul(uint64_t a, uint64_t b) { return b && a > UINT64_MAX / b ? UINT64_MAX : a * b; }

/* ---- string-keyed hash map (keys borrowed, may contain NUL) */

typedef struct {
    const char *key;
    size_t len;
    size_t value;
} map_slot;

typedef struct {
    map_slot *slots;
    size_t cap, count;
} strmap;

static uint64_t hash_bytes(const char *key, size_t len) {
    uint64_t hash = 1469598103934665603ull;
    for (size_t i = 0; i < len; i++) hash = (hash ^ (uint8_t)key[i]) * 1099511628211ull;
    return hash;
}

static map_slot *map_find(strmap *map, const char *key, size_t len) {
    if (!map->cap) return NULL;
    size_t i = (size_t)hash_bytes(key, len) & (map->cap - 1);
    while (map->slots[i].key) {
        if (map->slots[i].len == len && memcmp(map->slots[i].key, key, len) == 0) return &map->slots[i];
        i = (i + 1) & (map->cap - 1);
    }
    return NULL;
}

static void map_put(strmap *map, const char *key, size_t len, size_t value) {
    map_slot *found = map_find(map, key, len);
    if (found) {
        /* The newest key owner wins (earlier owners may be freed). */
        found->key = key;
        found->value = value;
        return;
    }
    if ((map->count + 1) * 2 > map->cap) {
        size_t cap = map->cap ? map->cap * 2 : 64;
        map_slot *slots = cg_calloc(cap, sizeof *slots);
        for (size_t i = 0; i < map->cap; i++) {
            if (!map->slots[i].key) continue;
            size_t j = (size_t)hash_bytes(map->slots[i].key, map->slots[i].len) & (cap - 1);
            while (slots[j].key) j = (j + 1) & (cap - 1);
            slots[j] = map->slots[i];
        }
        free(map->slots);
        map->slots = slots;
        map->cap = cap;
    }
    size_t i = (size_t)hash_bytes(key, len) & (map->cap - 1);
    while (map->slots[i].key) i = (i + 1) & (map->cap - 1);
    map->slots[i] = (map_slot){key, len, value};
    map->count++;
}

static void map_free(strmap *map) { free(map->slots); }

/* ---- zip crate errors (ZipError Display) */

typedef struct {
    bool io; /* ZipError::Io (extra field parsing ignores those) */
    char *msg;
} zerr;

static bool zerr_set(zerr *e, bool io, char *msg) {
    free(e->msg);
    e->io = io;
    e->msg = msg;
    return false;
}
static bool zinvalid(zerr *e, const char *what) { return zerr_set(e, false, cg_fmt("invalid Zip archive: %s", what)); }
static bool zunsupported(zerr *e, const char *what) {
    return zerr_set(e, false, cg_fmt("unsupported Zip archive: %s", what));
}
static bool zeof(zerr *e) { return zerr_set(e, true, cg_strdup("i/o error: failed to fill whole buffer")); }
static bool zos(zerr *e, int errnum) {
    char *detail = cg_io_message(errnum);
    zerr_set(e, true, cg_fmt("i/o error: %s", detail));
    free(detail);
    return false;
}
static void zerr_move(zerr *dst, zerr *src) {
    free(dst->msg);
    *dst = *src;
    src->msg = NULL;
}

/* ---- archive file with a read cache (the BufReader of the zip crate) */

typedef struct {
    int fd;
    uint64_t len;
    uint8_t *cache;
    uint64_t cache_start;
    size_t cache_len;
} zfile;

static bool zread(zfile *f, uint64_t pos, void *dst, size_t n, zerr *e) {
    if (pos > f->len || n > f->len - pos) return zeof(e);
    uint8_t *out = dst;
    while (n) {
        if (pos >= f->cache_start && pos < f->cache_start + f->cache_len) {
            size_t at = (size_t)(pos - f->cache_start);
            size_t take = f->cache_len - at < n ? f->cache_len - at : n;
            memcpy(out, f->cache + at, take);
            out += take;
            pos += take;
            n -= take;
            continue;
        }
        uint64_t want = f->len - pos < ARCHIVE_READ_BUFFER ? f->len - pos : ARCHIVE_READ_BUFFER;
        ssize_t got = cg_fsutil_pread_full(f->fd, f->cache, (size_t)want, pos);
        if (got < 0) {
            f->cache_len = 0;
            return zos(e, errno);
        }
        f->cache_start = pos;
        f->cache_len = (size_t)got;
        if (!got) return zeof(e);
    }
    return true;
}

/* Last position p in [lo, hi - 4] holding `sig`, -1 when none. */
static int64_t find_back(zfile *f, uint64_t lo, uint64_t hi, uint32_t sig, zerr *e, bool *failed) {
    uint8_t window[2048];
    uint8_t magic[4] = {(uint8_t)sig, (uint8_t)(sig >> 8), (uint8_t)(sig >> 16), (uint8_t)(sig >> 24)};
    while (hi >= lo + 4) {
        uint64_t start = hi - lo > sizeof window ? hi - sizeof window : lo;
        size_t n = (size_t)(hi - start);
        if (!zread(f, start, window, n, e)) {
            *failed = true;
            return -1;
        }
        for (size_t i = n - 4 + 1; i-- > 0;)
            if (memcmp(window + i, magic, 4) == 0) return (int64_t)(start + i);
        if (start == lo) break;
        hi = start + 3;
    }
    return -1;
}

/* First position p in [lo, hi - 4] holding `sig`, -1 when none. */
static int64_t find_forward(zfile *f, uint64_t lo, uint64_t hi, uint32_t sig, zerr *e, bool *failed) {
    uint8_t window[2048];
    uint8_t magic[4] = {(uint8_t)sig, (uint8_t)(sig >> 8), (uint8_t)(sig >> 16), (uint8_t)(sig >> 24)};
    while (hi >= lo + 4) {
        size_t n = hi - lo > sizeof window ? sizeof window : (size_t)(hi - lo);
        if (!zread(f, lo, window, n, e)) {
            *failed = true;
            return -1;
        }
        for (size_t i = 0; i + 4 <= n; i++)
            if (memcmp(window + i, magic, 4) == 0) return (int64_t)(lo + i);
        lo += n - 3;
    }
    return -1;
}

/* Magic at pos (the optimistic initial guess). */
static bool magic_at(zfile *f, uint64_t pos, uint64_t hi, uint32_t sig, zerr *e, bool *failed) {
    uint8_t bytes[4];
    if (sat_add(pos, 4) > hi) return false;
    if (!zread(f, pos, bytes, 4, e)) {
        *failed = true;
        return false;
    }
    return le32(bytes) == sig;
}

typedef struct {
    uint64_t eocd_pos;
    uint16_t disk, disk_cd, files_on_disk, files;
    uint32_t cd_offset;
    bool has64;
    uint16_t made64, need64;
    uint32_t disk64, disk_cd64;
    uint64_t files_on_disk64, files64, cd_offset64;
    uint64_t archive_offset;
} cd_end;

/* spec::find_central_directory: 1 found, 0 not found (*e), -1 I/O failure (*e). */
static int find_central_directory(zfile *f, uint64_t end_exclusive, cd_end *out, zerr *e) {
    zerr parsing = {0};
    bool failed = false;
    uint64_t hi = end_exclusive;
    int result = 0;
    while (true) {
        int64_t found = find_back(f, 0, hi, SIG_EOCD, e, &failed);
        if (failed) {
            result = -1;
            break;
        }
        if (found < 0) break;
        uint64_t pos = (uint64_t)found;
        hi = pos + 3;
        uint8_t block[22];
        zerr local = {0};
        if (!zread(f, pos, block, sizeof block, &local)) {
            if (!parsing.msg) zerr_move(&parsing, &local);
            free(local.msg);
            continue;
        }
        uint16_t comment = le16(block + 20);
        if (pos + 22 + comment > f->len) {
            if (!parsing.msg) zinvalid(&parsing, "EOCD comment exceeds file boundary");
            continue;
        }
        cd_end end = {0};
        end.eocd_pos = pos;
        end.disk = le16(block + 4);
        end.disk_cd = le16(block + 6);
        end.files_on_disk = le16(block + 8);
        end.files = le16(block + 10);
        end.cd_offset = le32(block + 16);
        bool may_be_zip64 = end.files == 0xFFFF || end.cd_offset == 0xFFFFFFFFu;
        bool has_locator = false;
        uint8_t locator[20];
        uint64_t locator_pos = 0;
        if (may_be_zip64 && pos >= 20) {
            locator_pos = pos - 20;
            zerr ignored = {0};
            has_locator = zread(f, locator_pos, locator, sizeof locator, &ignored) && le32(locator) == SIG_LOCATOR;
            free(ignored.msg);
        }
        if (!has_locator) {
            uint64_t relative = end.cd_offset;
            if (end.files == 0) {
                end.archive_offset = pos > relative ? pos - relative : 0;
                *out = end;
                result = 1;
                break;
            }
            if (relative >= pos) {
                zinvalid(&parsing, "Invalid CDFH offset in EOCD");
                continue;
            }
            int64_t cd = -1;
            if (magic_at(f, relative, pos, SIG_CENTRAL, e, &failed)) cd = (int64_t)relative;
            else if (!failed) cd = find_forward(f, relative, pos, SIG_CENTRAL, e, &failed);
            if (failed) {
                result = -1;
                break;
            }
            if (cd >= 0) {
                end.archive_offset = (uint64_t)cd - relative;
                *out = end;
                result = 1;
                break;
            }
            zinvalid(&parsing, "No CDFH found");
            continue;
        }
        uint32_t locator_disk_cd = le32(locator + 4);
        uint64_t eocd64_offset = le64(locator + 8);
        uint32_t disks = le32(locator + 16);
        if (eocd64_offset >= locator_pos) {
            zinvalid(&parsing, "Invalid EOCD64 Locator CD offset");
            continue;
        }
        if (disks > 1) {
            zinvalid(&parsing, "Multi-disk ZIP files are not supported");
            continue;
        }
        zerr local_error = {0};
        bool done = false;
        /* Optimistic guess first, then every match in order. */
        bool guess = magic_at(f, eocd64_offset, locator_pos, SIG_EOCD64, e, &failed);
        uint64_t scan = eocd64_offset;
        while (!failed) {
            int64_t candidate;
            if (guess) {
                candidate = (int64_t)eocd64_offset;
                guess = false;
            } else {
                candidate = find_forward(f, scan, locator_pos, SIG_EOCD64, e, &failed);
                if (failed || candidate < 0) break;
                scan = (uint64_t)candidate + 4;
            }
            uint64_t at = (uint64_t)candidate;
            uint64_t expected = locator_pos - at;
            uint8_t record[56];
            zerr attempt = {0};
            bool ok = zread(f, at, record, sizeof record, &attempt);
            if (ok && le32(record) != SIG_EOCD64) ok = zinvalid(&attempt, "Invalid digital signature header");
            uint64_t record_size = ok ? le64(record + 4) : 0;
            if (ok && record_size < 44) ok = zinvalid(&attempt, "Low EOCD64 record size");
            if (ok && sat_add(record_size, 12) > expected) ok = zinvalid(&attempt, "EOCD64 extends beyond EOCD64 locator");
            if (ok && (at + 56 > f->len || record_size - 44 > f->len - at - 56)) ok = zeof(&attempt);
            if (ok && le32(record + 20) != locator_disk_cd)
                ok = zinvalid(&attempt, "Invalid EOCD64: inconsistency with Locator data");
            if (ok && record_size + 12 != expected) ok = zinvalid(&attempt, "Invalid EOCD64: inconsistent length");
            if (!ok) {
                zerr_move(&local_error, &attempt);
                continue;
            }
            uint64_t files64 = le64(record + 32);
            uint64_t cd_offset64 = le64(record + 48);
            if (at < sat_add(sat_mul(files64, MIN_CENTRAL_RECORD), cd_offset64)) {
                zinvalid(&local_error, "Invalid EOCD64: inconsistent number of files");
                continue;
            }
            end.has64 = true;
            end.made64 = le16(record + 12);
            end.need64 = le16(record + 14);
            end.disk64 = le32(record + 16);
            end.disk_cd64 = le32(record + 20);
            end.files_on_disk64 = le64(record + 24);
            end.files64 = files64;
            end.cd_offset64 = cd_offset64;
            end.archive_offset = at - eocd64_offset;
            *out = end;
            done = true;
            break;
        }
        if (failed) {
            free(local_error.msg);
            result = -1;
            break;
        }
        if (done) {
            free(local_error.msg);
            result = 1;
            break;
        }
        if (local_error.msg) zerr_move(&parsing, &local_error);
        else zinvalid(&parsing, "Could not find EOCD64");
    }
    if (result == 0) {
        if (parsing.msg) zerr_move(e, &parsing);
        else zinvalid(e, "Could not find EOCD");
    }
    free(parsing.msg);
    return result;
}

/* ---- entries */

typedef struct {
    char *name; /* decoded (UTF-8), name_len bytes, may contain NUL */
    size_t name_len;
    uint64_t header_start, data_start, compressed_size, size;
    uint32_t crc32, external_attributes;
    uint16_t method;
    uint8_t system;
    bool encrypted, aes;
} zip_entry;

typedef struct {
    zfile file;
    zip_entry *entries;
    size_t count;
} zip_archive;

static void entries_free(zip_entry *entries, size_t count) {
    for (size_t i = 0; i < count; i++) free(entries[i].name);
    free(entries);
}

static void zip_close(zip_archive *za) {
    entries_free(za->entries, za->count);
    za->entries = NULL;
    za->count = 0;
    if (za->file.fd >= 0) close(za->file.fd);
    za->file.fd = -1;
    free(za->file.cache);
    za->file.cache = NULL;
}

static const uint16_t CP437[128] = {
    0x00c7, 0x00fc, 0x00e9, 0x00e2, 0x00e4, 0x00e0, 0x00e5, 0x00e7, 0x00ea, 0x00eb, 0x00e8, 0x00ef, 0x00ee,
    0x00ec, 0x00c4, 0x00c5, 0x00c9, 0x00e6, 0x00c6, 0x00f4, 0x00f6, 0x00f2, 0x00fb, 0x00f9, 0x00ff, 0x00d6,
    0x00dc, 0x00a2, 0x00a3, 0x00a5, 0x20a7, 0x0192, 0x00e1, 0x00ed, 0x00f3, 0x00fa, 0x00f1, 0x00d1, 0x00aa,
    0x00ba, 0x00bf, 0x2310, 0x00ac, 0x00bd, 0x00bc, 0x00a1, 0x00ab, 0x00bb, 0x2591, 0x2592, 0x2593, 0x2502,
    0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255d, 0x255c, 0x255b, 0x2510, 0x2514,
    0x2534, 0x252c, 0x251c, 0x2500, 0x253c, 0x255e, 0x255f, 0x255a, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550,
    0x256c, 0x2567, 0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256b, 0x256a, 0x2518, 0x250c,
    0x2588, 0x2584, 0x258c, 0x2590, 0x2580, 0x03b1, 0x00df, 0x0393, 0x03c0, 0x03a3, 0x03c3, 0x00b5, 0x03c4,
    0x03a6, 0x0398, 0x03a9, 0x03b4, 0x221e, 0x03c6, 0x03b5, 0x2229, 0x2261, 0x00b1, 0x2265, 0x2264, 0x2320,
    0x2321, 0x00f7, 0x2248, 0x00b0, 0x2219, 0x00b7, 0x221a, 0x207f, 0x00b2, 0x25a0, 0x00a0,
};

/* from_cp437 (malloc'd UTF-8; length in *out_len). */
static char *from_cp437(const uint8_t *bytes, size_t len, size_t *out_len) {
    cg_buf out = {0};
    cg_buf_reserve(&out, len + 1);
    for (size_t i = 0; i < len; i++) {
        uint32_t c = bytes[i] < 0x80 ? bytes[i] : CP437[bytes[i] - 0x80];
        if (c < 0x80) {
            cg_buf_putc(&out, (char)c);
        } else if (c < 0x800) {
            cg_buf_putc(&out, (char)(0xC0 | c >> 6));
            cg_buf_putc(&out, (char)(0x80 | (c & 0x3F)));
        } else {
            cg_buf_putc(&out, (char)(0xE0 | c >> 12));
            cg_buf_putc(&out, (char)(0x80 | ((c >> 6) & 0x3F)));
            cg_buf_putc(&out, (char)(0x80 | (c & 0x3F)));
        }
    }
    *out_len = out.len;
    return cg_buf_take(&out);
}

/* String::from_utf8_lossy (malloc'd; length in *out_len). NUL bytes are kept. */
static char *utf8_lossy(const uint8_t *bytes, size_t len, size_t *out_len) {
    if (cg_utf8_valid((const char *)bytes, len)) {
        *out_len = len;
        return cg_strndup((const char *)bytes, len);
    }
    cg_buf buf = {0};
    size_t start = 0;
    for (size_t i = 0; i <= len; i++) {
        if (i == len || bytes[i] == 0) {
            char *part = cg_utf8_lossy(bytes + start, i - start);
            cg_buf_puts(&buf, part);
            free(part);
            if (i < len) cg_buf_put(&buf, "", 1);
            start = i + 1;
        }
    }
    *out_len = buf.len;
    return cg_buf_take(&buf);
}

/* Cursor over an extra field. */
typedef struct {
    const uint8_t *data;
    size_t len, pos;
} cursor;

static bool cur_read(cursor *c, void *out, size_t n, zerr *e) {
    if (n > c->len - c->pos) {
        c->pos = c->len; /* read_exact consumes what it could */
        return zeof(e);
    }
    if (out) memcpy(out, c->data + c->pos, n);
    c->pos += n;
    return true;
}

static bool cur_u16(cursor *c, uint16_t *v, zerr *e) {
    uint8_t b[2];
    if (!cur_read(c, b, 2, e)) return false;
    *v = le16(b);
    return true;
}
static bool cur_u32(cursor *c, uint32_t *v, zerr *e) {
    uint8_t b[4];
    if (!cur_read(c, b, 4, e)) return false;
    *v = le32(b);
    return true;
}
static bool cur_u64(cursor *c, uint64_t *v, zerr *e) {
    uint8_t b[8];
    if (!cur_read(c, b, 8, e)) return false;
    *v = le64(b);
    return true;
}

typedef struct {
    zip_entry *entry;
    uint8_t *name_raw;
    size_t name_raw_len;
    char *comment;
    size_t comment_len;
} parse_state;

/* UnicodeExtraField::try_from_reader + unwrap_valid + String::from_utf8. */
static bool unicode_field(cursor *c, uint16_t len, const uint8_t *checked, size_t checked_len, uint8_t **content,
                          size_t *content_len, zerr *e) {
    uint32_t crc;
    if (!cur_read(c, NULL, 1, e) || !cur_u32(c, &crc, e)) return false;
    if (len < 5) return zinvalid(e, "Unicode extra field is too small");
    size_t n = (size_t)len - 5;
    const uint8_t *start = c->data + c->pos;
    if (!cur_read(c, NULL, n, e)) return false;
    if (crc != cg_archive_crc32(0, checked, checked_len))
        return zinvalid(e, "CRC32 checksum failed on Unicode extra field");
    if (!cg_utf8_valid((const char *)start, n)) return zinvalid(e, "Invalid UTF-8");
    *content = cg_malloc(n + 1);
    memcpy(*content, start, n);
    (*content)[n] = 0;
    *content_len = n;
    return true;
}

/* parse_single_extra_field. */
static bool parse_extra(cursor *c, parse_state *s, zerr *e) {
    zip_entry *entry = s->entry;
    uint16_t kind, len;
    if (!cur_u16(c, &kind, e) || !cur_u16(c, &len, e)) return false;
    switch (kind) {
    case 0x0001: { /* ZIP64 extended information */
        size_t consumed = 0;
        if (len >= 24 || entry->size == 0xFFFFFFFFu) {
            if (!cur_u64(c, &entry->size, e)) return false;
            consumed += 8;
        }
        if (len >= 24 || entry->compressed_size == 0xFFFFFFFFu) {
            if (!cur_u64(c, &entry->compressed_size, e)) return false;
            consumed += 8;
        }
        if (len >= 24 || entry->header_start == 0xFFFFFFFFu) {
            if (!cur_u64(c, &entry->header_start, e)) return false;
            consumed += 8;
        }
        if (consumed > len) return zinvalid(e, "ZIP64 extra-data field is the wrong length");
        return cur_read(c, NULL, len - consumed, e);
    }
    case 0x000a: { /* NTFS */
        if (len != 32) return zunsupported(e, "NTFS extra field has an unsupported length");
        uint32_t reserved;
        uint16_t tag, size;
        if (!cur_u32(c, &reserved, e) || !cur_u16(c, &tag, e)) return false;
        if (tag != 1) return zunsupported(e, "NTFS extra field has an unsupported attribute tag");
        if (!cur_u16(c, &size, e)) return false;
        if (size != 24) return zunsupported(e, "NTFS extra field has an unsupported attribute size");
        return cur_read(c, NULL, 24, e);
    }
    case 0x9901: { /* AES */
        if (len != 7) return zunsupported(e, "AES extra data field has an unsupported length");
        uint16_t vendor_version, vendor_id, method;
        uint8_t mode;
        if (!cur_u16(c, &vendor_version, e) || !cur_u16(c, &vendor_id, e) || !cur_read(c, &mode, 1, e) ||
            !cur_u16(c, &method, e))
            return false;
        if (vendor_id != 0x4541) return zinvalid(e, "Invalid AES vendor");
        if (vendor_version != 1 && vendor_version != 2) return zinvalid(e, "Invalid AES vendor version");
        if (mode < 1 || mode > 3) return zinvalid(e, "Invalid AES encryption strength");
        entry->aes = true;
        entry->method = method;
        return true;
    }
    case 0x5455: { /* extended timestamp */
        uint8_t flags;
        if (!cur_read(c, &flags, 1, e)) return false;
        if (len != 5 && len != 1 + 4 * (uint32_t)__builtin_popcount(flags))
            return zunsupported(e, "flags and len don't match in extended timestamp field");
        if (flags & 0xF8) return zunsupported(e, "found unsupported timestamps in the extended timestamp header");
        if (((flags & 1) || len == 5) && !cur_read(c, NULL, 4, e)) return false;
        if ((flags & 2) && len > 5 && !cur_read(c, NULL, 4, e)) return false;
        if ((flags & 4) && len > 5 && !cur_read(c, NULL, 4, e)) return false;
        return true;
    }
    case 0x6375: { /* Info-ZIP Unicode Comment */
        uint8_t *content;
        size_t content_len;
        if (!unicode_field(c, len, (const uint8_t *)s->comment, s->comment_len, &content, &content_len, e))
            return false;
        free(s->comment);
        s->comment = (char *)content;
        s->comment_len = content_len;
        return true;
    }
    case 0x7075: { /* Info-ZIP Unicode Path */
        uint8_t *content;
        size_t content_len;
        if (!unicode_field(c, len, s->name_raw, s->name_raw_len, &content, &content_len, e)) return false;
        free(s->name_raw);
        s->name_raw = content;
        s->name_raw_len = content_len;
        free(entry->name);
        entry->name = cg_strndup((const char *)content, content_len);
        entry->name_len = content_len;
        return true;
    }
    default:
        return cur_read(c, NULL, len, e);
    }
}

/* central_header_to_zip_file: one central record at *pos. */
static bool read_central_entry(zfile *f, uint64_t *pos, uint64_t archive_offset, uint64_t directory_start,
                               zip_entry *entry, zerr *e) {
    uint8_t block[46];
    memset(entry, 0, sizeof *entry);
    if (!zread(f, *pos, block, sizeof block, e)) return false;
    if (le32(block) != SIG_CENTRAL) return zinvalid(e, "Invalid Central Directory header");
    uint16_t version_made_by = le16(block + 4);
    uint16_t flags = le16(block + 8);
    entry->method = le16(block + 10);
    entry->crc32 = le32(block + 16);
    entry->compressed_size = le32(block + 20);
    entry->size = le32(block + 24);
    size_t name_len = le16(block + 28), extra_len = le16(block + 30), comment_len = le16(block + 32);
    entry->external_attributes = le32(block + 38);
    entry->header_start = le32(block + 42);
    entry->system = (uint8_t)(version_made_by >> 8);
    entry->encrypted = flags & 1;
    bool is_utf8 = flags & (1 << 11);
    uint64_t at = *pos + 46;
    parse_state s = {.entry = entry};
    s.name_raw = cg_malloc(name_len + 1);
    uint8_t *extra = cg_malloc(extra_len + 1);
    uint8_t *comment_raw = cg_malloc(comment_len + 1);
    bool ok = zread(f, at, s.name_raw, name_len, e) && zread(f, at + name_len, extra, extra_len, e) &&
              zread(f, at + name_len + extra_len, comment_raw, comment_len, e);
    if (ok) {
        s.name_raw_len = name_len;
        entry->name = is_utf8 ? utf8_lossy(s.name_raw, name_len, &entry->name_len)
                              : from_cp437(s.name_raw, name_len, &entry->name_len);
        s.comment = is_utf8 ? utf8_lossy(comment_raw, comment_len, &s.comment_len)
                            : from_cp437(comment_raw, comment_len, &s.comment_len);
        *pos = at + name_len + extra_len + comment_len;
        cursor c = {extra, extra_len, 0};
        zerr extra_error = {0};
        while (c.pos < c.len) {
            if (!parse_extra(&c, &s, &extra_error)) {
                /* I/O errors (truncated fields) end the parsing silently. */
                if (!extra_error.io) {
                    zerr_move(e, &extra_error);
                    ok = false;
                }
                break;
            }
        }
        free(extra_error.msg);
    }
    /* CompressionMethod::AES without the feature is Unsupported(99). */
    if (ok && entry->method == 99 && !entry->aes) ok = zinvalid(e, "AES encryption without AES extra data field");
    if (ok) {
        if (entry->header_start + archive_offset < entry->header_start) ok = zinvalid(e, "Archive header is too large");
        else entry->header_start += archive_offset;
    }
    free(s.name_raw);
    free(s.comment);
    free(extra);
    free(comment_raw);
    if (ok && entry->header_start >= directory_start)
        ok = zinvalid(e, "A local file entry can't start after the central directory");
    if (ok) {
        uint8_t local[30];
        ok = zread(f, entry->header_start, local, sizeof local, e);
        if (ok && le32(local) != SIG_LOCAL) ok = zinvalid(e, "Invalid local file header");
        if (ok) {
            entry->data_start = entry->header_start + 30 + le16(local + 26) + le16(local + 28);
            if (entry->data_start > directory_start)
                ok = zinvalid(e, "File data can't start after the central directory");
        }
    }
    if (!ok) {
        free(entry->name);
        entry->name = NULL;
    }
    return ok;
}

/* CentralDirectoryInfo::try_from + read_central_header (duplicate names keep the first position
 * with the last record, like the crate's IndexMap). */
static bool read_central_directory(zfile *f, const cd_end *end, zip_entry **out, size_t *count, zerr *e) {
    uint64_t relative, files;
    uint32_t disk, disk_cd;
    if (end->has64) {
        if (end->files_on_disk64 > end->files64)
            return zinvalid(e, "ZIP64 footer indicates more files on this disk than in the whole archive");
        if (end->need64 > end->made64)
            return zinvalid(e, "ZIP64 footer indicates a new version is needed to extract this archive than the "
                               "version that wrote it");
        relative = end->cd_offset64;
        files = end->files64;
        disk = end->disk64;
        disk_cd = end->disk_cd64;
    } else {
        relative = end->cd_offset;
        files = end->files_on_disk;
        disk = end->disk;
        disk_cd = end->disk_cd;
    }
    if (relative + end->archive_offset < relative) return zinvalid(e, "Invalid central directory size or offset");
    uint64_t directory_start = relative + end->archive_offset;
    if (disk != disk_cd) return zunsupported(e, "Support for multi-disk files is not implemented");
    zip_entry *entries = NULL;
    size_t len = 0, cap = 0;
    strmap names = {0};
    uint64_t pos = directory_start;
    bool ok = true;
    for (uint64_t i = 0; i < files; i++) {
        zip_entry entry;
        if (!read_central_entry(f, &pos, end->archive_offset, directory_start, &entry, e)) {
            ok = false;
            break;
        }
        map_slot *existing = map_find(&names, entry.name, entry.name_len);
        if (existing) {
            zip_entry *slot = &entries[existing->value];
            free(slot->name);
            *slot = entry;
            existing->key = slot->name; /* same bytes, new owner */
            continue;
        }
        if (len == cap) {
            cap = cap ? cap * 2 : 64;
            /* The map borrows the names, which do not move with the array. */
            entries = cg_realloc(entries, cap * sizeof *entries);
        }
        entries[len] = entry;
        map_put(&names, entries[len].name, entries[len].name_len, len);
        len++;
    }
    map_free(&names);
    if (!ok) {
        entries_free(entries, len);
        return false;
    }
    *out = entries;
    *count = len;
    return true;
}

/* archive.rs check_declared_entries: a forged entry count is rejected before reading entries.
 * NULL when fine, else the io::Error message (malloc'd). */
static char *check_declared_entries(int fd, uint64_t len) {
    uint64_t tail_len = len < 22 + 0xFFFF ? len : 22 + 0xFFFF;
    uint8_t *tail = cg_malloc((size_t)tail_len + 1);
    ssize_t got = cg_fsutil_pread_full(fd, tail, (size_t)tail_len, len - tail_len);
    if (got < 0 || (uint64_t)got != tail_len) {
        free(tail);
        return got < 0 ? cg_io_message(errno) : cg_strdup("failed to fill whole buffer");
    }
    int64_t end = -1;
    for (int64_t at = (int64_t)(tail_len > 21 ? tail_len - 21 : 0) - 1; at >= 0; at--) {
        if (le32(tail + at) == SIG_EOCD) {
            end = at;
            break;
        }
    }
    char *message = NULL;
    if (end >= 0) {
        uint64_t entries = le16(tail + end + 10);
        if (entries == 0xFFFF && end >= 20 && le32(tail + end - 20) == SIG_LOCATOR) {
            uint64_t offset = le64(tail + end - 12);
            if (sat_add(offset, 40) <= len) {
                uint8_t record[40];
                got = cg_fsutil_pread_full(fd, record, sizeof record, offset);
                if (got < 0 || got != (ssize_t)sizeof record) {
                    free(tail);
                    return got < 0 ? cg_io_message(errno) : cg_strdup("failed to fill whole buffer");
                }
                if (le32(record) == SIG_EOCD64) entries = le64(record + 32);
            }
        }
        if (sat_mul(entries, MIN_CENTRAL_RECORD) > len)
            message = cg_fmt("archive declares %llu entries, more than its size can hold", (unsigned long long)entries);
    }
    free(tail);
    return message;
}

/* open_archive: NULL on success, else the error display (malloc'd). */
static char *zip_open(const char *path, zip_archive *za) {
    memset(za, 0, sizeof *za);
    za->file.fd = cg_fsutil_open(path, O_RDONLY, 0);
    if (za->file.fd < 0) return cg_io_message(errno);
    struct stat st;
    if (fstat(za->file.fd, &st) != 0) {
        char *message = cg_io_message(errno);
        zip_close(za);
        return message;
    }
    za->file.len = (uint64_t)st.st_size;
    char *message = check_declared_entries(za->file.fd, za->file.len);
    if (message) {
        zip_close(za);
        return message;
    }
    za->file.cache = cg_malloc(ARCHIVE_READ_BUFFER);
    uint64_t end_exclusive = za->file.len;
    zerr e = {0};
    while (true) {
        cd_end end;
        int found = find_central_directory(&za->file, end_exclusive, &end, &e);
        if (found <= 0) break;
        if (read_central_directory(&za->file, &end, &za->entries, &za->count, &e)) {
            free(e.msg);
            /* The cache is only needed while reading the directory. */
            free(za->file.cache);
            za->file.cache = NULL;
            return NULL;
        }
        /* The next end record candidate must start before this one. */
        end_exclusive = end.eocd_pos;
    }
    message = e.msg ? e.msg : cg_strdup("invalid Zip archive: Could not find EOCD");
    zip_close(za);
    return message;
}

static bool entry_is_dir(const zip_entry *entry) {
    return entry->name_len && (entry->name[entry->name_len - 1] == '/' || entry->name[entry->name_len - 1] == '\\');
}

static bool entry_is_symlink(const zip_entry *entry) {
    if (!entry->external_attributes || entry->system != 3) return false;
    uint32_t mode = entry->external_attributes >> 16;
    return (mode & 0120000) == 0120000;
}

/* ZipArchive::by_index checks: NULL when the entry can be read, else the error display. */
static const char *entry_open_error(const zip_entry *entry) {
    if (entry->encrypted) return "unsupported Zip archive: Password required to decrypt file";
    if (entry->method != 0 && entry->method != 8) return "unsupported Zip archive: Compression method not supported";
    if (entry->aes) return "The password provided is incorrect";
    return NULL;
}

/* ---- entry data: Take(compressed_size) -> stored / raw inflate -> CRC check */

typedef struct {
    int fd;
    uint64_t raw_pos, raw_end;
    bool deflated;
    z_stream z;
    bool z_ready, stream_end, input_done;
    uint8_t *in;
    size_t in_cap;
    uint32_t crc, expected_crc;
} entry_stream;

static void stream_init(entry_stream *s, int fd, const zip_entry *entry, uint8_t *in, size_t in_cap) {
    memset(s, 0, sizeof *s);
    s->fd = fd;
    s->raw_pos = entry->data_start;
    s->raw_end = sat_add(entry->data_start, entry->compressed_size);
    s->deflated = entry->method == 8;
    s->in = in;
    s->in_cap = in_cap;
    s->expected_crc = entry->crc32;
}

static void stream_end(entry_stream *s) {
    if (s->z_ready) inflateEnd(&s->z);
    s->z_ready = false;
}

/* Raw bytes: > 0, 0 at the end of the entry (or file), -1 on error (errno). */
static ssize_t raw_read(entry_stream *s, uint8_t *buf, size_t cap) {
    uint64_t remaining = s->raw_end > s->raw_pos ? s->raw_end - s->raw_pos : 0;
    if ((uint64_t)cap > remaining) cap = (size_t)remaining;
    if (!cap) return 0;
    while (true) {
        ssize_t n = pread(s->fd, buf, cap, (off_t)s->raw_pos);
        if (n < 0 && errno == EINTR) continue;
        if (n > 0) s->raw_pos += (uint64_t)n;
        return n;
    }
}

/* Decompressed bytes (> 0), 0 at the end (CRC verified), -1 with *message (static or os). */
static ptrdiff_t stream_read(entry_stream *s, uint8_t *out, size_t cap, char **message) {
    size_t produced = 0;
    if (!s->deflated) {
        ssize_t n = raw_read(s, out, cap);
        if (n < 0) {
            *message = cg_io_message(errno);
            return -1;
        }
        produced = (size_t)n;
    } else if (!s->stream_end) {
        if (!s->z_ready) {
            memset(&s->z, 0, sizeof s->z);
            if (inflateInit2(&s->z, -15) != Z_OK) {
                *message = cg_strdup("corrupt deflate stream");
                return -1;
            }
            s->z_ready = true;
        }
        while (true) {
            if (!s->z.avail_in && !s->input_done) {
                ssize_t n = raw_read(s, s->in, s->in_cap);
                if (n < 0) {
                    *message = cg_io_message(errno);
                    return -1;
                }
                if (n == 0) s->input_done = true;
                s->z.next_in = s->in;
                s->z.avail_in = (uInt)n;
            }
            s->z.next_out = out + produced;
            s->z.avail_out = (uInt)(cap - produced);
            int rc = inflate(&s->z, s->input_done ? Z_FINISH : Z_NO_FLUSH);
            produced = cap - s->z.avail_out;
            if (rc == Z_STREAM_END) {
                s->stream_end = true;
                break;
            }
            if (rc != Z_OK && rc != Z_BUF_ERROR) {
                *message = cg_strdup("corrupt deflate stream");
                return -1;
            }
            if (s->input_done && !produced && cap) {
                /* flate2: no output at the end of the input without the final block. */
                *message = cg_strdup("incomplete deflate stream");
                return -1;
            }
            if (s->input_done || produced == cap) break;
            if (produced && !s->z.avail_in) break;
        }
    }
    if (produced == 0) {
        if (cap && s->crc != s->expected_crc) {
            *message = cg_strdup("Invalid checksum");
            return -1;
        }
        return 0;
    }
    s->crc = cg_archive_crc32(s->crc, out, produced);
    return (ptrdiff_t)produced;
}

/* ---- inflate reader (apk.c) */

typedef struct {
    cg_reader base;
    cg_reader *inner;
    uint8_t *in;
    size_t in_cap;
    z_stream z;
    bool ready, eof, ended;
} inflate_reader;

static ptrdiff_t inflate_reader_read(cg_reader *self, uint8_t *buf, size_t len, cg_error *err) {
    inflate_reader *r = (inflate_reader *)self;
    if (r->ended || !len) return 0;
    if (!r->ready) {
        if (inflateInit2(&r->z, -15) != Z_OK) {
            cg_fsutil_io_error(err, CG_IO_INVALID_INPUT, "corrupt deflate stream");
            return -1;
        }
        r->ready = true;
    }
    if (len > (1u << 30)) len = 1u << 30;
    while (true) {
        if (!r->z.avail_in && !r->eof) {
            ptrdiff_t n = cg_reader_read(r->inner, r->in, r->in_cap, err);
            if (n < 0) return -1;
            if (n == 0) r->eof = true;
            r->z.next_in = r->in;
            r->z.avail_in = (uInt)n;
        }
        r->z.next_out = buf;
        r->z.avail_out = (uInt)len;
        int rc = inflate(&r->z, r->eof ? Z_FINISH : Z_NO_FLUSH);
        size_t produced = len - r->z.avail_out;
        if (rc == Z_STREAM_END) {
            r->ended = true;
            return (ptrdiff_t)produced;
        }
        if (rc != Z_OK && rc != Z_BUF_ERROR) {
            cg_fsutil_io_error(err, CG_IO_INVALID_INPUT, "corrupt deflate stream");
            return -1;
        }
        if (!produced && r->eof) {
            cg_fsutil_io_error(err, CG_IO_UNEXPECTED_EOF, "incomplete deflate stream");
            return -1;
        }
        if (produced) return (ptrdiff_t)produced;
    }
}

static void inflate_reader_free(cg_reader *self) {
    inflate_reader *r = (inflate_reader *)self;
    if (r->ready) inflateEnd(&r->z);
    cg_reader_free(r->inner);
    free(r->in);
    free(r);
}

cg_reader *cg_archive_inflate_reader(cg_reader *inner, size_t buffer_size) {
    inflate_reader *r = cg_calloc(1, sizeof *r);
    r->base.read = inflate_reader_read;
    r->base.free = inflate_reader_free;
    r->inner = inner;
    r->in_cap = buffer_size ? buffer_size : 64 * 1024;
    r->in = cg_malloc(r->in_cap);
    return &r->base;
}

/* ---- errors */

void cg_extract_error_clear(cg_extract_error *error) {
    if (!error) return;
    free(error->detail);
    error->detail = NULL;
    error->detail_len = 0;
    error->kind = CG_EXTRACT_OK;
}

const char *cg_extract_error_stat(const cg_extract_error *error) {
    switch (error->kind) {
    case CG_EXTRACT_WINDOWS_PATH: return "windows_path_fail";
    case CG_EXTRACT_PATH_ESCAPE: return "canonical_path_fail";
    case CG_EXTRACT_DIRECTORY: return "directory_path_fail";
    default: return NULL;
    }
}

char *cg_extract_error_message(const cg_extract_error *error, size_t *len) {
    const char *prefix = "";
    switch (error->kind) {
    case CG_EXTRACT_WINDOWS_PATH: prefix = "Unzip failed: Windows path not supported: "; break;
    case CG_EXTRACT_PATH_ESCAPE: prefix = "Unzip failed: entry escapes bundle: "; break;
    case CG_EXTRACT_DIRECTORY: prefix = "Failed to ensure directory: "; break;
    case CG_EXTRACT_CANCELLED: prefix = "download_stopped"; break;
    default: break;
    }
    cg_buf out = {0};
    cg_buf_puts(&out, prefix);
    if (error->kind != CG_EXTRACT_CANCELLED && error->detail) cg_buf_put(&out, error->detail, error->detail_len);
    if (len) *len = out.len;
    return cg_buf_take(&out);
}

static bool set_error_len(cg_extract_error *error, cg_extract_kind kind, char *detail, size_t len) {
    if (!error) {
        free(detail);
        return false;
    }
    free(error->detail);
    error->kind = kind;
    error->detail = detail;
    error->detail_len = len;
    return false;
}

static bool set_error(cg_extract_error *error, cg_extract_kind kind, char *detail) {
    return set_error_len(error, kind, detail, detail ? strlen(detail) : 0);
}

/* ExtractError::Failed("Failed to unzip <zip>: <message>"). */
static bool set_failed(cg_extract_error *error, const char *zip_path, const char *message) {
    return set_error(error, CG_EXTRACT_FAILED, cg_fmt("Failed to unzip %s: %s", zip_path, message));
}

/* ---- extraction */

static bool resolve_entry(const char *destination, const zip_entry *entry, char **target, cg_extract_error *error) {
    *target = NULL;
    bool backslash = memchr(entry->name, '\\', entry->name_len) != NULL;
    /* paths.rs rejects NUL bytes with the backslash (invalid_separator); a C string cannot
     * carry them to cg_paths_resolve_path_inside. */
    if (entry->name_len && memchr(entry->name, 0, entry->name_len)) {
        char *name = cg_malloc(entry->name_len + 1);
        memcpy(name, entry->name, entry->name_len + 1);
        return set_error_len(error, backslash ? CG_EXTRACT_WINDOWS_PATH : CG_EXTRACT_PATH_ESCAPE, name,
                             entry->name_len);
    }
    cg_error err = CG_ERROR_INIT;
    *target = cg_paths_resolve_path_inside(destination, entry->name, &err);
    if (!*target) {
        bool windows = cg_err_is(&err, "invalid_separator") && backslash;
        set_error(error, windows ? CG_EXTRACT_WINDOWS_PATH : CG_EXTRACT_PATH_ESCAPE, cg_strdup(entry->name));
    }
    cg_err_clear(&err);
    return *target != NULL;
}

/* The deepest existing ancestor of path, canonicalized, must stay inside root (catches
 * directories reached through symlinks from earlier entries). */
static bool physically_inside(const char *root, const char *path) {
    char *real_root = cg_fsutil_canonicalize(root);
    if (!real_root) return false;
    char *probe = cg_strdup(path);
    bool inside = false;
    while (true) {
        struct stat st;
        if (lstat(probe, &st) == 0) {
            char *real = cg_fsutil_canonicalize(probe);
            inside = real && cg_fsutil_path_starts_with(real, real_root);
            free(real);
            break;
        }
        char *parent = cg_fsutil_parent(probe);
        if (!parent) break;
        free(probe);
        probe = parent;
    }
    free(probe);
    free(real_root);
    return inside;
}

/* lexical_normalize: components with `..` popping and `.` dropped, joined with '/'. */
static char *lexical_normalize(const char *path) {
    cg_buf out = {0};
    cg_buf_puts(&out, "");
    const char *p = path;
    if (*p == '/') {
        cg_buf_putc(&out, '/');
        while (*p == '/') p++;
    }
    while (*p) {
        const char *end = strchr(p, '/');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (len == 2 && p[0] == '.' && p[1] == '.') {
            /* PathBuf::pop: drop the last component (never the root). */
            size_t cut = out.len;
            while (cut && out.data[cut - 1] != '/') cut--;
            if (cut < out.len) {
                size_t keep = cut;
                while (keep > 1 && out.data[keep - 1] == '/') keep--;
                if (keep == 1 && out.data[0] == '/') out.len = 1;
                else out.len = cut ? keep : 0;
                out.data[out.len] = 0;
            }
        } else if (len && !(len == 1 && p[0] == '.')) {
            if (out.len && out.data[out.len - 1] != '/') cg_buf_putc(&out, '/');
            cg_buf_put(&out, p, len);
        }
        if (!end) break;
        p = end + 1;
        while (*p == '/') p++;
    }
    return cg_buf_take(&out);
}

static bool link_has_parent_component(const char *link) {
    const char *p = link;
    while (true) {
        const char *end = strchr(p, '/');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (len == 2 && p[0] == '.' && p[1] == '.') return true;
        if (!end) return false;
        p = end + 1;
    }
}

typedef struct {
    size_t index;
    const zip_entry *entry;
    char *target;
    uint64_t declared;
} file_entry;

typedef struct {
    const char *zip_path;
    const zip_archive *za;
    file_entry *files;
    size_t count;
    atomic_size_t next;
    atomic_bool stop;
    cg_mutex mutex;
    cg_cond cond;
    cg_extract_error first_error;
    size_t pending; /* completed files not reported yet */
    size_t active;  /* running workers */
} extract_shared;

static bool write_file_entry(extract_shared *shared, const file_entry *file, uint8_t *in, uint8_t *out,
                             cg_extract_error *error) {
    const char *zip_path = shared->zip_path;
    const zip_entry *entry = file->entry;
    struct stat st;
    if (lstat(file->target, &st) == 0) {
        /* A directory here is another entry's parent: never replace it. */
        if (S_ISDIR(st.st_mode))
            return set_error(error, CG_EXTRACT_FAILED,
                             cg_fmt("Entry %s collides with a directory in %s", entry->name, zip_path));
        cg_error err = CG_ERROR_INIT;
        if (!cg_fsutil_remove_path(file->target, &err)) {
            set_failed(error, zip_path, err.message);
            cg_err_clear(&err);
            return false;
        }
    }
    const char *open_error = entry_open_error(entry);
    if (open_error) return set_failed(error, zip_path, open_error);
    int fd = cg_fsutil_open(file->target, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) {
        char *message = cg_io_message(errno);
        set_failed(error, zip_path, message);
        free(message);
        return false;
    }
    entry_stream stream;
    stream_init(&stream, shared->za->file.fd, entry, in, ARCHIVE_READ_BUFFER);
    uint64_t written = 0;
    bool ok = true;
    while (true) {
        /* The zip reader verifies the CRC-32 when the entry is fully read. */
        char *message = NULL;
        ptrdiff_t n = stream_read(&stream, out, ARCHIVE_WRITE_BUFFER, &message);
        if (n < 0) {
            ok = set_failed(error, zip_path, message);
            free(message);
            break;
        }
        if (n == 0) break;
        written += (uint64_t)n;
        /* Never inflate past the size the central directory declares (zip bombs). */
        if (written > file->declared) {
            ok = set_error(error, CG_EXTRACT_FAILED,
                           cg_fmt("Entry %s inflates beyond its declared size", entry->name));
            break;
        }
        if (!cg_fsutil_write_all(fd, out, (size_t)n)) {
            char *detail = cg_io_message(errno);
            ok = set_failed(error, zip_path, detail);
            free(detail);
            break;
        }
    }
    stream_end(&stream);
    if (ok && written != file->declared) {
        ok = set_error(error, CG_EXTRACT_FAILED,
                       cg_fmt("Entry %s size %llu does not match declared %llu", entry->name,
                              (unsigned long long)written, (unsigned long long)file->declared));
    }
    if (close(fd) != 0 && ok) {
        char *detail = cg_io_message(errno);
        ok = set_failed(error, zip_path, detail);
        free(detail);
    }
    return ok;
}

static void record_error(extract_shared *shared, cg_extract_error *error) {
    cg_lock(&shared->mutex);
    if (shared->first_error.kind == CG_EXTRACT_OK) {
        shared->first_error = *error;
        error->detail = NULL;
        error->detail_len = 0;
    }
    cg_unlock(&shared->mutex);
    cg_extract_error_clear(error);
    atomic_store(&shared->stop, true);
}

static void extract_worker(void *arg) {
    extract_shared *shared = arg;
    uint8_t *in = cg_malloc(ARCHIVE_READ_BUFFER);
    uint8_t *out = cg_malloc(ARCHIVE_WRITE_BUFFER);
    while (!atomic_load(&shared->stop)) {
        size_t position = atomic_fetch_add(&shared->next, 1);
        if (position >= shared->count) break;
        cg_extract_error error = CG_EXTRACT_ERROR_INIT;
        if (!write_file_entry(shared, &shared->files[position], in, out, &error)) {
            record_error(shared, &error);
            break;
        }
        cg_lock(&shared->mutex);
        shared->pending++;
        cg_cond_signal(&shared->cond);
        cg_unlock(&shared->mutex);
    }
    free(in);
    free(out);
    cg_lock(&shared->mutex);
    shared->active--;
    cg_cond_signal(&shared->cond);
    cg_unlock(&shared->mutex);
}

static void free_files(file_entry *files, size_t count) {
    for (size_t i = 0; i < count; i++) free(files[i].target);
    free(files);
}

bool cg_archive_extract_zip(const char *zip_path, const char *destination, cg_extract_progress progress,
                            cg_extract_cancelled cancelled, void *ctx, cg_extract_error *error) {
    zip_archive za;
    char *open_message = zip_open(zip_path, &za);
    if (open_message) {
        set_failed(error, zip_path, open_message);
        free(open_message);
        return false;
    }
    if (!cg_fsutil_create_dir_all(destination)) {
        zip_close(&za);
        return set_error(error, CG_EXTRACT_DIRECTORY, cg_strdup(destination));
    }
    size_t total = za.count;
    size_t done = 0;
    file_entry *files = NULL;
    size_t file_count = 0, file_cap = 0;
    bool ok = true;

    /* Pass 1: validate every name, create directories and symlinks. */
    for (size_t index = 0; ok && index < total; index++) {
        if (cancelled && cancelled(ctx)) {
            ok = set_error(error, CG_EXTRACT_CANCELLED, NULL);
            break;
        }
        const zip_entry *entry = &za.entries[index];
        const char *open_error = entry_open_error(entry);
        if (open_error) {
            ok = set_failed(error, zip_path, open_error);
            break;
        }
        char *target = NULL;
        if (!resolve_entry(destination, entry, &target, error)) {
            ok = false;
            break;
        }
        bool is_dir = entry_is_dir(entry), is_symlink = entry_is_symlink(entry);
        if (!is_dir && !is_symlink) {
            /* Checked in pass 1b, once every symlink exists. */
            if (file_count == file_cap) {
                file_cap = file_cap ? file_cap * 2 : 64;
                files = cg_realloc(files, file_cap * sizeof *files);
            }
            files[file_count++] = (file_entry){index, entry, target, entry->size};
            continue;
        }
        char *parent = cg_fsutil_parent(target);
        if (!parent) parent = cg_strdup(destination);
        if (!physically_inside(destination, parent)) {
            ok = set_error(error, CG_EXTRACT_PATH_ESCAPE, cg_strdup(entry->name));
        } else if (is_dir) {
            if (!cg_fsutil_create_dir_all(target)) {
                ok = set_error(error, CG_EXTRACT_DIRECTORY, target);
                target = NULL;
            } else {
                done++;
                if (progress) progress(ctx, done, total);
            }
        } else if (!cg_fsutil_create_dir_all(parent)) {
            ok = set_error(error, CG_EXTRACT_DIRECTORY, parent);
            parent = NULL;
        } else {
            struct stat st;
            cg_error err = CG_ERROR_INIT;
            if (lstat(target, &st) == 0 && !cg_fsutil_remove_path(target, &err)) {
                ok = set_failed(error, zip_path, err.message);
            }
            cg_err_clear(&err);
            /* Bounded read: a tiny compressed entry could inflate to a huge "target". */
            uint8_t link[MAX_SYMLINK_TARGET + 2];
            size_t link_len = 0;
            entry_stream stream;
            uint8_t *in = ok && entry->method == 8 ? cg_malloc(64 * 1024) : NULL;
            if (ok) stream_init(&stream, za.file.fd, entry, in, 64 * 1024);
            while (ok && link_len < MAX_SYMLINK_TARGET + 1) {
                char *message = NULL;
                ptrdiff_t n = stream_read(&stream, link + link_len, MAX_SYMLINK_TARGET + 1 - link_len, &message);
                if (n < 0) {
                    ok = set_failed(error, zip_path, message);
                    free(message);
                    break;
                }
                if (n == 0) break;
                link_len += (size_t)n;
            }
            if (in) {
                stream_end(&stream);
                free(in);
            }
            link[link_len] = 0;
            if (ok && !cg_utf8_valid((const char *)link, link_len)) {
                ok = set_failed(error, zip_path, "stream did not contain valid UTF-8");
            } else if (ok && link_len > MAX_SYMLINK_TARGET) {
                ok = set_error(error, CG_EXTRACT_FAILED, cg_fmt("Symlink target of %s is too long", entry->name));
            } else if (ok) {
                /* Relative targets without `..` only: the link stays inside its own directory
                 * whatever the other entries are (no chains through `..`). */
                const char *text = (const char *)link;
                bool escapes = text[0] == '/' || link_has_parent_component(text);
                if (!escapes) {
                    char *joined = cg_fsutil_join(parent, text);
                    char *resolved = lexical_normalize(joined);
                    char *parent_normalized = lexical_normalize(parent);
                    escapes = strcmp(resolved, parent_normalized) != 0 &&
                              !cg_fsutil_path_starts_with(resolved, parent_normalized);
                    free(joined);
                    free(resolved);
                    free(parent_normalized);
                }
                if (escapes) {
                    ok = set_error(error, CG_EXTRACT_PATH_ESCAPE, cg_strdup(entry->name));
                } else if (memchr(link, 0, link_len)) {
                    ok = set_failed(error, zip_path, "file name contained an unexpected NUL byte");
                } else if (symlink(text, target) != 0) {
                    char *message = cg_io_message(errno);
                    ok = set_failed(error, zip_path, message);
                    free(message);
                } else {
                    done++;
                    if (progress) progress(ctx, done, total);
                }
            }
        }
        free(parent);
        free(target);
    }

    /* Pass 1b (sequential): every file gets its physical path. Two names can reach one file
     * through an in-bundle directory symlink (`b -> a`: `a/x` and `b/x`); parallel writers must
     * never share a file. No symlink is created after pass 1, so each directory is created,
     * checked and canonicalized once. */
    char *root = NULL;
    strmap real_dirs = {0};
    cg_strs dir_keys = {0}, dir_values = {0};
    if (ok) {
        root = cg_fsutil_canonicalize(destination);
        if (!root) ok = set_error(error, CG_EXTRACT_DIRECTORY, cg_strdup(destination));
    }
    for (size_t i = 0; ok && i < file_count; i++) {
        file_entry *file = &files[i];
        char *parent = cg_fsutil_parent(file->target);
        if (!parent) parent = cg_strdup(destination);
        map_slot *cached = map_find(&real_dirs, parent, strlen(parent));
        const char *real_parent;
        if (cached) {
            real_parent = dir_values.items[cached->value];
            free(parent);
        } else {
            if (!physically_inside(destination, parent)) {
                ok = set_error(error, CG_EXTRACT_PATH_ESCAPE, cg_strdup(file->entry->name));
                free(parent);
                break;
            }
            if (!cg_fsutil_create_dir_all(parent)) {
                ok = set_error(error, CG_EXTRACT_DIRECTORY, parent);
                break;
            }
            char *real = cg_fsutil_canonicalize(parent);
            if (!real || !cg_fsutil_path_starts_with(real, root)) {
                ok = set_error(error, CG_EXTRACT_PATH_ESCAPE, cg_strdup(file->entry->name));
                free(real);
                free(parent);
                break;
            }
            cg_strs_push(&dir_keys, parent);
            cg_strs_push(&dir_values, real);
            map_put(&real_dirs, dir_keys.items[dir_keys.len - 1], strlen(parent), dir_values.len - 1);
            real_parent = real;
        }
        const char *file_name = cg_fsutil_file_name(file->target);
        if (!file_name) {
            ok = set_error(error, CG_EXTRACT_PATH_ESCAPE, cg_strdup(file->entry->name));
            break;
        }
        char *physical = cg_fsutil_join(real_parent, file_name);
        free(file->target);
        file->target = physical;
    }
    map_free(&real_dirs);
    cg_strs_free(&dir_keys);
    cg_strs_free(&dir_values);
    free(root);

    /* The same physical file twice: the last entry wins (as a sequential extraction would). */
    if (ok && file_count) {
        strmap last = {0};
        for (size_t i = 0; i < file_count; i++) map_put(&last, files[i].target, strlen(files[i].target), i);
        size_t kept = 0;
        for (size_t i = 0; i < file_count; i++) {
            map_slot *slot = map_find(&last, files[i].target, strlen(files[i].target));
            if (slot->value == i) {
                files[kept++] = files[i];
            } else {
                free(files[i].target);
            }
        }
        map_free(&last);
        done += file_count - kept;
        file_count = kept;
    }

    /* Pass 2: regular files in parallel. */
    if (ok) {
        extract_shared shared;
        memset(&shared, 0, sizeof shared);
        shared.zip_path = zip_path;
        shared.za = &za;
        shared.files = files;
        shared.count = file_count;
        atomic_init(&shared.next, 0);
        atomic_init(&shared.stop, false);
        cg_mutex_init(&shared.mutex);
        cg_cond_init(&shared.cond);
        size_t workers = (size_t)cg_cpu_count();
        if (workers < 1) workers = 1;
        if (workers > MAX_EXTRACT_WORKERS) workers = MAX_EXTRACT_WORKERS;
        if (workers > (file_count ? file_count : 1)) workers = file_count ? file_count : 1;
        pthread_t threads[MAX_EXTRACT_WORKERS];
        size_t started = 0;
        shared.active = workers;
        for (size_t i = 0; i < workers; i++) {
            if (cg_spawn_joinable("unzip", extract_worker, &shared, &threads[started])) started++;
        }
        if (started < workers) {
            cg_lock(&shared.mutex);
            shared.active -= workers - started;
            cg_unlock(&shared.mutex);
            /* No thread at all: write on this thread (progress follows). */
            if (!started) {
                shared.active = 1;
                extract_worker(&shared);
            }
        }
        /* Progress and cancellation stay on the caller's thread. */
        cg_lock(&shared.mutex);
        while (true) {
            while (!shared.pending && shared.active) cg_cond_wait(&shared.cond, &shared.mutex);
            if (!shared.pending) break;
            size_t reported = shared.pending;
            shared.pending = 0;
            cg_unlock(&shared.mutex);
            for (size_t i = 0; i < reported; i++) {
                done++;
                if (progress) progress(ctx, done, total);
                if (cancelled && cancelled(ctx)) {
                    atomic_store(&shared.stop, true);
                    cg_lock(&shared.mutex);
                    if (shared.first_error.kind == CG_EXTRACT_OK) shared.first_error.kind = CG_EXTRACT_CANCELLED;
                    cg_unlock(&shared.mutex);
                }
            }
            cg_lock(&shared.mutex);
        }
        cg_unlock(&shared.mutex);
        for (size_t i = 0; i < started; i++) cg_join(threads[i]);
        cg_cond_destroy(&shared.cond);
        cg_mutex_destroy(&shared.mutex);
        if (shared.first_error.kind != CG_EXTRACT_OK) {
            ok = set_error_len(error, shared.first_error.kind, shared.first_error.detail,
                               shared.first_error.detail_len);
        }
    }
    free_files(files, file_count);
    zip_close(&za);
    return ok;
}

/* ---- install */

static int compare_names(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

bool cg_archive_install_extracted(const char *source, const char *destination, cg_error *err) {
    cg_error io = CG_ERROR_INIT;
    size_t count = 0;
    char **names = cg_fsutil_read_dir(source, &count, &io);
    if (!names) {
        cg_err_set(err, "io_error", "Cannot list extracted bundle: %s", io.message);
        cg_err_clear(&io);
        return false;
    }
    size_t visible = 0;
    for (size_t i = 0; i < count; i++) {
        if (cg_starts_with(names[i], "__MACOSX") || names[i][0] == '.') {
            free(names[i]);
            continue;
        }
        names[visible++] = names[i];
    }
    qsort(names, visible, sizeof *names, compare_names);
    bool ok = true;
    char *from = NULL;
    bool unwrap = false;
    if (!visible) {
        ok = cg_err_set(err, "unzip_fail", "Source file was not a directory or was empty: %s", source);
        goto done;
    }
    char *parent = cg_fsutil_parent(destination);
    if (parent && !cg_fsutil_create_dir_all(parent)) {
        cg_err_io(err, "Cannot create bundle root", errno);
        free(parent);
        ok = false;
        goto done;
    }
    free(parent);
    if (cg_fsutil_exists(destination) && !cg_fsutil_remove_path(destination, &io)) {
        cg_err_set(err, "io_error", "Cannot replace bundle folder: %s", io.message);
        cg_err_clear(&io);
        ok = false;
        goto done;
    }
    /* A real directory only: a symlink to a hidden folder would be moved alone, then its target
     * deleted with source. */
    char *only = visible == 1 ? cg_fsutil_join(source, names[0]) : NULL;
    struct stat st;
    char *index = cg_fsutil_join(source, "index.html");
    unwrap = only && lstat(only, &st) == 0 && S_ISDIR(st.st_mode) && !cg_fsutil_exists(index);
    free(index);
    from = unwrap ? only : cg_strdup(source);
    if (!unwrap) free(only);
    if (rename(from, destination) != 0) {
        char *detail = cg_io_message(errno);
        cg_err_set(err, "unzip_fail", "Failed to move bundle contents: %s -> %s: %s", from, destination, detail);
        free(detail);
        ok = false;
        goto done;
    }
    if (unwrap) {
        cg_error ignored = CG_ERROR_INIT;
        cg_fsutil_remove_path(source, &ignored);
        cg_err_clear(&ignored);
    }
done:
    free(from);
    for (size_t i = 0; i < visible; i++) free(names[i]);
    free(names);
    return ok;
}
