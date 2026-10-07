# Capgo updater core (Rust)

The Capgo live updater, written once. Android and iOS run the same compiled
Rust engine: update decisions, downloads, bundle storage, statistics and
security boundaries behave identically everywhere. A new host (another OS,
React Native, Flutter, Electron, desktop, ...) binds a few C functions and
implements a handful of platform hooks.

## What lives here

| Module | Responsibility |
| --- | --- |
| `engine::plugin` | The Capacitor plugin behavior: load, config, auto-update cycle, direct updates, `notifyAppReady` and rollback, delay conditions, preview sessions, channels, every JavaScript method, launch / health / WebView statistics |
| `engine::store` | Bundle registry (`<id>_info`), current / next / fallback bundles, set / reset / delete, cleanup |
| `engine::download`, `engine::manifest`, `engine::archive` | Zip and manifest downloads: resume, retries, checksum before extraction, decryption, brotli, delta cache, zip-slip / symlink guards |
| `engine::backend`, `engine::stats` | Update, channel and stats endpoints, 429 handling, batched and persisted stats |
| `net` | HTTP client (rustls, no cookies, HTTPS -> HTTP redirect guard) |
| `policy`, `http`, `paths`, `crypto` | Pure rules used by the engine, pinned by the contract fixtures |

Hosts keep only what needs the platform: the Capacitor bridge (method
registration, resolve / reject, listener dispatch), the WebView (applying a
bundle, injected scripts), lifecycle observers, UI (splash screen, loaders,
alerts, shake menu), key-value storage and app store APIs.

## Engine API

```c
CapgoEngine *capgo_engine_new(const char *config_json, CapgoHostCallbacks host);
char *capgo_engine_call(const CapgoEngine *engine, const char *operation, const char *input_json);
void capgo_engine_free(CapgoEngine *engine);
void capgo_core_free(char *value);
```

Results are envelopes (`{"ok": true, "value": ...}` / `{"ok": false, "error": {code, message}}`).
The main operations a plugin host uses:

- `pluginLoad {config, native}`: once at plugin load.
- `pluginMethod {name, args}`: every JavaScript method; answers
  `{"resolve": value}` or `{"reject": {message, code?, data?}}`.
- `appForeground`, `appBackground`, `appTerminate`, `openUrl {url}`.
- `shakeMenuSwitchChannel {channel}`: the shake-menu channel switch (set channel,
  check, download, queue as next); answers `{status, message, bundleId?, version?}`.

The host callbacks (`CapgoHostCallbacks`, JNI `CapgoEngineHost`) provide logging,
key-value storage, event delivery and `hook(name, payload)` for platform work:
`applyBundle`, `splash`, `previewLoader`, `previewNotice`, `shakeMenu`, `shakeMenuProgress`,
`keepUrlPath`, `backgroundTask`, `excludeFromBackup`, `scheduleDownload`, `releaseMethodLane`
(see `engine::plugin::hooks`).

Hosts run `pluginMethod` calls one at a time in call order. Methods listed by
`detachedPluginMethods` run on another thread while the host's lane waits until the engine
calls `releaseMethodLane` (the method now waits for the network or `notifyAppReady`) or the
method returns.

Downloads run in-process unless the host answers `scheduleDownload {id, version}` with
`{scheduled: true}` (Android: a WorkManager job that waits for the network, retries with
backoff and survives the process). The engine then stores the job under
`<storageRoot>/capgo_download_jobs/` and the caller waits; the job calls
`runScheduledDownload {id}` (one attempt, answers `success` / `retry` / `failure`) and
`stopScheduledDownload {id}` when the scheduler stops it. `detachScheduledDownloads` releases
waiting callers before the host frees the engine; the job still records the bundle.

`capgo_core_call(operation, json)` exposes one stateless rule to the hosts:
`resolvePathInside {base, path}` (bundle ids stay under the bundle root).

Bindings in this repository:

- iOS: `CapgoEngine.swift` / `CapgoCore.swift` (C ABI through `CapgoUpdaterCore.xcframework`)
- Android: `CapgoEngine.java` / `CapgoCore.java` (JNI, `CapgoCoreNative`)

## Build and test

```bash
bun run core:test            # cargo test: engine scenarios, downloads, contract fixtures
bun run core:lint            # rustfmt + clippy
bun run core:build:android   # android/src/main/jniLibs/<abi>/libcapgo_updater_core.so (needs cargo-ndk + NDK)
bun run core:build:ios       # ios/Frameworks/CapgoUpdaterCore.xcframework (needs Xcode)
```

`tests/plugin.rs` drives the engine like a Capacitor host does (hooks, events,
a fake update server) and covers the update lifecycle end to end.

Rust runs the fixtures; platforms smoke-test the binding. `tests/contract.rs`
runs every case of [`native-contract-tests/`](../native-contract-tests) against
the Rust functions the engine uses. The Android and iOS test suites only check
that their binding reaches the core and the engine (`CoreBindingTest.java`,
`CoreBindingTests.swift`).

The binaries are build outputs (git-ignored). CI builds them for every
Android/iOS job and the release workflows ship them in the npm package, so app
developers never need a Rust toolchain. Android JVM unit tests build a host
library automatically (`buildCapgoCoreHost` Gradle task).

## Adding a new host

1. Build the crate for the target (`staticlib` or `cdylib`) and bind the engine
   functions (header: `include/capgo_updater_core.h`).
2. Implement the host callbacks: storage, events, logging, the hooks above and
   TLS verification (`verify_server_certificate`). There is no built-in
   verifier: without it every HTTPS request fails.
3. Forward the framework's plugin methods to `pluginMethod` and its lifecycle
   events to `appForeground` / `appBackground`.
4. Add a binding smoke test: one core call and one engine call (see
   `CoreBindingTests.swift` / `CoreBindingTest.java`). The fixtures already run in Rust.

## Changing behavior

Change behavior in Rust with a test (`tests/plugin.rs` for plugin flows, the
fixtures for pure rules: `scripts/generate-core-contract-fixtures.mjs`, mapped in
`tests/contract.rs`). Hosts must not reimplement engine logic.

Security boundaries (path guards, signature/checksum/session-key checks) must
not be weakened without an explicit product decision and tests.
