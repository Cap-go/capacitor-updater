/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * The updater engine (Rust engine/mod.rs `Engine`).
 *
 * Hosts create one engine per process with their host callbacks and a JSON configuration,
 * then drive it with cg_engine_call (blocking; called off the UI thread). Long-running work
 * reports progress through events.
 *
 * Lifetime (Rust Arc<Engine> / Weak<Engine>): the engine carries a strong and a weak count.
 *  - The host's handle (capgo_engine_new) is one strong reference; cg_engine_free_handle
 *    drops it.
 *  - Code running inside an engine call borrows the caller's reference: functions taking a
 *    `cg_engine *` never retain it unless they hand it to another thread.
 *  - Worker threads keep a strong reference (cg_engine_retain, Rust `Arc` clone moved into
 *    the closure) or a weak one (cg_engine_downgrade, Rust `weak_self()`), upgraded per step
 *    with cg_engine_upgrade (NULL once the engine is dropped).
 *  - Dropping the last strong reference runs the Rust `Drop` (cg_stats_shutdown_stats), frees
 *    the members and releases the host context; the struct memory itself stays until the
 *    last weak reference goes, so a failed upgrade is always safe.
 *
 * Every member that belongs to a module is defined in that module's header (stats.h,
 * download.h, plugin/plugin.h); only engine.c creates and destroys them.
 */
#ifndef CG_ENGINE_H
#define CG_ENGINE_H

#include <stdatomic.h>
#include <stddef.h>

#include "engine/config.h"
#include "engine/download.h"
#include "engine/engine_api.h"
#include "engine/plugin/plugin.h"
#include "engine/stats.h"
#include "host.h"
#include "net.h"
#include "rt/sync.h"

struct cg_engine {
    /* Rust Arc counts. `weak` includes one reference shared by all strong ones. */
    atomic_size_t strong;
    atomic_size_t weak;

    cg_host host;
    /* The engine's HTTP client (Rust `http: Http`), created with the engine. */
    cg_net_http *http;

    /* RwLock<Arc<EngineConfig>>: `config` is the published snapshot, swapped under
     * `config_lock` (held only to retain / swap the pointer, never across other work);
     * `config_write` serializes writers (Rust config_mut). Use the functions below. */
    cg_mutex config_lock;
    cg_mutex config_write;
    cg_engine_config *config;

    /* stats.h */
    cg_stats_state stats;
    /* Serializes cg_store_delete_bundle (Rust `delete_lock`). */
    cg_mutex delete_lock;
    /* In-flight downloads per version (download.h; the same version can download twice at
     * once, e.g. `download()` overlapping the update cycle). */
    cg_download_map downloads;
    /* plugin/plugin.h */
    cg_plugin plugin;
    /* Set when the host releases the engine: callers waiting for a scheduled download return. */
    atomic_bool downloads_detached;
};

/* ---- references (Rust Arc / Weak) */

/* A weak reference. Same pointer as the engine, typed apart so it is never used directly. */
typedef struct cg_engine_weak cg_engine_weak;

/* Arc::clone: returns `engine`. */
cg_engine *cg_engine_retain(cg_engine *engine);
/* Drops a strong reference; the last one runs the engine's drop. NULL-safe. */
void cg_engine_release(cg_engine *engine);
/* Rust weak_self(): a new weak reference (release with cg_engine_weak_release). */
cg_engine_weak *cg_engine_downgrade(cg_engine *engine);
/* Weak::upgrade: a new strong reference, NULL once the engine is dropped. */
cg_engine *cg_engine_upgrade(cg_engine_weak *weak);
/* NULL-safe. */
void cg_engine_weak_release(cg_engine_weak *weak);
/* Engine::sleep_unless_dropped: sleeps, then upgrades (NULL when dropped meanwhile). */
cg_engine *cg_engine_sleep_unless_dropped(cg_engine_weak *weak, int64_t ms);

/* ---- configuration (Rust config() / config_mut()) */

/* A snapshot of the settings (retained; release with cg_config_release). Later changes do
 * not affect it, and holding it never blocks a writer (Rust readers never keep the lock). */
cg_engine_config *cg_engine_config_snapshot(cg_engine *engine);
/* Copy of one string member of the current snapshot (malloc'd, never NULL), e.g.
 * CG_CONFIG_DUP(engine, stats_url), CG_CONFIG_DUP(engine, keys.next). */
char *cg_engine_config_dup(cg_engine *engine, size_t offset);
#define CG_CONFIG_DUP(engine, field) cg_engine_config_dup((engine), offsetof(cg_engine_config, field))
/* One boolean member of the current snapshot: CG_CONFIG_FLAG(engine, preview_session). */
bool cg_engine_config_flag(cg_engine *engine, size_t offset);
#define CG_CONFIG_FLAG(engine, field) cg_engine_config_flag((engine), offsetof(cg_engine_config, field))

/* Rust config_mut(): exclusive access for a change. Returns a private copy of the current
 * settings to modify, then cg_engine_config_commit publishes it (or _abort drops it). Keep it
 * to the change itself: no snapshot of this engine's writer, host callback or network call
 * in between (writers are serialized). Example (Rust `self.config_mut().default_channel = x`):
 *     cg_engine_config *config = cg_engine_config_begin(engine);
 *     cg_replace(&config->default_channel, cg_strdup(x));
 *     cg_engine_config_commit(engine, config);  */
cg_engine_config *cg_engine_config_begin(cg_engine *engine);
void cg_engine_config_commit(cg_engine *engine, cg_engine_config *config);
void cg_engine_config_abort(cg_engine *engine, cg_engine_config *config);

/* Engine::configure: applies runtime settings (endpoints, ids, public key, preview session,
 * timeout), all or nothing; then updates the HTTP client (user agent, timeout, redirects). */
bool cg_engine_configure(cg_engine *engine, const cj *value, cg_error *err);

/* User agent of the engine's HTTP client (malloc'd). */
char *cg_engine_user_agent(cg_engine *engine);

/* Engine::call: runs one operation. `input` NULL reads as {}. Test operations first (with
 * CAPGO_TEST_SUPPORT), then ops.c, then the stateless operations of api.c. Owned value, or
 * NULL with *err. */
cj *cg_engine_call(cg_engine *engine, const char *operation, const cj *input, cg_error *err);

/* ---- threads (Rust Engine::spawn) */

/* Starts a detached thread "capgo-<name>". When the OS refuses, logs "Could not start the
 * <name> thread: <error>" and returns false: `arg` is untouched, the caller still owns it
 * (Rust drops the closure). */
bool cg_engine_spawn(cg_engine *engine, const char *name, void (*run)(void *arg), void *arg);

/* Closure helpers. `drop_ctx` (may be NULL) frees ctx once the work ran, or right away when
 * the thread cannot start.
 * - spawn_strong: the thread owns a strong reference for its whole run (Rust: an
 *   `Arc<Engine>` moved into the closure, e.g. `let engine = self.clone(); spawn(move ||..)`
 *   or `weak_self().upgrade()` before spawning).
 * - spawn_weak: the thread gets a weak reference to upgrade per step (Rust:
 *   `let weak = self.weak_self(); spawn(move || ...)`); the helper releases it afterwards. */
bool cg_engine_spawn_strong(cg_engine *engine, const char *name, void (*run)(cg_engine *engine, void *ctx),
                            void *ctx, void (*drop_ctx)(void *ctx));
bool cg_engine_spawn_weak(cg_engine *engine, const char *name, void (*run)(cg_engine_weak *weak, void *ctx),
                          void *ctx, void (*drop_ctx)(void *ctx));

#endif
