/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Small file-system helpers shared by the download pipeline. */

#include "engine/fsutil.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <copyfile.h>
#include <sys/clonefile.h>
#elif !defined(__ANDROID__)
#include <sys/random.h>
#endif

#include <mbedtls/aes.h>
#include <mbedtls/sha256.h>

#include "crypto/checksum.h"
#include "rt/sync.h"

/* ---- errors */

bool cg_fsutil_io_error(cg_error *err, const char *kind, const char *message) {
    return cg_err_set(err, kind, "%s", message);
}

bool cg_fsutil_os_error(cg_error *err, int errnum) {
    return cg_err_set_own(err, errnum == ENOENT ? CG_IO_NOT_FOUND : CG_IO_OTHER, cg_io_message(errnum));
}

bool cg_fsutil_eof_error(cg_error *err) {
    return cg_fsutil_io_error(err, CG_IO_UNEXPECTED_EOF, "failed to fill whole buffer");
}

/* ---- low level */

int cg_fsutil_open(const char *path, int flags, mode_t mode) {
    int fd;
    do {
        fd = open(path, flags | O_CLOEXEC, mode);
    } while (fd < 0 && errno == EINTR);
    return fd;
}

ssize_t cg_fsutil_pread_full(int fd, void *buf, size_t len, uint64_t offset) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = pread(fd, (uint8_t *)buf + done, len - done, (off_t)(offset + done));
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) break;
        done += (size_t)n;
    }
    return (ssize_t)done;
}

bool cg_fsutil_write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        p += n;
        len -= (size_t)n;
    }
    return true;
}

/* ---- readers */

void cg_reader_free(cg_reader *reader) {
    if (reader && reader->free) reader->free(reader);
}

bool cg_reader_read_exact(cg_reader *reader, uint8_t *buf, size_t len, cg_error *err) {
    while (len) {
        ptrdiff_t n = cg_reader_read(reader, buf, len, err);
        if (n < 0) return false;
        if (n == 0) return cg_fsutil_eof_error(err);
        buf += n;
        len -= (size_t)n;
    }
    return true;
}

typedef struct {
    cg_reader base;
    int fd;
    bool owns_fd;
    uint64_t remaining;
} fd_reader;

static ptrdiff_t fd_reader_read(cg_reader *self, uint8_t *buf, size_t len, cg_error *err) {
    fd_reader *reader = (fd_reader *)self;
    if ((uint64_t)len > reader->remaining) len = (size_t)reader->remaining;
    if (!len) return 0;
    while (true) {
        ssize_t n = read(reader->fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            cg_fsutil_os_error(err, errno);
            return -1;
        }
        reader->remaining -= (uint64_t)n;
        return n;
    }
}

static void fd_reader_free(cg_reader *self) {
    fd_reader *reader = (fd_reader *)self;
    if (reader->owns_fd) close(reader->fd);
    free(reader);
}

cg_reader *cg_fsutil_fd_reader(int fd, bool owns_fd, uint64_t limit) {
    fd_reader *reader = cg_calloc(1, sizeof *reader);
    reader->base.read = fd_reader_read;
    reader->base.free = fd_reader_free;
    reader->fd = fd;
    reader->owns_fd = owns_fd;
    reader->remaining = limit;
    return &reader->base;
}

cg_reader *cg_fsutil_file_reader(const char *path, cg_error *err) {
    int fd = cg_fsutil_open(path, O_RDONLY, 0);
    if (fd < 0) {
        cg_fsutil_os_error(err, errno);
        return NULL;
    }
    return cg_fsutil_fd_reader(fd, true, UINT64_MAX);
}

static ptrdiff_t empty_read(cg_reader *self, uint8_t *buf, size_t len, cg_error *err) { return 0; }
static void plain_free(cg_reader *self) { free(self); }

cg_reader *cg_fsutil_empty_reader(void) {
    cg_reader *reader = cg_calloc(1, sizeof *reader);
    reader->read = empty_read;
    reader->free = plain_free;
    return reader;
}

typedef struct {
    cg_reader base;
    int fd;
    uint64_t position, end;
} range_reader;

