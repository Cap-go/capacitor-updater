# Rust core vs C core: live-update performance (run 2, after the C fixes)

Branch `riderx/capgo-c-core` @ f4cd3112 (PR #962), built once in a clean worktree (`/tmp/capgo-bench-wt2`). Label `rust` = `CAPGO_CORE_IMPL=rust`, label `c` = `CAPGO_CORE_IMPL=c`. Everything else (Java/Swift glue, bench app, fixtures, server) is identical. This is run 2. Since run 1 (0d56b1c8, 2026-10-15) the C core got three performance fixes: Montgomery RSA (`crypto/rsa.c`), three-lane CRC-32 for unzip (`engine/archive.c`) and an Android descriptor-table pre-grow (`engine/engine.c`). The Rust core is unchanged. Measured 2026-10-16 13:23–16:50 WEST on an Apple M5 Pro (Mac17,9, 18 cores, 64 GB), macOS 27.2, Xcode 27.1. Raw results: `~/capgo-bench-c/run2/`.

## Summary

**iOS simulator: parity, with C ahead on zips.** Of the 39 timed cells, C is faster in 23, equal in 9 and slower in 7.
- Zips: 3 MB background −15% plain and −21% encrypted, 30 MB background −19% and −24%, 300 MB encrypted −34% background and −13% direct.
- Large manifests (200 and 2000 files): −7% to +6%. 2000 files encrypted: −3% background, −7% direct.
- Reuse: −2% to −10%. Shaped runs: identical (link-bound).
- Slower cells: 6 of the 7 are in the first iOS chunk (C, plain), which started right after a host I/O stall.
  - zip 300 MB plain background: 162 → 334 ms (+106%, C range 178–383 ms). An interleaved re-run of every zip cell gave 241 → 158 ms (−34%), which points to noise in the first pass.
  - zip 30 MB plain direct: 51 → 57 ms (+12%, ranges 50–51 vs 52–63 ms, no overlap). The re-run gave 56 → 49 ms (−13%).
  - manifest 2 files plain direct: 31 → 37 ms (+19%, +6 ms, ranges 31–34 vs 34–38 ms). In run 1 this cell was −3%. It was not re-run.
  - Four more cells are +5% to +9% (≤ 7 ms), and their ranges overlap: manifest 20 files plain background and direct, zip 300 MB plain direct, manifest 200 files encrypted direct.

**Android emulator: C faster on large manifests, parity elsewhere.** Of the 39 timed cells, C is faster in 31, equal in 3 and slower in 5.
- Manifest 200 and 2000 files: C is **21–35% faster** in both modes. Background 200 files plain: 155 → 100 ms. Background 2000 files plain: 1.37 s → 1.06 s; with encryption: 1.43 s → 1.14 s. Direct 2000 files plain: 1.40 s → 974 ms.
- Zips: −12% to +2%. Small manifests: −17% to +3%.
- Reuse: −43% to +5%, with wide ranges for both cores (see the reuse table).
- Shaped runs: −0% to −1%.
- Slower cells (all ≤ +5%, ≤ 20 ms): zip 3 MB encrypted background, manifest 2 and 20 files encrypted direct, delta-cache reuse 2000 files encrypted (423 → 443 ms, ranges 389–429 vs 438–449 ms, no overlap) and builtin reuse 200 files plain.
- **Cold start is no longer a C loss.** First manifest case after launch (20 files, background): cold 37 ms Rust vs 32 ms C (ranges 24–45 vs 27–33 ms), warm 31 vs 28 ms. The 2-file direct cold cell is equal (25 vs 26 ms).

**App size: C is much smaller.**
- Android arm64 `.so`: 2.89 MiB → 874 KiB (−70%). APK with all ABIs: −8.32 MiB.
- Estimated per-device download (arm64 split, gzip -9 of the `.so`): 1.47 MiB → 420 KiB, **−1.06 MiB**.
- iOS app executable (arm64 simulator): 4.22 → 1.48 MiB (**−2.74 MiB, −65%**).
- The three fixes added 1,624 B to the C arm64 `.so` (893,368 → 894,992 B).

**Host micro-benchmarks (release, through the C ABI): C is faster except SHA-256.**
- SHA-256: C is 2% slower (parity).
- AES-128-CBC: C is **13% faster**.
- unzip (inflate + CRC + write): C is **16% faster**.
- RSA public operation per checksum: C is **28% faster** (17.4 µs vs 24.1 µs).

**vs run 1 (the cells the fixes targeted):**
- RSA per checksum: C 30.5 → 17.4 µs (Rust 24.2 → 24.1 µs). C was 26% slower and is now 28% faster.
- unzip: C 5530 → 7955 MB/s (Rust 6799 → 6830 MB/s). C was 19% slower and is now 16% faster.
- Android cold start, 20 files background: C 43 → 32 ms (Rust 28 → 37 ms). C was 54% slower and is now 14% faster, within the Rust range.
- On the devices, the RSA change is worth about 7 µs per encrypted file (about 14 ms over 2000 files if all of it is serial), which is inside the run-to-run noise of those cells.

## Method and conditions

- Matrix and harness as in #937 (`scripts/bench`), unchanged.
  - Main suite: 3 runs per cell.
  - Reuse suite: 3 runs per cell.
  - Shaped suite: 3 runs.
  - Cold/warm: n=5 each.
  - Warm-ups are excluded.
- **Gate before timing.** In the worktree, `cd core && cargo test --features test-support` with `CAPGO_CORE_LIB` set to the C test-support dylib: 236 passed, 0 failed (3 ignored: 1 network test, the 2 perf benchmarks).
- **Builds verified before timing.**
  - Android arm64 `libcapgo_updater_core.so`: 3,030,160 B (Rust, same as run 1) vs 894,992 B (C). The Rust `.so` has 47 `rustls|ureq` strings and no `mbedtls`. The C `.so` has `mbedtls` strings and only 3 `rustls|ureq` strings: the `ureq/2.12.1` User-Agent and an error text it reproduces on purpose.
  - iOS `App` executable: 4,423,584 B with 49 `rustls|ureq` strings and no `mbedtls` (Rust) vs 1,552,496 B with `mbedtls` (C, same 3 compatibility strings).
  - Release builds; the iOS xcframework has all slices (no `CAPGO_CORE_IOS_SIMULATOR_ONLY`). Each Android APK carries `10.0.2.2:3193` in its builtin `bench.js`, and the `enc` builds carry the `publicKey`.
- **Interleaving.** For each platform and suite, both labels ran back to back, in ABBA order.
  - iOS: c, rust (plain); rust, c (enc); c, rust (reuse+shaped).
  - Android: rust, c (plain); c, rust (enc); rust, c (reuse+shaped).
  - Cold: rust/c alternated for every sample, with the order swapped on every sample (odd samples Rust first, even samples C first).
  - Warm: C first, then Rust (run 1 ran Rust first).
  - From the iOS reuse chunk on, a script waited up to 2–3 minutes before each chunk for the 1-minute load to fall below 4–4.5.
- **iOS device.** **iPhone 18 Pro (iOS 27.0)** simulator, the same device as run 1 (there is no iPhone 17 Pro simulator on this host). It was booted for this session and shut down afterwards.
- **Android device.** A fresh emulator for every Android cell (main, reuse, shaped, cold and warm): a clean clone of the `capgo_mem_api36` config (API 36, arm64, 4 cores, 2 GB, `-wipe-data -no-snapshot`, emulator-5556). Host alias 10.0.2.2, Wi-Fi off during runs (harness). It was booted, used and shut down by this session, and its temporary AVD was deleted.
  - The shared `capgo_mem_api36` emulator (emulator-5554, up 22 h, 650 MB swapped, other agents' apps resident) was probed first and found degraded: 3 MB zip warm-ups took 206–252 ms, against 45–86 ms in run 1. The fresh emulator gave 57–60 ms.
- **Host load** (1-minute average at chunk start): iOS 3.3–8.1, Android 2.5–6.5, which is higher than run 1 (1.7–4.3).
  - The busiest processes at chunk start were:
    - mediaanalysisd at about 100% during both iOS plain chunks.
    - Another session's `ugrep` at about 230% during both iOS enc chunks.
    - corespotlightd at 155–213% at the start of the iOS Rust reuse chunk and the Android Rust enc chunk.
    - A syspolicyd, trustd and fileproviderd burst (143/127/94%) at the start of the Android C reuse chunk.
  - OrbStack and two other emulators (the shared emulator-5554 and an unrelated AVD) ran for the whole session.
  - Before the device runs, the host had an I/O stall from 13:56 to 14:26 (load average up to 28.9, 6 GB swap in use, fileproviderd and Finder busy). The runs waited for it to end, but the first iOS chunk (C, plain) started while the 5-minute average was still 9.8.
  - No thermal or performance warnings were recorded (`pmset -g therm`).
- **Failures and retries:** 0 failed attempts and 0 harness retries or app restarts in all kept results.
  - Discarded: one probe on emulator-5554 whose first APK build lacked the `10.0.2.2` URL (the app never reached the server; the APKs were rebuilt before any timed run), and the degraded-emulator probe above. Both are in `run2/discarded/`.

## Live-update performance: Rust core vs C core

Median of 3 runs, (min–max) in parentheses. Negative delta = the C core is faster. *background* = JS `download()` call until it resolves (download + verify + decrypt + unzip/assemble). *direct* = `download()` + `set()` until the new bundle has called `notifyAppReady()` (bench HTTP calls excluded). Payloads are random (incompressible) bytes served from a local bun server on the host; manifest files are unique per run so nothing is reused from builtin or the delta cache. Warm-up cases are excluded.

#### Android cold start (first manifest case after a fresh app launch) vs warm

Cold: one fresh install + launch per sample (after the two zip warm-ups, which use one connection each), and only this cell runs. Warm: runs 2+ of one launch that runs both cells alternately (run 1 is dropped because it is cold). Measured on the same fresh emulator as the main suite (emulator-5556). The harness turned Wi-Fi off for each short run and back on afterwards. No sample shows the ~1 s delay of the Wi-Fi path, which hit run 1's first, discarded attempt. Cold samples alternate Rust/C on every sample, with the order swapped each time.

| Cell | Cold Rust | Warm Rust | Cold C | Warm C |
|---|---|---|---|---|
| manifest 20 files / 2 MB, background, plain | **37 ms** (24 ms–45 ms) n=5 | **31 ms** (26 ms–36 ms) n=5 | **32 ms** (27 ms–33 ms) n=5 | **28 ms** (23 ms–34 ms) n=5 |
| manifest 2 files / 20 KB, direct, plain | **25 ms** (23 ms–28 ms) n=5 | **25 ms** (23 ms–31 ms) n=5 | **26 ms** (25 ms–39 ms) n=5 | **27 ms** (23 ms–31 ms) n=5 |

vs run 1 (fresh emulator too, before the descriptor-table fix): the 20-file background cold cell was 28 ms Rust vs 43 ms C (40–57 ms). It is now 37 ms Rust vs 32 ms C (27–33 ms). The fix makes the first engine grow the descriptor table (256 → 512 slots) on a background thread at app start, so the 20 manifest workers no longer wait for that growth in `socket()`. Run 1 found that Rust pays the same growth one case earlier, in its first zip warm-up; this run did not re-measure that.

### iOS simulator (iPhone 18 Pro, iOS 27.0)

#### Background (download ready)

| Payload | Encryption | Rust | C | Δ |
|---|---|---|---|---|
| zip 3 MB | off | **13 ms** (12 ms–14 ms) | **11 ms** (8 ms–11 ms) | -15% |
| zip 3 MB | on | **14 ms** (12 ms–18 ms) | **11 ms** (10 ms–11 ms) | -21% |
| zip 30 MB | off | **27 ms** (26 ms–28 ms) | **22 ms** (20 ms–31 ms) | -19% |
| zip 30 MB | on | **38 ms** (35 ms–38 ms) | **29 ms** (29 ms–30 ms) | -24% |
| zip 300 MB | off | **162 ms** (158 ms–189 ms) | **334 ms** (178 ms–383 ms) | +106% |
| zip 300 MB | on | **337 ms** (269 ms–372 ms) | **221 ms** (207 ms–244 ms) | -34% |
| manifest 2 files / 20 KB | off | **5 ms** (4 ms–6 ms) | **5 ms** (5 ms–6 ms) | 0% |
| manifest 2 files / 20 KB | on | **5 ms** (5 ms–6 ms) | **5 ms** (5 ms–6 ms) | 0% |
| manifest 20 files / 2 MB | off | **11 ms** (10 ms–11 ms) | **12 ms** (9 ms–13 ms) | +9% |
| manifest 20 files / 2 MB | on | **13 ms** (13 ms–14 ms) | **13 ms** (12 ms–14 ms) | 0% |
| manifest 200 files / 20 MB | off | **61 ms** (60 ms–63 ms) | **60 ms** (59 ms–61 ms) | -2% |
| manifest 200 files / 20 MB | on | **95 ms** (93 ms–95 ms) | **94 ms** (90 ms–96 ms) | -1% |
| manifest 2000 files / 200 MB | off | **545 ms** (542 ms–555 ms) | **544 ms** (540 ms–557 ms) | -0% |
| manifest 2000 files / 200 MB | on | **867 ms** (853 ms–878 ms) | **845 ms** (818 ms–852 ms) | -3% |

#### Direct (download + set until app ready)

| Payload | Encryption | Rust | C | Δ |
|---|---|---|---|---|
| zip 3 MB | off | **33 ms** (32 ms–39 ms) | **32 ms** (31 ms–33 ms) | -3% |
| zip 3 MB | on | **32 ms** (32 ms–33 ms) | **32 ms** (31 ms–33 ms) | 0% |
| zip 30 MB | off | **51 ms** (50 ms–51 ms) | **57 ms** (52 ms–63 ms) | +12% |
| zip 30 MB | on | **63 ms** (62 ms–64 ms) | **57 ms** (55 ms–59 ms) | -10% |
| zip 300 MB | off | **200 ms** (186 ms–270 ms) | **210 ms** (182 ms–217 ms) | +5% |
| zip 300 MB | on | **305 ms** (289 ms–313 ms) | **265 ms** (262 ms–299 ms) | -13% |
| manifest 2 files / 20 KB | off | **31 ms** (31 ms–34 ms) | **37 ms** (34 ms–38 ms) | +19% |
| manifest 2 files / 20 KB | on | **32 ms** (31 ms–32 ms) | **31 ms** (30 ms–34 ms) | -3% |
| manifest 20 files / 2 MB | off | **38 ms** (36 ms–39 ms) | **40 ms** (38 ms–41 ms) | +5% |
| manifest 20 files / 2 MB | on | **40 ms** (36 ms–41 ms) | **40 ms** (39 ms–43 ms) | 0% |
| manifest 200 files / 20 MB | off | **89 ms** (86 ms–90 ms) | **86 ms** (85 ms–87 ms) | -3% |
| manifest 200 files / 20 MB | on | **116 ms** (114 ms–119 ms) | **123 ms** (116 ms–123 ms) | +6% |
| manifest 2000 files / 200 MB | off | **575 ms** (570 ms–597 ms) | **564 ms** (562 ms–565 ms) | -2% |
| manifest 2000 files / 200 MB | on | **933 ms** (889 ms–945 ms) | **870 ms** (833 ms–884 ms) | -7% |

<details><summary>Direct mode breakdown (download vs set() → app ready)</summary>

| Payload | Encryption | Download Rust | Download C | Apply Rust | Apply C |
|---|---|---|---|---|---|
| zip 3 MB | off | 10 ms | 7 ms | 24 ms | 24 ms |
| zip 3 MB | on | 9 ms | 8 ms | 23 ms | 24 ms |
| zip 30 MB | off | 26 ms | 27 ms | 24 ms | 26 ms |
| zip 30 MB | on | 38 ms | 33 ms | 25 ms | 24 ms |
| zip 300 MB | off | 175 ms | 186 ms | 25 ms | 24 ms |
| zip 300 MB | on | 280 ms | 241 ms | 25 ms | 24 ms |
| manifest 2 files / 20 KB | off | 7 ms | 11 ms | 24 ms | 27 ms |
| manifest 2 files / 20 KB | on | 7 ms | 7 ms | 24 ms | 24 ms |
| manifest 20 files / 2 MB | off | 13 ms | 15 ms | 25 ms | 25 ms |
| manifest 20 files / 2 MB | on | 15 ms | 15 ms | 24 ms | 25 ms |
| manifest 200 files / 20 MB | off | 65 ms | 62 ms | 23 ms | 24 ms |
| manifest 200 files / 20 MB | on | 93 ms | 98 ms | 24 ms | 25 ms |
| manifest 2000 files / 200 MB | off | 553 ms | 541 ms | 23 ms | 23 ms |
| manifest 2000 files / 200 MB | on | 908 ms | 846 ms | 25 ms | 24 ms |

</details>

#### Direct mode: apply step split (median, Rust / C)

*set()*: from the `set()` call until the new document starts loading (`performance.timeOrigin`). *reload*: new document load until the bench script calls `notifyAppReady()`. *notify*: the `notifyAppReady()` call.

| Payload | Encryption | Apply | set() | Reload | notify |
|---|---|---|---|---|---|
| zip 3 MB | off | 24 ms / 24 ms | 3 ms / 3 ms | 17 ms / 18 ms | 3 ms / 3 ms |
| zip 3 MB | on | 23 ms / 24 ms | 3 ms / 3 ms | 17 ms / 18 ms | 3 ms / 3 ms |
| zip 30 MB | off | 24 ms / 26 ms | 3 ms / 2 ms | 18 ms / 21 ms | 3 ms / 3 ms |
| zip 30 MB | on | 25 ms / 24 ms | 3 ms / 2 ms | 19 ms / 19 ms | 3 ms / 3 ms |
| zip 300 MB | off | 25 ms / 24 ms | 3 ms / 3 ms | 19 ms / 18 ms | 3 ms / 3 ms |
| zip 300 MB | on | 25 ms / 24 ms | 3 ms / 3 ms | 19 ms / 19 ms | 3 ms / 3 ms |
| manifest 2 files / 20 KB | off | 24 ms / 27 ms | 3 ms / 3 ms | 18 ms / 20 ms | 4 ms / 3 ms |
| manifest 2 files / 20 KB | on | 24 ms / 24 ms | 3 ms / 3 ms | 18 ms / 18 ms | 3 ms / 3 ms |
| manifest 20 files / 2 MB | off | 25 ms / 25 ms | 3 ms / 3 ms | 18 ms / 20 ms | 3 ms / 3 ms |
| manifest 20 files / 2 MB | on | 24 ms / 25 ms | 3 ms / 3 ms | 18 ms / 19 ms | 3 ms / 3 ms |
| manifest 200 files / 20 MB | off | 23 ms / 24 ms | 3 ms / 3 ms | 18 ms / 18 ms | 3 ms / 3 ms |
| manifest 200 files / 20 MB | on | 24 ms / 25 ms | 3 ms / 3 ms | 18 ms / 19 ms | 3 ms / 3 ms |
| manifest 2000 files / 200 MB | off | 23 ms / 23 ms | 3 ms / 3 ms | 18 ms / 17 ms | 2 ms / 3 ms |
| manifest 2000 files / 200 MB | on | 25 ms / 24 ms | 3 ms / 3 ms | 19 ms / 19 ms | 3 ms / 3 ms |

#### Manifest reuse (background, 90% of the files already on the device)

*delta cache*: version A with the same files was installed (untimed) right before B; only B is timed. *builtin*: the reused files ship in the app's builtin `public/`. "Fetched" = payload requests the server saw for B (expected: new files + `index.html` + `bench.js`).

| Reuse from | Payload | Encryption | Rust | C | Δ | Fetched Rust / C (expected) |
|---|---|---|---|---|---|---|
| delta cache | 200 files / 20 MB | off | **63 ms** (54 ms–64 ms) | **59 ms** (56 ms–62 ms) | -6% | 22 / 22 (22) |
| delta cache | 200 files / 20 MB | on | **74 ms** (73 ms–75 ms) | **70 ms** (58 ms–72 ms) | -5% | 22 / 22 (22) |
| delta cache | 2000 files / 200 MB | off | **500 ms** (498 ms–501 ms) | **492 ms** (487 ms–498 ms) | -2% | 202 / 202 (202) |
| delta cache | 2000 files / 200 MB | on | **585 ms** (583 ms–586 ms) | **570 ms** (568 ms–571 ms) | -3% | 202 / 202 (202) |
| builtin | 200 files / 20 MB | off | **31 ms** (28 ms–33 ms) | **28 ms** (27 ms–29 ms) | -10% | 22 / 22 (22) |
| builtin | 200 files / 20 MB | on | **36 ms** (36 ms–38 ms) | **35 ms** (35 ms–36 ms) | -3% | 22 / 22 (22) |
| builtin | 2000 files / 200 MB | off | **262 ms** (259 ms–271 ms) | **257 ms** (255 ms–271 ms) | -2% | 202 / 202 (202) |
| builtin | 2000 files / 200 MB | on | **339 ms** (331 ms–340 ms) | **323 ms** (322 ms–337 ms) | -5% | 202 / 202 (202) |

#### Network-shaped (background, plain): 80 ms before every response, 40 Mbit/s total (shared token bucket)

The link alone needs ~4.2 s for 20 MB and ~6.3 s for 30 MB. "Link use" = payload bytes / total time, as a share of the cap.

| Payload | Rust | C | Δ | Link use Rust / C | Peak parallel requests Rust / C |
|---|---|---|---|---|---|
| zip 30 MB | **6.39 s** (6.38 s–6.40 s) | **6.39 s** (6.38 s–6.39 s) | -0% | 98% / 98% | 1 / 1 |
| manifest 200 files / 20 MB | **4.28 s** (4.27 s–4.30 s) | **4.28 s** (4.28 s–4.28 s) | 0% | 98% / 98% | 64 / 64 |
| manifest 2000 files / 20 MB | **4.30 s** (4.30 s–4.30 s) | **4.30 s** (4.30 s–4.30 s) | -0% | 97% / 98% | 64 / 64 |

#### iOS zip confirmation (interleaved re-run)

The C plain chunk above was the first iOS chunk of the session. It started as the host I/O stall ended, and its 300 MB zip background cell came out at +106%. Every zip cell was re-run for both cores right after the Android runs (labels `rust-x`, then `c-x`, plain and encrypted, 3 runs, 1-minute load 3.3 and 3.8). This re-run was decided after seeing that cell. On the simulator the 300 MB cells are noisy for both cores: Rust ranged from 158 to 362 ms here.

| Payload | Encryption | Mode | Rust | C | Δ |
|---|---|---|---|---|---|
| zip 3 MB | off | background | **13 ms** (12 ms–14 ms) | **12 ms** (10 ms–14 ms) | -8% |
| zip 3 MB | on | background | **14 ms** (10 ms–14 ms) | **11 ms** (10 ms–11 ms) | -21% |
| zip 30 MB | off | background | **26 ms** (26 ms–53 ms) | **24 ms** (22 ms–26 ms) | -8% |
| zip 30 MB | on | background | **36 ms** (36 ms–37 ms) | **29 ms** (29 ms–29 ms) | -19% |
| zip 300 MB | off | background | **241 ms** (158 ms–362 ms) | **158 ms** (156 ms–214 ms) | -34% |
| zip 300 MB | on | background | **325 ms** (275 ms–399 ms) | **246 ms** (227 ms–257 ms) | -24% |
| zip 3 MB | off | direct | **36 ms** (33 ms–36 ms) | **32 ms** (31 ms–35 ms) | -11% |
| zip 3 MB | on | direct | **37 ms** (35 ms–40 ms) | **37 ms** (31 ms–38 ms) | 0% |
| zip 30 MB | off | direct | **56 ms** (56 ms–59 ms) | **49 ms** (48 ms–51 ms) | -13% |
| zip 30 MB | on | direct | **64 ms** (63 ms–74 ms) | **57 ms** (57 ms–62 ms) | -11% |
| zip 300 MB | off | direct | **218 ms** (198 ms–220 ms) | **212 ms** (199 ms–239 ms) | -3% |
| zip 300 MB | on | direct | **393 ms** (337 ms–393 ms) | **236 ms** (236 ms–288 ms) | -40% |

### Android emulator (API 36, arm64, fresh `capgo_mem_api36` clone; emulator host alias 10.0.2.2, Wi-Fi off, no adb reverse)

#### Background (download ready)

| Payload | Encryption | Rust | C | Δ |
|---|---|---|---|---|
| zip 3 MB | off | **60 ms** (56 ms–78 ms) | **53 ms** (53 ms–57 ms) | -12% |
| zip 3 MB | on | **62 ms** (62 ms–66 ms) | **63 ms** (62 ms–67 ms) | +2% |
| zip 30 MB | off | **394 ms** (370 ms–410 ms) | **383 ms** (376 ms–399 ms) | -3% |
| zip 30 MB | on | **411 ms** (383 ms–426 ms) | **405 ms** (397 ms–495 ms) | -1% |
| zip 300 MB | off | **3.78 s** (3.73 s–3.85 s) | **3.77 s** (3.73 s–4.38 s) | -0% |
| zip 300 MB | on | **3.82 s** (3.75 s–3.89 s) | **3.76 s** (3.58 s–3.81 s) | -1% |
| manifest 2 files / 20 KB | off | **14 ms** (13 ms–15 ms) | **13 ms** (12 ms–16 ms) | -7% |
| manifest 2 files / 20 KB | on | **15 ms** (13 ms–16 ms) | **14 ms** (13 ms–17 ms) | -7% |
| manifest 20 files / 2 MB | off | **35 ms** (34 ms–35 ms) | **31 ms** (29 ms–49 ms) | -11% |
| manifest 20 files / 2 MB | on | **32 ms** (29 ms–34 ms) | **29 ms** (21 ms–38 ms) | -9% |
| manifest 200 files / 20 MB | off | **155 ms** (153 ms–158 ms) | **100 ms** (100 ms–133 ms) | -35% |
| manifest 200 files / 20 MB | on | **153 ms** (152 ms–164 ms) | **119 ms** (115 ms–138 ms) | -22% |
| manifest 2000 files / 200 MB | off | **1.37 s** (1.35 s–1.41 s) | **1.06 s** (911 ms–1.12 s) | -23% |
| manifest 2000 files / 200 MB | on | **1.43 s** (1.41 s–1.49 s) | **1.14 s** (1.05 s–1.24 s) | -21% |

#### Direct (download + set until app ready)

| Payload | Encryption | Rust | C | Δ |
|---|---|---|---|---|
| zip 3 MB | off | **70 ms** (64 ms–73 ms) | **65 ms** (64 ms–69 ms) | -7% |
| zip 3 MB | on | **75 ms** (68 ms–79 ms) | **67 ms** (64 ms–95 ms) | -11% |
| zip 30 MB | off | **409 ms** (388 ms–426 ms) | **393 ms** (380 ms–407 ms) | -4% |
| zip 30 MB | on | **443 ms** (381 ms–461 ms) | **414 ms** (410 ms–428 ms) | -7% |
| zip 300 MB | off | **3.92 s** (3.82 s–4.15 s) | **3.75 s** (3.72 s–3.76 s) | -4% |
| zip 300 MB | on | **3.97 s** (3.85 s–4.01 s) | **3.87 s** (3.64 s–3.89 s) | -3% |
| manifest 2 files / 20 KB | off | **28 ms** (28 ms–39 ms) | **27 ms** (24 ms–28 ms) | -4% |
| manifest 2 files / 20 KB | on | **32 ms** (32 ms–34 ms) | **33 ms** (30 ms–34 ms) | +3% |
| manifest 20 files / 2 MB | off | **54 ms** (50 ms–54 ms) | **45 ms** (42 ms–56 ms) | -17% |
| manifest 20 files / 2 MB | on | **48 ms** (46 ms–53 ms) | **49 ms** (48 ms–65 ms) | +2% |
| manifest 200 files / 20 MB | off | **169 ms** (157 ms–171 ms) | **119 ms** (117 ms–123 ms) | -30% |
| manifest 200 files / 20 MB | on | **170 ms** (164 ms–171 ms) | **124 ms** (121 ms–125 ms) | -27% |
| manifest 2000 files / 200 MB | off | **1.40 s** (1.38 s–1.40 s) | **974 ms** (927 ms–981 ms) | -30% |
| manifest 2000 files / 200 MB | on | **1.46 s** (1.46 s–1.48 s) | **1.04 s** (1.02 s–1.13 s) | -29% |

<details><summary>Direct mode breakdown (download vs set() → app ready)</summary>

| Payload | Encryption | Download Rust | Download C | Apply Rust | Apply C |
|---|---|---|---|---|---|
| zip 3 MB | off | 57 ms | 53 ms | 13 ms | 13 ms |
| zip 3 MB | on | 62 ms | 55 ms | 13 ms | 13 ms |
| zip 30 MB | off | 396 ms | 380 ms | 14 ms | 13 ms |
| zip 30 MB | on | 418 ms | 403 ms | 14 ms | 13 ms |
| zip 300 MB | off | 3.90 s | 3.73 s | 22 ms | 19 ms |
| zip 300 MB | on | 3.95 s | 3.85 s | 16 ms | 16 ms |
| manifest 2 files / 20 KB | off | 12 ms | 12 ms | 16 ms | 15 ms |
| manifest 2 files / 20 KB | on | 15 ms | 15 ms | 17 ms | 16 ms |
| manifest 20 files / 2 MB | off | 34 ms | 28 ms | 20 ms | 16 ms |
| manifest 20 files / 2 MB | on | 32 ms | 32 ms | 18 ms | 21 ms |
| manifest 200 files / 20 MB | off | 155 ms | 106 ms | 14 ms | 14 ms |
| manifest 200 files / 20 MB | on | 156 ms | 111 ms | 14 ms | 13 ms |
| manifest 2000 files / 200 MB | off | 1.38 s | 961 ms | 18 ms | 13 ms |
| manifest 2000 files / 200 MB | on | 1.45 s | 1.02 s | 13 ms | 17 ms |

</details>

#### Direct mode: apply step split (median, Rust / C)

*set()*: from the `set()` call until the new document starts loading (`performance.timeOrigin`). *reload*: new document load until the bench script calls `notifyAppReady()`. *notify*: the `notifyAppReady()` call.

| Payload | Encryption | Apply | set() | Reload | notify |
|---|---|---|---|---|---|
| zip 3 MB | off | 13 ms / 13 ms | 3 ms / 3 ms | 6 ms / 6 ms | 4 ms / 4 ms |
| zip 3 MB | on | 13 ms / 13 ms | 3 ms / 3 ms | 6 ms / 6 ms | 4 ms / 4 ms |
| zip 30 MB | off | 14 ms / 13 ms | 3 ms / 3 ms | 6 ms / 7 ms | 5 ms / 3 ms |
| zip 30 MB | on | 14 ms / 13 ms | 3 ms / 3 ms | 7 ms / 6 ms | 5 ms / 4 ms |
| zip 300 MB | off | 22 ms / 19 ms | 6 ms / 4 ms | 10 ms / 6 ms | 6 ms / 5 ms |
| zip 300 MB | on | 16 ms / 16 ms | 5 ms / 4 ms | 7 ms / 8 ms | 5 ms / 5 ms |
| manifest 2 files / 20 KB | off | 16 ms / 15 ms | 3 ms / 3 ms | 8 ms / 7 ms | 6 ms / 4 ms |
| manifest 2 files / 20 KB | on | 17 ms / 16 ms | 4 ms / 4 ms | 7 ms / 8 ms | 6 ms / 4 ms |
| manifest 20 files / 2 MB | off | 20 ms / 16 ms | 4 ms / 4 ms | 7 ms / 7 ms | 5 ms / 4 ms |
| manifest 20 files / 2 MB | on | 18 ms / 21 ms | 4 ms / 4 ms | 8 ms / 9 ms | 5 ms / 6 ms |
| manifest 200 files / 20 MB | off | 14 ms / 14 ms | 3 ms / 3 ms | 6 ms / 7 ms | 5 ms / 4 ms |
| manifest 200 files / 20 MB | on | 14 ms / 13 ms | 3 ms / 3 ms | 6 ms / 6 ms | 4 ms / 4 ms |
| manifest 2000 files / 200 MB | off | 18 ms / 13 ms | 3 ms / 3 ms | 7 ms / 6 ms | 6 ms / 4 ms |
| manifest 2000 files / 200 MB | on | 13 ms / 17 ms | 3 ms / 4 ms | 6 ms / 6 ms | 4 ms / 6 ms |

#### Manifest reuse (background, 90% of the files already on the device)

*delta cache*: version A with the same files was installed (untimed) right before B; only B is timed. *builtin*: the reused files ship in the app's builtin `public/`. "Fetched" = payload requests the server saw for B (expected: new files + `index.html` + `bench.js`).

| Reuse from | Payload | Encryption | Rust | C | Δ | Fetched Rust / C (expected) |
|---|---|---|---|---|---|---|
| delta cache | 200 files / 20 MB | off | **51 ms** (44 ms–53 ms) | **44 ms** (29 ms–48 ms) | -14% | 22 / 22 (22) |
| delta cache | 200 files / 20 MB | on | **57 ms** (49 ms–57 ms) | **55 ms** (42 ms–58 ms) | -4% | 22 / 22 (22) |
| delta cache | 2000 files / 200 MB | off | **338 ms** (280 ms–376 ms) | **326 ms** (238 ms–348 ms) | -4% | 202 / 202 (202) |
| delta cache | 2000 files / 200 MB | on | **423 ms** (389 ms–429 ms) | **443 ms** (438 ms–449 ms) | +5% | 202 / 202 (202) |
| builtin | 200 files / 20 MB | off | **55 ms** (37 ms–65 ms) | **58 ms** (41 ms–59 ms) | +5% | 22 / 22 (22) |
| builtin | 200 files / 20 MB | on | **63 ms** (48 ms–72 ms) | **46 ms** (41 ms–64 ms) | -27% | 22 / 22 (22) |
| builtin | 2000 files / 200 MB | off | **409 ms** (283 ms–416 ms) | **331 ms** (262 ms–367 ms) | -19% | 202 / 202 (202) |
| builtin | 2000 files / 200 MB | on | **487 ms** (447 ms–582 ms) | **279 ms** (275 ms–327 ms) | -43% | 202 / 202 (202) |

#### Network-shaped (background, plain): 80 ms before every response, 40 Mbit/s total (shared token bucket)

The link alone needs ~4.2 s for 20 MB and ~6.3 s for 30 MB. "Link use" = payload bytes / total time, as a share of the cap.

| Payload | Rust | C | Δ | Link use Rust / C | Peak parallel requests Rust / C |
|---|---|---|---|---|---|
| zip 30 MB | **6.41 s** (6.40 s–6.41 s) | **6.39 s** (6.39 s–6.39 s) | -0% | 98% / 98% | 1 / 1 |
| manifest 200 files / 20 MB | **4.28 s** (4.28 s–4.29 s) | **4.28 s** (4.28 s–4.28 s) | -0% | 98% / 98% | 32 / 32 |
| manifest 2000 files / 20 MB | **5.27 s** (5.25 s–5.28 s) | **5.23 s** (5.21 s–5.24 s) | -1% | 80% / 80% | 32 / 32 |

### App size (release bench builds, plain variant)

The bench app's web assets (`public/`, including the 180 MB builtin pad used by the reuse cases) are listed separately; the rows without web assets show the native footprint.

#### Android (signed release APK, all ABIs)

| | Rust | C | Δ |
|---|---|---|---|
| APK total | 195.71 MiB | 187.38 MiB | -8.32 MiB |
| APK without web assets | 15.64 MiB | 7.32 MiB | -8.32 MiB |
| classes*.dex (uncompressed) | 8.52 MiB | 8.52 MiB | +0.0 KiB |
| lib/arm64-v8a/libcapgo_updater_core.so (in APK) | 2.89 MiB (2.89 MiB) | 874.0 KiB (874.0 KiB) | -2.04 MiB |
| lib/armeabi-v7a/libcapgo_updater_core.so (in APK) | 1.93 MiB (1.93 MiB) | 639.0 KiB (639.0 KiB) | -1.30 MiB |
| lib/x86/libcapgo_updater_core.so (in APK) | 3.41 MiB (3.41 MiB) | 898.6 KiB (898.6 KiB) | -2.53 MiB |
| lib/x86_64/libcapgo_updater_core.so (in APK) | 3.31 MiB (3.31 MiB) | 883.7 KiB (883.7 KiB) | -2.45 MiB |

Estimated per-device download change (arm64 split): gzip -9 of the arm64 `.so` (418.9 KiB) + dex difference (0.0 KiB) = **-1.06 MiB**.

#### iOS (Release simulator .app)

| | Rust | C | Δ |
|---|---|---|---|
| .app total | 189.04 MiB | 186.30 MiB | -2.74 MiB |
| .app without web assets | 9.03 MiB | 6.30 MiB | -2.74 MiB |
| App executable (arm64) | 4.22 MiB | 1.48 MiB | -2.74 MiB |
| App executable, arm64 slice | 4.22 MiB | 1.48 MiB | -2.74 MiB |
| Frameworks/Capacitor.framework | 4.05 MiB | 4.05 MiB | +0.0 KiB |
| Frameworks/CapgoUpdaterCore.framework | 34.9 KiB | 34.9 KiB | +0.0 KiB |
| Frameworks/Cordova.framework | 240.2 KiB | 240.2 KiB | +0.0 KiB |


Changes against run 1: with the three fixes, the C `.so` grew by 1,624 B on arm64-v8a (893,368 → 894,992 B), 964 B on armeabi-v7a, 3,204 B on x86 and 2,600 B on x86_64, and the C iOS executable by 336 B. The Rust `.so` files are byte-for-byte the same size. The Rust iOS executable is 272 B larger than in run 1, although its source is unchanged.

### Host micro-benchmarks (release, through the C ABI)

`cd core && cargo test --release --features test-support --test perf -- --ignored --nocapture --exact <test>`, run from the built test binary. Rust = the crate itself. C = `CAPGO_CORE_LIB=core-c/build-perf/libcapgo_updater_core.dylib` (CMake Release, `-DCAPGO_TEST_SUPPORT=ON`). Both run through the same C ABI. Runs alternate rust/c, and the order is swapped on every run. This ran after the device runs, with the simulator and the bench emulator shut down. The other two emulators were still running.

`hot_path_throughput`: 10 runs per core (100 MiB each). Runs 1–5 started at load 3.1 and runs 6–10 at load 5.5.

| Operation (100 MiB) | Rust median (min–max) | C median (min–max) | C vs Rust | Run 1: Rust / C |
|---|---|---|---|---|
| sha256 | **2853 MB/s** (2332–2873) | **2788 MB/s** (398–2821) | -2% | 2903 / 2839 |
| aes-128-cbc decrypt | **1659 MB/s** (1382–1669) | **1880 MB/s** (1592–1902) | +13% | 1646 / 1900 |
| unzip (inflate + CRC + write) | **6830 MB/s** (6451–6962) | **7955 MB/s** (7372–8235) | +16% | 6799 / 5530 |

The C SHA-256 minimum (398 MB/s) is the first C run of the session, as in run 1 (442 MB/s). Without it, the C range is 1652–2821 MB/s.

`rsa_checksum_throughput` (RSA-2048 public operation per encrypted checksum, `decryptChecksum` with the `crypto-rsa.json` fixture, including the ABI and JSON envelope: 200 warm-up calls, then 5 loops of 5000): 4 runs × 5 loops per core (n=20), load 5.2–5.5.

| Core | µs per checksum, median (min–max) | Run 1 |
|---|---|---|
| Rust (hand-written modexp) | **24.1 µs** (24.0–25.6) | 24.2 µs |
| C (CIOS Montgomery, precomputed per key) | **17.4 µs** (17.3–18.0) | 30.5 µs (Mbed TLS bignum) |

C is now 1.39× faster per checksum. In run 1 it was 1.26× slower. The envelope alone (measured in run 1 with `rsaUnpadType1`) is about 1.7–1.8 µs for both cores.

What changed in C since run 1:
- **RSA:** the Mbed TLS bignum exponentiation was replaced by a fused CIOS Montgomery multiplication: 64-bit limbs with a 128-bit product, or 32-bit limbs on armeabi-v7a and x86. It is precomputed per parsed key and does not allocate.
- **unzip:** large buffers run three interleaved `crc32d` chains, joined with the zlib `multmodp` shift, instead of one latency-bound chain. Inflate and write are unchanged.
- **Android cold start:** see the cold/warm table.

### Caveats

- **iPhone 18 Pro, not iPhone 17 Pro.** No 17 Pro simulator exists on this host. The absolute iOS numbers are not directly comparable to #937. The Rust-vs-C comparison is.
- **The host was busier than in run 1** (load 2.5–8.1 against 1.7–4.3), with Spotlight, media analysis, another session's `ugrep` and a FileProvider burst at different times (see Method). Both labels of a pair ran back to back under similar load, but single cells can still be hit.
  - The iOS C plain chunk (first iOS chunk, right after the I/O stall) holds 6 of the 7 slower iOS cells.
  - The zip cells were re-run (see the confirmation table). The manifest cells (2 files plain direct +19%, 20 files plain +5% and +9%) were not.
- **Android ran on a fresh emulator, not the shared one.** The shared emulator-5554 was degraded (warm-ups about 3–4× slower than in run 1), the same pattern as in run 1. Run 1's main suite ran on the shared emulator, while its cold/warm and confirmation tables ran on a fresh one. Here every Android cell is on one fresh clone, so absolute Android numbers can differ a little from run 1's main tables.
  - The probes touched emulator-5554: the bench APK was installed, and the harness turned Wi-Fi off and on again. Its Wi-Fi was on before and is on after.
- **Android reuse cells have wide ranges for both cores** (for example builtin 2000 files encrypted: Rust 447–582 ms, C 275–327 ms; in run 1 this cell was 0%). Read reuse deltas above about ±15% as noise unless the ranges are well apart.
- **The 300 MB zip cells on the iOS simulator are disk-bound and noisy for both cores** (Rust 158–362 ms and C 156–383 ms across the two passes).
- **The host micro-benchmarks run on macOS arm64**, with the system zlib for C and zlib-rs for Rust. On Android and iOS the C core also uses the platform zlib. The CRC-32 change uses the ARMv8 CRC instructions, which arm64 Android and iOS devices also have.
- **Wall-clock time:** about 3 h 30 min (13:18–16:50), including the gate, the builds (the Android APKs were built twice), the 30-minute host stall, the emulator probe and boot, and the iOS zip re-run. Every command stayed under 10 minutes; the longest chunk took 283 s.
