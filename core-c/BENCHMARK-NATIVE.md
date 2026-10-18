# Native updater vs Rust core vs C core: live-update performance (run 3, same session)

Three builds measured in one session on the same simulator, the same fresh emulator and the same host, with the labels interleaved chunk by chunk:

- `main`: `origin/main` @ 0beaa91b (plugin 8.53.0), the native Java/Swift updater. PR #937 is not merged there.
- `rust`: branch `riderx/capgo-c-core` @ f4cd3112 with `CAPGO_CORE_IMPL=rust`.
- `c`: the same commit with `CAPGO_CORE_IMPL=c`.

The `rust` and `c` apps are the run 2 builds (see `BENCHMARK.md`), reused unchanged. The branch head adds only docs on top of f4cd3112. The bench app, harness, fixtures, keys and server are the same for all three labels. Measured 2026-10-16 19:43–22:56 WEST on an Apple M5 Pro (Mac17,9, 18 cores, 64 GB), macOS 27.2, Xcode 27.1. Raw results: `~/capgo-bench-c/run3/`.

## Summary

Each platform has 39 timed cells (28 main, 8 reuse, 3 shaped). "Equal" means the median delta rounds to 0%. "(overlap)" in the tables marks cells where the min–max ranges of the two labels overlap. Treat those as within noise.

**C core vs native updater**

- **iOS simulator:** C is faster in 37 cells, equal in 2 and slower in 0. In 35 of the 37 the ranges do not overlap.
  - Manifests with 200 and 2000 files: −64% to −77%. 2000 files background: 2.34 s → 549 ms plain, 3.07 s → 874 ms encrypted.
  - Zips: −25% to −65% background, −15% to −69% direct. 300 MB plain background: 444 → 155 ms.
  - Small manifests (2 and 20 files): −14% to −66%.
  - Reuse: −24% to −66%.
  - Shaped: 2000 files −14% (4.97 → 4.30 s; native peaks at 36 parallel requests, C at 64). The 30 MB zip and 200-file cells are equal (−0.5%).
  - The two overlapping cells are zip 300 MB encrypted direct (−55%) and manifest 2 files encrypted direct (−14%).
- **Android emulator:** C is faster in 38 cells, equal in 1 and slower in 0. In 36 of the 38 the ranges do not overlap.
  - Zips: −35% to −54%. 300 MB encrypted background: 8.21 → 3.83 s (−4.37 s).
  - Manifests: −19% to −62%. 2000 files encrypted background: 2.60 → 1.02 s.
  - Reuse: −43% to −66%.
  - Shaped 2000 files: 21.02 → 5.21 s (−75%). The native updater peaks at 8 parallel requests and uses 20% of the link; C uses 32 and 80%. Shaped zip 30 MB: −6%. Shaped 200 files: equal.
  - Cold start (20 files, background): 60 → 31 ms. Warm: 51 → 31 ms.
  - The two overlapping cells are zip 3 MB plain direct (−40%; one C run took 452 ms) and manifest 2 files encrypted direct (−33%).

**Rust core vs native updater**

- **iOS simulator:** Rust is faster in 37 cells, equal in 2 and slower in 0. In 31 of the 37 the ranges do not overlap.
  - Manifests with 200 and 2000 files: −63% to −76%.
  - Plain zips: −23% to −64%. Reuse: −21% to −66%. Shaped 2000 files: −14%.
  - The 6 overlapping cells are all the encrypted zip cells (3, 30 and 300 MB, background and direct): −6% to −45%.
- **Android emulator:** Rust is faster in 38 cells, equal in 1 and slower in 0. In 37 of the 38 the ranges do not overlap.
  - Zips: −37% to −53%. Manifests: −17% to −47%. Reuse: −42% to −58%.
  - Shaped 2000 files: 21.02 → 5.25 s (−75%).
  - Cold start (20 files, background): 60 → 32 ms. Warm: 51 → 33 ms.
  - The overlapping cell is manifest 2 files encrypted direct (−22%).

**Largest gains in ms (both cores):** Android shaped 2000 files (about −15.8 s), Android 300 MB zips (−4.0 to −4.4 s), iOS 2000-file encrypted manifests (about −2.1 to −2.2 s).

**Where the time goes.** In direct mode the apply step (`set()` until the new bundle calls `notifyAppReady()`) is about the same for the three builds: 20–32 ms on iOS, 12–34 ms on Android. The difference is in the download, verify, decrypt and unzip/assemble step.

**C vs Rust in this run.** By median, C is faster than Rust in 29 cells, equal in 6 and slower in 4 on iOS, and faster in 27, equal in 4 and slower in 8 on Android. Several of these cells have overlapping ranges.
- C is ahead on Android encrypted large manifests (2000 files encrypted background: 1.46 → 1.02 s) and on all 12 iOS zip cells.
- The largest C loss is Android 2000 files plain direct: 1.31 s for Rust, 1.46 s for C (+11%), and C's range is wide (1.15–1.78 s).
- The other C losses are +2% to +9%, or +1 ms in the 2-file iOS background cell (4 → 5 ms).

**App size (plain release bench builds):**

| | Native (main) | Rust | C | Δ C vs native | Δ Rust vs native |
|---|---|---|---|---|---|
| iOS app executable (arm64) | 1.91 MiB | 4.22 MiB | 1.48 MiB | −435.0 KiB (−22%) | +2.31 MiB (+121%) |
| Android arm64 download estimate (gzip -9 of dex + arm64 `.so`) | 3.51 MiB | 4.47 MiB | 3.40 MiB | −109.9 KiB (−3%) | +978.6 KiB (+27%) |
| Android APK, all ABIs, without web assets | 4.63 MiB | 15.64 MiB | 7.32 MiB | +2.69 MiB | +11.01 MiB |

Details are in the app size section.

## Method and conditions

- **Harness:** `scripts/bench` from f4cd3112, which is identical to the branch head, run from a worktree at f4cd3112. `BENCH_DIR=~/capgo-bench-c/run3`. The fixtures and RSA keys are APFS clones of run 2's, so all three labels get byte-identical payloads, builtin pad and keys.
  - Main suite: 3 runs per cell. Reuse suite: 3 runs per cell. Shaped suite: 3 runs. Cold and warm: n=5 each. Warm-ups are excluded.
