# Example App for `@capgo/capacitor-updater`

This Vite project links directly to the local plugin source so you can exercise the native APIs while developing.

## Actions in this playground

- **Notify app ready** – Signals to the native plugin that the current bundle launched successfully.
- **Get current bundle** – Returns the bundle currently in use.
- **List downloaded bundles** – Lists bundles that were downloaded on the device.
- **Get plugin version** – Returns the native plugin version.
- **Set update URL** – Configures the update server endpoint.

## Getting started

```bash
npm install
npm start
```

Add native shells with `npx cap add ios` or `npx cap add android` from this folder to try behaviour on device or simulator.
