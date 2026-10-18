/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* http_response: the input is `<mode> <raw HTTP response>`, served by a loopback server (also
 * the proxy for every other URL, so redirects never leave the machine). The low bit of
 * `mode` picks a buffered GET (cg_http_get: status line, headers, chunked and
 * Content-Length bodies, gzip, redirects) or a streamed download (cg_http_download).
 * Rust: core/fuzz/fuzz_targets/http_response.rs. */

#include <stdio.h>
#include <stdlib.h>

#include "fuzz_support.h"
#include "host.h"
#include "net.h"

static bool count_bytes(void *context, const cg_net_stream *event, cg_net_error *err) {
    (void)err;
    size_t *total = context;
    if (event->kind == CG_NET_STREAM_CHUNK) *total += event->len;
    return *total < (64u << 20);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size == 0) return 0;
    uint16_t port = fz_server_port();
    fz_server_set_response(data + 1, size - 1);
    cg_host host = {fz_host_callbacks()};
    cg_http *http = cg_http_new(&host, "capgo-fuzz", 2000);
    char url[64];
    snprintf(url, sizeof url, "http://127.0.0.1:%u/fuzz", (unsigned)port);
    cg_net_error err = CG_NET_ERROR_INIT;
    if (data[0] & 1) {
        size_t total = 0;
        cg_net_stream_head head = {0};
        cg_http_download(http, url, NULL, 0, count_bytes, &total, &head, &err);
        cg_net_stream_head_clear(&head);
    } else {
        cg_net_response response = {0};
        if (cg_http_get(http, url, &response, &err)) cj_free(cg_net_response_json(&response));
        cg_net_response_clear(&response);
    }
    cg_net_error_clear(&err);
    cg_http_free(http);
    cg_host_release(&host);
    return 0;
}
