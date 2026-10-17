/* Alt-Svc discovery parser, same input and origin as core/fuzz/fuzz_targets/alt_svc.rs. */
#include "altsvc.h"
#include <stdlib.h>
#include <string.h>
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t len) {
    char *value = cg_utf8_lossy(data, len);
    cg_altsvc_parse(value, strlen(value), "example.com");
    free(value);
    return 0;
}
