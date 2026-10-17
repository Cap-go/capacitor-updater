# Rust core vs C core

Both libraries implement `core/include/capgo_updater_core.h` and the JNI entry
points, and pass the same tests. Measured in October 2026 on an Apple silicon
Mac (iOS simulator, Android emulator `capgo_mem_api36`), Mbed TLS 3.6.5,
Rust 1.98.

## Behavior

| Check | Rust | C |
| --- | --- | --- |
| `core/tests` through the C ABI (206 integration tests) | pass | pass |
| Contract fixtures (`native-contract-tests/`, 255 cases) | pass | pass, byte-identical replies |
| Android JVM unit tests (JNI binding) | 72/72 | 72/72 |
| iOS XCTest | 71/71 | 71/71 |
| Maestro end-to-end, iOS + Android (smoke, live update modes, edge cases: network drop, kill during download, corrupt bundle, offline, direct-update network drop) | pass | 32/32 pass |

Known differences (documented in the sources): the C client checks the TLS
certificate right after the handshake instead of during it (still before any
HTTP byte), has no TLS session resumption, and Mbed TLS refuses server chains
with key types it cannot parse (e.g. Ed25519) before the host is asked. A
response header line without `:` is skipped by C and refuses the response in
Rust (see Crash safety). On Android, the first engine grows the process
descriptor table once on a background thread (see Speed, cold start); Rust has
no such step.

## Size

With the crash-safety changes (hardening flags, crash-loop breaker; Rust:
overflow checks and correctly rounded floats):

| | Rust | C |
| --- | --- | --- |
| Android arm64-v8a `.so` (stripped) | 3,160 KB | 911 KB |
| Android armeabi-v7a | 2,109 KB | 672 KB |
| Android x86 | 3,705 KB | 942 KB |
| Android x86_64 | 3,606 KB | 929 KB |
| iOS arm64 executable, minimal app linking the static library | 3,480 KB | 812 KB |
| Android download, arm64 device (bench app, run 2, before) | | about 1.06 MiB smaller |
| iOS app executable (bench app, release, run 2, before) | 4.22 MiB | 1.48 MiB |

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
| Memory safety | by the language (`unsafe` only in the FFI / JNI glue and two libc calls: statvfs, localtime; Miri in CI) | by discipline and tools: ASan + UBSan and ThreadSanitizer (macOS CI), Valgrind memcheck + UBSan (Linux CI) over the whole suite, static analysis, fuzzing (see Crash safety) |

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

## Crash safety

What keeps bad input or a bug from taking the app down, per core, and where
the two still differ. Measured October 2026 on the same Mac.

### Prevented: bugs caught before they ship

| | Rust | C |
| --- | --- | --- |
| Memory safety | The compiler. `unsafe` only in the C ABI / JNI glue and two libc calls (`statvfs`, `localtime_r`). Miri runs the C ABI marshalling and `localtime_r` tests (`rust_core_miri`); `statvfs` has no Miri shim and `jni.rs` needs a JVM. | Tools over the whole Rust test suite through the C ABI: ASan + UBSan and ThreadSanitizer (`c_core_sanitizers`, macOS), Valgrind memcheck + UBSan (`c_core_memcheck`, Linux). |
| Sanitized test suite | `cargo test` under AddressSanitizer (`rust_core_asan`, nightly, Linux, with leak detection) | see above (leaks: Valgrind and the fuzz targets' LeakSanitizer; Apple's ASan runtime has no leak detection) |
| Static analysis | clippy `-D warnings` (`rust_core`) | Clang static analyzer + bugprone checks, every finding an error (`core-c/.clang-tidy`, `c_core_static_analysis`); a lint refuses `strcpy`, `strcat`, `sprintf`, `vsprintf`, `gets`, `strncpy`, `strncat`, `stpcpy` (`scripts/ci/check-core-c-banned-calls.sh`) |
| Integer overflow | Panics: `overflow-checks = true` in the release profile (every crate); the C ABI and JNI entry points catch the panic | UBSan traps signed overflow in the CI suites and the fuzz targets; shipped builds wrap |
| Fuzzing | 11 cargo-fuzz targets: libFuzzer + ASan, built like the shipped library (release, overflow checks, no debug assertions) | The same 11 targets: libFuzzer + ASan + UBSan + LeakSanitizer |