- **Builds**
  - `rust` and `c`: the run 2 apps (`run2/apps/*-{ios,android}-{plain,enc}.*`), copied without rebuilding. The run 2 build worktree no longer existed. Checked before the runs that the binaries match run 2's records:
    - Android arm64 `libcapgo_updater_core.so`: 3,030,160 B for Rust (47 `rustls|ureq` strings, no `mbedtls`) and 894,992 B for C.
    - iOS `App` executable: 4,423,584 B for Rust (49 `rustls|ureq` strings, no `mbedtls`) and 1,552,496 B for C (`mbedtls`, 3 compatibility strings).
    - Every APK has `10.0.2.2:3193` in its builtin `bench.js`. The `enc` variants carry the `publicKey` and the `plain` ones do not.
  - `main`: a clean worktree at 0beaa91b with `bun install && bun run build`. The bench apps were built with the same harness `prepare-app.mjs`: iOS Release for the simulator, and an Android release APK, zipaligned and signed with the debug key. The `example-app/ios` and `example-app/android` projects are identical between main and f4cd3112, so the host apps match. Checks:
    - The main APKs contain no `lib/` directory at all, so no `libcapgo_updater_core.so`. Their dex contains the native updater classes (`DownloadService`, `CryptoCipher`, `CapgoUpdater`).
    - The main iOS executable is 1,997,984 B with 0 `rustls`, `ureq` or `mbedtls` strings. It is compiled from the plugin's Swift sources (`CapgoUpdater.swift`, `CryptoCipher.swift` and others), and the app has no `CapgoUpdaterCore.framework`.
    - `10.0.2.2:3193` is in the Android builtin `bench.js`, and the `publicKey` is in the `enc` builds.
  - A short untimed probe per platform (main label, 2- and 20-file manifests and 3 MB zips, plain and encrypted) checked that the native updater works with the bench server before timing. Both probes are in `run3/discarded/`.
- **iOS device:** iPhone 18 Pro simulator (iOS 27.0, UDID EDFC80C4-…), the same device as runs 1 and 2. It was booted for this session and shut down after the iOS runs.
- **Android device:** a fresh emulator: a new AVD with `capgo_mem_api36`'s `config.ini` (API 36 google_apis, arm64, 4 cores, 2 GB), started with `-port 5556 -no-window -no-audio -wipe-data -no-snapshot` (emulator-5556). Every Android cell, including cold and warm, ran on it. It was killed after the runs and its AVD was deleted. The harness turned Wi-Fi off for each run, so traffic went to the host alias 10.0.2.2 over eth0, with no adb reverse. The shared emulator-5554 and the attached physical device were not used. Every command passed `ANDROID_SERIAL=emulator-5556`.
- **Interleaving:** every platform and suite ran as one chunk per label, back to back. The order rotated between chunks.
  - iOS: main suite plain: main, c, rust. Main suite encrypted: c, rust, main. Reuse: rust, main, c. Shaped: main, c, rust.
  - Android: main suite plain: rust, c, main. Main suite encrypted: c, main, rust. Reuse: main, rust, c. Shaped: c, rust, main.
  - Reuse and shaped ran as separate chunks, for every label. Run 2 ran them together.
  - The Android main shaped chunk was split into two calls (zip + 200 files, then 2000 files) to stay under the 10-minute limit. They took 59 s and 81 s.
  - Cold: one sample per label per cell. The label order rotated on every sample: main, c, rust / c, rust, main / rust, main, c / … Warm: rust, main, c.
- **Load gate:** before each chunk, a script waited for the 1-minute load to fall below 4.5 (up to 180 s). From the native iOS encrypted chunk on, an extra wait of up to about 9 minutes ran before most chunks. Before each cold triple, the wait was up to 120 s, and up to 90 s before each warm chunk. Each chunk logs the load and the top processes (`run3/logs/agent/chunks.log`).
  - 1-minute load at the start of the kept chunks:
    - iOS: 3.0–4.5, except the Rust encrypted main chunk at 7.7 (still above the gate after 180 s).
    - Android main, reuse and shaped: 2.8–4.7.
    - Cold and warm: 3.0–6.2.
  - **Discard rule:** a chunk that started at a 1-minute load of 10 or more was discarded and re-run. Two chunks were discarded:
    - iOS C main suite plain: started at 14.9, with another session's `java` at 152% and `mediaanalysisd` at 114%. The rule was set after that chunk ran, when its background numbers had already been looked at (they were in line with Rust).
    - iOS native shaped: started at 21.9 during a host stall.
    - The re-runs started at 3.5 (C) and 4.5 (native). Both are at the end of the iOS session, so the C plain re-run is about 1 h 45 min after the native and Rust plain chunks, not next to them.
    - The discarded results are in `run3/discarded/`.
  - **Host stalls:**
    - 19:43, just before the session: load 38.
    - 21:05–21:35: load up to 118, with 23–27 GB of swap in use. Another session started the shared `capgo_mem_api36` emulator (emulator-5554) at about 21:01, and `STExtractionService`, `diagnosticd` and Finder/fileproviderd were busy. The runs waited for it to end. emulator-5554 stayed up for the rest of the session, which covers the last iOS chunks and all Android chunks.
    - OrbStack (`dory-hv`) ran the whole session, at up to 184% at the start of some chunks.
    - No thermal or performance warnings were recorded (`pmset -g therm`).
- **Failures:** 0 failed attempts, 0 harness retries and 0 app restarts in all kept results (all three labels, both platforms, including cold and warm).
- **Time limits:** every command stayed under 10 minutes. The longest chunk took 244 s (native, Android main suite encrypted).

## Live-update performance: native updater vs Rust core vs C core

Median of 3 runs, (min–max) in parentheses. Negative delta = the core is faster than the native updater. *background* = JS `download()` call until it resolves (download + verify + decrypt + unzip/assemble). *direct* = `download()` + `set()` until the new bundle has called `notifyAppReady()` (bench HTTP calls excluded). Payloads are random (incompressible) bytes served from a local bun server on the host. Manifest files are unique per run, so nothing is reused from builtin or the delta cache. Warm-up cases are excluded.

