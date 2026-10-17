/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* aes_cbc: the input is `<key 16> <iv 16> <ciphertext>`. Decrypts it in one call and in
 * uneven chunks (cg_cbc_update / cg_cbc_finish, PKCS#7 padding check): both must agree.
 * The whole input is also read as a session key `<iv>:<key>` and opened with the
 * configured public key (cg_crypto_bundle_session_key). Rust: core/fuzz/fuzz_targets/aes_cbc.rs. */

#include <stdlib.h>
#include <string.h>

#include "crypto/aes_cbc.h"
#include "crypto/crypto.h"
#include "fuzz_support.h"
#include "rt/str.h"

/* Plaintext of ciphertext decrypted in chunks of chunk(i) bytes; false on a padding error. */
static bool decrypt(const uint8_t *key, const uint8_t *iv, const uint8_t *data, size_t size, bool chunked,
                    cg_buf *out) {
    cg_cbc_decryptor decryptor;
    cg_cbc_init(&decryptor, key, iv);
    size_t offset = 0;
    size_t step = 0;
    while (offset < size) {
        size_t len = chunked ? (size_t)(1 + (step * 7 + data[offset]) % 37) : size;
        if (len > size - offset) len = size - offset;
        cg_cbc_update_buf(&decryptor, data + offset, len, out);
        offset += len;
        step++;
    }
    cg_error err = CG_ERROR_INIT;
    bool ok = cg_cbc_finish_buf(&decryptor, out, &err);
    cg_err_clear(&err);
    cg_cbc_free(&decryptor);
    return ok;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size >= 32) {
        cg_buf whole = {0}, chunks = {0};
        bool whole_ok = decrypt(data, data + 16, data + 32, size - 32, false, &whole);
        bool chunks_ok = decrypt(data, data + 16, data + 32, size - 32, true, &chunks);
        if (whole_ok != chunks_ok) fz_fail("chunked decryption disagrees on the padding");
        if (whole_ok && (whole.len != chunks.len || memcmp(whole.data, chunks.data, whole.len) != 0))
            fz_fail("chunked decryption gives other bytes");
        size_t ciphertext = size - 32;
        if (whole_ok && (ciphertext == 0 || ciphertext % 16 != 0 || whole.len >= ciphertext || whole.len + 16 < ciphertext))
            fz_fail("%zu plaintext bytes from %zu ciphertext bytes", whole.len, ciphertext);
        cg_buf_free(&whole);
        cg_buf_free(&chunks);
    }
    char *text = strndup((const char *)data, size);
    if (!text) abort();
    cg_session_key session;
    bool has_key = false;
    cg_error err = CG_ERROR_INIT;
    cg_crypto_bundle_session_key(FZ_PUBLIC_KEY, text, &session, &has_key, &err);
    cg_err_clear(&err);
    free(text);
    return 0;
}
