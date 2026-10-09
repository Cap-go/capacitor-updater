/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Builtin files inside the Android APK (`assets/...`), indexed from the zip
 * central directory alone.
 *
 * Opening an archive the zip-crate way reads the local header of every entry:
 * thousands of random reads over a large APK, 0.5-1.6 s on the first manifest
 * download of each process. This index reads the central directory once (one
 * contiguous read) and touches a local header only when that entry is used. */

#include "engine/apk.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "engine/archive.h"
#include "rt/sync.h"

#define EOCD_SIGNATURE 0x06054b50u
#define EOCD_LEN 22
#define ZIP64_LOCATOR_SIGNATURE 0x07064b50u
#define ZIP64_EOCD_SIGNATURE 0x06064b50u
#define CENTRAL_SIGNATURE 0x02014b50u
#define LOCAL_SIGNATURE 0x04034b50u
/* Sanity cap: an APK central directory is a few MB at most. */
#define MAX_CENTRAL_DIRECTORY (256ull * 1024 * 1024)

typedef struct {
    char *name;
    uint64_t header_offset;
    uint64_t compressed_size;
    uint16_t method;
    size_t position; /* archive order */
} apk_entry;

struct cg_apk_index {
    atomic_int refs;
    int fd;
    apk_entry *entries; /* sorted by name, unique */
    size_t count;
};

static uint16_t u16_at(const uint8_t *bytes, size_t at) { return (uint16_t)(bytes[at] | bytes[at + 1] << 8); }
static uint32_t u32_at(const uint8_t *bytes, size_t at) {
    return (uint32_t)bytes[at] | (uint32_t)bytes[at + 1] << 8 | (uint32_t)bytes[at + 2] << 16 |
           (uint32_t)bytes[at + 3] << 24;
}
static uint64_t u64_at(const uint8_t *bytes, size_t at) {
    return (uint64_t)u32_at(bytes, at) | (uint64_t)u32_at(bytes, at + 4) << 32;
}

static bool invalid(cg_error *err, const char *message) {
    return cg_fsutil_io_error(err, CG_IO_INVALID_DATA, message);
}

static bool read_exact_at(int fd, void *buf, size_t len, uint64_t offset, cg_error *err) {
    ssize_t got = cg_fsutil_pread_full(fd, buf, len, offset);
    if (got < 0) return cg_fsutil_os_error(err, errno);
    if ((size_t)got != len) return cg_fsutil_io_error(err, CG_IO_UNEXPECTED_EOF, "failed to fill whole buffer");
    return true;
}

/* (offset, size) of the central directory, from the (zip64) end record. */
static bool central_directory(int fd, uint64_t len, uint64_t *offset_out, uint64_t *size_out, cg_error *err) {
    uint64_t tail_len = len < EOCD_LEN + 0xFFFF ? len : EOCD_LEN + 0xFFFF;
    if (tail_len < EOCD_LEN) return invalid(err, "not a zip");
    uint64_t tail_start = len - tail_len;
    uint8_t *tail = cg_malloc((size_t)tail_len);
    if (!read_exact_at(fd, tail, (size_t)tail_len, tail_start, err)) {
        free(tail);
        return false;
    }
    /* The last end record whose comment length reaches exactly the end of the file. */
    int64_t eocd = -1;
    for (int64_t at = (int64_t)(tail_len - EOCD_LEN); at >= 0; at--) {
        if (u32_at(tail, (size_t)at) == EOCD_SIGNATURE &&
            (uint64_t)at + EOCD_LEN + u16_at(tail, (size_t)at + 20) == tail_len) {
            eocd = at;
            break;
        }
    }
    if (eocd < 0) {
        free(tail);
        return invalid(err, "end of central directory not found");
    }
    uint64_t size = u32_at(tail, (size_t)eocd + 12);
    uint64_t offset = u32_at(tail, (size_t)eocd + 16);
    bool zip64 = u16_at(tail, (size_t)eocd + 10) == 0xFFFF || size == 0xFFFFFFFFu || offset == 0xFFFFFFFFu;
    free(tail);
    if (zip64) {
        uint64_t locator_at = tail_start + (uint64_t)eocd;
        if (locator_at < 20) return invalid(err, "zip64 locator missing");
        locator_at -= 20;
        uint8_t locator[20];
        if (!read_exact_at(fd, locator, sizeof locator, locator_at, err)) return false;
        if (u32_at(locator, 0) != ZIP64_LOCATOR_SIGNATURE) return invalid(err, "zip64 locator missing");
        uint8_t record[56];
        if (!read_exact_at(fd, record, sizeof record, u64_at(locator, 8), err)) return false;
        if (u32_at(record, 0) != ZIP64_EOCD_SIGNATURE) return invalid(err, "zip64 end record missing");
        size = u64_at(record, 40);
        offset = u64_at(record, 48);
    }
    if (size > MAX_CENTRAL_DIRECTORY || offset + size < offset || offset + size > len)
        return invalid(err, "central directory out of bounds");
    *offset_out = offset;
    *size_out = size;
    return true;
}