### iOS simulator (iPhone 18 Pro, iOS 27.0)

#### Background (download ready)

| Payload | Encryption | Native (main) | Rust | C | Δ C vs native | Δ Rust vs native |
|---|---|---|---|---|---|---|
| zip 3 MB | off | **20 ms** (18 ms–21 ms) | **13 ms** (10 ms–14 ms) | **10 ms** (6 ms–12 ms) | -50% | -35% |
| zip 3 MB | on | **17 ms** (16 ms–32 ms) | **16 ms** (11 ms–19 ms) | **12 ms** (12 ms–14 ms) | -29% | -6% (overlap) |
| zip 30 MB | off | **63 ms** (55 ms–77 ms) | **28 ms** (26 ms–30 ms) | **24 ms** (21 ms–45 ms) | -62% | -56% |
| zip 30 MB | on | **69 ms** (68 ms–78 ms) | **38 ms** (37 ms–145 ms) | **31 ms** (30 ms–32 ms) | -55% | -45% (overlap) |
| zip 300 MB | off | **444 ms** (404 ms–560 ms) | **197 ms** (180 ms–225 ms) | **155 ms** (141 ms–228 ms) | -65% | -56% |
| zip 300 MB | on | **572 ms** (525 ms–721 ms) | **483 ms** (310 ms–601 ms) | **431 ms** (295 ms–458 ms) | -25% | -16% (overlap) |
| manifest 2 files / 20 KB | off | **9 ms** (8 ms–11 ms) | **4 ms** (4 ms–5 ms) | **5 ms** (4 ms–5 ms) | -44% | -56% |
| manifest 2 files / 20 KB | on | **14 ms** (11 ms–16 ms) | **7 ms** (7 ms–7 ms) | **5 ms** (5 ms–7 ms) | -64% | -50% |
| manifest 20 files / 2 MB | off | **32 ms** (32 ms–35 ms) | **12 ms** (12 ms–13 ms) | **11 ms** (11 ms–11 ms) | -66% | -63% |
| manifest 20 files / 2 MB | on | **41 ms** (41 ms–43 ms) | **15 ms** (13 ms–17 ms) | **15 ms** (13 ms–16 ms) | -63% | -63% |
| manifest 200 files / 20 MB | off | **241 ms** (230 ms–256 ms) | **63 ms** (61 ms–69 ms) | **61 ms** (60 ms–62 ms) | -75% | -74% |
| manifest 200 files / 20 MB | on | **305 ms** (295 ms–335 ms) | **97 ms** (95 ms–107 ms) | **94 ms** (86 ms–107 ms) | -69% | -68% |
| manifest 2000 files / 200 MB | off | **2.34 s** (2.29 s–2.44 s) | **563 ms** (532 ms–639 ms) | **549 ms** (541 ms–562 ms) | -77% | -76% |
| manifest 2000 files / 200 MB | on | **3.07 s** (2.88 s–3.35 s) | **873 ms** (859 ms–924 ms) | **874 ms** (872 ms–884 ms) | -72% | -72% |

#### Direct (download + set until app ready)

| Payload | Encryption | Native (main) | Rust | C | Δ C vs native | Δ Rust vs native |
|---|---|---|---|---|---|---|
| zip 3 MB | off | **43 ms** (41 ms–43 ms) | **33 ms** (32 ms–38 ms) | **27 ms** (26 ms–27 ms) | -37% | -23% |
| zip 3 MB | on | **41 ms** (40 ms–54 ms) | **37 ms** (36 ms–53 ms) | **35 ms** (35 ms–38 ms) | -15% | -10% (overlap) |
| zip 30 MB | off | **86 ms** (80 ms–113 ms) | **57 ms** (54 ms–57 ms) | **48 ms** (42 ms–48 ms) | -44% | -34% |
| zip 30 MB | on | **89 ms** (88 ms–95 ms) | **72 ms** (66 ms–90 ms) | **65 ms** (57 ms–85 ms) | -27% | -19% (overlap) |
| zip 300 MB | off | **590 ms** (491 ms–700 ms) | **213 ms** (207 ms–232 ms) | **180 ms** (158 ms–191 ms) | -69% | -64% |
| zip 300 MB | on | **667 ms** (485 ms–820 ms) | **533 ms** (332 ms–623 ms) | **297 ms** (283 ms–619 ms) | -55% (overlap) | -20% (overlap) |
| manifest 2 files / 20 KB | off | **45 ms** (39 ms–48 ms) | **36 ms** (35 ms–38 ms) | **32 ms** (30 ms–33 ms) | -29% | -20% |
| manifest 2 files / 20 KB | on | **42 ms** (42 ms–58 ms) | **33 ms** (33 ms–39 ms) | **36 ms** (35 ms–45 ms) | -14% (overlap) | -21% |
| manifest 20 files / 2 MB | off | **56 ms** (50 ms–59 ms) | **39 ms** (39 ms–42 ms) | **32 ms** (32 ms–36 ms) | -43% | -30% |
| manifest 20 files / 2 MB | on | **68 ms** (68 ms–89 ms) | **48 ms** (38 ms–55 ms) | **43 ms** (40 ms–45 ms) | -37% | -29% |
| manifest 200 files / 20 MB | off | **261 ms** (260 ms–281 ms) | **88 ms** (88 ms–92 ms) | **82 ms** (78 ms–86 ms) | -69% | -66% |
| manifest 200 files / 20 MB | on | **334 ms** (331 ms–356 ms) | **123 ms** (119 ms–144 ms) | **121 ms** (120 ms–125 ms) | -64% | -63% |
| manifest 2000 files / 200 MB | off | **2.46 s** (2.15 s–2.77 s) | **592 ms** (578 ms–604 ms) | **572 ms** (568 ms–576 ms) | -77% | -76% |
| manifest 2000 files / 200 MB | on | **2.99 s** (2.91 s–3.10 s) | **919 ms** (907 ms–920 ms) | **901 ms** (866 ms–907 ms) | -70% | -69% |

<details><summary>Direct mode breakdown (download vs set() → app ready), medians</summary>

