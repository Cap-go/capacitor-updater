# Rust core vs C core

Both libraries implement `core/include/capgo_updater_core.h` and the JNI entry
points, and pass the same tests. Measured in October 2026 on an Apple silicon
Mac (iOS simulator, Android emulator `capgo_mem_api36`), Mbed TLS 3.6.5,
Rust 1.98.

## Behavior

| Check | Rust | C |
| --- | --- | --- |
| `core/tests` through the C ABI (195 integration tests) | pass | pass |
| Contract fixtures (`native-contract-tests/`, 255 cases) | pass | pass, byte-identical replies |
| Android JVM unit tests (JNI binding) | 72/72 | 72/72 |
| iOS XCTest | 71/71 | 71/71 |
| Maestro end-to-end, iOS + Android (smoke, live update modes, edge cases: network drop, kill during download, corrupt bundle, offline, direct-update network drop) | pass | 32/32 pass |

Known differences (documented in the sources): the C client checks the TLS
certificate right after the handshake instead of during it (still before any
HTTP byte), has no TLS session resumption, and Mbed TLS refuses server chains
with key types it cannot parse (e.g. Ed25519) before the host is asked. On
Android, the first engine grows the process descriptor table once on a
background thread (see Speed, cold start); Rust has no such step.

## Size

| | Rust | C |
| --- | --- | --- |
| Android arm64-v8a `.so` (stripped) | 3,030 KB | 895 KB |
| Android armeabi-v7a | 2,023 KB | 654 KB |
| Android x86 | 3,575 KB | 920 KB |
| Android x86_64 | 3,471 KB | 905 KB |
| Android download, arm64 device (bench app) | | about 1.06 MiB smaller |
| iOS app executable (bench app, release) | 4.22 MiB | 1.48 MiB |

## Speed

Full tables (run 2, same session for both cores, every suite #937 measured,
after the C RSA, CRC-32 and descriptor-table fixes): `BENCHMARK.md`.

- **iOS simulator: parity, C ahead on zips.** 39 cells: C faster in 23,
  equal in 9, slower in 7. Zips 3 MB and 30 MB in the background are 15-24%
  faster, and 300 MB encrypted is 34% faster. Manifests are -7% to +6%, reuse
  -2% to -10%, and network-shaped runs are identical. Six of the seven slower
  cells come from one chunk that started right after a host stall.
  - The 300 MB plain zip (+106% in that chunk) was -34% in an interleaved
    re-run, and the 30 MB plain zip direct went from +12% to -13%.
  - The 2-file plain direct cell (31 -> 37 ms, +19%) was not re-run. It is
    the largest C loss left, at 6 ms. In run 1 it was -3%.
  - The other slower cells are +5% to +9%, at most 7 ms, and their ranges
    overlap.
- **Android emulator: C faster on large manifests.** 200 and 2000 files are
  21-35% faster in both modes (2000 files plain background 1.37 s -> 1.06 s).
  Zips, small manifests, reuse and shaped runs are the same within noise.
  Five cells are slower by at most 5% (20 ms). Of these, only delta-cache
  reuse with 2000 encrypted files (423 -> 443 ms) has non-overlapping ranges.
- **Android cold start: on par.** In run 1, the first manifest case after
  launch (20 files, background) took 28 ms with Rust and 43 ms with C.
  - Cause: the bench app holds about 250 descriptors, and Linux grows the
    descriptor table (256 -> 512 slots) with an RCU grace period (about
    20 ms). During it, every thread that needs a new descriptor sleeps. All 20
    C workers waited in `socket()`.
  - Rust paid the same wait one case earlier, in the first zip: its
    extraction workers each open the archive, while C's share one descriptor
    (first zip 75 ms Rust vs 59 ms C).
  - Fix: the C core now grows the table on a background thread when the
    first engine is created.
  - Run 2 (n=5, interleaved): cold 37 ms Rust vs 32 ms C, warm 31 vs 28 ms.
- **Apply step** (`set()` until app ready): identical on both platforms.
- **Host (release, through the C ABI):**
  - SHA-256: -2%.
  - AES-128-CBC: +13%.
  - unzip: +16% with the three-lane hardware CRC-32 (-19% with a single CRC
    chain).
  - RSA public operation: 17.4 µs per checksum vs 24.1 µs for Rust, with
    Montgomery modexp (30.5 µs with Mbed TLS bignum).

## Cost and safety

| | Rust | C |
| --- | --- | --- |
| Code, non-blank non-comment lines (Rust counts its inline unit tests, C excludes its test-only files) | ~13k | ~21.5k |
| Third-party code | crates (rustls, ring, ureq, url, zip, zlib-rs, brotli, serde_json...) | Mbed TLS, Brotli decoder, platform zlib |
| Clean core build, one iOS slice | ~1 min 45 s (CI) | ~9 s (local) |
| Toolchain | rustup, cargo-ndk | CMake, NDK / Xcode |
| Memory safety | by the language (`unsafe` only in the FFI / JNI glue and two libc calls: statvfs, localtime) | by discipline and tools: ASan + UBSan (macOS), ThreadSanitizer (macOS), Valgrind memcheck + UBSan (Linux CI) over the whole suite |

Bugs the tools found while porting to C, all fixed:

- Mbed TLS built its AES tables on first use without a memory barrier: two
  downloads decrypting at once could read half-built tables on ARM
  (ThreadSanitizer). Fixed with constant tables and CPU-feature detection at
  load.
- Strings with NUL bytes from JSON would be cut short in C and could pass a
  path check that Rust rejects; every guarded input now refuses them.
- 128-bit integers in a time check did not build for 32-bit Android ABIs.

The port also found one race present in both cores (a log ordering between the
launch cleanup and a waiting download), fixed in both.

## Verdict

C ships 3 to 4 times less code. It is on par on iOS and on Android cold start
and faster on large Android manifests (21-35%). On the host micro-benchmarks
it is faster on AES, unzip and RSA, and 2% slower on SHA-256. A few small
device cells are still slower with C: the iOS 2-file plain direct case by
6 ms, the others by at most 7 ms on iOS and 5% on Android.
It costs 65% more source lines to maintain, hand-written replacements for
the HTTP client, URL parser, zip reader and JSON, and memory safety that has
to be enforced by sanitizers and Valgrind in CI instead of by the compiler.
