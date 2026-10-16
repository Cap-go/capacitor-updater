# Rust core vs C core: live-update performance (same session)

Branch `riderx/capgo-c-core` @ 0d56b1c8 (PR #962, stacked on #937), built once in a clean worktree (`/tmp/capgo-bench-wt`). Label `rust` = `CAPGO_CORE_IMPL=rust`, label `c` = `CAPGO_CORE_IMPL=c`. Everything else (Java/Swift glue, bench app, fixtures, server) is identical. Measured 2026-10-15 18:22–20:27 WEST on an Apple M5 Pro (Mac17,9, 18 cores, 64 GB), Xcode 27.1.

## Summary

**iOS simulator: parity.** Of the 39 timed cells, C is faster in 25, equal in 6 and slower in 8. Every slower cell is at most +3%: ≤ 2 ms, except the 300 MB encrypted zip (+7 ms) and the 2000-file encrypted delta-cache cell (+8 ms). Every slower cell's range overlaps Rust's. The clearest C wins are on zips: 3 MB background −15% plain and −33% encrypted (13→11 ms, 18→12 ms), 30 MB background −15% and −14%, and 300 MB plain −13% background and −33% direct. The Rust 300 MB plain direct median is inflated by one run (423 ms) taken while Finder and syspolicyd were busy at the start of the session. Large manifests are within −5% to +2%. Reuse is within −9% to +3%, and shaped runs are identical (link-bound).

**Android emulator: C wins on manifests, parity elsewhere, but slower on cold start.** Of the 39 timed cells, C is faster in 30, equal in 5 and slower in 4.
- Manifest 200 and 2000 files: C is **24–35% faster** in both modes. Background 2000 files plain: 1.46 s → 997 ms (0.68×); with encryption: 1.47 s → 1.12 s (0.76×). Direct 200 files plain: 169 → 110 ms (0.65×). A confirmation run on a second, fresh emulator gave −21% to −32% (table below).
- Zips: within −11% to +10%, and the ranges overlap.
- Small manifests: within noise. 2 files encrypted background is 16 → 20 ms (+25%), but the ranges overlap (14–17 vs 13–24 ms).
- Reuse: equal, except the builtin 2000 files plain cell (−10%) and the delta-cache 200 files plain cell (−16%).
- Shaped runs: equal (−0% to −1%).
- **Cold start is a C loss**: manifest 20 files background cold is 28 ms for Rust and 43 ms for C (+54%, ranges 27–34 vs 40–57 ms, no overlap). Warm is the same cell at 33 vs 28 ms. The cold 2-file direct cell is equal (27 vs 27 ms).

**App size: C is much smaller.**
- Android arm64 `.so`: 2.89 MiB → 872 KiB (−70%). APK with all ABIs: −8.34 MiB.
- Estimated per-device download (arm64 split, gzip -9 of the `.so`): 1.47 MiB → 418 KiB, **−1.06 MiB**.
- iOS app executable (arm64 simulator): 4.22 → 1.48 MiB (**−2.74 MiB, −65%**).

**Host micro-benchmarks (release, through the C ABI): mixed.** Median of 5 alternating runs. C vs Rust:
- SHA-256: C is 2% slower (parity).
- AES-128-CBC: C is **15% faster**.
- unzip (inflate + CRC + write): C is **19% slower** (platform zlib vs zlib-rs).
- RSA public operation per checksum: C is **about 25% slower** (30.5 µs vs 24.2 µs).

Both slower cells were fixed afterwards (see "After the RSA and CRC-32 changes" below):
unzip is now **17% faster** than Rust and the RSA checksum **29% faster**.

## Method and conditions

- Matrix and harness as in #937 (`scripts/bench`), unchanged.
  - Main suite: 3 runs per cell.
  - Reuse suite: 3 runs per cell (#937 used n=1 for after).
  - Shaped suite: 3 runs.
  - Cold/warm: n=5 each.
  - Warm-ups are excluded.
- **Builds verified before timing.**
  - Android arm64 `libcapgo_updater_core.so`: 3,030,160 B (Rust) vs 893,368 B (C).
  - iOS `App` executable: 4,423,312 B with 50 `rustls|ureq` strings and no `mbedtls` (Rust) vs 1,552,160 B with `mbedtls` (C).
  - Release builds; the iOS xcframework has all slices (no `CAPGO_CORE_IOS_SIMULATOR_ONLY`).
- **Interleaving.** For each platform, suite and variant, both labels ran back to back, and the order alternated between chunks. iOS: rust r1, c, rust r2–3 (plain); c, rust (enc); rust, c (reuse+shaped). Android: rust r1, c, rust r2–3 (plain); rust, c (enc); c, rust (reuse+shaped). Cold samples alternated rust/c for every sample; warm ran rust, then c.
- **iOS device.** There is no iPhone 17 Pro simulator on this host. All iOS runs used **iPhone 18 Pro (iOS 27.0)**, which was already booted and was not shut down.
- **Android device.**
  - Main, reuse and shaped suites: the shared `capgo_mem_api36` emulator (emulator-5554, API 36, arm64, 4 cores, 2 GB). Host alias 10.0.2.2, Wi-Fi off during runs (harness).
  - Cold/warm: a fresh emulator, see the caveats.
- **Host load** (1-minute average before each chunk): 1.7–4.3 on 18 cores during the device runs. The very first chunk (iOS rust plain r1) started at 3.8, with a short Finder/syspolicyd/fileproviderd burst. No thermal or performance warnings were recorded (`pmset -g therm`).
- **Failures and retries:** 0 failed attempts and 0 harness retries in all kept results.

## Live-update performance: Rust core (before) vs C core (after)

Median of 3 runs, (min–max) in parentheses. Negative delta = the C core is faster. *background* = JS `download()` call until it resolves (download + verify + decrypt + unzip/assemble). *direct* = `download()` + `set()` until the new bundle has called `notifyAppReady()` (bench HTTP calls excluded). Payloads are random (incompressible) bytes served from a local bun server on the host; manifest files are unique per run so nothing is reused from builtin or the delta cache. Warm-up cases are excluded.

#### Android cold start (first manifest case after a fresh app launch) vs warm

Cold: one fresh install + launch per sample (after the two zip warm-ups, which use one connection each), and only this cell runs. Warm: runs 2+ of one launch that runs both cells alternately (run 1 is dropped because it is cold). Measured on a fresh emulator built from the `capgo_mem_api36` config (emulator-5556) with Wi-Fi held off (see caveats).

| Cell | Cold Rust | Warm Rust | Cold C | Warm C |
|---|---|---|---|---|
| manifest 20 files / 2 MB, background, plain | **28 ms** (27 ms–34 ms) n=5 | **33 ms** (25 ms–35 ms) n=5 | **43 ms** (40 ms–57 ms) n=5 | **28 ms** (25 ms–40 ms) n=5 |
| manifest 2 files / 20 KB, direct, plain | **27 ms** (24 ms–49 ms) n=5 | **26 ms** (23 ms–34 ms) n=5 | **27 ms** (22 ms–43 ms) n=5 | **28 ms** (25 ms–35 ms) n=5 |

### iOS simulator (iPhone 18 Pro, iOS 27.0)

#### Background (download ready)

| Payload | Encryption | Rust | C | Δ |
|---|---|---|---|---|
| zip 3 MB | off | **13 ms** (10 ms–15 ms) | **11 ms** (9 ms–12 ms) | -15% |
| zip 3 MB | on | **18 ms** (14 ms–20 ms) | **12 ms** (11 ms–13 ms) | -33% |
| zip 30 MB | off | **26 ms** (26 ms–29 ms) | **22 ms** (21 ms–22 ms) | -15% |
| zip 30 MB | on | **35 ms** (34 ms–37 ms) | **30 ms** (28 ms–36 ms) | -14% |
| zip 300 MB | off | **186 ms** (180 ms–288 ms) | **161 ms** (147 ms–202 ms) | -13% |
| zip 300 MB | on | **251 ms** (249 ms–381 ms) | **258 ms** (235 ms–459 ms) | +3% |
| manifest 2 files / 20 KB | off | **6 ms** (4 ms–6 ms) | **4 ms** (4 ms–5 ms) | -33% |
| manifest 2 files / 20 KB | on | **6 ms** (5 ms–6 ms) | **5 ms** (5 ms–7 ms) | -17% |
| manifest 20 files / 2 MB | off | **11 ms** (11 ms–11 ms) | **11 ms** (11 ms–11 ms) | 0% |
| manifest 20 files / 2 MB | on | **14 ms** (13 ms–14 ms) | **13 ms** (13 ms–14 ms) | -7% |
| manifest 200 files / 20 MB | off | **62 ms** (60 ms–65 ms) | **59 ms** (59 ms–62 ms) | -5% |
| manifest 200 files / 20 MB | on | **91 ms** (87 ms–92 ms) | **92 ms** (92 ms–93 ms) | +1% |
| manifest 2000 files / 200 MB | off | **551 ms** (548 ms–556 ms) | **541 ms** (532 ms–562 ms) | -2% |
| manifest 2000 files / 200 MB | on | **877 ms** (857 ms–878 ms) | **877 ms** (849 ms–890 ms) | 0% |

#### Direct (download + set until app ready)

| Payload | Encryption | Rust | C | Δ |
|---|---|---|---|---|
| zip 3 MB | off | **32 ms** (31 ms–36 ms) | **31 ms** (29 ms–32 ms) | -3% |
| zip 3 MB | on | **33 ms** (32 ms–39 ms) | **31 ms** (30 ms–33 ms) | -6% |
| zip 30 MB | off | **52 ms** (48 ms–55 ms) | **50 ms** (50 ms–52 ms) | -4% |
| zip 30 MB | on | **62 ms** (60 ms–62 ms) | **58 ms** (57 ms–61 ms) | -6% |
| zip 300 MB | off | **278 ms** (214 ms–423 ms) | **185 ms** (180 ms–235 ms) | -33% |
| zip 300 MB | on | **282 ms** (273 ms–330 ms) | **267 ms** (253 ms–287 ms) | -5% |
| manifest 2 files / 20 KB | off | **34 ms** (32 ms–34 ms) | **33 ms** (31 ms–35 ms) | -3% |
| manifest 2 files / 20 KB | on | **34 ms** (32 ms–37 ms) | **35 ms** (32 ms–35 ms) | +3% |
| manifest 20 files / 2 MB | off | **38 ms** (31 ms–39 ms) | **39 ms** (38 ms–39 ms) | +3% |
| manifest 20 files / 2 MB | on | **40 ms** (35 ms–41 ms) | **41 ms** (36 ms–42 ms) | +3% |
| manifest 200 files / 20 MB | off | **86 ms** (85 ms–88 ms) | **86 ms** (85 ms–87 ms) | 0% |
| manifest 200 files / 20 MB | on | **118 ms** (117 ms–119 ms) | **120 ms** (112 ms–123 ms) | +2% |
| manifest 2000 files / 200 MB | off | **579 ms** (575 ms–590 ms) | **570 ms** (568 ms–570 ms) | -2% |
| manifest 2000 files / 200 MB | on | **899 ms** (893 ms–926 ms) | **895 ms** (882 ms–896 ms) | -0% |

<details><summary>Direct mode breakdown (download vs set() → app ready)</summary>

| Payload | Encryption | Download Rust | Download C | Apply Rust | Apply C |
|---|---|---|---|---|---|
| zip 3 MB | off | 8 ms | 7 ms | 24 ms | 23 ms |
| zip 3 MB | on | 10 ms | 7 ms | 23 ms | 23 ms |
| zip 30 MB | off | 27 ms | 25 ms | 25 ms | 26 ms |
| zip 30 MB | on | 37 ms | 32 ms | 25 ms | 25 ms |
| zip 300 MB | off | 255 ms | 160 ms | 24 ms | 25 ms |
| zip 300 MB | on | 254 ms | 244 ms | 25 ms | 23 ms |
| manifest 2 files / 20 KB | off | 7 ms | 7 ms | 27 ms | 26 ms |
| manifest 2 files / 20 KB | on | 8 ms | 7 ms | 27 ms | 28 ms |
| manifest 20 files / 2 MB | off | 13 ms | 13 ms | 24 ms | 26 ms |
| manifest 20 files / 2 MB | on | 15 ms | 16 ms | 24 ms | 24 ms |
| manifest 200 files / 20 MB | off | 64 ms | 62 ms | 23 ms | 24 ms |
| manifest 200 files / 20 MB | on | 95 ms | 97 ms | 23 ms | 23 ms |
| manifest 2000 files / 200 MB | off | 557 ms | 546 ms | 24 ms | 23 ms |
| manifest 2000 files / 200 MB | on | 871 ms | 872 ms | 24 ms | 23 ms |

</details>

#### Direct mode: apply step split (median, Rust / C)

*set()*: from the `set()` call until the new document starts loading (`performance.timeOrigin`). *reload*: new document load until the bench script calls `notifyAppReady()`. *notify*: the `notifyAppReady()` call.

| Payload | Encryption | Apply | set() | Reload | notify |
|---|---|---|---|---|---|
| zip 3 MB | off | 24 ms / 23 ms | 3 ms / 3 ms | 18 ms / 18 ms | 3 ms / 3 ms |
| zip 3 MB | on | 23 ms / 23 ms | 3 ms / 3 ms | 17 ms / 17 ms | 3 ms / 3 ms |
| zip 30 MB | off | 25 ms / 26 ms | 3 ms / 3 ms | 19 ms / 20 ms | 3 ms / 3 ms |
| zip 30 MB | on | 25 ms / 25 ms | 3 ms / 3 ms | 19 ms / 19 ms | 3 ms / 3 ms |
| zip 300 MB | off | 24 ms / 25 ms | 3 ms / 3 ms | 18 ms / 19 ms | 3 ms / 3 ms |
| zip 300 MB | on | 25 ms / 23 ms | 3 ms / 2 ms | 19 ms / 18 ms | 3 ms / 3 ms |
| manifest 2 files / 20 KB | off | 27 ms / 26 ms | 3 ms / 3 ms | 20 ms / 20 ms | 3 ms / 3 ms |
| manifest 2 files / 20 KB | on | 27 ms / 28 ms | 3 ms / 3 ms | 20 ms / 21 ms | 4 ms / 4 ms |
| manifest 20 files / 2 MB | off | 24 ms / 26 ms | 3 ms / 3 ms | 18 ms / 20 ms | 3 ms / 3 ms |
| manifest 20 files / 2 MB | on | 24 ms / 24 ms | 2 ms / 2 ms | 18 ms / 19 ms | 3 ms / 3 ms |
| manifest 200 files / 20 MB | off | 23 ms / 24 ms | 2 ms / 3 ms | 18 ms / 18 ms | 3 ms / 3 ms |
| manifest 200 files / 20 MB | on | 23 ms / 23 ms | 3 ms / 3 ms | 18 ms / 17 ms | 3 ms / 3 ms |
| manifest 2000 files / 200 MB | off | 24 ms / 23 ms | 2 ms / 3 ms | 18 ms / 18 ms | 3 ms / 2 ms |
| manifest 2000 files / 200 MB | on | 24 ms / 23 ms | 3 ms / 3 ms | 18 ms / 17 ms | 3 ms / 3 ms |

#### Manifest reuse (background, 90% of the files already on the device)

*delta cache*: version A with the same files was installed (untimed) right before B; only B is timed. *builtin*: the reused files ship in the app's builtin `public/`. "Fetched" = payload requests the server saw for B (expected: new files + `index.html` + `bench.js`).

| Reuse from | Payload | Encryption | Rust | C | Δ | Fetched Rust / C (expected) |
|---|---|---|---|---|---|---|
| delta cache | 200 files / 20 MB | off | **65 ms** (54 ms–66 ms) | **59 ms** (54 ms–61 ms) | -9% | 22 / 22 (22) |
| delta cache | 200 files / 20 MB | on | **74 ms** (73 ms–76 ms) | **76 ms** (74 ms–77 ms) | +3% | 22 / 22 (22) |
| delta cache | 2000 files / 200 MB | off | **516 ms** (512 ms–518 ms) | **501 ms** (492 ms–508 ms) | -3% | 202 / 202 (202) |
| delta cache | 2000 files / 200 MB | on | **584 ms** (569 ms–584 ms) | **592 ms** (579 ms–599 ms) | +1% | 202 / 202 (202) |
| builtin | 200 files / 20 MB | off | **28 ms** (27 ms–29 ms) | **28 ms** (28 ms–30 ms) | 0% | 22 / 22 (22) |
| builtin | 200 files / 20 MB | on | **38 ms** (38 ms–39 ms) | **38 ms** (38 ms–39 ms) | 0% | 22 / 22 (22) |
| builtin | 2000 files / 200 MB | off | **269 ms** (266 ms–287 ms) | **262 ms** (262 ms–265 ms) | -3% | 202 / 202 (202) |
| builtin | 2000 files / 200 MB | on | **362 ms** (344 ms–481 ms) | **354 ms** (346 ms–364 ms) | -2% | 202 / 202 (202) |

#### Network-shaped (background, plain): 80 ms before every response, 40 Mbit/s total (shared token bucket)

The link alone needs ~4.2 s for 20 MB and ~6.3 s for 30 MB. "Link use" = payload bytes / total time, as a share of the cap.

| Payload | Rust | C | Δ | Link use Rust / C | Peak parallel requests Rust / C |
|---|---|---|---|---|---|
| zip 30 MB | **6.39 s** (6.39 s–6.40 s) | **6.38 s** (6.38 s–6.39 s) | -0% | 98% / 99% | 1 / 1 |
| manifest 200 files / 20 MB | **4.28 s** (4.27 s–4.28 s) | **4.28 s** (4.28 s–4.28 s) | 0% | 98% / 98% | 64 / 64 |
| manifest 2000 files / 20 MB | **4.30 s** (4.30 s–4.30 s) | **4.30 s** (4.30 s–4.30 s) | -0% | 97% / 98% | 64 / 64 |

### Android emulator (API 36, arm64; emulator host alias 10.0.2.2, Wi-Fi off, no adb reverse)

#### Background (download ready)

| Payload | Encryption | Rust | C | Δ |
|---|---|---|---|---|
| zip 3 MB | off | **56 ms** (56 ms–59 ms) | **57 ms** (52 ms–60 ms) | +2% |
| zip 3 MB | on | **59 ms** (55 ms–60 ms) | **65 ms** (52 ms–73 ms) | +10% |
| zip 30 MB | off | **395 ms** (382 ms–397 ms) | **385 ms** (348 ms–389 ms) | -3% |
| zip 30 MB | on | **418 ms** (393 ms–420 ms) | **380 ms** (353 ms–402 ms) | -9% |
| zip 300 MB | off | **3.70 s** (3.57 s–3.81 s) | **3.68 s** (3.65 s–3.79 s) | -1% |
| zip 300 MB | on | **3.81 s** (3.69 s–3.95 s) | **3.79 s** (3.70 s–3.79 s) | -1% |
| manifest 2 files / 20 KB | off | **15 ms** (13 ms–15 ms) | **15 ms** (12 ms–16 ms) | 0% |
| manifest 2 files / 20 KB | on | **16 ms** (14 ms–17 ms) | **20 ms** (13 ms–24 ms) | +25% |
| manifest 20 files / 2 MB | off | **34 ms** (34 ms–37 ms) | **34 ms** (25 ms–34 ms) | 0% |
| manifest 20 files / 2 MB | on | **34 ms** (31 ms–34 ms) | **31 ms** (27 ms–42 ms) | -9% |
| manifest 200 files / 20 MB | off | **152 ms** (151 ms–157 ms) | **107 ms** (98 ms–140 ms) | -30% |
| manifest 200 files / 20 MB | on | **156 ms** (151 ms–158 ms) | **108 ms** (104 ms–133 ms) | -31% |
| manifest 2000 files / 200 MB | off | **1.46 s** (1.40 s–1.52 s) | **997 ms** (949 ms–1.04 s) | -32% |
| manifest 2000 files / 200 MB | on | **1.47 s** (1.45 s–1.50 s) | **1.12 s** (1.05 s–1.17 s) | -24% |

#### Direct (download + set until app ready)

| Payload | Encryption | Rust | C | Δ |
|---|---|---|---|---|
| zip 3 MB | off | **65 ms** (57 ms–70 ms) | **64 ms** (64 ms–79 ms) | -2% |
| zip 3 MB | on | **70 ms** (63 ms–72 ms) | **70 ms** (62 ms–89 ms) | 0% |
| zip 30 MB | off | **412 ms** (394 ms–429 ms) | **408 ms** (385 ms–414 ms) | -1% |
| zip 30 MB | on | **445 ms** (428 ms–448 ms) | **398 ms** (396 ms–417 ms) | -11% |
| zip 300 MB | off | **3.84 s** (3.79 s–3.94 s) | **3.73 s** (3.69 s–3.91 s) | -3% |
| zip 300 MB | on | **3.92 s** (3.85 s–4.08 s) | **3.87 s** (3.71 s–3.88 s) | -1% |
| manifest 2 files / 20 KB | off | **29 ms** (28 ms–30 ms) | **27 ms** (24 ms–35 ms) | -7% |
| manifest 2 files / 20 KB | on | **35 ms** (30 ms–43 ms) | **26 ms** (25 ms–31 ms) | -26% |
| manifest 20 files / 2 MB | off | **48 ms** (48 ms–50 ms) | **47 ms** (43 ms–51 ms) | -2% |
| manifest 20 files / 2 MB | on | **50 ms** (49 ms–54 ms) | **46 ms** (45 ms–54 ms) | -8% |
| manifest 200 files / 20 MB | off | **169 ms** (152 ms–179 ms) | **110 ms** (107 ms–120 ms) | -35% |
| manifest 200 files / 20 MB | on | **166 ms** (160 ms–175 ms) | **123 ms** (122 ms–138 ms) | -26% |
| manifest 2000 files / 200 MB | off | **1.48 s** (1.37 s–1.49 s) | **974 ms** (938 ms–977 ms) | -34% |
| manifest 2000 files / 200 MB | on | **1.50 s** (1.49 s–1.50 s) | **1.11 s** (1.09 s–1.16 s) | -26% |

<details><summary>Direct mode breakdown (download vs set() → app ready)</summary>

| Payload | Encryption | Download Rust | Download C | Apply Rust | Apply C |
|---|---|---|---|---|---|
| zip 3 MB | off | 51 ms | 51 ms | 13 ms | 14 ms |
| zip 3 MB | on | 57 ms | 56 ms | 13 ms | 14 ms |
| zip 30 MB | off | 399 ms | 392 ms | 13 ms | 16 ms |
| zip 30 MB | on | 433 ms | 387 ms | 12 ms | 12 ms |
| zip 300 MB | off | 3.82 s | 3.70 s | 22 ms | 16 ms |
| zip 300 MB | on | 3.90 s | 3.85 s | 16 ms | 18 ms |
| manifest 2 files / 20 KB | off | 13 ms | 11 ms | 16 ms | 16 ms |
| manifest 2 files / 20 KB | on | 19 ms | 13 ms | 16 ms | 14 ms |
| manifest 20 files / 2 MB | off | 33 ms | 29 ms | 15 ms | 17 ms |
| manifest 20 files / 2 MB | on | 32 ms | 28 ms | 17 ms | 18 ms |
| manifest 200 files / 20 MB | off | 156 ms | 97 ms | 13 ms | 13 ms |
| manifest 200 files / 20 MB | on | 154 ms | 111 ms | 14 ms | 12 ms |
| manifest 2000 files / 200 MB | off | 1.47 s | 961 ms | 14 ms | 13 ms |
| manifest 2000 files / 200 MB | on | 1.48 s | 1.10 s | 15 ms | 14 ms |

</details>

#### Direct mode: apply step split (median, Rust / C)

*set()*: from the `set()` call until the new document starts loading (`performance.timeOrigin`). *reload*: new document load until the bench script calls `notifyAppReady()`. *notify*: the `notifyAppReady()` call.

| Payload | Encryption | Apply | set() | Reload | notify |
|---|---|---|---|---|---|
| zip 3 MB | off | 13 ms / 14 ms | 3 ms / 3 ms | 5 ms / 6 ms | 5 ms / 4 ms |
| zip 3 MB | on | 13 ms / 14 ms | 4 ms / 4 ms | 6 ms / 5 ms | 4 ms / 4 ms |
| zip 30 MB | off | 13 ms / 16 ms | 3 ms / 5 ms | 6 ms / 7 ms | 4 ms / 4 ms |
| zip 30 MB | on | 12 ms / 12 ms | 2 ms / 3 ms | 6 ms / 6 ms | 4 ms / 3 ms |
| zip 300 MB | off | 22 ms / 16 ms | 8 ms / 3 ms | 7 ms / 7 ms | 7 ms / 6 ms |
| zip 300 MB | on | 16 ms / 18 ms | 4 ms / 6 ms | 8 ms / 7 ms | 5 ms / 5 ms |
| manifest 2 files / 20 KB | off | 16 ms / 16 ms | 4 ms / 4 ms | 6 ms / 6 ms | 5 ms / 4 ms |
| manifest 2 files / 20 KB | on | 16 ms / 14 ms | 5 ms / 4 ms | 6 ms / 6 ms | 4 ms / 4 ms |
| manifest 20 files / 2 MB | off | 15 ms / 17 ms | 3 ms / 4 ms | 8 ms / 10 ms | 4 ms / 4 ms |
| manifest 20 files / 2 MB | on | 17 ms / 18 ms | 4 ms / 5 ms | 8 ms / 7 ms | 4 ms / 6 ms |
| manifest 200 files / 20 MB | off | 13 ms / 13 ms | 3 ms / 3 ms | 6 ms / 6 ms | 4 ms / 4 ms |
| manifest 200 files / 20 MB | on | 14 ms / 12 ms | 3 ms / 3 ms | 6 ms / 6 ms | 4 ms / 3 ms |
| manifest 2000 files / 200 MB | off | 14 ms / 13 ms | 3 ms / 3 ms | 7 ms / 6 ms | 4 ms / 4 ms |
| manifest 2000 files / 200 MB | on | 15 ms / 14 ms | 4 ms / 4 ms | 6 ms / 5 ms | 4 ms / 5 ms |

#### Manifest reuse (background, 90% of the files already on the device)

*delta cache*: version A with the same files was installed (untimed) right before B; only B is timed. *builtin*: the reused files ship in the app's builtin `public/`. "Fetched" = payload requests the server saw for B (expected: new files + `index.html` + `bench.js`).

| Reuse from | Payload | Encryption | Rust | C | Δ | Fetched Rust / C (expected) |
|---|---|---|---|---|---|---|
| delta cache | 200 files / 20 MB | off | **50 ms** (41 ms–50 ms) | **42 ms** (42 ms–47 ms) | -16% | 22 / 22 (22) |
| delta cache | 200 files / 20 MB | on | **53 ms** (43 ms–56 ms) | **52 ms** (38 ms–58 ms) | -2% | 22 / 22 (22) |
| delta cache | 2000 files / 200 MB | off | **323 ms** (311 ms–324 ms) | **321 ms** (320 ms–325 ms) | -1% | 202 / 202 (202) |
| delta cache | 2000 files / 200 MB | on | **358 ms** (302 ms–415 ms) | **363 ms** (283 ms–414 ms) | +1% | 202 / 202 (202) |
| builtin | 200 files / 20 MB | off | **59 ms** (55 ms–66 ms) | **59 ms** (49 ms–75 ms) | 0% | 22 / 22 (22) |
| builtin | 200 files / 20 MB | on | **65 ms** (45 ms–66 ms) | **64 ms** (40 ms–64 ms) | -2% | 22 / 22 (22) |
| builtin | 2000 files / 200 MB | off | **448 ms** (439 ms–450 ms) | **402 ms** (395 ms–407 ms) | -10% | 202 / 202 (202) |
| builtin | 2000 files / 200 MB | on | **489 ms** (334 ms–509 ms) | **489 ms** (317 ms–501 ms) | 0% | 202 / 202 (202) |

#### Network-shaped (background, plain): 80 ms before every response, 40 Mbit/s total (shared token bucket)

The link alone needs ~4.2 s for 20 MB and ~6.3 s for 30 MB. "Link use" = payload bytes / total time, as a share of the cap.

| Payload | Rust | C | Δ | Link use Rust / C | Peak parallel requests Rust / C |
|---|---|---|---|---|---|
| zip 30 MB | **6.41 s** (6.41 s–6.42 s) | **6.39 s** (6.39 s–6.39 s) | -0% | 98% / 98% | 1 / 1 |
| manifest 200 files / 20 MB | **4.28 s** (4.28 s–4.30 s) | **4.28 s** (4.28 s–4.28 s) | -0% | 98% / 98% | 32 / 32 |
| manifest 2000 files / 20 MB | **5.25 s** (5.25 s–5.28 s) | **5.22 s** (5.21 s–5.22 s) | -1% | 80% / 80% | 32 / 32 |

### App size (release bench builds, plain variant)

The bench app's web assets (`public/`, including the 180 MB builtin pad used by the reuse cases) are listed separately; the rows without web assets show the native footprint.

#### Android (signed release APK, all ABIs)

| | Rust | C | Δ |
|---|---|---|---|
| APK total | 195.71 MiB | 187.37 MiB | -8.34 MiB |
| APK without web assets | 15.64 MiB | 7.30 MiB | -8.34 MiB |
| classes*.dex (uncompressed) | 8.52 MiB | 8.52 MiB | +0.0 KiB |
| lib/arm64-v8a/libcapgo_updater_core.so (in APK) | 2.89 MiB (2.89 MiB) | 872.4 KiB (872.4 KiB) | -2.04 MiB |
| lib/armeabi-v7a/libcapgo_updater_core.so (in APK) | 1.93 MiB (1.93 MiB) | 638.1 KiB (638.1 KiB) | -1.31 MiB |
| lib/x86/libcapgo_updater_core.so (in APK) | 3.41 MiB (3.41 MiB) | 895.4 KiB (895.4 KiB) | -2.54 MiB |
| lib/x86_64/libcapgo_updater_core.so (in APK) | 3.31 MiB (3.31 MiB) | 881.1 KiB (881.1 KiB) | -2.45 MiB |

Estimated per-device download change (arm64 split): gzip -9 of the arm64 `.so` (417.8 KiB) + dex difference (0.0 KiB) = **-1.06 MiB**.

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

### Android confirmation run (fresh emulator, large manifests)

Run on a second emulator booted for this session (a clean clone of the `capgo_mem_api36` config, emulator-5556), same APKs, 3 runs per cell, median (min–max).

| Payload | Encryption | Mode | Rust | C | Δ |
|---|---|---|---|---|---|
| manifest 200 files / 20 MB | off | background | **158 ms** (148–164) | **124 ms** (117–175) | -22% |
| manifest 200 files / 20 MB | on | background | **173 ms** (158–211) | **137 ms** (116–179) | -21% |
| manifest 2000 files / 200 MB | off | background | **1.51 s** (1.49–1.52) | **1.15 s** (1.15–1.20) | -24% |
| manifest 2000 files / 200 MB | on | background | **1.56 s** (1.55–1.59) | **1.13 s** (1.13–1.29) | -27% |
| manifest 200 files / 20 MB | off | direct | **183 ms** (170–224) | **124 ms** (124–132) | -32% |
| manifest 200 files / 20 MB | on | direct | **186 ms** (181–204) | **135 ms** (133–140) | -27% |
| manifest 2000 files / 200 MB | off | direct | **1.57 s** (1.55–1.65) | **1.11 s** (1.07–1.21) | -30% |
| manifest 2000 files / 200 MB | on | direct | **1.57 s** (1.55–1.60) | **1.20 s** (1.17–1.21) | -24% |

### Host micro-benchmarks (release, quiet machine)

`cd core && cargo test --release --features test-support --test perf -- --ignored --nocapture`. Rust = the crate itself. C = `CAPGO_CORE_LIB=core-c/build-perf/libcapgo_updater_core.dylib` (CMake Release `-O3`, `-DCAPGO_TEST_SUPPORT=ON`). Both run through the same C ABI.

Two sets of 5 runs alternated rust/c. Set 2 is the reference. Set 1 ran while FPCKService, Finder and fileproviderd were busy and has outliers (Rust unzip 2325 MB/s, C SHA-256 442 MB/s, C unzip 1627 and 2041 MB/s, C AES 1270 MB/s).

| Operation (100 MiB) | Rust median (min–max) | C median (min–max) | C vs Rust | Set 1 medians Rust / C |
|---|---|---|---|---|
| sha256 | **2903 MB/s** (2680–2909) | **2839 MB/s** (2833–2860) | -2% | 2869 / 2820 |
| aes-128-cbc decrypt | **1646 MB/s** (1566–1658) | **1900 MB/s** (1585–1919) | +15% | 1641 / 1885 |
| unzip (inflate + CRC + write) | **6799 MB/s** (6504–6880) | **5530 MB/s** (5320–5640) | -19% | 6456 / 5495 |

### RSA public operation per checksum

A local Rust test (not committed) calls `core().test("decryptChecksum", …)` with the `crypto-rsa.json` RSA-2048 fixture. Each loop runs 200 warm-up calls, then 5000 timed calls, 5 loops per set and 2 sets per core, with rust/c alternated. The result is checked against the fixture.

The time includes the ABI and JSON envelope, which is measured separately with `rsaUnpadType1` on a 256-byte block: about 1.65 µs for Rust and 1.81 µs for C.

| Core | µs per checksum, median of 10 (min–max) | Without the envelope (approx.) |
|---|---|---|
| Rust (hand-written modexp) | **24.2 µs** (24.1–27.0) | ~22.6 µs |
| C (Mbed TLS 3.6 bignum) | **30.5 µs** (29.4–33.0) | ~28.7 µs |

C is about 1.26× slower per checksum. That adds about 6 µs per encrypted file: about 12 ms over the 2000 files of the largest encrypted manifest, if all of it is serial.

### After the RSA and CRC-32 changes

- **RSA:** the Mbed TLS bignum exponentiation was replaced by a fused CIOS Montgomery multiplication (64-bit limbs with a 128-bit product, 32-bit limbs on armeabi-v7a and x86), precomputed per parsed key, without allocation.
- **unzip:** profiling showed the gap was the CRC-32 check, not inflate. On this payload the platform zlib inflates at 30–40 GB/s, while a single `crc32d` chain is latency bound at about 10 GB/s. Large buffers now run three interleaved `crc32d` chains, joined with the zlib `multmodp` shift (about 29 GB/s). Inflate and write sizes are unchanged.
- The RSA benchmark is now committed as `perf.rs` `rsa_checksum_throughput` (same method as above).
- Runs used `cargo test --release --test perf -- --ignored --nocapture` with rust / C before / C after alternated. Set A: 8 runs of `hot_path_throughput` and 6 runs × 5 loops of RSA, load average about 4 on 18 cores. Set B repeated both later under load 6–8.

| Set A | Rust | C before | C after | C after vs Rust |
|---|---|---|---|---|
| RSA µs per checksum (n=30) | 26.2 (25.7–31.5) | 31.6 (31.1–41.4) | **18.5** (18.3–24.0) | -29% |
| unzip MB/s (n=8) | 6268 (6041–6404) | 5066 (4813–5124) | **7348** (6494–7583) | +17% |
| sha256 MB/s (n=8) | 2674 (2268–2753) | 2580 (1612–2722) | 2622 (303–2695) | -2% |

Set B medians (Rust / C before / C after): RSA 29.5 / 35.4 / 20.7 µs, unzip 4601 / 3921 / 5419 MB/s, sha256 2357 / 2323 / 2381 MB/s.

Size cost of both changes (stripped `.so`): arm64-v8a +1.2 KB, armeabi-v7a +0.6 KB, x86 +2.8 KB, x86_64 +2.2 KB.

### Caveats

- **iPhone 18 Pro, not iPhone 17 Pro.** No 17 Pro simulator exists on this host. The absolute iOS numbers are not directly comparable to #937. The Rust-vs-C comparison is.
- **The Android cold/warm table comes from a different emulator instance.**
  - The shared emulator-5554 was started by another agent (with `nice`, 2 GB RAM, about 1.1 GB swapped, other agents' apps resident). From 19:17 local time it slowed down by about 3× for both cores: 3 MB warm-up 50–80 ms became 130–350 ms, and the first warm runs showed a 165 s stall.
  - Two cold/warm attempts on it were discarded: `discarded/coldwarm-wifi-race/` and `discarded/coldwarm-degraded-5554/`. `am kill-all` and holding Wi-Fi off did not help.
  - The main, reuse and shaped suites on emulator-5554 ran before that point. Their warm-up times stayed at 45–86 ms throughout.
  - Cold/warm (and the confirmation table) were then measured on a fresh emulator: a clean clone of the `capgo_mem_api36` config (`-wipe-data`, emulator-5556). It was booted, used and shut down by this session, and its temporary AVD was deleted. Wi-Fi was held off for the whole series, so the harness did not toggle it between the short runs.
  - Cold samples are therefore on a clean device. The main-suite cells are on the shared one.
- **Wi-Fi on the shared emulator.** For the second (discarded) attempt, Wi-Fi was turned off by hand on emulator-5554. It was turned back on afterwards, matching the state before the session.
- **The reuse suite has 3 runs per cell, while #937's after column has n=1.** The ranges are therefore wider than #937's single values.
- **The host micro-benchmarks run on macOS arm64**, with the system zlib for C and zlib-rs for Rust. On Android and iOS the C core also uses the platform zlib.
- **Wall-clock time:** about 2 h 20 min (18:08–20:28), including 2 discarded cold/warm attempts, emulator diagnosis and the confirmation run. Every command stayed under 10 minutes; the longest chunk took 282 s.