| Payload | Encryption | Download native / Rust / C | Apply native / Rust / C |
|---|---|---|---|
| zip 3 MB | off | 17 ms / 9 ms / 7 ms | 26 ms / 24 ms / 20 ms |
| zip 3 MB | on | 17 ms / 12 ms / 9 ms | 24 ms / 25 ms / 26 ms |
| zip 30 MB | off | 61 ms / 30 ms / 25 ms | 25 ms / 26 ms / 23 ms |
| zip 30 MB | on | 65 ms / 42 ms / 36 ms | 24 ms / 29 ms / 29 ms |
| zip 300 MB | off | 564 ms / 189 ms / 159 ms | 26 ms / 25 ms / 20 ms |
| zip 300 MB | on | 640 ms / 505 ms / 270 ms | 27 ms / 27 ms / 27 ms |
| manifest 2 files / 20 KB | off | 13 ms / 7 ms / 7 ms | 32 ms / 30 ms / 25 ms |
| manifest 2 files / 20 KB | on | 16 ms / 7 ms / 8 ms | 29 ms / 27 ms / 31 ms |
| manifest 20 files / 2 MB | off | 31 ms / 13 ms / 10 ms | 25 ms / 26 ms / 22 ms |
| manifest 20 files / 2 MB | on | 42 ms / 16 ms / 16 ms | 26 ms / 32 ms / 27 ms |
| manifest 200 files / 20 MB | off | 236 ms / 64 ms / 62 ms | 25 ms / 24 ms / 20 ms |
| manifest 200 files / 20 MB | on | 312 ms / 100 ms / 98 ms | 23 ms / 26 ms / 23 ms |
| manifest 2000 files / 200 MB | off | 2.43 s / 567 ms / 552 ms | 27 ms / 25 ms / 20 ms |
| manifest 2000 files / 200 MB | on | 2.96 s / 887 ms / 875 ms | 23 ms / 29 ms / 26 ms |

</details>

#### Direct mode: apply step split (median, native / Rust / C)

*set()*: from the `set()` call until the new document starts loading (`performance.timeOrigin`). *reload*: new document load until the bench script calls `notifyAppReady()`. *notify*: the `notifyAppReady()` call.

| Payload | Encryption | Apply | set() | Reload | notify |
|---|---|---|---|---|---|
| zip 3 MB | off | 26 ms / 24 ms / 20 ms | 4 ms / 3 ms / 2 ms | 19 ms / 19 ms / 15 ms | 3 ms / 3 ms / 3 ms |
| zip 3 MB | on | 24 ms / 25 ms / 26 ms | 4 ms / 3 ms / 3 ms | 18 ms / 19 ms / 20 ms | 3 ms / 3 ms / 4 ms |
| zip 30 MB | off | 25 ms / 26 ms / 23 ms | 3 ms / 3 ms / 3 ms | 20 ms / 20 ms / 18 ms | 2 ms / 4 ms / 2 ms |
| zip 30 MB | on | 24 ms / 29 ms / 29 ms | 3 ms / 3 ms / 4 ms | 18 ms / 21 ms / 21 ms | 3 ms / 3 ms / 4 ms |
| zip 300 MB | off | 26 ms / 25 ms / 20 ms | 3 ms / 3 ms / 2 ms | 20 ms / 19 ms / 15 ms | 3 ms / 3 ms / 3 ms |
| zip 300 MB | on | 27 ms / 27 ms / 27 ms | 3 ms / 3 ms / 3 ms | 20 ms / 20 ms / 21 ms | 3 ms / 4 ms / 3 ms |
| manifest 2 files / 20 KB | off | 32 ms / 30 ms / 25 ms | 4 ms / 4 ms / 3 ms | 23 ms / 22 ms / 18 ms | 4 ms / 4 ms / 3 ms |
| manifest 2 files / 20 KB | on | 29 ms / 27 ms / 31 ms | 3 ms / 3 ms / 4 ms | 23 ms / 20 ms / 22 ms | 3 ms / 4 ms / 5 ms |
| manifest 20 files / 2 MB | off | 25 ms / 26 ms / 22 ms | 3 ms / 3 ms / 3 ms | 19 ms / 20 ms / 18 ms | 3 ms / 3 ms / 2 ms |
| manifest 20 files / 2 MB | on | 26 ms / 32 ms / 27 ms | 3 ms / 3 ms / 3 ms | 20 ms / 24 ms / 20 ms | 3 ms / 3 ms / 3 ms |
| manifest 200 files / 20 MB | off | 25 ms / 24 ms / 20 ms | 3 ms / 3 ms / 2 ms | 19 ms / 18 ms / 16 ms | 3 ms / 3 ms / 2 ms |
| manifest 200 files / 20 MB | on | 23 ms / 26 ms / 23 ms | 3 ms / 3 ms / 3 ms | 18 ms / 19 ms / 18 ms | 2 ms / 4 ms / 3 ms |
| manifest 2000 files / 200 MB | off | 27 ms / 25 ms / 20 ms | 4 ms / 3 ms / 2 ms | 20 ms / 19 ms / 15 ms | 3 ms / 3 ms / 2 ms |
| manifest 2000 files / 200 MB | on | 23 ms / 29 ms / 26 ms | 3 ms / 3 ms / 3 ms | 17 ms / 20 ms / 20 ms | 3 ms / 3 ms / 3 ms |

#### Manifest reuse (background, 90% of the files already on the device)

*delta cache*: version A with the same files was installed (untimed) right before B; only B is timed. *builtin*: the reused files ship in the app's builtin `public/`. "Fetched" = payload requests the server saw for B (expected: new files + `index.html` + `bench.js`).

