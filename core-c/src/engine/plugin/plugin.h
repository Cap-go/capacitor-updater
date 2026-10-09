/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * The Capacitor plugin layer (Rust engine/plugin/mod.rs): update cycle, direct updates,
 * rollback, delay conditions, preview sessions, channels and launch telemetry.
 *
 * Hosts keep only what needs the platform (bridge, WebView, lifecycle observers, UI) and
 * reach it through host hooks named CG_HOOK_*. Every public JavaScript method is one engine
 * operation (`pluginMethod`), which answers `{ "resolve": value }` or
 * `{ "reject": { message, code?, data? } }`.
 *
 * Files: plugin.c (this header: config, state, hooks/keys, helpers), flow.c, methods.c,
 * ready.c, channel.c, delay.c, preview.c, telemetry.c, each with its header. Rust private
 * items of mod.rs used by the child modules (mark_cleanup, object_bool, object_i64, the
 * Plugin fields) are exposed here too.
 *
 * Locks: keep every guard scope exactly as Rust does (a statement-long temporary such as
 * `self.plugin_state().x = y`, or a `let guard` alive until `drop(guard)` / end of block).
 * `state_lock` (Rust plugin_state()) guards `state`; Rust never calls the host, the network
 * or the store while holding it, neither may C. `cycle` serializes starting the update
 * cycle and `confirmation` serializes notifyAppReady with the rollback check: both are held
 * across store / host calls, as in Rust. Known nesting: cleanup.lock -> state_lock
 * (wait_for_cleanup), cycle -> state_lock, confirmation -> state_lock. `ready.lock` and
 * `lifecycle_lock` are leaves.
 */
#ifndef CG_ENGINE_PLUGIN_H
#define CG_ENGINE_PLUGIN_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "bundle.h"
#include "engine/engine_api.h"
#include "rt/err.h"
#include "rt/json.h"
#include "rt/str.h"
#include "rt/sync.h"

#define CG_DEFAULT_UPDATE_URL "https://plugin.capgo.app/updates"
#define CG_DEFAULT_STATS_URL "https://plugin.capgo.app/stats"
#define CG_DEFAULT_CHANNEL_URL "https://plugin.capgo.app/channel_self"
/* A download that runs longer than this no longer blocks new update checks. */
#define CG_DOWNLOAD_STUCK_TIMEOUT_MS 600000
/* Pacing between obsolete bundle deletes after a native update. */
#define CG_OBSOLETE_DELETE_PACING_MS 75
/* A bundle that has not confirmed itself yet (`notifyAppReady`) gets at least this long
 * before it is rolled back, on both platforms. */
#define CG_PENDING_BUNDLE_MIN_APP_READY_TIMEOUT_MS 30000

/* ---- hook names (Rust plugin::hooks); payloads documented in mod.rs */
#define CG_HOOK_APPLY_BUNDLE "applyBundle"
#define CG_HOOK_SPLASH "splash"
#define CG_HOOK_PREVIEW_LOADER "previewLoader"
#define CG_HOOK_PREVIEW_NOTICE "previewNotice"
#define CG_HOOK_SHAKE_MENU "shakeMenu"
#define CG_HOOK_SHAKE_MENU_PROGRESS "shakeMenuProgress"
#define CG_HOOK_KEEP_URL_PATH "keepUrlPath"
#define CG_HOOK_BACKGROUND_TASK "backgroundTask"
#define CG_HOOK_EXCLUDE_FROM_BACKUP "excludeFromBackup"
#define CG_HOOK_CLEARTEXT_PERMITTED "cleartextPermitted"
#define CG_HOOK_SCHEDULE_DOWNLOAD "scheduleDownload"
#define CG_HOOK_PROXY_FOR_URL "proxyForUrl"
#define CG_HOOK_RELEASE_METHOD_LANE "releaseMethodLane"

