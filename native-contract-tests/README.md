# Native Contract Tests

This directory is the shared behavior contract for updater core logic.

Each fixture is platform-neutral JSON. Native runners load the same fixture and
compare the platform implementation against the same expected output. Keep these
cases focused on deterministic core decisions that do not need a simulator,
emulator, WebView, bridge, network, filesystem permissions, or app lifecycle.
App-store update helpers and shake-menu helpers are intentionally excluded from
this core contract because they depend on platform UI/services rather than
updater state decisions.

Current runners:

- Android: `android/src/test/java/ee/forgr/capacitor_updater/NativeContractTest.java`
- iOS: `ios/Tests/CapacitorUpdaterPluginTests/NativeContractTests.swift`

Run them with:

```bash
bun run native:contract:android
bun run native:contract:ios
```

A new native implementation should add its own runner and pass these same JSON
fixtures before relying on device-level tests.