| Reuse from | Payload | Encryption | Native (main) | Rust | C | Δ C vs native | Δ Rust vs native | Fetched native / Rust / C (expected) |
|---|---|---|---|---|---|---|---|---|
| delta cache | 200 files / 20 MB | off | **82 ms** (69 ms–83 ms) | **59 ms** (59 ms–66 ms) | **56 ms** (55 ms–57 ms) | -32% | -28% | 22 / 22 / 22 (22) |
| delta cache | 200 files / 20 MB | on | **122 ms** (112 ms–125 ms) | **72 ms** (64 ms–73 ms) | **62 ms** (60 ms–73 ms) | -49% | -41% | 22 / 22 / 22 (22) |
| delta cache | 2000 files / 200 MB | off | **645 ms** (639 ms–720 ms) | **508 ms** (496 ms–517 ms) | **490 ms** (485 ms–492 ms) | -24% | -21% | 202 / 202 / 202 (202) |
| delta cache | 2000 files / 200 MB | on | **969 ms** (960 ms–1.22 s) | **579 ms** (570 ms–586 ms) | **565 ms** (563 ms–599 ms) | -42% | -40% | 202 / 202 / 202 (202) |
| builtin | 200 files / 20 MB | off | **72 ms** (65 ms–73 ms) | **29 ms** (26 ms–30 ms) | **31 ms** (31 ms–33 ms) | -57% | -60% | 22 / 22 / 22 (22) |
| builtin | 200 files / 20 MB | on | **109 ms** (94 ms–117 ms) | **37 ms** (37 ms–38 ms) | **37 ms** (37 ms–38 ms) | -66% | -66% | 22 / 22 / 22 (22) |
| builtin | 2000 files / 200 MB | off | **609 ms** (601 ms–735 ms) | **260 ms** (255 ms–337 ms) | **274 ms** (274 ms–283 ms) | -55% | -57% | 202 / 202 / 202 (202) |
| builtin | 2000 files / 200 MB | on | **939 ms** (886 ms–988 ms) | **341 ms** (340 ms–352 ms) | **333 ms** (328 ms–343 ms) | -65% | -64% | 202 / 202 / 202 (202) |

#### Network-shaped (background, plain): 80 ms before every response, 40 Mbit/s total (shared token bucket)

The link alone needs ~4.2 s for 20 MB and ~6.3 s for 30 MB. "Link use" = payload bytes / total time, as a share of the cap.

| Payload | Native (main) | Rust | C | Δ C vs native | Δ Rust vs native | Link use native / Rust / C | Peak parallel requests native / Rust / C |
|---|---|---|---|---|---|---|---|
| zip 30 MB | **6.42 s** (6.42 s–6.42 s) | **6.39 s** (6.38 s–6.40 s) | **6.39 s** (6.38 s–6.39 s) | -0% | -0% | 98% / 98% / 98% | 1 / 1 / 1 |
| manifest 200 files / 20 MB | **4.30 s** (4.30 s–4.30 s) | **4.28 s** (4.27 s–4.28 s) | **4.28 s** (4.27 s–4.28 s) | -0% | -0% | 98% / 98% / 98% | 36 / 64 / 64 |
| manifest 2000 files / 20 MB | **4.97 s** (4.96 s–4.99 s) | **4.30 s** (4.30 s–4.30 s) | **4.30 s** (4.30 s–4.30 s) | -14% | -14% | 84% / 98% / 98% | 36 / 64 / 64 |

### Android emulator (API 36, arm64, fresh `capgo_mem_api36` clone; host alias 10.0.2.2, Wi-Fi off, no adb reverse)

#### Android cold start (first manifest case after a fresh app launch) vs warm

Cold: one fresh install + launch per sample (after the two zip warm-ups, which use one connection each), and only this cell runs. Warm: runs 2+ of one launch that runs both cells alternately (run 1 is dropped because it is cold). Same fresh emulator as the tables below. The label order rotated on every sample.

| Cell | State | Native (main) | Rust | C | Δ C vs native | Δ Rust vs native |
|---|---|---|---|---|---|---|
| manifest 20 files / 2 MB, background, plain | cold | **60 ms** (55 ms–64 ms) n=5 | **32 ms** (29 ms–35 ms) n=5 | **31 ms** (29 ms–37 ms) n=5 | -48% | -47% |
| manifest 20 files / 2 MB, background, plain | warm | **51 ms** (44 ms–52 ms) n=5 | **33 ms** (29 ms–35 ms) n=5 | **31 ms** (24 ms–36 ms) n=5 | -39% | -35% |
| manifest 2 files / 20 KB, direct, plain | cold | **34 ms** (34 ms–44 ms) n=5 | **26 ms** (24 ms–27 ms) n=5 | **24 ms** (22 ms–35 ms) n=5 | -29% (overlap) | -24% |
| manifest 2 files / 20 KB, direct, plain | warm | **35 ms** (32 ms–42 ms) n=5 | **26 ms** (22 ms–35 ms) n=5 | **27 ms** (26 ms–38 ms) n=5 | -23% (overlap) | -26% (overlap) |

#### Background (download ready)

| Payload | Encryption | Native (main) | Rust | C | Δ C vs native | Δ Rust vs native |
|---|---|---|---|---|---|---|
| zip 3 MB | off | **102 ms** (95 ms–102 ms) | **60 ms** (56 ms–67 ms) | **59 ms** (56 ms–64 ms) | -42% | -41% |
| zip 3 MB | on | **105 ms** (102 ms–123 ms) | **65 ms** (62 ms–67 ms) | **66 ms** (55 ms–66 ms) | -37% | -38% |
| zip 30 MB | off | **794 ms** (792 ms–820 ms) | **401 ms** (366 ms–409 ms) | **387 ms** (360 ms–389 ms) | -51% | -49% |
| zip 30 MB | on | **811 ms** (792 ms–820 ms) | **379 ms** (375 ms–418 ms) | **391 ms** (367 ms–444 ms) | -52% | -53% |
| zip 300 MB | off | **7.88 s** (7.61 s–7.93 s) | **3.87 s** (3.73 s–4.08 s) | **3.74 s** (3.60 s–4.25 s) | -53% | -51% |
| zip 300 MB | on | **8.21 s** (8.08 s–8.30 s) | **3.88 s** (3.78 s–3.97 s) | **3.83 s** (3.66 s–3.95 s) | -53% | -53% |
| manifest 2 files / 20 KB | off | **22 ms** (21 ms–29 ms) | **14 ms** (13 ms–16 ms) | **12 ms** (11 ms–15 ms) | -45% | -36% |
| manifest 2 files / 20 KB | on | **26 ms** (25 ms–35 ms) | **16 ms** (15 ms–17 ms) | **12 ms** (12 ms–13 ms) | -54% | -38% |
| manifest 20 files / 2 MB | off | **53 ms** (51 ms–65 ms) | **32 ms** (30 ms–33 ms) | **33 ms** (30 ms–36 ms) | -38% | -40% |
| manifest 20 files / 2 MB | on | **56 ms** (55 ms–83 ms) | **36 ms** (30 ms–38 ms) | **28 ms** (28 ms–29 ms) | -50% | -36% |
| manifest 200 files / 20 MB | off | **225 ms** (219 ms–231 ms) | **142 ms** (134 ms–143 ms) | **134 ms** (117 ms–143 ms) | -40% | -37% |
| manifest 200 files / 20 MB | on | **280 ms** (269 ms–281 ms) | **148 ms** (146 ms–168 ms) | **108 ms** (104 ms–131 ms) | -61% | -47% |
| manifest 2000 files / 200 MB | off | **2.09 s** (2.02 s–2.10 s) | **1.22 s** (1.22 s–1.31 s) | **1.14 s** (1.11 s–1.23 s) | -45% | -42% |
| manifest 2000 files / 200 MB | on | **2.60 s** (2.60 s–2.66 s) | **1.46 s** (1.45 s–1.47 s) | **1.02 s** (983 ms–1.31 s) | -61% | -44% |

