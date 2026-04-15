# Example App for `@capgo/capacitor-updater`

This Vite project links directly to the local plugin source so you can exercise the native APIs while developing.

## Test harness

The example app now renders a deterministic OTA dashboard for the Maestro suite:

- The built asset label bundled into the app or update zip
- The current bundle version reported by the plugin
- The next queued bundle version
- Retained updater events and the most recent download

## Getting started

```bash
bun install
bun run start
```

Add native shells with `bunx cap add ios` or `bunx cap add android` from this folder to try behaviour on device or simulator.
