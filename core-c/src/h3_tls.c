/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include "h3.h"
#include "rt/str.h"
#include <mbedtls/md.h>
#include <mbedtls/pk.h>
#include <mbedtls/rsa.h>
#include <mbedtls/x509_crt.h>
#include <ngtcp2/ngtcp2_crypto.h>
#include <ngtcp2/ngtcp2_crypto_picotls.h>
#include <picotls.h>
#include <picotls/mbedtls.h>
#include <psa/crypto.h>
#include <stdlib.h>

/* Verify CertificateVerify as well as the host's chain/pinning decision. A host
 * accepting a chain does not prove that the peer owns the certificate's key. */
static int verify_signature(void *data, uint16_t algo, ptls_iovec_t message, ptls_iovec_t signature) {
    mbedtls_x509_crt *leaf = data;
    int result = PTLS_ALERT_DECRYPT_ERROR;
    if (message.len || signature.len) {
        mbedtls_md_type_t md = MBEDTLS_MD_NONE;
        bool pss = false;
        switch (algo) {
        case PTLS_SIGNATURE_ECDSA_SECP256R1_SHA256:
            md = MBEDTLS_MD_SHA256;
            break;
        case PTLS_SIGNATURE_ECDSA_SECP384R1_SHA384:
            md = MBEDTLS_MD_SHA384;
            break;
        case PTLS_SIGNATURE_ECDSA_SECP521R1_SHA512:
            md = MBEDTLS_MD_SHA512;
            break;
        case PTLS_SIGNATURE_RSA_PSS_RSAE_SHA256:
            md = MBEDTLS_MD_SHA256;
            pss = true;
            break;
        case PTLS_SIGNATURE_RSA_PSS_RSAE_SHA384:
            md = MBEDTLS_MD_SHA384;
            pss = true;
            break;
        case PTLS_SIGNATURE_RSA_PSS_RSAE_SHA512:
            md = MBEDTLS_MD_SHA512;
            pss = true;
            break;
        }
        const mbedtls_md_info_t *info = mbedtls_md_info_from_type(md);
        uint8_t hash[64];
        if (info && mbedtls_md(info, message.base, message.len, hash) == 0) {
            int rv;
            if (pss) {
                mbedtls_pk_rsassa_pss_options options = {md, (int)mbedtls_md_get_size(info)};
                rv = mbedtls_pk_verify_ext(MBEDTLS_PK_RSASSA_PSS, &options, &leaf->pk, md, hash,
                                           mbedtls_md_get_size(info), signature.base, signature.len);
            } else if (mbedtls_pk_can_do(&leaf->pk, MBEDTLS_PK_ECDSA)) {
                rv = mbedtls_pk_verify(&leaf->pk, md, hash, mbedtls_md_get_size(info), signature.base,
                                       signature.len);
            } else
                rv = -1;
            if (rv == 0)
                result = 0;
        }
    }
    mbedtls_x509_crt_free(leaf);
    free(leaf);
    return result;
}

static int verify_certificate(ptls_verify_certificate_t *self, ptls_t *tls, const char *server_name,
                              int (**verify_sign)(void *, uint16_t, ptls_iovec_t, ptls_iovec_t),
                              void **verify_data, ptls_iovec_t *certs, size_t count) {
    ngtcp2_crypto_conn_ref *ref = *ptls_get_data_ptr(tls);
    cg_h3_tls_peer *peer = ref ? ref->user_data : NULL;
    if (!peer || count == 0 || count > 32)
        return PTLS_ALERT_BAD_CERTIFICATE;
    mbedtls_x509_crt *chain = cg_calloc(1, sizeof *chain);
    mbedtls_x509_crt_init(chain);
    bool ok = true;
    for (size_t i = 0; i < count && ok; i++)
        ok = mbedtls_x509_crt_parse_der(chain, certs[i].base, certs[i].len) == 0;
    net_io_error err = {0};
    if (ok)
        ok = net_tls_verify_chain(chain, peer->host, peer->server_name, &err);
    net_io_clear(&err);
    if (!ok) {
        mbedtls_x509_crt_free(chain);
        free(chain);
        return PTLS_ALERT_BAD_CERTIFICATE;
    }
    *verify_sign = verify_signature;
    *verify_data = chain;
    return 0;
}

static const uint16_t algorithms[] = {PTLS_SIGNATURE_ECDSA_SECP256R1_SHA256,
                                      PTLS_SIGNATURE_ECDSA_SECP384R1_SHA384,
                                      PTLS_SIGNATURE_ECDSA_SECP521R1_SHA512,
                                      PTLS_SIGNATURE_RSA_PSS_RSAE_SHA256,
                                      PTLS_SIGNATURE_RSA_PSS_RSAE_SHA384,
                                      PTLS_SIGNATURE_RSA_PSS_RSAE_SHA512,
                                      UINT16_MAX};
static ptls_verify_certificate_t verifier = {verify_certificate, algorithms};
static ptls_context_t context;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static bool ready;
static void initialize(void) {
    if (psa_crypto_init() != PSA_SUCCESS)
        return;
    context.random_bytes = ptls_mbedtls_random_bytes;
    context.get_time = &ptls_get_time;
    context.key_exchanges = ptls_mbedtls_key_exchanges;
    context.cipher_suites = ptls_mbedtls_cipher_suites;
    context.verify_certificate = &verifier;
    context.omit_end_of_early_data = 1;
    ready = ngtcp2_crypto_picotls_configure_client_context(&context) == 0;
}
ptls_context_t *cg_h3_tls_context(void) {
    pthread_once(&once, initialize);
    return ready ? &context : NULL;
}