/* ---- persisted keys owned by the plugin layer (Rust plugin::keys) */
#define CG_KEY_CUSTOM_ID "CapacitorUpdater.customId"
#define CG_KEY_UPDATE_URL "CapacitorUpdater.updateUrl"
#define CG_KEY_STATS_URL "CapacitorUpdater.statsUrl"
#define CG_KEY_CHANNEL_URL "CapacitorUpdater.channelUrl"
#define CG_KEY_DEFAULT_CHANNEL "CapacitorUpdater.defaultChannel"
#define CG_KEY_PREVIEW_SESSION "CapacitorUpdater.previewSession"
#define CG_KEY_PREVIEW_ALERT_PENDING "CapacitorUpdater.previewSessionAlertPending"
#define CG_KEY_PREVIEW_SESSIONS "CapacitorUpdater.previewSessions"
#define CG_KEY_PREVIEW_APP_ID "CapacitorUpdater.previewAppId"
#define CG_KEY_PREVIEW_PAYLOAD_URL "CapacitorUpdater.previewPayloadUrl"
#define CG_KEY_PREVIEW_NAME "CapacitorUpdater.previewName"
#define CG_KEY_PREVIEW_SOURCE "CapacitorUpdater.previewSource"
#define CG_KEY_PREVIEW_PREVIOUS_SHAKE_MENU "CapacitorUpdater.previewPreviousShakeMenu"
#define CG_KEY_PREVIEW_PREVIOUS_SHAKE_CHANNEL_SELECTOR "CapacitorUpdater.previewPreviousShakeChannelSelector"
#define CG_KEY_PREVIEW_PREVIOUS_NEXT_BUNDLE "CapacitorUpdater.previewPreviousNextBundle"
#define CG_KEY_PREVIEW_PREVIOUS_APP_ID "CapacitorUpdater.previewPreviousAppId"
#define CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL "CapacitorUpdater.previewPreviousDefaultChannel"
#define CG_KEY_PREVIEW_PREVIOUS_DEFAULT_CHANNEL_WAS_SET "CapacitorUpdater.previewPreviousDefaultChannelWasSet"
#define CG_KEY_INSTALL_MARKER_CREATED "CapacitorUpdater.defaultChannelInstallMarkerCreated"
#define CG_KEY_LAST_FAILED_BUNDLE "CapacitorUpdater.lastFailedBundle"
#define CG_KEY_LAST_VERSION_OS "CapacitorUpdater.lastVersionOs"
#define CG_KEY_LAST_VERSION_BUILD "CapacitorUpdater.lastVersionBuild"
#define CG_KEY_LAST_VERSION_CODE "CapacitorUpdater.lastVersionCode"
#define CG_KEY_DELAY_CONDITIONS "DELAY_CONDITION_PREFERENCES_CAPGO"
#define CG_KEY_BACKGROUND_TIMESTAMP "BACKGROUND_TIMESTAMP_KEY_CAPGO"
/* Files in the host's no-backup directory. */
#define CG_KEY_INSTALL_MARKER_FILE "CapacitorUpdater.defaultChannelInstallMarker"
#define CG_KEY_DEFAULT_CHANNEL_STATE_FILE "CapacitorUpdater.defaultChannelState"
#define CG_KEY_DEFAULT_CHANNEL_SNAPSHOT_FILE "CapacitorUpdater.defaultChannelPreviewSnapshot"

/* ---- PluginConfig: `plugins.CapacitorUpdater` plus the native facts read at load.
 * Strings are malloc'd, never NULL. */
