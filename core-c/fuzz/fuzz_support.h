/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * Shared helpers of the libFuzzer targets (core-c/fuzz/<target>.c). The Rust core has the
 * same targets with the same input format in core/fuzz/fuzz_targets/<target>.rs, and both
 * share the seed corpus in fuzz/corpus/<target>.
 */
#ifndef CG_FUZZ_SUPPORT_H
#define CG_FUZZ_SUPPORT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "capgo_updater_core.h"

/* The public key the crypto targets use (native-contract-tests/cli/cli-crypto.json). */
extern const char FZ_PUBLIC_KEY[];

/* Aborts (a libFuzzer crash) with a message: the fuzz harness found a broken invariant. */
void fz_fail(const char *format, ...) __attribute__((noreturn, format(printf, 1, 2)));

/* A per-process scratch directory (created once). */
const char *fz_scratch_dir(void);
/* Removes a file or a directory tree; missing paths are fine. */
void fz_remove_tree(const char *path);
/* Writes bytes to a file (aborts on failure). */
void fz_write_file(const char *path, const uint8_t *data, size_t len);

/* A loopback HTTP server that answers every request with the current response bytes,
 * then half-closes. Started once; returns the port. */
uint16_t fz_server_port(void);
void fz_server_set_response(const uint8_t *data, size_t len);

/* Host callbacks over an in-memory store; every request goes through the loopback server
 * (proxyForUrl), plain HTTP is permitted, HTTPS is refused (no certificate verifier). */
CapgoHostCallbacks fz_host_callbacks(void);

#endif