#### Direct (download + set until app ready)

| Payload | Encryption | Native (main) | Rust | C | Δ C vs native | Δ Rust vs native |
|---|---|---|---|---|---|---|
| zip 3 MB | off | **123 ms** (112 ms–136 ms) | **75 ms** (69 ms–78 ms) | **74 ms** (65 ms–452 ms) | -40% (overlap) | -39% |
| zip 3 MB | on | **112 ms** (110 ms–124 ms) | **71 ms** (68 ms–73 ms) | **73 ms** (72 ms–100 ms) | -35% | -37% |
| zip 30 MB | off | **832 ms** (803 ms–847 ms) | **422 ms** (411 ms–431 ms) | **393 ms** (357 ms–419 ms) | -53% | -49% |
| zip 30 MB | on | **813 ms** (805 ms–819 ms) | **435 ms** (397 ms–444 ms) | **426 ms** (418 ms–448 ms) | -48% | -46% |
| zip 300 MB | off | **7.91 s** (7.75 s–8.02 s) | **3.85 s** (3.79 s–3.92 s) | **3.85 s** (3.50 s–4.02 s) | -51% | -51% |
| zip 300 MB | on | **8.09 s** (7.98 s–8.27 s) | **3.86 s** (3.86 s–3.93 s) | **3.71 s** (3.64 s–4.39 s) | -54% | -52% |
| manifest 2 files / 20 KB | off | **36 ms** (34 ms–38 ms) | **30 ms** (29 ms–31 ms) | **29 ms** (27 ms–30 ms) | -19% | -17% |
| manifest 2 files / 20 KB | on | **49 ms** (40 ms–127 ms) | **38 ms** (35 ms–42 ms) | **33 ms** (28 ms–43 ms) | -33% (overlap) | -22% (overlap) |
| manifest 20 files / 2 MB | off | **69 ms** (60 ms–88 ms) | **49 ms** (48 ms–49 ms) | **52 ms** (47 ms–57 ms) | -25% | -29% |
| manifest 20 files / 2 MB | on | **70 ms** (66 ms–74 ms) | **47 ms** (44 ms–48 ms) | **43 ms** (42 ms–47 ms) | -39% | -33% |
| manifest 200 files / 20 MB | off | **234 ms** (227 ms–276 ms) | **160 ms** (149 ms–171 ms) | **117 ms** (117 ms–119 ms) | -50% | -32% |
| manifest 200 files / 20 MB | on | **306 ms** (292 ms–307 ms) | **170 ms** (165 ms–195 ms) | **122 ms** (119 ms–138 ms) | -60% | -44% |
| manifest 2000 files / 200 MB | off | **2.04 s** (2.02 s–2.17 s) | **1.31 s** (1.23 s–1.36 s) | **1.46 s** (1.15 s–1.78 s) | -28% | -36% |
| manifest 2000 files / 200 MB | on | **2.69 s** (2.57 s–2.70 s) | **1.46 s** (1.46 s–1.47 s) | **1.02 s** (975 ms–1.23 s) | -62% | -46% |

<details><summary>Direct mode breakdown (download vs set() → app ready), medians</summary>

| Payload | Encryption | Download native / Rust / C | Apply native / Rust / C |
|---|---|---|---|
| zip 3 MB | off | 94 ms / 62 ms / 58 ms | 24 ms / 13 ms / 16 ms |
| zip 3 MB | on | 98 ms / 57 ms / 60 ms | 18 ms / 13 ms / 13 ms |
| zip 30 MB | off | 814 ms / 411 ms / 377 ms | 18 ms / 12 ms / 16 ms |
| zip 30 MB | on | 795 ms / 420 ms / 412 ms | 20 ms / 15 ms / 14 ms |
| zip 300 MB | off | 7.89 s / 3.83 s / 3.84 s | 18 ms / 24 ms / 23 ms |
| zip 300 MB | on | 8.05 s / 3.84 s / 3.67 s | 34 ms / 21 ms / 23 ms |
| manifest 2 files / 20 KB | off | 22 ms / 13 ms / 12 ms | 14 ms / 16 ms / 17 ms |
| manifest 2 files / 20 KB | on | 31 ms / 20 ms / 14 ms | 17 ms / 18 ms / 15 ms |
| manifest 20 files / 2 MB | off | 56 ms / 33 ms / 30 ms | 13 ms / 16 ms / 18 ms |
| manifest 20 files / 2 MB | on | 54 ms / 32 ms / 27 ms | 14 ms / 16 ms / 16 ms |
| manifest 200 files / 20 MB | off | 223 ms / 148 ms / 105 ms | 13 ms / 17 ms / 12 ms |
| manifest 200 files / 20 MB | on | 294 ms / 157 ms / 109 ms | 13 ms / 13 ms / 13 ms |
| manifest 2000 files / 200 MB | off | 2.02 s / 1.30 s / 1.44 s | 13 ms / 16 ms / 16 ms |
| manifest 2000 files / 200 MB | on | 2.67 s / 1.45 s / 1.00 s | 13 ms / 16 ms / 14 ms |