All CI jobs above run on every pull request, each capped at 10 minutes.

### Fuzzing

`scripts/fuzz.sh build|run|smoke rust|c`. Both cores have the same target
names, input formats and seed corpus (`fuzz/corpus/<target>`, written by
`scripts/generate-fuzz-corpus.mjs`); each target calls its own core
(`core/fuzz/fuzz_targets/<target>.rs`, `core-c/fuzz/<target>.c`).

| Target | Input | Rust | C |
| --- | --- | --- | --- |
| `zip` | bundle zip: central directory, entries, inflate, CRC, zip-slip and symlink guards, single-folder unwrap | `archive::extract_zip`, `install_extracted` | `cg_archive_extract_zip`, `cg_archive_install_extracted` |
| `inflate` | raw deflate stream | flate2 `DeflateDecoder` (zlib-rs, used by the zip crate) | `cg_archive_inflate_reader` (platform zlib) |
| `brotli` | manifest `.br` file | `brotli_decompressor::Decompressor` | `cg_brotli_reader` (Brotli decoder) |
| `json` | JSON text; printing and parsing again must give the same value and text | serde_json | `cj_parsen`, `cj_print` |
| `manifest` | update reply or manifest JSON | `DownloadRequest::from_json`, engine `missingBundleFiles`, per-entry path and cache-name guards | the same, engine through `capgo_engine_call` |
| `update_response` | body of the update-check reply, over loopback HTTP | engine `getLatest` | engine `getLatest` |
| `http_response` | raw HTTP response over loopback: status line, headers, chunked and Content-Length bodies, gzip, redirects (every other host goes to the same server through the proxy hook) | `net::Http` (ureq) | `cg_http_get`, `cg_http_download` |
| `rsa_key` | public key, PEM or DER | `RsaPublicKey::from_pem`, `from_der`, `crypto::key_id` | `cg_rsa_from_pem`, `cg_rsa_from_der`, `cg_crypto_key_id` |
| `rsa_checksum` | signed checksum (hex or base64), raw RSA block | `decrypt_checksum`, `public_decrypt`, `unpad_type1` | `cg_crypto_decrypt_checksum`, `cg_rsa_public_decrypt`, `cg_rsa_unpad_type1` |
| `aes_cbc` | key + IV + ciphertext (one call and uneven chunks must agree), session key text | `CbcDecryptor`, `bundle_session_key` | `cg_cbc_*`, `cg_crypto_bundle_session_key` |
| `path_guard` | base + relative path: an accepted path stays strictly inside its base | `paths::resolve_path_inside`, `resolve_manifest_target_path`, `builtin_asset_path` | `cg_paths_*` |

Campaign on the Mac above, 6 runs of 9 minutes per target
and core (54 minutes each), all 22 fuzzers at once: about 20 fuzzer-hours. The
host has 18 cores and ran at load 40 to 60, so the CPU time is lower (about 16
CPU-hours). CI (`fuzz_smoke`) runs every target for 20 s per core on each pull
request (the Rust targets unoptimized there, to build within the time cap).

| Target | Rust executions | C executions |
| --- | --- | --- |
| `aes_cbc` | 11.9 M | 118.1 M |
| `brotli` | 1.2 M | 2.5 M |
| `http_response` | 2.9 M | 3.9 M |
| `inflate` | 10.8 M | 297.8 M |
| `json` | 10.2 M (one run after the fix below) | 30.0 M |
| `manifest` | 13.1 M | 11.3 M |
| `path_guard` | 21.5 M | 165.4 M |
| `rsa_checksum` | 21.0 M | 185.2 M |
| `rsa_key` | 14.7 M | 26.8 M |
| `update_response` | 3.9 M | 4.6 M |
| `zip` | 2.1 M | 1.8 M |
| total | 113 M | 847 M |

