/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* rsa_key: the input is a configured public key (PEM text, or DER bytes). Parses it both
 * ways (cg_rsa_from_pem, cg_rsa_from_der), computes its key id, and runs one public
 * operation with each key that parses. Rust: core/fuzz/fuzz_targets/rsa_key.rs. */

#include <stdlib.h>
#include <string.h>

#include "crypto/crypto.h"
#include "crypto/rsa.h"
#include "fuzz_support.h"

static void exercise(cg_rsa_public_key *key) {
    if (!key) return;
    /* Same value as the Rust target: one RSA-2048 block (other key sizes refuse it). */
    size_t size = 256;
    uint8_t value[256] = {0};
    value[size - 1] = 2;
    size_t out_len = 0;
    cg_error err = CG_ERROR_INIT;
    free(cg_rsa_public_op(key, value, size, &out_len, &err));
    cg_err_clear(&err);
    free(cg_rsa_public_decrypt(key, value, size, &out_len, &err));
    cg_err_clear(&err);
    cg_rsa_release(key);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    char *text = strndup((const char *)data, size);
    if (!text) abort();
    cg_error err = CG_ERROR_INIT;
    exercise(cg_rsa_from_pem(text, &err));
    cg_err_clear(&err);
    exercise(cg_rsa_from_der(data, size, &err));
    cg_err_clear(&err);
    free(cg_crypto_key_id(text));
    free(text);
    return 0;
}
