/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* rsa_checksum: the input is a signed bundle checksum (hex or base64 text) checked with the
 * configured key (cg_crypto_decrypt_checksum), then the raw block through the public
 * decrypt and the PKCS#1 type-1 unpadding. Rust: core/fuzz/fuzz_targets/rsa_checksum.rs. */

#include <stdlib.h>
#include <string.h>

#include "crypto/crypto.h"
#include "crypto/rsa.h"
#include "fuzz_support.h"

static cg_rsa_public_key *key;

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    cg_error err = CG_ERROR_INIT;
    if (!key) {
        key = cg_rsa_from_pem(FZ_PUBLIC_KEY, &err);
        if (!key) fz_fail("fuzz public key refused");
    }
    char *text = strndup((const char *)data, size);
    if (!text) abort();
    char *checksum = cg_crypto_decrypt_checksum(text, FZ_PUBLIC_KEY, &err);
    if (checksum && strlen(checksum) % 2 != 0) fz_fail("checksum %s is not hex", checksum);
    free(checksum);
    cg_err_clear(&err);
    free(text);

    size_t out_len = 0;
    uint8_t *payload = cg_rsa_unpad_type1(data, size, &out_len);
    if (payload && (out_len == 0 || out_len + 11 > size)) fz_fail("unpadded %zu bytes from %zu", out_len, size);
    free(payload);
    free(cg_rsa_public_decrypt(key, data, size, &out_len, &err));
    cg_err_clear(&err);
    return 0;
}
