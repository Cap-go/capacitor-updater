/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Brotli decoding with the semantics of brotli_decompressor's Read adapter
 * (DecompressorCustomIo::read) and manifest.rs decode_brotli. */

#include "engine/brotli_stream.h"

#include <brotli/decode.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "crypto/checksum.h"

typedef struct {
    cg_reader base;
    cg_reader *inner;
    BrotliDecoderState *state;
    uint8_t *input;
    size_t cap, len, offset;
    bool done;
    bool error_reported; /* error_if_invalid_data.take(): the error is returned once */
} brotli_reader;

/* Err(InvalidData) the first time, Ok(0) afterwards. */
static ptrdiff_t invalid_data(brotli_reader *reader, cg_error *err) {
    if (reader->error_reported) return 0;
    reader->error_reported = true;
    cg_fsutil_io_error(err, CG_IO_INVALID_DATA, "Invalid Data");
    return -1;
}

static ptrdiff_t brotli_read(cg_reader *self, uint8_t *buf, size_t len, cg_error *err) {
    brotli_reader *reader = (brotli_reader *)self;
    if (!len) return 0;
    while (true) {
        size_t avail_in = reader->len - reader->offset;
        const uint8_t *next_in = reader->input + reader->offset;
        size_t avail_out = len;
        uint8_t *next_out = buf;
        BrotliDecoderResult result =
            BrotliDecoderDecompressStream(reader->state, &avail_in, &next_in, &avail_out, &next_out, NULL);
        reader->offset = (size_t)(next_in - reader->input);
        size_t produced = len - avail_out;
        switch (result) {
        case BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT: {
            /* The decoder returns what it has before reading again (a read error must not lose
             * decoded bytes). */
            if (produced) return (ptrdiff_t)produced;
            reader->offset = reader->len = 0;
            ptrdiff_t got = cg_reader_read(reader->inner, reader->input, reader->cap, err);
            if (got < 0) return -1;
            if (got == 0) return invalid_data(reader, err);
            reader->len = (size_t)got;
            continue;
        }
        case BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT: return (ptrdiff_t)produced;
        case BROTLI_DECODER_RESULT_SUCCESS:
            if (!produced) {
                if (!reader->done) reader->done = true;
                else if (reader->len != reader->offset) return invalid_data(reader, err);
            }
            return (ptrdiff_t)produced;
        default: return invalid_data(reader, err);
        }
    }
}

static void brotli_free(cg_reader *self) {
    brotli_reader *reader = (brotli_reader *)self;
    BrotliDecoderDestroyInstance(reader->state);
    cg_reader_free(reader->inner);
    free(reader->input);
    free(reader);
}

cg_reader *cg_brotli_reader(cg_reader *inner, size_t buffer_size) {
    brotli_reader *reader = cg_calloc(1, sizeof *reader);
    reader->base.read = brotli_read;
    reader->base.free = brotli_free;
    reader->inner = inner;
    reader->cap = buffer_size ? buffer_size : CG_IO_BUFFER_BYTES;
    reader->input = cg_malloc(reader->cap);
    reader->state = BrotliDecoderCreateInstance(NULL, NULL, NULL);
    if (!reader->state) abort(); /* allocation failure, like Rust */
    return &reader->base;
}

bool cg_brotli_decode_file(const char *source, const char *target, const char *expected, char **hash,
                           cg_error *err) {
    *hash = NULL;
    struct stat st;
    if (stat(source, &st) != 0) return cg_fsutil_os_error(err, errno);
    uint64_t bytes_len = (uint64_t)st.st_size;
    uint8_t head[3] = {0};
    uint8_t last = 0;
    bool has_head = false;
    int fd = cg_fsutil_open(source, O_RDONLY, 0);
    if (fd < 0) return cg_fsutil_os_error(err, errno);
    has_head = bytes_len >= 3 && cg_fsutil_pread_full(fd, head, 3, 0) == 3;
    if (bytes_len > 3) {
        uint64_t size = (uint64_t)lseek(fd, 0, SEEK_END);
        ssize_t got = cg_fsutil_pread_full(fd, &last, 1, size - 1);
        if (got != 1) {
            bool failed = got < 0 ? cg_fsutil_os_error(err, errno) : cg_fsutil_eof_error(err);
            close(fd);
            return failed;
        }
    }
    static const uint8_t empty_stream[3] = {0x1b, 0x00, 0x06};
    static const uint8_t stored_header[3] = {0x0b, 0x02, 0x80};
    cg_reader *reader;
    if (bytes_len == 0 || (bytes_len == 3 && has_head && memcmp(head, empty_stream, 3) == 0)) {
        close(fd);
        reader = cg_fsutil_empty_reader();
    } else if (bytes_len > 3 && last == 0x03 && has_head &&
               (memcmp(head, empty_stream, 3) == 0 || memcmp(head, stored_header, 3) == 0)) {
        if (lseek(fd, 3, SEEK_SET) < 0) {
            bool failed = cg_fsutil_os_error(err, errno);
            close(fd);
            return failed;
        }
        reader = cg_fsutil_fd_reader(fd, true, bytes_len - 4);
    } else {
        if (lseek(fd, 0, SEEK_SET) < 0) {
            bool failed = cg_fsutil_os_error(err, errno);
            close(fd);
            return failed;
        }
        reader = cg_brotli_reader(cg_fsutil_fd_reader(fd, true, UINT64_MAX), CG_IO_BUFFER_BYTES);
    }
    bool ok = cg_fsutil_write_verified(reader, target, expected, hash, err);
    cg_reader_free(reader);
    return ok;
}
