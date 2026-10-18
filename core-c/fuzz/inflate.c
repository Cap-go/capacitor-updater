/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* inflate: the input is a raw deflate stream (zip entry data), decoded by the zip reader's
 * inflate (cg_archive_inflate_reader) up to 64 MiB. Rust: flate2 DeflateDecoder, which the
 * zip crate uses. */

#include <stdlib.h>
#include <string.h>

#include "engine/archive.h"
#include "fuzz_support.h"

typedef struct {
    cg_reader base;
    const uint8_t *data;
    size_t len;
} memory_reader;

static ptrdiff_t memory_read(cg_reader *self, uint8_t *buf, size_t len, cg_error *err) {
    (void)err;
    memory_reader *reader = (memory_reader *)self;
    size_t take = len < reader->len ? len : reader->len;
    memcpy(buf, reader->data, take);
    reader->data += take;
    reader->len -= take;
    return (ptrdiff_t)take;
}

static void memory_free(cg_reader *self) { free(self); }

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    memory_reader *inner = calloc(1, sizeof *inner);
    if (!inner) abort();
    inner->base.read = memory_read;
    inner->base.free = memory_free;
    inner->data = data;
    inner->len = size;
    cg_reader *reader = cg_archive_inflate_reader(&inner->base, 64 * 1024);
    uint8_t buffer[65536];
    size_t total = 0;
    for (;;) {
        cg_error err = CG_ERROR_INIT;
        ptrdiff_t got = cg_reader_read(reader, buffer, sizeof buffer, &err);
        cg_err_clear(&err);
        if (got <= 0) break;
        total += (size_t)got;
        if (total > (64u << 20)) break;
    }
    cg_reader_free(reader);
    return 0;
}