The counts are not a quality comparison: the C targets call the platform zlib,
which is not instrumented, and the Rust targets allocate more, which ASan
slows down.

Found and fixed, each with a regression test in `core/tests/fuzz_regressions.rs`
that runs on both cores:

- **Rust, HTTP response headers (dependency).** ureq 2.12, the last 2.x
  release, panics when it reads a response header line that has no `:` (it
  slices past the end of the line). On an engine thread (update cycle,
  download) the panic ended the thread and left the update cycle marked as
  running until its 10-minute timeout; through the C ABI the call returned an
  internal error. `net.rs` now catches it and refuses the response with a
  network error. The C client skips such a line, as ureq intends: a documented
  difference.
- **Rust, JSON numbers.** serde_json's default float parser is not always
  correctly rounded: `1844670000000000000000791150157654596454443.0` came back
  as `1.8446699999999998e+42`, where the C core (`strtod`) gives `1.84467e+42`.
  The Rust core now enables serde_json's `float_roundtrip`: both cores parse and
  print the same.
- **Rust fuzz builds only.** A `debug_assert!` in `idna_adapter` (the
  ASCII-only adapter) fires on a redirect `Location` host with a
  percent-encoded non-ASCII byte. Shipped builds do not contain it; the fuzz
  targets now build with the shipped profile.
- **C:** no crash, leak, sanitizer report or timeout.

Follow-ups: OSS-Fuzz for continuous fuzzing (the targets already use the
libFuzzer interface), and a differential target that sends the same input to
both cores and compares their replies.

### Static analysis (C)

The first run reported 20 analyzer findings. One is the C11 Annex K advice,
now disabled. 11 came from `return cg_err_set(...)` paths the analyzer
followed as successes, because it reads one file at a time: `rt/err.h` and
`engine/fsutil.h` now tell it, under `__clang_analyzer__` only, that these
helpers always return false. None of the other 8 could happen at run time; each
got a defensive change: zero-initialized
buffers in `crypto/rsa.c` (Montgomery accumulator), `engine/archive.c`
(end-record search window) and `rt/json.c` (float digits, and `strtol` instead
of `atoi`), NULL checks in `engine/archive.c`, `rt/str.c` and `net_url.c`.
clang-tidy 18 (the CI version) found one more, real: `engine/apk.c` passed a
NULL array to `qsort` for an APK without entries, undefined behavior even with
a count of zero. It now sorts only two entries or more. The bugprone checks
found nothing else beyond style patterns, which `core-c/.clang-tidy` disables
with the reason.

### Hardening of the shipped libraries