static ptrdiff_t range_reader_read(cg_reader *self, uint8_t *buf, size_t len, cg_error *err) {
    range_reader *reader = (range_reader *)self;
    uint64_t remaining = reader->end > reader->position ? reader->end - reader->position : 0;
    if ((uint64_t)len > remaining) len = (size_t)remaining;
    if (!len) return 0;
    while (true) {
        ssize_t n = pread(reader->fd, buf, len, (off_t)reader->position);
        if (n < 0) {
            if (errno == EINTR) continue;
            cg_fsutil_os_error(err, errno);
            return -1;
        }
        if (n == 0) {
            cg_fsutil_io_error(err, CG_IO_UNEXPECTED_EOF, "unexpected end of file");
            return -1;
        }
        reader->position += (uint64_t)n;
        return n;
    }
}

cg_reader *cg_fsutil_range_reader(int fd, uint64_t offset, uint64_t end) {
    range_reader *reader = cg_calloc(1, sizeof *reader);
    reader->base.read = range_reader_read;
    reader->base.free = plain_free;
    reader->fd = fd;
    reader->position = offset;
    reader->end = end;
    return &reader->base;
}

/* ---- paths */

/* Length of path without trailing separators (a lone "/" is kept). */
static size_t trimmed_len(const char *path, size_t len) {
    while (len > 1 && path[len - 1] == '/') len--;
    return len;
}

char *cg_fsutil_parent(const char *path) {
    size_t len = trimmed_len(path, strlen(path));
    if (len == 0 || (len == 1 && path[0] == '/')) return NULL;
    /* A trailing "." component is ignored by Path::components. */
    while (len >= 2 && path[len - 1] == '.' && path[len - 2] == '/') len = trimmed_len(path, len - 1);
    if (len == 1 && path[0] == '.') return cg_strdup("");
    size_t cut = len;
    while (cut && path[cut - 1] != '/') cut--;
    if (cut == 0) return cg_strdup("");
    /* Drop the separators before the last component. */
    while (cut > 1 && path[cut - 1] == '/') cut--;
    return cg_strndup(path, cut);
}

const char *cg_fsutil_file_name(const char *path) {
    size_t len = trimmed_len(path, strlen(path));
    if (len == 0 || (len == 1 && path[0] == '/')) return NULL;
    size_t start = len;
    while (start && path[start - 1] != '/') start--;
    if (len - start == 2 && path[start] == '.' && path[start + 1] == '.') return NULL;
    return path + start;
}

char *cg_fsutil_join(const char *base, const char *child) {
    if (child[0] == '/' || !base[0]) return cg_strdup(child);
    size_t len = strlen(base);
    return base[len - 1] == '/' ? cg_fmt("%s%s", base, child) : cg_fmt("%s/%s", base, child);
}

/* Next component of path at *at: start in *start, length returned (0 at the end). Leading "/"
 * is a component of its own ("/"); "." components after the first are skipped. */
static size_t next_component(const char *path, size_t *at, size_t *start) {
    size_t i = *at;
    if (i == 0 && path[0] == '/') {
        *start = 0;
        *at = 1;
        return 1;
    }
    while (true) {
        while (path[i] == '/') i++;
        if (!path[i]) {
            *at = i;
            return 0;
        }
        size_t s = i;
        while (path[i] && path[i] != '/') i++;
        if (i - s == 1 && path[s] == '.' && s != 0) continue;
        *start = s;
        *at = i;
        return i - s;
    }
}

bool cg_fsutil_path_starts_with(const char *path, const char *prefix) {
    size_t pa = 0, pr = 0;
    while (true) {
        size_t ps, rs;
        size_t rl = next_component(prefix, &pr, &rs);
        if (!rl) return true;
        size_t pl = next_component(path, &pa, &ps);
        if (pl != rl || memcmp(path + ps, prefix + rs, pl) != 0) return false;
    }
}

bool cg_fsutil_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

