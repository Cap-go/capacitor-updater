# Mobile resource and recovery comparison

Measured on 2026-10-18. Five repetitions per implementation, OS and workload. Values are medians with observed min–max ranges; these ranges are not confidence intervals.

The C and Rust candidates are experimental core PR revisions. The Java/Swift comparison starts from main at `e2d8bc7b`. The core branches predate newer main features, so these are pinned implementation comparisons, not isolated language benchmarks or proof of current-main feature parity.

## Versions and controls

| Implementation | Before runtime commit | After runtime commit                       |
| -------------- | --------------------- | ------------------------------------------ |
| C              | `ff6783bd`            | `14988ba96efbeac4f276be03a80854a038f0f7ae` |
| Rust           | `97ca6bb3`            | `533a927b`                                 |
| Java/Swift     | `e2d8bc7b`            | `c56347c8e3d730aada0d1112bef207765e7473c3` |

Release builds, identical app assets (including 1,800 bundled pad files), random payload fixtures, encryption keys, benchmark JavaScript and HTTP/1.1 server. ZIP payload is 300 MiB; the large manifest has 2,000 generated files / 200 MiB plus harness files. The delayed case has 2,000 generated files / 20 MiB, a shared 40 Mbit/s response-body budget and 80 ms response TTFB. It does not model TCP RTT.

Android: rooted API 36 emulator, four vCPUs, guest MemTotal 2.41 GiB. iOS: simulator on the same 18-core Apple M5 Pro host, 64 GiB RAM. Platform results must be compared within their own OS; simulator and emulator absolute numbers are not comparable to each other or to physical phones.

Final candidates use eight manifest workers per CPU, capped at 32 per update, 64 KiB I/O buffers, and (for shared cores) 256 KiB ZIP blocks with one queued block. Before: C/Rust use 32 workers on Android and 64 on the iOS simulator; Java/Swift use 8 and 36 respectively.

Candidate orders rotate and reverse across rounds. Three complete rounds ran after all candidates were frozen; unchanged measurements from the first two tuning rounds were retained, with revised candidates rerun. Each label and encryption variant is freshly installed/launched per round, with warm-ups excluded. No local builds, mobile test suites or CPU profiling ran concurrently with timed cases. Exploratory samples were excluded when their implementation changed; unaffected frozen candidates retained their valid samples. See metadata and artifact checksums for exact revisions.

## Measurement boundaries