typedef struct {
    uint64_t app_ready_timeout_ms;
    bool auto_delete_failed;
    bool auto_delete_previous;
    char *auto_update_mode;
    char *direct_update_mode;
    bool reset_when_update;
    bool auto_splashscreen;
    uint64_t auto_splashscreen_timeout_ms;
    uint64_t period_check_delay_s;
    bool allow_modify_url;
    bool allow_modify_app_id;
    bool allow_manual_bundle_error;
    bool allow_preview;
    bool persist_custom_id;
    bool persist_modify_url;
    bool allow_set_default_channel;
    bool persist_default_channel_on_reinstall;
    char *default_channel;
    bool keep_url_path_after_reload;
    bool shake_menu;
    char *shake_menu_gesture;
    bool allow_shake_channel_selector;
    /* Capacitor `server.url` is set (live reload): auto update is unavailable. */
    bool server_url_configured;
    /* App marketing version (`version` config or native version name). */
    char *native_version;
    /* Native build number (versionCode / CFBundleVersion). */
    char *native_build;
    /* Directory excluded from backups (default channel reinstall files). "" = none. */
    char *no_backup_dir;
    /* `_reload` waits for `notifyAppReady` (Android) or returns once the path is applied (iOS). */
    bool reload_waits_for_app_ready;
    /* Minimum rollback delay while the current bundle is not yet confirmed. */
    uint64_t pending_bundle_min_timeout_ms;
    /* Report crashes from session markers (iOS). */
    bool track_unclean_exits;
} cg_plugin_config;

/* PluginConfig::from_json(config, native): *out initialized; the warnings to log are appended
 * to *warnings (may be NULL). NULL / non-object inputs read as {} (PluginConfig::default()). */
void cg_plugin_config_from_json(const cj *config, const cj *native, cg_strs *warnings, cg_plugin_config *out);
void cg_plugin_config_copy(cg_plugin_config *out, const cg_plugin_config *config);
void cg_plugin_config_clear(cg_plugin_config *config);
bool cg_plugin_config_auto_update_enabled(const cg_plugin_config *config);
bool cg_plugin_config_track_unclean_exits(const cg_plugin_config *config);
bool cg_plugin_config_should_set_next_bundle(const cg_plugin_config *config);

/* ---- PluginState: mutable plugin state (one per engine), guarded by plugin.state_lock */

/* CycleDownload: download of the running update cycle. */
typedef struct {
    char *version;
    /* The cycle planned a direct update. */
    bool planned;
    /* Waiting for a scheduled (WorkManager) job: not stuck however long it takes. */
    bool waiting_scheduled;
    /* The job is retrying (no network): the bundle installs at the next background. */
    bool launch_released;
} cg_cycle_download;

/* HashMap<String, i64> entry. */
typedef struct {
    char *id;
    int64_t percent;
} cg_stat_percent;

typedef struct {
    bool loaded;
    cg_plugin_config config;
    bool was_recently_installed_or_updated;
    bool on_launch_direct_update_used;
    bool auto_splashscreen_timed_out;
    bool preview_session_enabled;
    bool preview_alert_pending;
    bool leaving_preview_for_link;
    bool shake_menu_enabled;
    bool shake_channel_selector_enabled;
    char *shake_menu_gesture; /* never NULL */
    int64_t launch_started_at_ms;
    bool launch_start_reported;
    bool launch_ready_reported;
    bool launch_timeout_reported;
    /* Last `download_<bucket>` statistic sent, per downloading bundle id. */
    struct {
        cg_stat_percent *items;
        size_t len, cap;
    } last_notified_stat_percent;
    /* Option<Instant>: cg_mono_ms() when set. */
    bool has_download_started_at;
    int64_t download_started_at_ms;
    bool default_channel_cleanup_must_retry;
    int64_t ready_generation;
    bool ready_guard_armed;
    /* Between `appBackground` and `appForeground`: rollback checks wait for the next foreground. */
    bool in_background;
    /* A host `appForeground` was handled and no `appBackground` came since. */
    bool foreground_handled;
    /* Option<CycleDownload>: the bundle the running update cycle downloads. */
    bool has_cycle_download;
    cg_cycle_download cycle_download;
} cg_plugin_state;

/* last_notified_stat_percent helpers (call with state_lock held). */
bool cg_plugin_state_stat_percent(const cg_plugin_state *state, const char *id, int64_t *out);
void cg_plugin_state_set_stat_percent(cg_plugin_state *state, const char *id, int64_t percent);
void cg_plugin_state_remove_stat_percent(cg_plugin_state *state, const char *id);
/* Sets / clears cycle_download (copies the strings). NULL clears. */
void cg_plugin_state_set_cycle_download(cg_plugin_state *state, const cg_cycle_download *download);