static int compare_entries(const void *a, const void *b) {
    const apk_entry *x = a, *y = b;
    int cmp = strcmp(x->name, y->name);
    if (cmp) return cmp;
    return x->position < y->position ? -1 : x->position > y->position;
}

static void free_entries(apk_entry *entries, size_t count) {
    for (size_t i = 0; i < count; i++) free(entries[i].name);
    free(entries);
}

static bool parse_central_directory(const uint8_t *central, size_t len, const char *prefix, apk_entry **out,
                                    size_t *count_out, cg_error *err) {
    apk_entry *entries = NULL;
    size_t count = 0, cap = 0;
    size_t prefix_len = strlen(prefix);
    size_t at = 0;
    while (at + 46 <= len) {
        if (u32_at(central, at) != CENTRAL_SIGNATURE) break;
        uint16_t flags = u16_at(central, at + 8);
        uint16_t method = u16_at(central, at + 10);
        uint64_t compressed_size = u32_at(central, at + 20);
        uint32_t uncompressed_size = u32_at(central, at + 24);
        size_t name_len = u16_at(central, at + 28);
        size_t extra_len = u16_at(central, at + 30);
        size_t comment_len = u16_at(central, at + 32);
        uint64_t header_offset = u32_at(central, at + 42);
        size_t name_start = at + 46;
        size_t extra_start = name_start + name_len;
        size_t next = extra_start + extra_len + comment_len;
        if (next > len) {
            free_entries(entries, count);
            return invalid(err, "truncated central directory");
        }
        const uint8_t *name = central + name_start;
        if (!(flags & 1) && name_len >= prefix_len && memcmp(name, prefix, prefix_len) == 0) {
            /* Zip64 extra field: the 64-bit values replace the saturated ones, in order. */
            const uint8_t *extra = central + extra_start;
            size_t extra_left = extra_len;
            while (extra_left >= 4) {
                uint16_t id = u16_at(extra, 0);
                size_t size = u16_at(extra, 2);
                if (size > extra_left - 4) size = extra_left - 4;
                if (id == 1) {
                    size_t fields = size / 8, field = 0;
                    if (uncompressed_size == 0xFFFFFFFFu && field < fields) field++;
                    if (compressed_size == 0xFFFFFFFFu && field < fields) compressed_size = u64_at(extra, 4 + 8 * field++);
                    if (header_offset == 0xFFFFFFFFu && field < fields) header_offset = u64_at(extra, 4 + 8 * field++);
                }
                extra += 4 + size;
                extra_left -= 4 + size;
            }
            if (cg_utf8_valid((const char *)name, name_len) && !memchr(name, 0, name_len)) {
                if (count == cap) {
                    cap = cap ? cap * 2 : 64;
                    entries = cg_realloc(entries, cap * sizeof *entries);
                }
                entries[count] = (apk_entry){cg_strndup((const char *)name, name_len), header_offset,
                                             compressed_size, method, count};
                count++;
            }
        }
        at = next;
    }
    /* HashMap::insert: the last entry of a name wins (sorted by name, then archive order). */
    qsort(entries, count, sizeof *entries, compare_entries);
    size_t unique = 0;
    for (size_t i = 0; i < count; i++) {
        if (unique && strcmp(entries[unique - 1].name, entries[i].name) == 0) {
            free(entries[unique - 1].name);
            entries[unique - 1] = entries[i];
        } else {
            entries[unique++] = entries[i];
        }
    }
    *out = entries;
    *count_out = unique;
    return true;
}