bool cg_fsutil_is_dir(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

bool cg_fsutil_is_file(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

char *cg_fsutil_canonicalize(const char *path) {
    char *real = realpath(path, NULL);
    if (!real) return NULL;
    char *out = cg_strdup(real);
    free(real);
    return out;
}

bool cg_fsutil_create_dir_all(const char *path) {
    if (!path[0]) return true;
    if (mkdir(path, 0777) == 0) return true;
    if (errno != ENOENT) {
        int saved = errno;
        if (cg_fsutil_is_dir(path)) return true;
        errno = saved;
        return false;
    }
    /* Walk up to the deepest existing ancestor, then create downwards (no recursion). */
    char *work = cg_strdup(path);
    size_t len = strlen(work);
    cg_buf cuts = {0}; /* stack of cut positions (size_t) */
    bool ok = true;
    while (true) {
        size_t end = trimmed_len(work, len);
        size_t cut = end;
        while (cut && work[cut - 1] != '/') cut--;
        if (cut == 0) break;
        while (cut > 1 && work[cut - 1] == '/') cut--;
        if (cut == 1 && work[0] == '/') break;
        cg_buf_put(&cuts, &cut, sizeof cut);
        char saved = work[cut];
        work[cut] = 0;
        if (mkdir(work, 0777) == 0 || (errno != ENOENT && cg_fsutil_is_dir(work))) {
            work[cut] = saved;
            cuts.len -= sizeof cut;
            break;
        }
        int failure = errno;
        work[cut] = saved;
        if (failure != ENOENT) {
            errno = failure;
            ok = false;
            break;
        }
        len = cut;
    }
    /* Create the pending ancestors, deepest-first popped last. */
    while (ok && cuts.len) {
        size_t cut;
        cuts.len -= sizeof cut;
        memcpy(&cut, cuts.data + cuts.len, sizeof cut);
        char saved = work[cut];
        work[cut] = 0;
        if (mkdir(work, 0777) != 0 && !cg_fsutil_is_dir(work)) ok = false;
        work[cut] = saved;
    }
    if (ok && mkdir(path, 0777) != 0) {
        int saved = errno;
        if (!cg_fsutil_is_dir(path)) {
            errno = saved;
            ok = false;
        }
    }
    int saved = errno;
    cg_buf_free(&cuts);
    free(work);
    errno = saved;
    return ok;
}

bool cg_fsutil_create_dir_all_err(const char *path, cg_error *err) {
    return cg_fsutil_create_dir_all(path) || cg_fsutil_os_error(err, errno);
}

char **cg_fsutil_read_dir(const char *path, size_t *len, cg_error *err) {
    DIR *dir = opendir(path);
    if (!dir) {
        cg_fsutil_os_error(err, errno);
        return NULL;
    }
    cg_strs names = {0};
    struct dirent *entry;
    errno = 0;
    while ((entry = readdir(dir))) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        cg_strs_push_copy(&names, entry->d_name);
        errno = 0;
    }
    int failure = errno;
    closedir(dir);
    if (failure) {
        cg_strs_free(&names);
        cg_fsutil_os_error(err, failure);
        return NULL;
    }
    *len = names.len;
    if (!names.items) return cg_calloc(1, sizeof(char *));
    return names.items;
}

void cg_fsutil_free_names(char **names, size_t len) {
    if (!names) return;
    for (size_t i = 0; i < len; i++) free(names[i]);
    free(names);
}

/* `fs::remove_dir_all` recursion overflowed host thread stacks on deep bundle trees: same
 * walk, with the work list on the heap. */
static bool remove_dir_iteratively(const char *root, cg_error *err) {
    typedef struct {
        char *dir;
        bool emptied;
    } item;
    item *pending = cg_malloc(sizeof(item) * 16);
    size_t count = 0, cap = 16;
    pending[count++] = (item){cg_strdup(root), false};
    bool ok = true;
    while (count) {
        item current = pending[--count];
        if (current.emptied) {
            if (rmdir(current.dir) != 0) {
                ok = cg_fsutil_os_error(err, errno);
            }
            free(current.dir);
            if (!ok) break;
            continue;
        }
        if (count == cap) pending = cg_realloc(pending, sizeof(item) * (cap *= 2));
        pending[count++] = (item){current.dir, true};
        DIR *dir = opendir(current.dir);
        if (!dir) {
            ok = cg_fsutil_os_error(err, errno);
            break;
        }
        struct dirent *entry;
        errno = 0;
        while ((entry = readdir(dir))) {
            if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
            char *path = cg_fsutil_join(current.dir, entry->d_name);
            struct stat st;
            /* lstat: a link to a folder is removed, not walked. */
            if (lstat(path, &st) != 0) {
                ok = cg_fsutil_os_error(err, errno);
                free(path);
                break;
            }
            if (S_ISDIR(st.st_mode)) {
                if (count == cap) pending = cg_realloc(pending, sizeof(item) * (cap *= 2));
                pending[count++] = (item){path, false};
            } else {
                if (unlink(path) != 0) {
                    ok = cg_fsutil_os_error(err, errno);
                    free(path);
                    break;
                }
                free(path);
            }
            errno = 0;
        }
        if (ok && errno) ok = cg_fsutil_os_error(err, errno);
        closedir(dir);
        if (!ok) break;
    }
    for (size_t i = 0; i < count; i++) free(pending[i].dir);
    free(pending);
    return ok;
}

bool cg_fsutil_remove_path(const char *path, cg_error *err) {
    struct stat st;
    if (lstat(path, &st) != 0) return errno == ENOENT ? true : cg_fsutil_os_error(err, errno);
    if (S_ISDIR(st.st_mode)) return remove_dir_iteratively(path, err);
    return unlink(path) == 0 || cg_fsutil_os_error(err, errno);
}

bool cg_fsutil_copy_file(const char *source, const char *destination, cg_error *err) {
    int in = cg_fsutil_open(source, O_RDONLY, 0);
    if (in < 0) return cg_fsutil_os_error(err, errno);
    struct stat st;
    if (fstat(in, &st) != 0) {
        int failure = errno;
        close(in);
        return cg_fsutil_os_error(err, failure);
    }
    if (!S_ISREG(st.st_mode)) {
        close(in);
        return cg_fsutil_io_error(err, CG_IO_INVALID_INPUT, "the source path is neither a regular file nor a symlink to a regular file");
    }
#if defined(__APPLE__)
    /* std::fs::copy clones first on APFS (copy-on-write, content and permissions). */
    if (fclonefileat(in, AT_FDCWD, destination, 0) == 0) {
        close(in);
        return true;
    }
#endif
    int out = cg_fsutil_open(destination, O_WRONLY | O_CREAT | O_TRUNC, st.st_mode & 07777);
    if (out < 0) {
        int failure = errno;
        close(in);
        return cg_fsutil_os_error(err, failure);
    }
    bool ok = true;
#if defined(__APPLE__)
    if (fcopyfile(in, out, NULL, COPYFILE_DATA) != 0) ok = cg_fsutil_os_error(err, errno);
#else
    size_t cap = CG_IO_BUFFER_BYTES;
    uint8_t *buffer = cg_malloc(cap);
    while (ok) {
        ssize_t n = read(in, buffer, cap);
        if (n < 0) {
            if (errno == EINTR) continue;
            ok = cg_fsutil_os_error(err, errno);
            break;
        }
        if (n == 0) break;
        if (!cg_fsutil_write_all(out, buffer, (size_t)n)) ok = cg_fsutil_os_error(err, errno);
    }
    free(buffer);
#endif
    if (ok && fchmod(out, st.st_mode & 07777) != 0) ok = cg_fsutil_os_error(err, errno);
    close(in);
    if (close(out) != 0 && ok) ok = cg_fsutil_os_error(err, errno);
    return ok;
}

/* ---- text */

char *cg_fsutil_hex(const uint8_t *bytes, size_t len) {
    static const char digits[] = "0123456789abcdef";
    char *out = cg_malloc(len * 2 + 1);
    for (size_t i = 0; i < len; i++) {
        out[i * 2] = digits[bytes[i] >> 4];
        out[i * 2 + 1] = digits[bytes[i] & 15];
    }
    out[len * 2] = 0;
    return out;
}

static void random_bytes(uint8_t *out, size_t len) {
#if defined(__APPLE__) || defined(__ANDROID__)
    arc4random_buf(out, len);
#else
    while (len) {
        ssize_t n = getrandom(out, len, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            abort(); /* Rust: "system RNG available" */
        }
        out += n;
        len -= (size_t)n;
    }
#endif
}

char *cg_fsutil_random_id(void) {
    static const char alphabet[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    uint8_t bytes[10];
    random_bytes(bytes, sizeof bytes);
    char *out = cg_malloc(11);
    for (int i = 0; i < 10; i++) out[i] = alphabet[bytes[i] % 62];
    out[10] = 0;
    return out;
}

/* ---- fsutil.rs */

bool cg_fsutil_available_space(const char *path, uint64_t *out) {
    char *probe = cg_strdup(path);
    while (!cg_fsutil_exists(probe)) {
        char *parent = cg_fsutil_parent(probe);
        free(probe);
        if (!parent) return false;
        probe = parent;
    }
    struct statvfs st;
    /* Path::exists("") is false, so probe is never empty here. */
    int rc = statvfs(probe, &st);
    free(probe);
    if (rc != 0) return false;
    *out = (uint64_t)st.f_bavail * (uint64_t)st.f_frsize;
    return true;
}

char *cg_fsutil_unique_temp(const char *dir, const char *prefix, const char *suffix) {
    char *id = cg_fsutil_random_id();
    char *name = cg_fmt("%s%s%s", prefix, id, suffix);
    char *out = cg_fsutil_join(dir, name);
    free(id);
    free(name);
    return out;
}

/* Parent of destination, created. NULL with *err. */
static char *prepare_parent(const char *destination, cg_error *err) {
    char *parent = cg_fsutil_parent(destination);
    if (!parent) {
        cg_fsutil_io_error(err, CG_IO_OTHER, "destination has no parent");
        return NULL;
    }
    if (!cg_fsutil_create_dir_all_err(parent, err)) {
        free(parent);
        return NULL;
    }
    return parent;
}

bool cg_fsutil_copy_atomically(const char *source, const char *destination, cg_error *err) {
    char *parent = prepare_parent(destination, err);
    if (!parent) return false;
    char *temp = cg_fsutil_unique_temp(parent, "capgo-", ".tmp");
    free(parent);
    bool ok = cg_fsutil_copy_file(source, temp, err);
    if (ok && rename(temp, destination) != 0) ok = cg_fsutil_os_error(err, errno);
    if (!ok) unlink(temp);
    free(temp);
    return ok;
}

bool cg_fsutil_link_or_copy(const char *source, const char *destination, cg_error *err) {
    char *parent = prepare_parent(destination, err);
    if (!parent) return false;
    char *temp = cg_fsutil_unique_temp(parent, "capgo-", ".tmp");
    free(parent);
    /* std::fs::hard_link does not follow a symlink source (linkat without AT_SYMLINK_FOLLOW). */
    if (linkat(AT_FDCWD, source, AT_FDCWD, temp, 0) == 0) {
        if (rename(temp, destination) == 0) {
            free(temp);
            return true;
        }
        unlink(temp);
    }
    free(temp);
    return cg_fsutil_copy_atomically(source, destination, err);
}

bool cg_fsutil_write_atomically(const char *destination, const void *data, size_t len, cg_error *err) {
    char *parent = prepare_parent(destination, err);
    if (!parent) return false;
    char *temp = cg_fsutil_unique_temp(parent, "capgo-", ".tmp");
    free(parent);
    bool ok = true;
    int fd = cg_fsutil_open(temp, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) {
        ok = cg_fsutil_os_error(err, errno);
    } else {
        if (!cg_fsutil_write_all(fd, data, len)) ok = cg_fsutil_os_error(err, errno);
        if (close(fd) != 0 && ok) ok = cg_fsutil_os_error(err, errno);
    }
    if (ok && rename(temp, destination) != 0) ok = cg_fsutil_os_error(err, errno);
    if (!ok) unlink(temp);
    free(temp);
    return ok;
}

static char *sha256_finish_hex(mbedtls_sha256_context *context) {
    uint8_t digest[32];
    mbedtls_sha256_finish(context, digest);
    mbedtls_sha256_free(context);
    return cg_fsutil_hex(digest, sizeof digest);
}

bool cg_fsutil_write_verified(cg_reader *reader, const char *destination, const char *expected, char **hash,
                              cg_error *err) {
    *hash = NULL;
    char *parent = prepare_parent(destination, err);
    if (!parent) return false;
    char *temp = cg_fsutil_unique_temp(parent, "capgo-", ".tmp");
    free(parent);
    bool ok = true;
    int fd = cg_fsutil_open(temp, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) {
        ok = cg_fsutil_os_error(err, errno);
    } else {
        mbedtls_sha256_context context;
        mbedtls_sha256_init(&context);
        mbedtls_sha256_starts(&context, 0);
        uint8_t *buffer = cg_malloc(CG_IO_BUFFER_BYTES);
        while (true) {
            ptrdiff_t n = cg_reader_read(reader, buffer, CG_IO_BUFFER_BYTES, err);
            if (n < 0) {
                ok = false;
                break;
            }
            if (n == 0) break;
            mbedtls_sha256_update(&context, buffer, (size_t)n);
            if (!cg_fsutil_write_all(fd, buffer, (size_t)n)) {
                ok = cg_fsutil_os_error(err, errno);
                break;
            }
        }
        free(buffer);
        if (close(fd) != 0 && ok) ok = cg_fsutil_os_error(err, errno);
        char *actual = sha256_finish_hex(&context);
        if (ok && (!expected || cg_eq_nocase(expected, actual))) {
            if (rename(temp, destination) != 0) {
                ok = cg_fsutil_os_error(err, errno);
            } else {
                *hash = actual;
                actual = NULL;
            }
        }
        free(actual);
    }
    unlink(temp);
    free(temp);
    return ok;
}

char *cg_fsutil_sha256_reader(cg_reader *reader, cg_error *err) {
    mbedtls_sha256_context context;
    mbedtls_sha256_init(&context);
    mbedtls_sha256_starts(&context, 0);
    uint8_t *buffer = cg_malloc(CG_IO_BUFFER_BYTES);
    bool ok = true;
    while (true) {
        ptrdiff_t n = cg_reader_read(reader, buffer, CG_IO_BUFFER_BYTES, err);
        if (n < 0) {
            ok = false;
            break;
        }
        if (n == 0) break;
        mbedtls_sha256_update(&context, buffer, (size_t)n);
    }
    free(buffer);
    char *out = sha256_finish_hex(&context);
    if (!ok) {
        free(out);
        return NULL;
    }
    return out;
}

bool cg_fsutil_file_matches_hash(const char *path, const char *expected) {
    if (cg_empty(expected) || !cg_fsutil_is_file(path)) return false;
    cg_error err = CG_ERROR_INIT;
    char *actual = cg_checksum_sha256_file(path, &err);
    cg_err_clear(&err);
    bool matches = actual && cg_eq_nocase(actual, expected);
    free(actual);
    return matches;
}

bool cg_fsutil_modified_before(const char *path, uint64_t age_ms) {
    struct stat st;
    if (stat(path, &st) != 0) return false;
#if defined(__APPLE__)
    struct timespec modified = st.st_mtimespec;
#else
    struct timespec modified = st.st_mtim;
#endif
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    __int128 elapsed = ((__int128)now.tv_sec - modified.tv_sec) * 1000000000 + (now.tv_nsec - modified.tv_nsec);
    /* SystemTime::elapsed fails when the mtime is in the future. */
    if (elapsed < 0) return false;
    return elapsed > (__int128)age_ms * 1000000;
}

/* ---- block writer */

#define BLOCK_BYTES (1024 * 1024)
#define CHANNEL_DEPTH 4

/* AES-128-CBC with PKCS#7 padding, streaming (same rules as crypto/aes_cbc.rs CbcDecryptor). */
typedef struct {
    mbedtls_aes_context aes;
    uint8_t previous[16];
    uint8_t pending[16];
    bool has_pending;
    uint8_t partial[16];
    size_t partial_len;
} cbc_decryptor;

static void cbc_init(cbc_decryptor *d, const uint8_t key[16], const uint8_t iv[16]) {
    memset(d, 0, sizeof *d);
    mbedtls_aes_init(&d->aes);
    mbedtls_aes_setkey_dec(&d->aes, key, 128);
    memcpy(d->previous, iv, 16);
}

static void cbc_block(cbc_decryptor *d, const uint8_t *cipher, cg_buf *out) {
    uint8_t plain[16];
    mbedtls_aes_crypt_ecb(&d->aes, MBEDTLS_AES_DECRYPT, cipher, plain);
    for (int i = 0; i < 16; i++) plain[i] ^= d->previous[i];
    memcpy(d->previous, cipher, 16);
    if (d->has_pending) cg_buf_put(out, d->pending, 16);
    memcpy(d->pending, plain, 16);
    d->has_pending = true;
}

static void cbc_update(cbc_decryptor *d, const uint8_t *input, size_t len, cg_buf *out) {
    if (d->partial_len) {
        size_t take = 16 - d->partial_len < len ? 16 - d->partial_len : len;
        memcpy(d->partial + d->partial_len, input, take);
        d->partial_len += take;
        input += take;
        len -= take;
        if (d->partial_len < 16) return;
        d->partial_len = 0;
        cbc_block(d, d->partial, out);
    }
    size_t whole = len - len % 16;
    for (size_t at = 0; at < whole; at += 16) cbc_block(d, input + at, out);
    memcpy(d->partial, input + whole, len - whole);
    d->partial_len = len - whole;
}

static bool cbc_finish(cbc_decryptor *d, cg_buf *out) {
    bool ok = false;
    if (!d->partial_len && d->has_pending) {
        size_t pad = d->pending[15];
        ok = pad != 0 && pad <= 16;
        for (size_t i = 16 - (ok ? pad : 0); ok && i < 16; i++)
            if (d->pending[i] != pad) ok = false;
        if (ok) cg_buf_put(out, d->pending, 16 - pad);
    }
    mbedtls_aes_free(&d->aes);
    return ok;
}

typedef struct {
    cg_mutex mutex;
    cg_cond cond;
    uint8_t *blocks[CHANNEL_DEPTH];
    size_t lens[CHANNEL_DEPTH];
    size_t head, count;
    bool closed;   /* sender dropped */
    bool gone;     /* receiver ended */
    int refs;      /* writer + thread */
    cg_stream_sink_kind kind;
    uint8_t key[16], iv[16];
    char *plain;
    char *result;  /* thread result */
    bool finished; /* thread done */
} sink_channel;

struct cg_block_writer {
    int fd;
    uint8_t *block;
    size_t len;
    sink_channel *sink;
    pthread_t thread;
};

static void channel_release(sink_channel *ch) {
    cg_lock(&ch->mutex);
    bool last = --ch->refs == 0;
    cg_unlock(&ch->mutex);
    if (!last) return;
    for (size_t i = 0; i < ch->count; i++) free(ch->blocks[(ch->head + i) % CHANNEL_DEPTH]);
    free(ch->plain);
    free(ch->result);
    cg_cond_destroy(&ch->cond);
    cg_mutex_destroy(&ch->mutex);
    free(ch);
}

/* Next block (owned) or NULL once the sender is gone and the queue is empty. */
static uint8_t *channel_recv(sink_channel *ch, size_t *len) {
    cg_lock(&ch->mutex);
    while (!ch->count && !ch->closed) cg_cond_wait(&ch->cond, &ch->mutex);
    uint8_t *block = NULL;
    if (ch->count) {
        block = ch->blocks[ch->head];
        *len = ch->lens[ch->head];
        ch->head = (ch->head + 1) % CHANNEL_DEPTH;
        ch->count--;
        cg_cond_broadcast(&ch->cond);
    }
    cg_unlock(&ch->mutex);
    return block;
}

/* false when the receiver is gone (block freed). */
static bool channel_send(sink_channel *ch, uint8_t *block, size_t len) {
    cg_lock(&ch->mutex);
    while (ch->count == CHANNEL_DEPTH && !ch->gone) cg_cond_wait(&ch->cond, &ch->mutex);
    if (ch->gone) {
        cg_unlock(&ch->mutex);
        free(block);
        return false;
    }
    size_t slot = (ch->head + ch->count) % CHANNEL_DEPTH;
    ch->blocks[slot] = block;
    ch->lens[slot] = len;
    ch->count++;
    cg_cond_broadcast(&ch->cond);
    cg_unlock(&ch->mutex);
    return true;
}

static char *decrypt_sink(sink_channel *ch) {
    int fd = cg_fsutil_open(ch->plain, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) return NULL;
    cbc_decryptor decryptor;
    cbc_init(&decryptor, ch->key, ch->iv);
    mbedtls_sha256_context context;
    mbedtls_sha256_init(&context);
    mbedtls_sha256_starts(&context, 0);
    cg_buf out = {0};
    cg_buf pending_out = {0}; /* BufWriter */
    size_t produced = 0;
    bool ok = true;
    uint8_t *block;
    size_t len;
    while ((block = channel_recv(ch, &len))) {
        out.len = 0;
        cbc_update(&decryptor, block, len, &out);
        free(block);
        mbedtls_sha256_update(&context, (const uint8_t *)out.data, out.len);
        cg_buf_put(&pending_out, out.data, out.len);
        if (pending_out.len >= BLOCK_BYTES) {
            ok = cg_fsutil_write_all(fd, pending_out.data, pending_out.len);
            pending_out.len = 0;
        }
        produced += out.len;
        if (!ok) break;
    }
    char *result = NULL;
    out.len = 0;
    if (ok && cbc_finish(&decryptor, &out)) {
        mbedtls_sha256_update(&context, (const uint8_t *)out.data, out.len);
        cg_buf_put(&pending_out, out.data, out.len);
        produced += out.len;
        if (cg_fsutil_write_all(fd, pending_out.data, pending_out.len) && produced > 0) {
            result = sha256_finish_hex(&context);
        }
    } else if (ok) {
        ok = false;
    } else {
        mbedtls_aes_free(&decryptor.aes);
    }
    if (!result) mbedtls_sha256_free(&context);
    close(fd);
    cg_buf_free(&out);
    cg_buf_free(&pending_out);
    return result;
}

static void sink_thread(void *arg) {
    sink_channel *ch = arg;
    char *result = NULL;
    if (ch->kind == CG_SINK_HASH) {
        mbedtls_sha256_context context;
        mbedtls_sha256_init(&context);
        mbedtls_sha256_starts(&context, 0);
        uint8_t *block;
        size_t len;
        while ((block = channel_recv(ch, &len))) {
            mbedtls_sha256_update(&context, block, len);
            free(block);
        }
        result = sha256_finish_hex(&context);
    } else {
        result = decrypt_sink(ch);
        if (!result) unlink(ch->plain);
    }
    cg_lock(&ch->mutex);
    ch->gone = true;
    ch->result = result;
    ch->finished = true;
    cg_cond_broadcast(&ch->cond);
    cg_unlock(&ch->mutex);
    channel_release(ch);
}

cg_block_writer *cg_block_writer_new(int fd, const cg_stream_sink *sink) {
    cg_block_writer *writer = cg_calloc(1, sizeof *writer);
    writer->fd = fd;
    writer->block = cg_malloc(BLOCK_BYTES);
    if (sink && sink->kind != CG_SINK_NONE) {
        sink_channel *ch = cg_calloc(1, sizeof *ch);
        cg_mutex_init(&ch->mutex);
        cg_cond_init(&ch->cond);
        ch->kind = sink->kind;
        memcpy(ch->key, sink->key, 16);
        memcpy(ch->iv, sink->iv, 16);
        ch->plain = cg_strdup(sink->plain);
        ch->refs = 2;
        if (cg_spawn_joinable("blocksink", sink_thread, ch, &writer->thread)) {
            writer->sink = ch;
        } else {
            /* Rust panics when a thread cannot start; here the caller falls back to a file pass. */
            ch->refs = 1;
            channel_release(ch);
        }
    }
    return writer;
}

static bool flush_block(cg_block_writer *writer, cg_error *err) {
    if (!writer->len) return true;
    if (!cg_fsutil_write_all(writer->fd, writer->block, writer->len)) return cg_fsutil_os_error(err, errno);
    if (writer->sink) {
        uint8_t *block = writer->block;
        size_t len = writer->len;
        writer->block = cg_malloc(BLOCK_BYTES);
        /* A failed side thread only loses its result; the caller falls back to a file pass. */
        if (!channel_send(writer->sink, block, len)) {
            sink_channel *ch = writer->sink;
            writer->sink = NULL;
            cg_lock(&ch->mutex);
            ch->closed = true;
            cg_cond_broadcast(&ch->cond);
            cg_unlock(&ch->mutex);
            pthread_detach(writer->thread);
            channel_release(ch);
        }
    }
    writer->len = 0;
    return true;
}

bool cg_block_writer_write(cg_block_writer *writer, const void *data, size_t len, cg_error *err) {
    const uint8_t *p = data;
    while (len) {
        size_t take = BLOCK_BYTES - writer->len < len ? BLOCK_BYTES - writer->len : len;
        memcpy(writer->block + writer->len, p, take);
        writer->len += take;
        p += take;
        len -= take;
        if (writer->len == BLOCK_BYTES && !flush_block(writer, err)) return false;
    }
    return true;
}

static void close_sink(cg_block_writer *writer, bool join, char **hash) {
    sink_channel *ch = writer->sink;
    if (!ch) return;
    writer->sink = NULL;
    cg_lock(&ch->mutex);
    ch->closed = true;
    cg_cond_broadcast(&ch->cond);
    cg_unlock(&ch->mutex);
    if (join) {
        cg_join(writer->thread);
        if (hash) {
            *hash = ch->result;
            ch->result = NULL;
        }
    } else {
        pthread_detach(writer->thread);
    }
    channel_release(ch);
}

bool cg_block_writer_finish(cg_block_writer *writer, char **hash, cg_error *err) {
    *hash = NULL;
    bool ok = flush_block(writer, err);
    /* On a write error Rust returns before joining: the dropped writer detaches the thread. */
    close_sink(writer, ok, ok ? hash : NULL);
    close(writer->fd);
    free(writer->block);
    free(writer);
    return ok;
}

void cg_block_writer_free(cg_block_writer *writer) {
    if (!writer) return;
    close_sink(writer, false, NULL);
    close(writer->fd);
    free(writer->block);
    free(writer);
}