</details>

#### Direct mode: apply step split (median, native / Rust / C)

*set()*: from the `set()` call until the new document starts loading (`performance.timeOrigin`). *reload*: new document load until the bench script calls `notifyAppReady()`. *notify*: the `notifyAppReady()` call.

| Payload | Encryption | Apply | set() | Reload | notify |
|---|---|---|---|---|---|
| zip 3 MB | off | 24 ms / 13 ms / 16 ms | 8 ms / 3 ms / 3 ms | 7 ms / 6 ms / 6 ms | 5 ms / 4 ms / 7 ms |
| zip 3 MB | on | 18 ms / 13 ms / 13 ms | 4 ms / 3 ms / 3 ms | 6 ms / 7 ms / 7 ms | 4 ms / 4 ms / 5 ms |
| zip 30 MB | off | 18 ms / 12 ms / 16 ms | 4 ms / 3 ms / 3 ms | 7 ms / 6 ms / 8 ms | 6 ms / 3 ms / 4 ms |
| zip 30 MB | on | 20 ms / 15 ms / 14 ms | 4 ms / 3 ms / 3 ms | 7 ms / 7 ms / 7 ms | 10 ms / 7 ms / 4 ms |
| zip 300 MB | off | 18 ms / 24 ms / 23 ms | 5 ms / 10 ms / 8 ms | 7 ms / 10 ms / 6 ms | 4 ms / 5 ms / 4 ms |
| zip 300 MB | on | 34 ms / 21 ms / 23 ms | 13 ms / 5 ms / 5 ms | 12 ms / 10 ms / 12 ms | 9 ms / 5 ms / 6 ms |
| manifest 2 files / 20 KB | off | 14 ms / 16 ms / 17 ms | 3 ms / 4 ms / 3 ms | 7 ms / 8 ms / 8 ms | 4 ms / 5 ms / 6 ms |
| manifest 2 files / 20 KB | on | 17 ms / 18 ms / 15 ms | 4 ms / 4 ms / 3 ms | 7 ms / 7 ms / 7 ms | 4 ms / 8 ms / 5 ms |
| manifest 20 files / 2 MB | off | 13 ms / 16 ms / 18 ms | 4 ms / 3 ms / 3 ms | 5 ms / 8 ms / 10 ms | 4 ms / 5 ms / 5 ms |
| manifest 20 files / 2 MB | on | 14 ms / 16 ms / 16 ms | 3 ms / 3 ms / 3 ms | 5 ms / 6 ms / 8 ms | 5 ms / 5 ms / 4 ms |
| manifest 200 files / 20 MB | off | 13 ms / 17 ms / 12 ms | 3 ms / 3 ms / 3 ms | 6 ms / 7 ms / 6 ms | 4 ms / 5 ms / 4 ms |
| manifest 200 files / 20 MB | on | 13 ms / 13 ms / 13 ms | 3 ms / 4 ms / 3 ms | 6 ms / 6 ms / 7 ms | 3 ms / 3 ms / 4 ms |
| manifest 2000 files / 200 MB | off | 13 ms / 16 ms / 16 ms | 3 ms / 4 ms / 3 ms | 6 ms / 8 ms / 6 ms | 4 ms / 4 ms / 4 ms |
| manifest 2000 files / 200 MB | on | 13 ms / 16 ms / 14 ms | 3 ms / 5 ms / 3 ms | 6 ms / 7 ms / 7 ms | 5 ms / 4 ms / 4 ms |

#### Manifest reuse (background, 90% of the files already on the device)

*delta cache*: version A with the same files was installed (untimed) right before B; only B is timed. *builtin*: the reused files ship in the app's builtin `public/`. "Fetched" = payload requests the server saw for B (expected: new files + `index.html` + `bench.js`).

| Reuse from | Payload | Encryption | Native (main) | Rust | C | Δ C vs native | Δ Rust vs native | Fetched native / Rust / C (expected) |
|---|---|---|---|---|---|---|---|---|
| delta cache | 200 files / 20 MB | off | **87 ms** (72 ms–90 ms) | **48 ms** (46 ms–53 ms) | **48 ms** (43 ms–55 ms) | -45% | -45% | 22 / 22 / 22 (22) |
| delta cache | 200 files / 20 MB | on | **97 ms** (78 ms–103 ms) | **56 ms** (54 ms–58 ms) | **53 ms** (48 ms–54 ms) | -45% | -42% | 22 / 22 / 22 (22) |
| delta cache | 2000 files / 200 MB | off | **612 ms** (519 ms–623 ms) | **332 ms** (323 ms–352 ms) | **346 ms** (246 ms–354 ms) | -43% | -46% | 202 / 202 / 202 (202) |
| delta cache | 2000 files / 200 MB | on | **772 ms** (708 ms–896 ms) | **429 ms** (424 ms–500 ms) | **383 ms** (376 ms–385 ms) | -50% | -44% | 202 / 202 / 202 (202) |
| builtin | 200 files / 20 MB | off | **100 ms** (73 ms–136 ms) | **45 ms** (34 ms–47 ms) | **49 ms** (34 ms–55 ms) | -51% | -55% | 22 / 22 / 22 (22) |
| builtin | 200 files / 20 MB | on | **133 ms** (107 ms–139 ms) | **56 ms** (53 ms–58 ms) | **49 ms** (45 ms–61 ms) | -63% | -58% | 22 / 22 / 22 (22) |
| builtin | 2000 files / 200 MB | off | **723 ms** (537 ms–857 ms) | **320 ms** (312 ms–337 ms) | **279 ms** (267 ms–291 ms) | -61% | -56% | 202 / 202 / 202 (202) |
| builtin | 2000 files / 200 MB | on | **914 ms** (776 ms–1.41 s) | **420 ms** (410 ms–428 ms) | **312 ms** (249 ms–332 ms) | -66% | -54% | 202 / 202 / 202 (202) |

#### Network-shaped (background, plain): 80 ms before every response, 40 Mbit/s total (shared token bucket)

The link alone needs ~4.2 s for 20 MB and ~6.3 s for 30 MB. "Link use" = payload bytes / total time, as a share of the cap.

