# Capgo updater core (Rust)

Platform-neutral core of the Capgo live updater. Android and iOS call the same
compiled Rust code, so security boundaries and update decisions behave
identically everywhere, and a new host (another OS, React Native, Flutter,
Electron, desktop, ...) only has to bind two C functions.

## What lives here

| Module | Responsibility |
| --- | --- |
| `policy` | `autoUpdate` / `directUpdate` modes, period check delay, launch-download notifications, default-channel resets, manifest concurrency, shake menu gesture, bundle status parsing |
| `http` | User agent, retryable statuses, `Content-Range` parsing, zip resume planning, 429 rate-limit deadlines, backend error bodies |
| `paths` | Path traversal guards for manifest `file_name`, zip entries and bundle ids; delta-cache and partial-download names |
| `crypto` | RSA public-key parsing and PKCS#1 v1.5 type-1 recovery (Capgo CLI `privateEncrypt`), session keys, checksum decryption, streaming AES-128-CBC bundle decryption, file SHA-256 |

Hosts keep what is inherently platform specific: networking stack, background
work (WorkManager / URLSession), key-value storage, WebView reloads, lifecycle,
UI (shake menu), and the Capacitor bridge.

## One entry point

Every operation is `name + JSON object -> JSON object`:

```c
char *capgo_core_call(const char *operation, const char *input_json);
void capgo_core_free(char *value);
```

The result is always an envelope:

```json
{"ok": true, "value": {"maxConcurrentFiles": 8}}
{"ok": false, "error": {"code": "path_traversal", "message": "..."}}
```

Operation names and payloads are exactly the group names and `input`/`expect`
objects of the shared fixtures in [`native-contract-tests/`](../native-contract-tests).
`api::OPERATIONS` lists them; `coreInfo` returns the list at runtime.

Bindings in this repository:

- iOS: `ios/Sources/CapacitorUpdaterPlugin/CapgoCore.swift` (C ABI through `CapgoUpdaterCore.xcframework`)
- Android: `android/src/main/java/ee/forgr/capacitor_updater/CapgoCore.java` (JNI, `CapgoCoreNative`)

## Build

```bash
bun run core:test            # cargo test: unit tests + every shared contract fixture
bun run core:lint            # rustfmt + clippy
bun run core:build:android   # android/src/main/jniLibs/<abi>/libcapgo_updater_core.so (needs cargo-ndk + NDK)
bun run core:build:ios       # ios/Frameworks/CapgoUpdaterCore.xcframework (needs Xcode)
```

The binaries are build outputs (git-ignored). CI builds them for every
Android/iOS job and the release workflows ship them in the npm package, so app
developers never need a Rust toolchain. Android JVM unit tests build a host
library automatically (`buildCapgoCoreHost` Gradle task).

## Adding a new host

1. Build the crate for the target (`staticlib` or `cdylib`) and bind
   `capgo_core_call` / `capgo_core_free` (header: `include/capgo_updater_core.h`).
2. Write a thin `call(operation, input)` wrapper that parses the envelope.
3. Add a contract runner that executes `native-contract-tests/*.json` through
   that wrapper (see `CoreContractTests.swift` / `CoreContractTest.java`).
4. Implement the host-only pieces (network, storage, reload) around it.

## Changing behavior

Change the fixture first (`scripts/generate-core-contract-fixtures.mjs`, then
`bun run generate:core-contract policy security`), then the Rust code. The Rust,
Android and iOS runners must all pass the same fixtures.

Security boundaries (path guards, signature/checksum/session-key checks) must
not be weakened without an explicit product decision and tests.
