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
| Android arm64-v8a `.so` (stripped) | 3,030 KB | 893 KB |
| Android armeabi-v7a | 2,023 KB | 653 KB |
| Android x86 | 3,575 KB | 917 KB |
| Android x86_64 | 3,471 KB | 902 KB |
| Android download, arm64 device (bench app) | | about 1.06 MiB smaller |
| iOS app executable (bench app, release) | 4.22 MiB | 1.48 MiB |

## Speed

Full tables (same session, both cores, every suite #937 measured): `BENCHMARK.md`.

- **iOS simulator: parity.** 39 cells: C faster in 25, equal in 6, slower in 8
  (each slower cell at most +3%, ranges overlap). Clearest wins on zips:
  3 MB encrypted background 18 -> 12 ms, 30 MB background -15%. Manifests
  -5% to +2%, reuse -9% to +3%, network-shaped identical.
- **Android emulator: C faster on manifests.** 200 and 2000 files are 24-35%
  faster in both modes (2000 files plain background 1.46 s -> 997 ms),
  confirmed -21% to -32% on a second fresh emulator. Zips, small manifests,
  reuse and shaped runs: same within noise.
- **Android cold start: fixed, now on par.** The first manifest case after
  launch (20 files, background) was 28 ms Rust vs 43 ms C. Cause: the bench
  app holds about 250 descriptors, and Linux grows the descriptor table
  (256 -> 512 slots) with an RCU grace period (about 20 ms) during which every
  thread that needs a new descriptor sleeps. All 20 C workers waited in
  `socket()`. Rust paid the same wait one case earlier, in the first zip (its
  extraction workers each open the archive, C shares one descriptor: first
  zip 75 vs 59 ms). The C core now grows the table on a background thread
  when the first engine is created. Re-measured (n=10, interleaved): cold
  36 ms Rust, 56 ms C before, 31 ms C after; warm (n=20) 31.5 / 29.5 / 32 ms.
- **Apply step** (`set()` until app ready): identical on both platforms.
- **Host (release, through the C ABI):** SHA-256 -2%, AES-128-CBC +15%,
  unzip +17% (three-lane hardware CRC-32; it was -19% with a single CRC
  chain), RSA public operation 18.5 µs vs 26.2 µs per checksum (Montgomery
  modexp; it was 30.5 µs with Mbed TLS bignum).

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

C is smaller (3 to 4 times less code shipped), on par on iOS and on Android
cold start, and faster on large Android manifests and on the RSA and unzip
micro-benchmarks.
It costs 65% more source lines to maintain, hand-written replacements for
the HTTP client, URL parser, zip reader and JSON, and memory safety that has
to be enforced by sanitizers and Valgrind in CI instead of by the compiler.
