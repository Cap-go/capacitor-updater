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
with key types it cannot parse (e.g. Ed25519) before the host is asked.

## Size

| | Rust | C |
| --- | --- | --- |
| Android arm64-v8a `.so` (stripped) | 3,030 KB | 893 KB |
| Android armeabi-v7a | 2,023 KB | 653 KB |
| Android x86 | 3,575 KB | 917 KB |
| Android x86_64 | 3,471 KB | 902 KB |
| Android download, arm64 device (bench app) | | about 1.06 MiB smaller |
| iOS app executable (bench app, release) | 4.22 MiB | 1.48 MiB |

## Speed (on-device benchmark, `scripts/bench`, median of 3, ratio C / Rust)

- iOS zip bundles: C faster, up to 0.54 (encrypted 300 MB: 429 ms vs 232 ms);
  30 MB zips 0.83 to 0.92.
- Android manifest (delta) downloads: C faster on large manifests, 0.71 to 0.85
  (2000 files / 200 MB: 1.42 s vs 1.04 s plain, 1.55 s vs 1.10 s encrypted
  direct).
- iOS manifests and Android zips: same speed (within noise, 0.93 to 1.08).
- Network-shaped runs (80 ms latency, 40 Mbit/s): within 1%, the link is the
  limit.
- Host micro-benchmarks (100 MB, release): SHA-256 equal (~2.6 GB/s); AES-CBC
  and unzip comparable, noisy on a loaded machine.

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

C is smaller (3 to 4 times less code shipped) and at least as fast, on device.
It costs 65% more source lines to maintain, hand-written replacements for
the HTTP client, URL parser, zip reader and JSON, and memory safety that has
to be enforced by sanitizers and Valgrind in CI instead of by the compiler.
