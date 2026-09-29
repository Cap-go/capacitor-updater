# Native Contract Tests

This directory is the shared behavior contract for updater core logic.

Each fixture is platform-neutral JSON. Native runners load the same fixture and
compare the platform implementation against the same expected output. Keep these
cases focused on deterministic core decisions that do not need a simulator,
emulator, WebView, bridge, network, filesystem permissions, or app lifecycle.
App-store update helpers and shake-menu helpers are intentionally excluded from
this core contract because they depend on platform UI/services rather than
updater state decisions.

The updater core logic these fixtures describe is implemented once, in Rust
(`core/`, see `core/README.md`). Each group name is a core operation name and
each case's `input`/`expect` is that operation's JSON payload; failures are
`expect: {"error": "<code>"}` (a lone `error` key).

Fixture files:

- `core.json`, `policy.json`: update policy and HTTP helper decisions
- `security.json`: path traversal, cache-name and partial-download guards
- `crypto.json`, `crypto-rsa.json`: session keys, checksums, RSA and AES bundle decryption

`policy.json`, `security.json` and `crypto.json` are written by
`scripts/generate-core-contract-fixtures.mjs` (`bun run generate:core-contract`).

Current runners:

- Rust core: `core/tests/contract.rs` (all files, checks error codes too)
- Android: `android/src/test/java/ee/forgr/capacitor_updater/NativeContractTest.java`
- Android: `android/src/test/java/ee/forgr/capacitor_updater/CoreContractTest.java`
- Android: `android/src/test/java/ee/forgr/capacitor_updater/RsaContractTest.java`
- iOS: `ios/Tests/CapacitorUpdaterPluginTests/NativeContractTests.swift`
- iOS: `ios/Tests/CapacitorUpdaterPluginTests/CoreContractTests.swift`
- iOS: `ios/Tests/CapacitorUpdaterPluginTests/RsaContractTests.swift`

RSA public-decrypt fixtures live in `native-contract-tests/crypto-rsa.json`.
Regenerate them with:

```bash
bun scripts/generate-rsa-contract-fixtures.mjs
```

Run RSA contract tests with:

```bash
bun run native:contract:crypto:ios
bun run native:contract:crypto:android
```

Run core contract tests with:

```bash
bun run core:test
bun run native:contract:android
bun run native:contract:ios
```

A new native implementation should add its own runner and pass these same JSON
fixtures before relying on device-level tests.
