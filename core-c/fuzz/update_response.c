/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* update_response: the input is the body of the update server's reply (HTTP 200, JSON),
 * served by a loopback server and read by the engine's update check (`getLatest`: body
 * limits, JSON, error and kind mapping). Rust: core/fuzz/fuzz_targets/update_response.rs. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "capgo_updater_core.h"
#include "fuzz_support.h"
#include "rt/json.h"
#include "rt/str.h"

static CapgoEngine *engine;
static char *input;

static void create_engine(void) {
    const char *dir = fz_scratch_dir();
    cj *config = cj_obj();
    cj_set(config, "platform", cj_str("android"));
    cj_set(config, "appId", cj_str("app.capgo.fuzz"));
    cj_set(config, "versionBuild", cj_str("1.0.0"));
    cj_set(config, "deviceId", cj_str("fuzz"));
    cj_set(config, "timeoutMs", cj_u64(2000));
    cj_set(config, "storageRoot", cj_str_own(cg_fmt("%s", dir)));
    cj_set(config, "bundleRoot", cj_str_own(cg_fmt("%s/versions", dir)));
    cj_set(config, "cacheDir", cj_str_own(cg_fmt("%s/cache", dir)));
    char *text = cj_print(config);
    engine = capgo_engine_new(text, fz_host_callbacks());
    if (!engine) fz_fail("engine refused the fuzz configuration");
    free(text);
    cj_free(config);
    input = cg_fmt("{\"updateUrl\":\"http://127.0.0.1:%u/updates\"}", (unsigned)fz_server_port());
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (!engine) create_engine();
    char head[160];
    int head_len = snprintf(head, sizeof head,
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: %zu\r\n\r\n", size);
    uint8_t *response = malloc((size_t)head_len + size + 1);
    if (!response) abort();
    memcpy(response, head, (size_t)head_len);
    if (size) memcpy(response + head_len, data, size);
    fz_server_set_response(response, (size_t)head_len + size);
    free(response);
    char *reply = capgo_engine_call(engine, "getLatest", input);
    char *error = NULL;
    cj *parsed = cj_parse(reply, &error);
    if (!parsed) fz_fail("engine reply is not JSON: %s", reply);
    free(error);
    cj_free(parsed);
    capgo_core_free(reply);
    return 0;
}