/* ---- Plugin: the plugin member of the engine */

/* `notifyAppReady` signal: waiters record the count they saw and wake when it grows. */
typedef struct {
    cg_mutex lock;
    cg_cond changed;
    uint64_t signals;
    /* Token armed at load / reload; consumed by the next `appReady` emission. */
    bool has_pending;
    uint64_t pending;
} cg_ready_signal;

/* Launch cleanup gate: downloads wait until obsolete bundles are removed. */
typedef struct {
    cg_mutex lock;
    cg_cond changed;
    bool complete;
} cg_cleanup_gate;

/* Lifecycle work (foreground / background) waiting to run, in call order. */
typedef struct cg_lifecycle_task {
    void (*run)(cg_engine *engine, void *ctx);
    void *ctx;
    void (*drop_ctx)(void *ctx); /* may be NULL */
    struct cg_lifecycle_task *next;
} cg_lifecycle_task;

typedef struct {
    cg_mutex state_lock;
    cg_plugin_state state;
    cg_ready_signal ready;
    cg_cleanup_gate cleanup;
    /* Bumped on every `checkAppReady`; a deferred rollback check only runs if still current. */
    atomic_uint_fast64_t app_ready_check;
    atomic_uint_fast64_t splash_timer;
    atomic_bool periodic_started;
    /* Serializes starting the update cycle. */
    cg_mutex cycle;
    /* Serializes `notifyAppReady` confirming the current bundle with the rollback check
     * failing it: a confirmation never loses against a concurrent rollback. */
    cg_mutex confirmation;
    /* Lifecycle queue: FIFO of tasks; `draining` = a worker thread is draining it. */
    cg_mutex lifecycle_lock;
    cg_lifecycle_task *lifecycle_head, *lifecycle_tail;
    bool lifecycle_draining;
} cg_plugin;

/* Plugin::default() / drop. Called by engine.c only. */
void cg_plugin_init(cg_plugin *plugin);
void cg_plugin_destroy(cg_plugin *plugin);

/* ---- Rejection / MethodResult
 * A plugin method returns an owned value (`cj *`, a JSON null is cj_null(), never NULL) on
 * success, or NULL with *rejection set (Rust Err(Rejection)). */
typedef struct {
    char *message; /* NULL: no rejection */
    char *code;    /* NULL = None */
    cj *data;      /* NULL = None */
} cg_rejection;

#define CG_REJECTION_INIT {0}

/* Rejection::new (replaces a previous one). Always returns NULL (for `return reject(...)`). */
cj *cg_rejection_new(cg_rejection *rejection, const char *message);
cj *cg_rejection_newf(cg_rejection *rejection, const char *format, ...) CG_PRINTF(2, 3);
/* Rejection::coded: data = {message, error}. Returns NULL. */
cj *cg_rejection_coded(cg_rejection *rejection, const char *message, const char *code, const char *error);
/* From<CoreError>: the message only. Returns NULL. */
cj *cg_rejection_from_error(cg_rejection *rejection, const cg_error *error);
/* Rejection::to_json. Owned. */
cj *cg_rejection_to_json(const cg_rejection *rejection);
bool cg_rejection_is_set(const cg_rejection *rejection);
void cg_rejection_clear(cg_rejection *rejection);

/* ---- helpers (mod.rs) */

int64_t cg_plugin_now_ms(void);
/* iso_now: malloc'd. */
char *cg_plugin_iso_now(void);
/* Trims and drops JavaScript `undefined` / `null` spellings (case-insensitive). malloc'd,
 * NULL = None. */
char *cg_plugin_normalized_optional(const char *value);
/* object_bool / object_i64 / object_str of mod.rs (config parsing, also used by flow.c).
 * object_str returns malloc'd or NULL. */
bool cg_plugin_object_bool(const cj *object, const char *key, bool fallback);
int64_t cg_plugin_object_i64(const cj *object, const char *key, int64_t fallback);
char *cg_plugin_object_str(const cj *object, const char *key);