cg_apk_index *cg_apk_index_open(const char *path, const char *prefix, cg_error *err) {
    int fd = cg_fsutil_open(path, O_RDONLY, 0);
    if (fd < 0) {
        cg_fsutil_os_error(err, errno);
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        cg_fsutil_os_error(err, errno);
        close(fd);
        return NULL;
    }
    uint64_t offset = 0, size = 0;
    if (!central_directory(fd, (uint64_t)st.st_size, &offset, &size, err)) {
        close(fd);
        return NULL;
    }
    uint8_t *central = cg_malloc(size ? (size_t)size : 1);
    apk_entry *entries = NULL;
    size_t count = 0;
    bool ok = read_exact_at(fd, central, (size_t)size, offset, err) &&
              parse_central_directory(central, (size_t)size, prefix, &entries, &count, err);
    free(central);
    if (!ok) {
        close(fd);
        return NULL;
    }
    cg_apk_index *index = cg_calloc(1, sizeof *index);
    atomic_init(&index->refs, 1);
    index->fd = fd;
    index->entries = entries;
    index->count = count;
    return index;
}

static cg_apk_index *retain(cg_apk_index *index) {
    atomic_fetch_add(&index->refs, 1);
    return index;
}

void cg_apk_index_release(cg_apk_index *index) {
    if (!index || atomic_fetch_sub(&index->refs, 1) != 1) return;
    free_entries(index->entries, index->count);
    close(index->fd);
    free(index);
}

size_t cg_apk_index_len(const cg_apk_index *index) { return index->count; }

static cg_mutex cache_mutex = CG_MUTEX_INIT;
static char *cache_path;
static cg_apk_index *cache_index;

cg_apk_index *cg_apk_index_shared(const char *path) {
    cg_lock(&cache_mutex);
    if (cache_index && cg_eq(cache_path, path)) {
        cg_apk_index *index = retain(cache_index);
        cg_unlock(&cache_mutex);
        return index;
    }
    cg_error err = CG_ERROR_INIT;
    cg_apk_index *index = cg_apk_index_open(path, "assets/", &err);
    cg_err_clear(&err);
    if (index) {
        cg_apk_index_release(cache_index);
        free(cache_path);
        cache_path = cg_strdup(path);
        cache_index = retain(index);
    }
    cg_unlock(&cache_mutex);
    return index;
}

static const apk_entry *find(const cg_apk_index *index, const char *name) {
    size_t lo = 0, hi = index->count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        int cmp = strcmp(index->entries[mid].name, name);
        if (cmp == 0) return &index->entries[mid];
        if (cmp < 0) lo = mid + 1;
        else hi = mid;
    }
    return NULL;
}

/* Keeps the index alive while a reader uses its fd. */
typedef struct {
    cg_reader base;
    cg_reader *inner;
    cg_apk_index *index;
} held_reader;

static ptrdiff_t held_read(cg_reader *self, uint8_t *buf, size_t len, cg_error *err) {
    return cg_reader_read(((held_reader *)self)->inner, buf, len, err);
}

static void held_free(cg_reader *self) {
    held_reader *reader = (held_reader *)self;
    cg_reader_free(reader->inner);
    cg_apk_index_release(reader->index);
    free(reader);
}

cg_reader *cg_apk_index_entry(cg_apk_index *index, const char *name) {
    const apk_entry *entry = find(index, name);
    if (!entry) return NULL;
    uint8_t header[30];
    cg_error err = CG_ERROR_INIT;
    bool ok = read_exact_at(index->fd, header, sizeof header, entry->header_offset, &err);
    cg_err_clear(&err);
    if (!ok || u32_at(header, 0) != LOCAL_SIGNATURE) return NULL;
    uint64_t skip = 30 + (uint64_t)u16_at(header, 26) + u16_at(header, 28);
    uint64_t data_start = entry->header_offset + skip;
    if (data_start < skip) return NULL;
    uint64_t end = data_start + entry->compressed_size;
    if (end < data_start) return NULL;
    cg_reader *raw;
    switch (entry->method) {
    case 0: raw = cg_fsutil_range_reader(index->fd, data_start, end); break;
    case 8: raw = cg_archive_inflate_reader(cg_fsutil_range_reader(index->fd, data_start, end), 64 * 1024); break;
    default: return NULL;
    }
    held_reader *reader = cg_calloc(1, sizeof *reader);
    reader->base.read = held_read;
    reader->base.free = held_free;
    reader->inner = raw;
    reader->index = retain(index);
    return &reader->base;
}
