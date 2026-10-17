/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* zip: the input is a bundle zip. Central directory, entry reader, inflate, CRC and the
 * zip-slip / symlink guards (cg_archive_extract_zip), then the single-folder unwrap
 * (cg_archive_install_extracted). Rust: core/fuzz/fuzz_targets/zip.rs. */

#include <stdio.h>
#include <stdlib.h>

#include "engine/archive.h"
#include "fuzz_support.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    char zip[600], out[600], bundle[600];
    snprintf(zip, sizeof zip, "%s/input.zip", fz_scratch_dir());
    snprintf(out, sizeof out, "%s/extract", fz_scratch_dir());
    snprintf(bundle, sizeof bundle, "%s/bundle", fz_scratch_dir());
    fz_remove_tree(out);
    fz_remove_tree(bundle);
    fz_write_file(zip, data, size);
    cg_extract_error error = CG_EXTRACT_ERROR_INIT;
    if (cg_archive_extract_zip(zip, out, NULL, NULL, NULL, &error)) {
        cg_error err = CG_ERROR_INIT;
        cg_archive_install_extracted(out, bundle, &err);
        cg_err_clear(&err);
    } else {
        size_t len = 0;
        free(cg_extract_error_message(&error, &len));
    }
    cg_extract_error_clear(&error);
    fz_remove_tree(out);
    fz_remove_tree(bundle);
    return 0;
}