- Download latency: JavaScript `download()` until resolution, after the app’s bundle cleanup.
- CPU: primary app process, including worker threads, from server case assignment through completion plus 1.5 seconds. This also includes pre-download cleanup and asynchronous cache work.
- Memory: sampled primary-process peak over the CPU window, Android PSS and iOS physical footprint. Separate WebView processes and OS network daemons are excluded. These are not whole-app peak-memory measurements.
- Android sampling is approximately 100 ms; CPU counters have 10 ms resolution. iOS sampling is 20 ms; Mach CPU ticks are converted with `mach_timebase_info` (125/3 here), independently checked against `process_time` over a 100 ms CPU loop. [XNU records task CPU in Mach units](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c#L6811), and [copies those counters into rusage](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c#L1260).
- Every normal-network result has exactly the expected payload request count and bytes. Recovery profiles disable the harness’s whole-case retries; failures are retained.

## Normal-network measurements

Milliseconds for latency and CPU; MiB for sampled peak memory. Every row has five successful timed updates.

### Android: Encrypted ZIP, 300 MiB

| Build         | Download ms      | Lifecycle CPU ms | Peak memory MiB     |
| ------------- | ---------------- | ---------------- | ------------------- |
| c-before      | 3703 (3614–3965) | 4590 (4440–4860) | 95.3 (94.1–96.3)    |
| c-after       | 3741 (3450–4055) | 890 (740–980)    | 93.0 (91.4–97.5)    |
| rust-before   | 3666 (3627–3978) | 850 (790–910)    | 96.9 (95.7–97.8)    |
| rust-after    | 3817 (3657–4072) | 880 (840–980)    | 97.4 (96.1–98.8)    |
| native-before | 8359 (7911–8748) | 5270 (5180–5430) | 105.9 (103.2–106.6) |
| native-after  | 5769 (5286–6440) | 2690 (2470–2880) | 97.2 (96.7–97.5)    |

### Android: Encrypted manifest, 2,000 files / 200 MiB

| Build         | Download ms      | Lifecycle CPU ms | Peak memory MiB     |
| ------------- | ---------------- | ---------------- | ------------------- |
| c-before      | 1332 (1250–1367) | 2610 (2320–2680) | 112.7 (99.9–115.6)  |
| c-after       | 1387 (1229–1643) | 1650 (1560–2210) | 110.6 (105.6–113.2) |
| rust-before   | 1544 (1480–1591) | 1520 (1490–1730) | 134.1 (133.1–139.3) |
| rust-after    | 1450 (1412–1583) | 1400 (1390–1490) | 124.0 (121.2–125.5) |
| native-before | 2945 (2780–3359) | 4400 (4300–5220) | 112.8 (108.7–117.8) |
| native-after  | 2404 (2347–2835) | 3700 (3520–4320) | 113.5 (110.6–123.7) |

### Android: Delayed plain manifest, 2,000 files / 20 MiB

| Build         | Download ms         | Lifecycle CPU ms | Peak memory MiB     |
| ------------- | ------------------- | ---------------- | ------------------- |
| c-before      | 5226 (5224–5251)    | 5870 (5750–5930) | 106.7 (105.3–107.8) |
| c-after       | 5236 (5229–5255)    | 770 (690–770)    | 105.2 (103.9–105.4) |
| rust-before   | 5249 (5238–5253)    | 750 (740–870)    | 121.7 (121.3–122.6) |
| rust-after    | 5238 (5233–5251)    | 770 (760–820)    | 117.3 (116.1–117.6) |
| native-before | 20861 (20857–20899) | 4120 (4070–4180) | 112.2 (110.3–112.8) |
| native-after  | 5306 (5302–5309)    | 1770 (1760–1980) | 111.5 (111.1–113.8) |

### Ios: Encrypted ZIP, 300 MiB

| Build         | Download ms   | Lifecycle CPU ms | Peak memory MiB  |
| ------------- | ------------- | ---------------- | ---------------- |
| c-before      | 620 (457–666) | 558 (546–585)    | 20.9 (20.3–22.4) |
| c-after       | 649 (418–732) | 582 (575–607)    | 23.1 (23.0–25.0) |
| rust-before   | 631 (439–677) | 673 (644–690)    | 20.3 (20.2–20.6) |
| rust-after    | 595 (429–714) | 684 (668–701)    | 20.5 (20.4–22.3) |
| native-before | 828 (646–986) | 723 (691–774)    | 20.5 (20.3–20.6) |
| native-after  | 909 (806–965) | 840 (825–845)    | 20.7 (20.4–20.8) |

### Ios: Encrypted manifest, 2,000 files / 200 MiB

| Build         | Download ms      | Lifecycle CPU ms    | Peak memory MiB  |
| ------------- | ---------------- | ------------------- | ---------------- |
| c-before      | 807 (794–835)    | 8364 (8124–8562)    | 43.9 (43.3–44.3) |
| c-after       | 924 (909–953)    | 7985 (7917–8268)    | 41.4 (40.6–41.8) |
| rust-before   | 849 (832–858)    | 8809 (8315–8879)    | 44.1 (43.9–44.4) |
| rust-after    | 933 (908–1014)   | 8170 (7951–8698)    | 40.1 (39.8–40.3) |
| native-before | 3036 (2940–3174) | 17262 (17073–17747) | 47.2 (46.3–47.6) |
| native-after  | 3044 (3033–3088) | 18910 (18838–19033) | 46.4 (45.9–47.0) |

### Ios: Delayed plain manifest, 2,000 files / 20 MiB

| Build         | Download ms      | Lifecycle CPU ms | Peak memory MiB  |
| ------------- | ---------------- | ---------------- | ---------------- |
| c-before      | 4306 (4299–4309) | 2400 (2264–2592) | 38.7 (38.0–39.0) |
| c-after       | 5358 (5344–5358) | 3098 (2967–3310) | 37.1 (36.9–38.0) |
| rust-before   | 4306 (4305–4308) | 2494 (2432–2565) | 40.0 (39.7–40.0) |
| rust-after    | 5358 (5349–5378) | 3183 (2975–3325) | 36.9 (36.7–37.6) |
| native-before | 5104 (5043–5144) | 6245 (6065–6413) | 40.0 (39.0–41.7) |
| native-after  | 5648 (5642–5667) | 6068 (5885–6190) | 38.3 (37.0–39.4) |

## Changes relative to each implementation’s own baseline

Negative percentages mean lower cost. Small differences within the observed spread should not be treated as a winner.

| OS      | Implementation | Workload        | Latency change | CPU change | Memory change |
| ------- | -------------- | --------------- | -------------- | ---------- | ------------- |
| android | C              | zip             | +1.0%          | -80.6%     | -2.5%         |
| android | C              | manifest        | +4.1%          | -36.8%     | -1.8%         |
| android | C              | shaped-manifest | +0.2%          | -86.9%     | -1.4%         |
| android | Rust           | zip             | +4.1%          | +3.5%      | +0.5%         |
| android | Rust           | manifest        | -6.1%          | -7.9%      | -7.6%         |
| android | Rust           | shaped-manifest | -0.2%          | +2.7%      | -3.6%         |
| android | Java/Swift     | zip             | -31.0%         | -49.0%     | -8.2%         |
| android | Java/Swift     | manifest        | -18.4%         | -15.9%     | +0.6%         |
| android | Java/Swift     | shaped-manifest | -74.6%         | -57.0%     | -0.6%         |
| ios     | C              | zip             | +4.7%          | +4.4%      | +10.2%        |
| ios     | C              | manifest        | +14.5%         | -4.5%      | -5.7%         |
| ios     | C              | shaped-manifest | +24.4%         | +29.1%     | -4.1%         |
| ios     | Rust           | zip             | -5.7%          | +1.6%      | +0.6%         |
| ios     | Rust           | manifest        | +9.9%          | -7.3%      | -9.1%         |
| ios     | Rust           | shaped-manifest | +24.4%         | +27.6%     | -7.7%         |
| ios     | Java/Swift     | zip             | +9.8%          | +16.2%     | +1.1%         |
| ios     | Java/Swift     | manifest        | +0.3%          | +9.5%      | -1.7%         |
| ios     | Java/Swift     | shaped-manifest | +10.7%         | -2.8%      | -4.3%         |

## One transient server failure per update

The first timed manifest payload returns HTTP 503 once. Warm-ups are unaffected. The update has 20 generated files / 2 MiB plus harness files. Exactly one harness attempt is allowed. A fast failed update is not a successful recovery.

| OS      | Build         | Successful recovery | Successful latency ms |
| ------- | ------------- | ------------------- | --------------------- |
| android | c-before      | 5/5                 | 30040 (30038–30051)   |
| android | c-after       | 5/5                 | 30045 (30042–30053)   |
| android | rust-before   | 5/5                 | 30043 (30038–30051)   |
| android | rust-after    | 5/5                 | 30040 (30039–30049)   |
| android | native-before | 0/5                 | —                     |
| android | native-after  | 5/5                 | 280 (273–284)         |
| ios     | c-before      | 0/5                 | —                     |
| ios     | c-after       | 5/5                 | 279 (274–281)         |
| ios     | rust-before   | 0/5                 | —                     |
| ios     | rust-after    | 5/5                 | 275 (270–284)         |
| ios     | native-before | 0/5                 | —                     |
| ios     | native-after  | 5/5                 | 278 (269–282)         |

Android scheduled jobs retain their scheduler-owned retry policy; inline retries do not multiply job retries. Foreground manifest transfers can retry transient transport errors, HTTP 408 and 5xx at most three times with 250/500 ms backoff. HTTP 429, TLS, checksum, decryption and local-storage failures do not trigger this immediate loop. Unit tests cover those boundaries and partial-file resume.

## Packet loss: Android cold launches

Linux netem adds 75 ms delay and 1% loss independently on emulator eth0 egress and ingress (via an owned IFB). No application warm-up, no harness retry, 20 generated files / 2 MiB per update. TCP retransmissions can recover packet loss without an HTTP-level retry. This emulator’s TCP proxy and network offloads make it an approximation of a carrier network. Qdisc counters and restoration evidence are included with the raw data.

| Build         | Successes | Successful latency ms | Lifecycle CPU ms  | Peak PSS MiB      |
| ------------- | --------- | --------------------- | ----------------- | ----------------- |
| c-before      | 5/5       | 8429 (5241–51052)     | 8390 (5180–50750) | 91.4 (91.0–92.4)  |
| c-after       | 5/5       | 5251 (3983–8200)      | 50 (30–70)        | 90.3 (90.1–91.3)  |
| rust-before   | 5/5       | 6625 (5049–10538)     | 60 (40–60)        | 93.3 (92.6–93.5)  |
| rust-after    | 5/5       | 7692 (5426–10008)     | 50 (30–60)        | 92.5 (92.1–93.7)  |
| native-before | 5/5       | 10714 (6398–14422)    | 110 (110–120)     | 96.6 (95.7–102.2) |
| native-after  | 5/5       | 5756 (4915–10546)     | 90 (70–100)       | 96.4 (96.3–97.1)  |

## Interpretation

- On this four-vCPU Android emulator, the native Java changes reduce encrypted ZIP latency by 31.0% and lifecycle CPU by 49.0%; the delayed manifest improves by 74.6% and 57.0% respectively. Encrypted-manifest latency improves 18.4%, with 15.9% less CPU and essentially unchanged sampled memory (+0.6%). These are improvements against the native baseline, without requiring a core rewrite.
- The optimized C and Rust cores have close Android completion times. C has the lowest sampled Android memory in these three cases; Rust uses less CPU for the encrypted manifest (1,400 vs 1,650 ms). Encrypted-ZIP CPU medians are effectively tied (890 vs 880 ms), and delayed-manifest CPU medians tie exactly. The C waiter clock fix accounts for a large portion of its Android CPU improvement; this is an implementation defect, not an inherent language advantage.
- On the iOS simulator, C and Rust encrypted-manifest latency ranges overlap (median 924 vs 933 ms), and both are much faster than native Swift (3,044 ms). Rust has slightly lower sampled memory; C has a slightly lower CPU median. The ZIP latency ranges also overlap substantially. There is no defensible universal C-versus-Rust speed winner.
- The new worker ceiling is a tradeoff on this 18-core host: both cores take 24.4% longer on the delayed manifest while reducing sampled memory 4.1% (C) and 7.7% (Rust). Their lifecycle CPU also rises 29.1% and 27.6%. Native Swift has mixed results: delayed-manifest latency rises 10.7%, ZIP CPU rises 16.2%, and encrypted-manifest CPU rises 9.5%. These iOS changes must not be described as a uniform performance improvement. Worker count is a likely contributor, but the combined benchmark does not isolate each change.
- For the injected server error on Android, native recovers in a median 280 ms. Both shared cores recover through their existing scheduled-job backoff at about 30,040 ms, essentially unchanged from their baselines. Their foreground fast-retry changes improve iOS recovery but do not remove this Android latency penalty. The native implementation wins this specific recovery-latency test.
- All 30 packet-loss updates succeed, so this profile establishes no reliability winner. Optimized latency medians are 5.25 seconds for C, 5.76 for native and 7.69 for Rust, with broad overlapping ranges. Random loss and only five repetitions limit ranking confidence. Actual qdisc counters record 138 egress and 186 ingress drops; offloads make the configured 1% policy an approximation.
- Use the native PR as a lower-migration-cost option with proven Android gains and added recovery behavior. Choose a shared core for cross-platform ownership and future bindings; these measurements alone do not justify choosing C over Rust or bypassing feature-parity and physical-device validation.

## What changed

- C: fixed the scheduled-download condition-variable clock. The static initializer used realtime while deadlines used monotonic time, causing an idle Android/Linux waiter to spin. An Android C-ABI regression test measured 348.8 ms thread CPU during a 350 ms idle wait before the fix; both fixed C and Rust measured below timer resolution. The test fails on the old C library and passes on both current implementations.
- Both cores: smaller buffers and ZIP queue, bounded workers, borrowed manifest input, calling-thread participation, and bounded foreground transient retries. Rust also falls back when optional worker creation fails.
- Java/Swift: smaller buffers, bounded workers, checked hashing, verified-file moves, atomic immutable-file links with copy fallback, best-effort cache writes, and bounded transient retries. Each manifest now prepares its session key once; each file still creates fresh CBC state. Progress is coalesced before WorkManager writes and Swift bridge callbacks; known bundle metadata avoids repeated store lookups. Concurrent real-CLI fixture tests cover separate keys and repeated files, while malformed/missing sessions and checksum gates remain strict.

## Validation and limits

- All three `bun run verify` and formatter runs passed locally. Native Java/Swift passed 328 JVM tests and the full 288-test iOS suite. Shared fixtures and C-ABI flow tests validate behavior independently of implementation language.
- C passed focused AddressSanitizer/UndefinedBehaviorSanitizer and ThreadSanitizer suites; CI additionally runs fuzzing and Linux checks. Final PR check status is recorded in each PR.
- No physical-phone thermal, battery, forced memory-pressure/OOM or carrier-handover testing. The benchmarks measure successful normal transfers and controlled recovery scenarios, not all mobile failure modes.
- Payloads are generated random data. Their compression ratios and file mix do not represent a particular customer application.
- Existing Rust/C PRs need separate current-main feature parity before production merge. Their newer-main omissions are not benchmarked as performance differences.

## Raw evidence and reproduction

The [artifact manifest](benchmarks/mobile-resources/artifacts.json) records all 24 release snapshots; [metadata](benchmarks/mobile-resources/metadata.json) pins runtime commits, hardware, policies and boundaries. Compressed reports retain every attempt and its joined samples. CSVs provide the same per-attempt metrics for inspection. Raw primary-process sample archives allow recomputing the windows.

- main: [CSV](benchmarks/mobile-resources/main.csv), [joined JSON](benchmarks/mobile-resources/main.json.gz), [raw samples](benchmarks/mobile-resources/main-samples.tar.gz).
- fault: [CSV](benchmarks/mobile-resources/fault.csv), [joined JSON](benchmarks/mobile-resources/fault.json.gz), [raw samples](benchmarks/mobile-resources/fault-samples.tar.gz).
- lossy: [CSV](benchmarks/mobile-resources/lossy.csv), [joined JSON](benchmarks/mobile-resources/lossy.json.gz), [raw samples](benchmarks/mobile-resources/lossy-samples.tar.gz).

Use the release benchmark harness in `scripts/bench/README.md`. Freeze the before/after snapshots at the recorded commits first. Run the sampler concurrently with one platform runner, using `BENCH_MAX_ATTEMPTS=1`; `BENCH_FAULT_PROFILE=503-once` selects the server fault, and `BENCH_NO_WARMUP=1` selects cold launches. Keep builds and profiling outside timed runs. Repeat each cell five times, rotating candidate order and reversing it on alternating rounds. Join samples with `resource-report.py`; verify success counts, expected bytes, sample coverage and boundary overhang before comparing medians.

Generated with AI assistance; measurements are actual release-app runs, not simulated benchmark numbers.

### Reproducing a cell

Use this PR's harness, even when the plugin checkout is an older snapshot. Create one checkout per commit in the version table, run `bun install` and `bun run build` inside each, and keep one shared `BENCH_DIR` for fixtures and release snapshots. Build snapshots before starting any timed measurements. For C, set `CAPGO_CORE_IMPL=c`; for Rust, set it to `rust`; native checkouts have no core build.

For example, prepare both C-after release variants from a checkout of `14988ba9`:

```bash
export BENCH_DIR="$PWD/.context/mobile-repro"
export ANDROID_SERIAL=emulator-5610
export BENCH_IOS_UDID=EDFC80C4-6DA0-4966-B9C4-8C439106E328
CAPGO_CORE_IMPL=c BENCH_BUILD_ONLY=1 scripts/bench/run-android.sh c-after /path/to/c-after --variants plain,enc
CAPGO_CORE_IMPL=c BENCH_BUILD_ONLY=1 scripts/bench/run-ios.sh c-after /path/to/c-after --variants plain,enc
```

Replace the device identifiers with your owned devices. Then measure a single Android encrypted-manifest cell with a matching sample filename:

```bash
mkdir -p .context/mobile-repro/samples
python3 scripts/bench/resource-sampler.py --platform android \
  --output .context/mobile-repro/samples/resources-c-after-android-enc-r1.jsonl &
bench_sample_pid=$!
BENCH_MAX_ATTEMPTS=1 scripts/bench/run-android.sh c-after /path/to/c-after \
  --skip-build --no-core --variants enc --suites main \
  --only '^manifest-2000f-200MB-enc-background-r1$' --runs 1
kill "$bench_sample_pid"
wait "$bench_sample_pid" || true
python3 scripts/bench/resource-report.py "$BENCH_DIR" \
  --samples .context/mobile-repro/samples --output .context/mobile-repro/report.json
```

Use `run-ios.sh` and `--platform ios` together for iOS. The three normal-workload filters are `zip-300MB-enc-background-rN`, `manifest-2000f-200MB-enc-background-rN`, and `shaped-manifest-2000f-20MB-plain-background-rN`. The last requires `--suites shaped --variants plain`. Set `N` and `--runs` to the current round, 1 through 5. The runner skips already recorded cases, so keep profiles in separate result directories. They can share `apps`, `fixtures` and `keys` through symlinks.

For the server-error profile, use `BENCH_FAULT_PROFILE=503-once BENCH_MAX_ATTEMPTS=1`, plain variant, main suite and `^manifest-20f-2MB-plain-background-rN$`. For packet loss, unset `BENCH_FAULT_PROFILE`, set `BENCH_NO_WARMUP=1 BENCH_MAX_ATTEMPTS=1`, and use the same small manifest. The recorded network setup was netem `delay 75ms loss 1% limit 10000` on Android `eth0` egress, plus ingress redirected through a separate IFB with the same policy. Root qdisc handles were `7711:` and `7712:`, and ingress filter priority `62000`; prior `clsact` configuration was preserved. Record `tc -s` counters before removing only those owned entries and restoring Wi-Fi. The included active/counter/restoration logs give the exact configuration used.

Round orders were: native-before/native-after/Rust-before/Rust-after/C-before/C-after; the reverse; Rust-before/Rust-after/C-before/C-after/native-before/native-after; native-after/native-before/C-after/C-before/Rust-after/Rust-before; C-before/C-after/native-before/native-after/Rust-before/Rust-after. Android ran first on odd rounds, iOS on even rounds. Normal measurements ran before the fault profile, followed by the Android loss profile.