/* plugin_state(): locks state_lock and returns the state; unlock when the Rust guard ends. */
cg_plugin_state *cg_plugin_lock_state(cg_engine *engine);
void cg_plugin_unlock_state(cg_engine *engine);
/* plugin_config(): a copy of the current plugin config (*out initialized, caller clears). */
void cg_plugin_plugin_config(cg_engine *engine, cg_plugin_config *out);

/* hook(name, payload): takes ownership of payload. Owned reply, NULL when unanswered. */
cj *cg_plugin_hook(cg_engine *engine, const char *name, cj *payload);
void cg_plugin_emit_bundle_event(cg_engine *engine, const char *event, const cg_bundle_info *bundle);
/* `set`: retained for listeners registered after the reload. */
void cg_plugin_emit_set_event(cg_engine *engine, const cg_bundle_info *bundle);
/* Retained `updateAvailable` of an `onlyDownload` (or auto update off) check. */
void cg_plugin_emit_only_download_update_available(cg_engine *engine, const cg_bundle_info *bundle);
/* kv_flag: Option<bool> -> false when absent, else true with *out ("true" or "1"). */
bool cg_plugin_kv_flag(cg_engine *engine, const char *key, bool *out);
/* kv_text: malloc'd, NULL when absent. */
char *cg_plugin_kv_text(cg_engine *engine, const char *key);
/* value NULL removes. */
void cg_plugin_kv_write(cg_engine *engine, const char *key, const char *value);
void cg_plugin_kv_write_flag(cg_engine *engine, const char *key, bool value);

/* Preview state blocks auto-update work, rollback and pending installs. */
bool cg_plugin_is_preview_state_active(cg_engine *engine);
bool cg_plugin_block_for_preview(cg_engine *engine);
void cg_plugin_set_engine_preview_session(cg_engine *engine, bool active);
/* `autoUpdate` on, an update URL, no live-reload server URL, no preview session. */
bool cg_plugin_is_auto_update_enabled(cg_engine *engine);
void cg_plugin_sync_shake_menu(cg_engine *engine);
void cg_plugin_preview_loader(cg_engine *engine, bool show, const char *reason);

/* mark_cleanup: opens / closes the launch cleanup gate and wakes waiters. */
void cg_plugin_mark_cleanup(cg_engine *engine, bool complete);
/* Download gate: blocks until the launch cleanup finished (120 s at most: cleanup_timeout).
 * Releases the method lane first. */
bool cg_plugin_wait_for_cleanup(cg_engine *engine, cg_error *err);

/* Initializes the plugin layer (Capacitor `load()`, flow.c load_plugin). Owned, NULL with *err. */
cj *cg_plugin_plugin_load(cg_engine *engine, const cj *input, cg_error *err);
/* Runs one JavaScript plugin method: `{resolve}` / `{reject}`. Detached methods hold the
 * method lane (cg_method_lane_hold) for their duration. Owned. */
cj *cg_plugin_plugin_method(cg_engine *engine, const char *name, const cj *args);

/* Test-only synchronous entry points (`test.pluginForeground`, `test.pluginPeriodicTick`,
 * `test.waitForCleanup`). */
void cg_plugin_plugin_foreground_for_tests(cg_engine *engine);
void cg_plugin_plugin_periodic_tick_for_tests(cg_engine *engine);
void cg_plugin_wait_for_cleanup_for_tests(cg_engine *engine);
void cg_plugin_plugin_terminate_for_tests(cg_engine *engine);

/* Runs lifecycle work off the caller's thread, one task at a time in call order, on a
 * "lifecycle" thread holding a weak reference (upgraded per task). drop_ctx (may be NULL)
 * frees ctx after the task ran or when it is discarded (thread could not start, engine
 * dropped). */
void cg_plugin_spawn_plugin_task(cg_engine *engine, void (*task)(cg_engine *engine, void *ctx), void *ctx,
                                 void (*drop_ctx)(void *ctx));

#endif
