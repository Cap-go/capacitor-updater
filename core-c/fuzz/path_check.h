/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* The path guard invariant shared by the path_guard and manifest targets: a resolved path is
 * `<base>/<components>` with no empty, `.` or `..` component and no backslash. */
#ifndef CG_FUZZ_PATH_CHECK_H
#define CG_FUZZ_PATH_CHECK_H

#include <string.h>

#include "fuzz_support.h"

static inline void fz_check_inside(const char *base, const char *relative, const char *resolved) {
    size_t base_len = strlen(base);
    while (base_len > 0 && base[base_len - 1] == '/') base_len--;
    const char *prefix = base_len == 0 ? "/" : base;
    size_t prefix_len = base_len == 0 ? 1 : base_len;
    if (strncmp(resolved, prefix, prefix_len) != 0) fz_fail("%s + %s -> %s: outside base", base, relative, resolved);
    const char *rest = resolved + prefix_len;
    if (!(prefix_len == 1 && prefix[0] == '/')) {
        if (*rest != '/') fz_fail("%s + %s -> %s: not a child", base, relative, resolved);
        rest++;
    }
    if (*rest == 0) fz_fail("%s + %s -> %s: resolves to the base itself", base, relative, resolved);
    if (strchr(rest, '\\')) fz_fail("%s + %s -> %s: backslash", base, relative, resolved);
    const char *segment = rest;
    for (;;) {
        const char *end = strchr(segment, '/');
        size_t len = end ? (size_t)(end - segment) : strlen(segment);
        if (len == 0) fz_fail("%s + %s -> %s: empty segment", base, relative, resolved);
        if ((len == 1 && segment[0] == '.') || (len == 2 && segment[0] == '.' && segment[1] == '.'))
            fz_fail("%s + %s -> %s: dot segment", base, relative, resolved);
        if (!end) break;
        segment = end + 1;
    }
}

#endif