| | Rust | C |
| --- | --- | --- |
| Integer overflow | `overflow-checks = true` (panic) | not checked (`-fwrapv` not adopted: AES-CBC and SHA-256 were 2-3% slower in the medians, inside the noise but not free; UBSan checks it in CI) |
| Stack buffer overflow | safe code | `-fstack-protector-strong` (already the NDK default, now explicit for every toolchain) |
| libc bounds checks | n/a | `-D_FORTIFY_SOURCE=3` in optimized builds (the NDK and Apple SDK default to 2) |
| Uninitialized stack variables | the compiler refuses them | `-ftrivial-auto-var-init=zero` |
| Android `.so` | full RELRO + `BIND_NOW`, non-executable stack: explicit link arguments (they were already the NDK linker's defaults; checked with `llvm-readelf`) | the same |
| `-fbounds-safety` | n/a | not adopted. Xcode 27.1's clang has it for iOS and macOS, but it is not drop-in: unannotated pointers become single-object pointers, and six parser files (`rt/json.c`, `engine/archive.c`, `engine/manifest.c`, `net.c`, `crypto/rsa.c`, `paths.c`) give 691 errors until every buffer pointer gets `__counted_by` / `__sized_by` annotations. The NDK's clang 19 has no support, so the annotations would be macros that do nothing on Android. A separate porting effort. |

Cost, host micro-benchmarks (`cargo test --release --test perf -- --ignored`,
C through `CAPGO_CORE_LIB`), the four variants interleaved, pooled medians:

| Operation | Rust before → after | C before → after |
| --- | --- | --- |
| SHA-256 (100 MiB) | 2694 → 2669 MB/s (-0.9%) | 2619 → 2646 MB/s (+1.0%) |
| AES-128-CBC decrypt | 1544 → 1530 MB/s (-0.9%) | 1732 → 1756 MB/s (+1.4%) |
| unzip (inflate + CRC + write) | 6087 → 6203 MB/s (+1.9%) | 6903 → 7229 MB/s (+4.7%) |
| RSA public operation per checksum | 25.9 → 26.0 µs | 18.4 → 18.6 µs (+1%) |

Pooled over three passes: 26 runs per variant, and 130 loops of 5000 for RSA.
Single runs spread by about ±6%, so only the C RSA cost (+1%, the same sign in
every pass; probably the zero-initialized Montgomery buffers) is above the
noise. The host was busier than for `BENCHMARK.md`, so absolute numbers are
lower there.

Size, before and after the hardening (same sources):

| | Rust before → after | C before → after |
| --- | --- | --- |
| Android arm64-v8a `.so` | 3,056,240 → 3,118,656 B (+2.0%) | 902,920 → 911,112 B (+0.9%) |
| Android armeabi-v7a | 2,039,352 → 2,076,608 B (+1.8%) | 660,060 → 671,484 B (+1.7%) |
| Android x86 | 3,612,132 → 3,655,460 B (+1.2%) | 928,468 → 942,404 B (+1.5%) |
| Android x86_64 | 3,498,512 → 3,559,920 B (+1.8%) | 912,680 → 929,192 B (+1.8%) |
| iOS arm64 executable (a minimal app linking the static library, dead-stripped and stripped) | 3,374,176 → 3,425,968 B (+1.5%) | 795,480 → 811,880 B (+2.1%) |

The Rust overflow checks cost 1.2-2.0% of size. Correctly rounded floats
(`float_roundtrip`, above) add another 41 KB to the Rust arm64 `.so` and 54 KB
to the iOS executable.

### Contained: the app keeps running

| | Rust | C |
| --- | --- | --- |
| Bug on the host's calling thread | the panic is caught at the C ABI / JNI boundary: the call returns an error | the process dies |
| Bug on an engine thread (update cycle, download, stats) | the panic ends that thread; the app goes on (an interrupted update cycle blocks new ones until its 10-minute stuck timeout) | the process dies |
| Native crash during a download or a bundle switch, again and again | crash-loop breaker (below) | the same breaker |
| Downloads in a separate Android process | no (below) | no |

### Crash-loop breaker

Same behavior in both cores (`core/src/engine/crash_guard.rs`,
`core-c/src/engine/crash_guard.c`), tested by `core/tests/plugin.rs` on both:

- **Steps.** `download`: the transfer, verification, decryption and extraction
  of a bundle (zip or manifest; in-process, plugin `download()`, update cycle or
  Android download job). `set`: switching to a new bundle until the reload
  returns (`set()`, direct update, install at background, `reload()` with a
  pending bundle). Switching to the builtin bundle is not guarded.
- **Marker.** While a step runs, `CapacitorUpdater.crashGuard` (a new key; older
  versions never read it) holds per version `{step, id, attempts, active,
  process, pid, background, failed}`. A clean end, success or handled error,
  removes the record, so only deaths in a row count.
- **Counting, at the next plugin load.** A record still running for another
  process (a random token per process, so a reused pid or a second engine of the
  same process is not a death) is a death:
  - With Android's report of that pid (`previousExits`): counted only for a
    crash, a native crash or an ANR. A user or low-memory kill is not.
  - Without a report (iOS, Android before 11): counted only when the step ran
    in the foreground. The OS stops background apps at will, and a user who
    closes the app sends it to the background first.
- **At 2 deaths in a row for the same version:**
  - The version is marked failed and its bundle record becomes ERROR.
  - If it was the current bundle, the app goes back to the last successful
    bundle, else builtin. This happens before the load returns the path, so the
    host never loads the failed bundle again. A pending `next` on it is cleared.
  - A `download_fail` or `set_fail` statistic is sent with
    `metadata.message = "native crash during <step> (2 in a row)"`.
  - The update cycle skips that version ("Latest version crashed the app
    natively. Aborting update.") until the server offers another one, which
    forgets the record. An explicit `download()` from JavaScript is still
    allowed.
- **Security gates are unchanged.** The breaker only adds an ERROR status, a
  rollback to an already trusted bundle and a skip.

### Android: downloads in a separate process, not done

Running the WorkManager download job in its own `android:process` would keep a
native crash there away from the app. The engine was built for one process, so
this is not safe without a redesign:

- **Storage.** The key-value storage is Capacitor's `SharedPreferences` file.
  Each process keeps its own copy and the last `commit()` wins, so bundle records
  and the `next` pointer written by the job would be lost or stale. The stats
  queue file and the job files have only in-process locks.
- **Completion.** The waiting `download()` call and the update cycle wake up on
  an in-memory condition variable (`scheduled.rs`). A job finishing in another
  process never wakes them.
- **Events.** Progress, `downloadComplete`, `updateAvailable` and
  `directUpdateFinish` are emitted by the job's engine, which would have no
  JavaScript listener.
- **Cancellation, cleanup and limits.** Cancellation, the launch cleanup (delta
  cache, `capgo_unzip_*` folders, bundle folders), the per-path partial-file
  locks and the rate limit are per process.

A redesign would need cross-process storage with file locks (or one writer and
IPC), completion and progress through WorkManager's `WorkInfo`, and cleanup that
respects a live job's files. A smaller option: run only the risky native step
(TLS, unzip, brotli) in a helper process that returns a finished folder or an
error, with all state changes kept in the app process.

### What still kills the app

- **C:** any memory fault or abort in the core or its dependencies (Mbed TLS,
  the Brotli decoder, the platform zlib): there is nothing to catch it. The
  breaker stops it from repeating at every launch in the steps it guards.
- **Both:**
  - An allocation failure: Rust's allocator aborts, and so does `cg_malloc`.
  - A fault in C or assembly code of a dependency (Rust: `ring`).
  - A crash of the host's own native code or WebView.
  - Stack overflow: JSON nesting is capped at 128 in both, and no other
    recursion follows untrusted input.
- **System RNG failure:** C aborts; Rust panics, which is then contained like
  any other panic.

## Verdict

C ships 3 to 4 times less code. It is on par on iOS and on Android cold start
and faster on large Android manifests (21-35%). On the host micro-benchmarks
it is faster on AES, unzip and RSA, and 2% slower on SHA-256. A few small
device cells are still slower with C: the iOS 2-file plain direct case by
6 ms, the others by at most 7 ms on iOS and 5% on Android.
It costs 65% more source lines to maintain, hand-written replacements for
the HTTP client, URL parser, zip reader and JSON, and memory safety that has
to be enforced by sanitizers, Valgrind, static analysis and fuzzing in CI
instead of by the compiler. Both cores now have the same crash-loop breaker
and fuzz targets; the remaining safety difference is containment: a Rust bug
becomes a caught panic, a C bug ends the process.
