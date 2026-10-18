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

# Android (the script uses `adb root`; the app reaches the host at http://10.0.2.2:<port>,
# the emulator's host alias, with the emulator's virtual Wi-Fi off for the run.
# For a physical device: BENCH_ANDROID_TRANSPORT=reverse uses `adb reverse` + 127.0.0.1, but the
# adb reverse forwarder makes some of a burst of 16+ new connections wait for a 1 s SYN retry)
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

## Resource and recovery measurements

Set `BENCH_BUILD_ONLY=1` to prepare release snapshots without launching a device. The Android
benchmark build uses a 3 GiB Gradle heap and four build workers; those settings affect the build
host, not the app runtime. iOS snapshots and fixture copies use copy-on-write storage on APFS.

`resource-sampler.py --platform android|ios --output .context/bench/samples.jsonl` records the updater's primary
app process. Output paths must stay inside the workspace `.context/` directory; device identifiers are validated before invoking platform tools. Android reads CPU ticks, resident and proportional memory, and thread counts through one persistent
ADB connection, roughly every 100 ms. Pass `--serial` when using another emulator. The iOS
simulator sampler reads host process CPU, RSS and physical footprint every 20 ms; `--udid`
selects the simulator. Separate WebView processes and OS networking daemons are excluded.
These measurements are sampled process peaks, not whole-app peak memory or physical-phone
battery measurements. Android CPU counters have 10 ms resolution.

The server records `hostStartedAt` and `hostFinishedAt` for each attempt. Name sample files
`resources-<label>-<platform>-<variant>-r<run>.jsonl`, then join them with:

```bash
python3 scripts/bench/resource-report.py results-directory --samples samples-directory --output .context/bench/report.json
```

The report keeps failures, sample counts and measurement-boundary overhang. Check those fields
before comparing short cases; a sample can straddle an operation's boundaries. CPU time covers
the process, including its worker threads. Do not interpret RSS as private heap size. Prefer Android PSS and iOS physical footprint when discussing memory pressure; both still exclude separate WebView processes.

For recovery checks, `BENCH_FAULT_PROFILE=503-once` makes the server refuse the first manifest
payload request of every timed case with HTTP 503. Warm-ups are unaffected. Results include
`faultsInjected`. Set `BENCH_MAX_ATTEMPTS=1` to disable the harness's whole-case retry, so client
recovery and a harness retry cannot be confused. This is a controlled server-failure test;
packet loss and disconnections require separate network shaping and transport tests.

Resource windows begin when the server assigns the case, so they also include the app's
pre-download bundle cleanup. `cpuThroughSettleMs` and memory peaks include a further 1.5 seconds
after completion to capture asynchronous cache work. Runners keep the app alive for at least two
seconds after the final result. This lifecycle CPU measurement has a different boundary from
`downloadMs`, which starts after the app's cleanup. Keep both boundaries explicit in reports.