| Payload | Native (main) | Rust | C | Δ C vs native | Δ Rust vs native | Link use native / Rust / C | Peak parallel requests native / Rust / C |
|---|---|---|---|---|---|---|---|
| zip 30 MB | **6.78 s** (6.75 s–6.78 s) | **6.41 s** (6.41 s–6.42 s) | **6.39 s** (6.39 s–6.39 s) | -6% | -5% | 93% / 98% / 99% | 1 / 1 / 1 |
| manifest 200 files / 20 MB | **4.29 s** (4.29 s–4.29 s) | **4.28 s** (4.28 s–4.28 s) | **4.28 s** (4.27 s–4.28 s) | -0% | -0% | 98% / 98% / 98% | 8 / 32 / 32 |
| manifest 2000 files / 20 MB | **21.02 s** (21.00 s–21.07 s) | **5.25 s** (5.25 s–5.25 s) | **5.21 s** (5.21 s–5.22 s) | -75% | -75% | 20% / 80% / 80% | 8 / 32 / 32 |

### App size (release bench builds, plain variant)

The bench app's web assets (`public/`, including the 180 MB builtin pad used by the reuse cases) are the same for all three labels. The rows without web assets show the native footprint. The host app (Capacitor, Cordova, AndroidX) is the same, so the differences come from the updater: on `main`, the Java/Swift updater and its libraries; on the branch, the Java/Swift glue plus the core library.

#### Android (signed release APK, all ABIs)

| | Native (main) | Rust | C | Δ C vs native | Δ Rust vs native |
|---|---|---|---|---|---|
| APK total | 184.69 MiB | 195.71 MiB | 187.38 MiB | +2.69 MiB | +11.01 MiB |
| APK without web assets | 4.63 MiB | 15.64 MiB | 7.32 MiB | +2.69 MiB | +11.01 MiB |
| classes.dex (uncompressed) | 9.76 MiB | 8.52 MiB | 8.52 MiB | −1.24 MiB | −1.24 MiB |
| lib/arm64-v8a/libcapgo_updater_core.so | none | 2.89 MiB | 874.0 KiB | +874.0 KiB | +2.89 MiB |
| lib/armeabi-v7a/libcapgo_updater_core.so | none | 1.93 MiB | 639.0 KiB | +639.0 KiB | +1.93 MiB |
| lib/x86/libcapgo_updater_core.so | none | 3.41 MiB | 898.6 KiB | +898.6 KiB | +3.41 MiB |
| lib/x86_64/libcapgo_updater_core.so | none | 3.31 MiB | 883.7 KiB | +883.7 KiB | +3.31 MiB |
| gzip -9 of classes.dex | 3.51 MiB | 2.99 MiB | 2.99 MiB | −529.9 KiB | −529.9 KiB |
| gzip -9 of the arm64 `.so` | none | 1.47 MiB | 420.0 KiB | +420.0 KiB | +1.47 MiB |
| **Estimated arm64 per-device download** (gzip -9 dex + gzip -9 arm64 `.so`) | **3.51 MiB** | **4.47 MiB** | **3.40 MiB** | **−109.9 KiB** | **+978.6 KiB** |

The `.so` files are stored uncompressed in the APK, so the all-ABI APK grows with every ABI's library. A Play Store split install ships only one ABI, and the estimate above models that for arm64. It is an estimate: the store's own compression differs from gzip -9.

#### iOS (Release simulator .app, arm64)

| | Native (main) | Rust | C | Δ C vs native | Δ Rust vs native |
|---|---|---|---|---|---|
| .app total | 186.69 MiB | 189.04 MiB | 186.30 MiB | −399.3 KiB | +2.35 MiB |
| .app without web assets | 6.69 MiB | 9.03 MiB | 6.30 MiB | −399.3 KiB | +2.35 MiB |
| App executable | 1.91 MiB | 4.22 MiB | 1.48 MiB | −435.0 KiB (−22%) | +2.31 MiB (+121%) |
| App executable, gzip -9 | 608.3 KiB | 1.74 MiB | 599.6 KiB | −8.7 KiB | +1.15 MiB |
| Frameworks/CapgoUpdaterCore.framework | none | 34.9 KiB | 34.9 KiB | +34.9 KiB | +34.9 KiB |
| Frameworks/Capacitor.framework | 4.05 MiB | 4.05 MiB | 4.05 MiB | 0 | 0 |
| Frameworks/Cordova.framework | 240.2 KiB | 240.2 KiB | 240.2 KiB | 0 | 0 |

The updater code and its dependencies are in the `App` executable in all three builds: there is no separate updater framework apart from the 34.9 KiB `CapgoUpdaterCore.framework` of the branch builds. These are simulator builds; device (arm64 iphoneos) builds were not measured.

### Caveats

- **iPhone 18 Pro, not iPhone 17 Pro.** No iPhone 17 Pro simulator exists on this host. Absolute iOS numbers are not directly comparable to #937; the three-way comparison in this file is.
- **The host was shared and busy at times** (see Method). The labels of each suite ran back to back under the same gate. Two chunks were discarded and re-run under the load rule, so those two re-runs are not adjacent to the other labels' chunks. Single cells can still be hit; the "(overlap)" marks show where the ranges do not separate the labels.
- **Noisy cells:** the iOS 300 MB zip cells (native 404–820 ms, Rust 180–623 ms, C 141–619 ms across the background and direct cells), the iOS encrypted zip cells for Rust (one 145 ms run at 30 MB), Android C zip 3 MB plain direct (one 452 ms run) and Android C manifest 2000 files plain direct (1.15–1.78 s).
- **The `rust` and `c` apps were not rebuilt.** They are the run 2 binaries, checked against run 2's recorded sizes and strings. `main` was built in this session on the same machine (Xcode 27.1, Java 21, the Gradle setup of the identical example-app projects); the run 2 builds were made earlier the same day.
- **Simulator and emulator, not devices.** The emulator reaches the bench server over the host loopback, so Android network times are much lower than on a real network. The shaped suite is the only one with latency and a bandwidth cap.
- **Wall-clock time:** about 3 h 20 min (19:37–22:57), including the main builds, the probes, the host stall and the two re-runs.
