/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* json: the input is JSON text (manifests, server replies, stored records). Parses it and
 * checks that printing and parsing again gives the same value. Rust: serde_json. */

#include <stdlib.h>
#include <string.h>

#include "fuzz_support.h"
#include "rt/json.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    char *error = NULL;
    cj *value = cj_parsen((const char *)data, size, &error);
    free(error);
    if (!value) return 0;
    char *printed = cj_print(value);
    char *again_error = NULL;
    cj *again = cj_parse(printed, &again_error);
    if (!again) fz_fail("printed JSON does not parse: %s (%s)", printed, again_error ? again_error : "");
    if (!cj_eq(value, again)) fz_fail("JSON round trip changed the value: %s", printed);
    char *printed_again = cj_print(again);
    if (strcmp(printed, printed_again) != 0) fz_fail("JSON printing is not stable: %s / %s", printed, printed_again);
    free(printed_again);
    free(printed);
    cj_free(again);
    cj_free(value);
    return 0;
}
