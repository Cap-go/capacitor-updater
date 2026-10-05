# Native Contract Tests

This directory is the shared behavior contract for updater core logic.

Each fixture is platform-neutral JSON: deterministic core decisions that do not
need a simulator, emulator, WebView, bridge, network, filesystem permissions, or
app lifecycle. App-store update helpers and shake-menu helpers are intentionally
excluded because they depend on platform UI/services rather than updater state
decisions.

The updater core logic these fixtures describe is implemented once, in Rust
(`core/`, see `core/README.md`). Rust runs the fixtures; the platforms only
smoke-test their binding.

Each group name maps to one core rule and each case's `input`/`expect` is that
rule's JSON payload; failures are `expect: {"error": "<code>"}` (a lone `error`
key).

Fixture files:

- `core.json`, `policy.json`: update policy and HTTP helper decisions
- `security.json`: path traversal, cache-name and partial-download guards
- `crypto.json`, `crypto-rsa.json`: session keys, checksums, RSA and AES bundle decryption

`policy.json`, `security.json` and `crypto.json` are written by
`scripts/generate-core-contract-fixtures.mjs` (`bun run generate:core-contract`).
RSA public-decrypt fixtures live in `crypto-rsa.json`; regenerate them with
`bun run generate:rsa-contract`.

Bundles encrypted by the real Capgo CLI live in `cli/` (see its README). The CLI
is the source of truth for the encryption format; regenerate them with
`bun run generate:cli-crypto`. `core/tests/cli_crypto.rs` decrypts every one of
them, with the crypto functions and through the engine `download` path.

## Runners

- Rust core: `core/tests/contract.rs` runs every case of every file against the
  Rust functions the engine uses, error codes included (`bun run core:test`).
  RSA signature edge cases live in `core/tests/crypto_rsa.rs`.
- Android: `android/src/test/java/ee/forgr/capacitor_updater/CoreBindingTest.java`
  smoke-tests the JNI binding (one core call, one engine call).
- iOS: `ios/Tests/CapacitorUpdaterPluginTests/CoreBindingTests.swift`
  smoke-tests the C ABI binding (one core call, one engine call).

```bash
bun run core:test
bun run native:contract:android
bun run native:contract:ios
```

A new rule gets its fixture group here and its mapping in `core/tests/contract.rs`.
A new host binds the C ABI (`core/include/capgo_updater_core.h`) and adds a
binding smoke test like the ones above.
