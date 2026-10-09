/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * PLACEHOLDER engine (wave 1): only the host and test operations, so the leaf
 * modules (net, archive, crypto) can be tested through the C ABI. Replaced by
 * the full port of core/src/engine/mod.rs, which keeps these members/functions.
 */
#ifndef CG_ENGINE_H
#define CG_ENGINE_H

#include <stdatomic.h>

#include "engine/engine_api.h"
#include "host.h"

struct cg_engine {
    cg_host host;
    atomic_int refs;
};

/* User agent of the engine's HTTP client (malloc'd). */
char *cg_engine_user_agent(cg_engine *engine);

#endif
