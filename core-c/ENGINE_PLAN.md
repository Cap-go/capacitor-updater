# Engine port plan (wave 3)

Read `PORTING.md` first. The engine skeleton is in place: every header of
`src/engine/` is written, and these files are complete ports:

| File | Rust |
| --- | --- |
| `engine/engine.{h,c}` | `engine/mod.rs` (Engine, Arc/Weak, config snapshots, spawn, call) |
| `engine/config.{h,c}` | `engine/config.rs` |
| `engine/ops.{h,c}` | `engine/ops.rs` (every operation, same parsing and messages) |
| `engine/store.{h,c}` | `engine/store.rs` |
| `engine/plugin/plugin.{h,c}` | `engine/plugin/mod.rs` (PluginConfig, state, hooks/keys, helpers, lifecycle queue, wait_for_cleanup, plugin_method) |
| `testing_engine.c` | `testing.rs` engine ops: waitForCleanup, fetchJson, pluginForeground, pluginPeriodicTick, cleanupDownloadTempFiles (`http` is in the net agent's `testing_net.c`) |

What is left: one `.c` per remaining Rust file, against the headers that
already declare every function (`nm -u` on the library lists what is missing).

## Split

| Agent | Implements | Owns (may extend) | Rust lines |
| --- | --- | --- | --- |
| A: stats / backend / scheduled | `engine/stats.c`, `engine/backend.c`, `engine/scheduled.c` | `stats.h`, `backend.h`, `scheduled.h` | 1490 |
| B: downloads | `engine/download.c`, `engine/manifest.c` | `download.h`, `manifest.h` | 1600 |
| C: plugin flow | `plugin/flow.c`, `plugin/methods.c`, `plugin/ready.c`, `plugin/telemetry.c` | `flow.h`, `methods.h`, `ready.h`, `telemetry.h`, `plugin.h` + `plugin.c` | 2660 |
| D: plugin features | `plugin/channel.c`, `plugin/delay.c`, `plugin/preview.c` | `channel.h`, `delay.h`, `preview.h` | 2140 |

Also to implement, declared in the owned headers (small helpers):

- A: `cg_stats_add_ack`, `cg_remote_block_clear`, `cg_scheduled_clear`,
  `cg_backend_manifest_size_url` (then `testing_archive.c` may call it instead
  of its private copy).
- B: `cg_download_request_init/_from_json/_to_json/_copy/_clear`,
  `cg_download_net_error_retryable/_code`; `register/unregister_download_token`
  live in manifest.c (as in Rust).
- C: `cg_methods_engine_methods`, `cg_methods_detached_methods`,
  `cg_methods_is_detached` (method lists as functions, see Rules),
  `cg_flow_cycle_end`.
- D: `cg_channel_snapshot_clear`, `cg_channel_state_clear`,
  `cg_delay_conditions_clear`, `cg_delay_condition_to_json`,
  `cg_native_version_*`, `cg_delay_source_name`.

Headers outside your column are read-only: adding a declaration to a header you
own is fine; changing an existing signature, or needing something new from
another agent's header, goes in your report (the other side implements it).

## Cross-dependencies

- Everyone: `store.h` (done), `engine.h` (config snapshots, spawn, refs),
  `bundle.h`, `host.h`, `plugin.h` helpers (`cg_plugin_hook`, kv helpers,
  `cg_plugin_lock_state`).
- A uses: `store` (current bundle), `net.h` (`cg_http_post_json/send_json/get/download`),
  `http.h` rules, `plugin.h` (`cg_plugin_lock_state()->loaded`), `flow.h`
  (`cg_flow_scheduled_download_waiting/_retrying`), `download.h`
  (`transfer_and_install`, `settle_download`, `is_retryable_download_error`,
  request JSON), `manifest.h` (tokens), `fsutil.h` (`write_atomically`).
- B uses: `store`, `stats`, `backend` (none directly), `scheduled.h`
  (`schedule_download`, `scheduled_result`, `pending_job_ids`,
  `job_has_manifest`), `telemetry.h` (`notify_download`,
  `forget_download_progress`), `archive.h`, `fsutil.h`, `apk` (archive agent),
  `crypto/*`, `paths.h`, `policy.h`, `net.h`.
- C uses: everything; `methods.c` dispatches to D's `method_*` functions and to
  `cg_methods_download_bundle` / store / backend; `flow.c` calls
  `channel`/`delay`/`preview`/`telemetry`.
- D uses: `backend.h` (channels, get_latest, fetch_json), `methods.h`
  (`cg_methods_download_bundle`), `ready.h` (reload, set_and_reload),
  `flow.h`, `store`, `fsutil.h` (`write_atomically`).

## Rules

- Naming: `cg_<file>_<rust_name>` for every `pub`/`pub(crate)` item, file-local
  helpers `static`. The headers already fix every cross-file name.
- Result conventions (documented in the headers):
  `Option<BundleInfo>` -> `bool f(..., cg_bundle_info *out)`;
  `CoreResult<BundleInfo>` -> `bool f(..., cg_bundle_info *out, cg_error *err)`;
  `MethodResult` -> `cj *f(..., cg_rejection *rejection)` (NULL = rejected);
  `Map<String, Value>` results -> owned `cj *` objects; JSON arguments are
  borrowed.
- Config: `self.config().x` -> `CG_CONFIG_DUP(engine, x)` /
  `CG_CONFIG_FLAG(engine, x)` or `cg_engine_config_snapshot` +
  `cg_config_release` for several fields. `self.config_mut().x = y` ->
  `cg_engine_config_begin` / modify / `cg_engine_config_commit`. Never hold a
  config writer across a host callback, a network call, or another
  `begin` (writers are serialized; snapshots never block).
- Threads: `Engine::spawn(name, closure)` ->
  `cg_engine_spawn_strong` when the Rust closure owns an `Arc<Engine>`
  (`self.clone()`, `weak_self().upgrade()` before spawning), or
  `cg_engine_spawn_weak` when it owns `weak_self()` and upgrades per step
  (stats timer, periodic check, delayed checks: use
  `cg_engine_sleep_unless_dropped`, release the strong ref each iteration).
  On spawn failure the helpers already log "Could not start the <name> thread"
  and drop the context. `std::thread::scope` (manifest workers) ->
  `cg_spawn_joinable` + `cg_join` for every worker before returning.
- The engine's drop (last strong ref, possibly on a worker thread) calls
  `cg_stats_shutdown_stats` and then frees module state: module code must not
  keep pointers into the engine past its references.
- Locks: keep Rust guard scopes exactly (a `self.x.lock().y = z` statement locks
  for that statement only). Documented orders: stats `persist_lock -> queue_lock
  -> in_flight_lock`; plugin `cleanup.lock -> state_lock`, `cycle -> state_lock`,
  `confirmation -> state_lock`; `engine->delete_lock` is held across host
  callbacks and stats (as Rust); the process-wide rate-limit (backend.c) and
  job registry (scheduled.c) mutexes and `engine->downloads.lock` are leaves:
  never call the host or the network while holding them. net.c: the timeout
  lock is released before the proxy-agent map (Rust comment in net.rs).
- Method lane: every Rust `crate::host::release_method_lane()` ->
  `cg_release_method_lane()` at the same place (before network waits,
  `notifyAppReady` waits, scheduled waits).
- No `extern` data shared across modules (constants are `#define`s, lists are
  functions): while modules are missing the library is linked with
  `CAPGO_ALLOW_UNDEFINED`, and an undefined data symbol makes `dlopen` fail
  for every test; undefined functions only fail when called.
- Rust `format!("{x:?}")` of strings, `Value::to_string()` (= `cj_print`),
  `Display` of io errors (`err.message` from fsutil) must match byte for byte.

## Testing a module before the others exist

Calls into a missing module crash the test process. To test your module alone,
put temporary stubs of the functions it reaches in an untracked file (e.g.
`src/zz_test_stubs.c`), build into a separate directory, run, delete the file:

```bash
cmake -S core-c -B core-c/build-stub -DCAPGO_TEST_SUPPORT=ON -DCAPGO_ALLOW_UNDEFINED=ON
cmake --build core-c/build-stub -j
cd core && CAPGO_CORE_LIB=$PWD/../core-c/build-stub/libcapgo_updater_core.dylib \
  cargo test --features test-support --test engine_store
```

`engine_store` passes (19/19) this way with stubs of `cg_http_*`,
`cg_stats_send_stats` (host `sendStats` hook only), `cg_stats_shutdown_stats`,
`cg_scheduled_cancel_version_download` (host hook only),
`cg_scheduled_cancel_scheduled_downloads` and `cg_scheduled_running_jobs`.
Test files per agent: A `engine_backend`, `engine_rate_limit`,
`engine_scheduled`; B `engine_download`, `engine_overlapping_manifests`,
`engine_parallel_decrypt`, `perf`; C and D `plugin`, `engine_lock_order`.
