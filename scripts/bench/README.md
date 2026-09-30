# Live-update benchmark

Measures the live-update pipeline of `@capgo/capacitor-updater` on the iOS simulator and
the Android emulator, to compare two plugin checkouts (e.g. native `main` = **before**
vs. the Rust core branch = **after**).

## What is measured

Each cell = 3 runs (median, min, max). Encryption off/on (Capgo CLI format: AES-128-CBC,
RSA-2048 `privateEncrypt` session key, RSA-encrypted checksums / `file_hash`).

- zip bundles: 3 MB, 30 MB, 300 MB of random bytes (10/30/100 files + `index.html` + `bench.js`)
- manifest (delta) downloads: 2 files / 20 KB, 20 / 2 MB, 200 / 20 MB, 2000 / 200 MB. Every
  version has fresh random content (plus a unique `index.html`/`bench.js`), so every file is
  downloaded. The server also counts the requests per version (`requests` in the JSONL).
- manifest reuse (`--suites reuse`, background only): 200 files / 20 MB and 2000 files / 200 MB,
  where 90% of the files are already on the device. There are two sources: *delta cache*
  (version A, which holds the same files, is downloaded untimed right before B, and only B
  is timed) and *builtin* (1800 random 100 KiB files ship in the app's `public/bpad/`, and
  the manifest reuses them). `expectedDownloads` versus `requests` in the JSONL shows
  whether the reuse really happened.
- network-shaped (`--suites shaped`, plain, background): zip 30 MB, manifest 200 files /
  20 MB and 2000 files / 20 MB. Every payload response waits 80 ms before its headers, and
  all payload bytes share one 40 Mbit/s token bucket (`BENCH_SHAPE_LATENCY_MS`,
  `BENCH_SHAPE_MBIT`). This measures how well each side parallelizes requests and uses the link.
- `background`: time from the JS `download()` call until it resolves.
- `direct`: `download()`, then `set()`. The clock stops when the new bundle's JS has
  resolved `notifyAppReady()`. The time spent on bench HTTP calls is not counted
  (`totalMs = downloadMs + applyMs`, and `wallMs` is also recorded).

The app is a copy of the checkout's `example-app` native projects in `.context/bench/apps/<label>`.
It uses a bench-only `capacitor.config.json` (`autoUpdate: false`, `responseTimeout: 600`,
`appReadyTimeout: 60000`, and `publicKey` for the `enc` variant) and a plain `bench.js`.
It is built in **Release** (iOS) or as a signed **release APK** (Android). The checkout's
own `example-app` is not modified. Before each case, the server waits a few seconds (so the
previous case's async delta-cache work can finish) and clears `capgo_downloads`. The app
deletes all bundles except the current one. Two warm-up cases run first and are excluded
from the report.

## Run

```bash
# BEFORE = origin/main in a worktree
git worktree add .context/bench-main origin/main
(cd .context/bench-main && bun install && bun run build)

# iOS (simulator "iPhone 17 Pro", override with BENCH_IOS_UDID)
scripts/bench/run-ios.sh before .context/bench-main
scripts/bench/run-ios.sh after .

# Android (start the emulator first; the script uses `adb root` + `adb reverse`)
~/Library/Android/sdk/emulator/emulator -avd capgo_mem_api36 -no-window -no-audio &
scripts/bench/run-android.sh before .context/bench-main
scripts/bench/run-android.sh after .

# Markdown report -> .context/bench/report.md
bun scripts/bench/report.mjs
```

For an `after` checkout that has `core/`, the runners call `scripts/build-core.sh <platform>`
first (skip this with `--no-core`).

The runners re-exec themselves under `caffeinate -dimsu`. They hold `/tmp/capgo-maestro.lock`
(which Maestro runs share; set `BENCH_DEVICE_LOCK=` to disable) while they use a device, and
they boot the simulator or start the emulator (AVD `BENCH_AVD`) if needed. They shut down only
the devices they started.

Options: `--suites main,reuse,shaped`, `--variants plain|enc|plain,enc`, `--only '<regex on case id>'`, `--runs N`,
`--skip-build` (reuse the last built app), `--retry-failed`.

Results are appended per attempt to `.context/bench/results-<label>-<platform>.jsonl`. If you
run the same command again, it resumes and skips finished cases, so you can split a run with
`--only`/`--variants` to keep each invocation short. Each case has a timeout (2 to 10 min
depending on size). On a timeout, the runner restarts the app and retries the case once.
Logs are in `.context/bench/logs/`.

## Files

- `config.mjs`: matrix and paths. `fixtures.mjs`: crypto, random trees, manifest versions.
- `gen-fixtures.mjs`: RSA keys (`.context/bench/keys`), builtin www, and zips (plain + encrypted).
- `server.mjs`: bench server (serves files, hands out cases, records timings).
- `app-template.mjs`: `index.html` and `bench.js` used in every bundle.
- `prepare-app.mjs`: isolated bench app per checkout.
- `run-ios.sh`, `run-android.sh`, `lib.sh`: runners.
- `report.mjs`: markdown tables.
