/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* path_guard: the input is `<base> 0xFF <relative path>` (no 0xFF: the relative path under
 * /data/app/versions). Manifest file_name, zip entry and bundle id guards
 * (cg_paths_resolve_path_inside, cg_paths_resolve_manifest_target_path,
 * cg_paths_builtin_asset_path) must keep every accepted path strictly inside its base.
 * Rust: core/fuzz/fuzz_targets/path_guard.rs. */

#include <stdlib.h>
#include <string.h>

#include "fuzz_support.h"
#include "path_check.h"
#include "paths.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    const uint8_t *split = memchr(data, 0xFF, size);
    char *base;
    char *relative;
    if (split) {
        base = strndup((const char *)data, (size_t)(split - data));
        relative = strndup((const char *)split + 1, size - (size_t)(split - data) - 1);
    } else {
        base = strdup("/data/app/versions");
        relative = strndup((const char *)data, size);
    }
    if (!base || !relative) abort();

    cg_error err = CG_ERROR_INIT;
    char *resolved = cg_paths_resolve_path_inside(base, relative, &err);
    bool traversal = cg_paths_contains_path_traversal_segment(relative);
    if (resolved) {
        if (traversal) fz_fail("%s accepted with a .. segment", relative);
        if (relative[0] == '/' || relative[0] == '~') fz_fail("%s accepted as absolute", relative);
        fz_check_inside(base, relative, resolved);
    }
    free(resolved);
    cg_err_clear(&err);

    char *target = cg_paths_resolve_manifest_target_path(base, relative, &err);
    if (target) fz_check_inside(base, relative, target);
    free(target);
    cg_err_clear(&err);

    char *asset = cg_paths_builtin_asset_path(relative, &err);
    if (asset) {
        if (strncmp(asset, "public/", 7) != 0) fz_fail("builtin asset %s -> %s", relative, asset);
        fz_check_inside("public", relative, asset);
    }
    free(asset);
    cg_err_clear(&err);

    free(base);
    free(relative);
    return 0;
}
