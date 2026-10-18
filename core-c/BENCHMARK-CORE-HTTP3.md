# Native core HTTP/3 experiment

This experiment puts HTTP/3 in the C and Rust libraries. Each core is compared
with its own HTTP/1.1 client in the same release app. HTTP/3 remains opt-in.
See [the implementation notes](HTTP3.md).

## Method

Measured starting October 17, 2026 UTC, on one 18-core Apple silicon Mac. The
iOS device is an iPhone 18 Pro simulator on iOS 27.0; Android is an API 36 arm64 emulator, using
QEMU's host alias. These are simulated devices, not physical phones.

Caddy serves HTTPS/HTTP/1.1 and HTTP/3 on port 9443 and proxies the benchmark
server on port 3293. Both cores use the same certificate-verification callbacks
as before. The benchmark-only CA is trusted by the test apps. The two apps for
each core differ only in their `http3` configuration; the default pool in this
comparison is four QUIC connections per origin.

Times are `totalMs` from the live-update benchmark: background download,
validation and installation. The normal-network runs exclude two warm-ups per
launch. Each measured case has five runs. HTTP/1.1 and HTTP/3 runs are interleaved; their order reverses
between rounds. The simulator stays booted. The normal-network matrix runs
without builds.
The Mac is shared with other applications, so the ranges matter.

Every successful update passes the engine's checksum gate. Result records retain
the payload request count and byte count. Caddy access logs independently record
the actual protocol, status and response bytes for each run.

The shaped suite limits payload delivery to 40 Mbit/s shared and waits 80 ms before
each response. This is application-level shaping, not 80 ms of network RTT or
packet loss. A 30 MiB payload needs at least about 6.3 seconds at that rate.

## Results

Keep this transport opt-in. Both libraries improve the tested lossy Android path
when the manifest pool is tuned. The 32-connection results are close within their
observed ranges, while C has a smaller binary cost. The default four-connection
manifest pool is slower than HTTP/1.1 on this profile. The bandwidth-limited
normal-network case shows no measurable change.

The 120 primary normal-network updates all succeeded. The 40 Mbit/s case is
network-limited and shows no measurable difference. Loopback results are
inconclusive as an adoption decision: the iOS ranges are wide, and no CPU or
scheduler profile isolates the cause of the smaller Android gaps. Android's
four-connection HTTP/3 manifest configuration measured slower in these runs.

Times below are median milliseconds with the minimum and maximum in brackets.
There are five samples per cell. Zip is 3 MiB, manifest is 200 files / 20 MiB,
and shaped zip is 30 MiB.

| Platform | Core | Workload | HTTP/1.1 ms | HTTP/3 ms, four connections |
| --- | --- | --- | ---: | ---: |
| ios | rust | Zip | 113 [15, 160] | 85 [27, 162] |
| ios | rust | Manifest | 1,179 [80, 1,834] | 313 [261, 541] |
| ios | rust | Shaped zip | 6,432 [6,404, 6,563] | 6,459 [6,412, 6,567] |
| ios | c | Zip | 59 [14, 122] | 89 [56, 117] |
| ios | c | Manifest | 1,587 [613, 1,747] | 408 [220, 1,096] |
| ios | c | Shaped zip | 6,428 [6,417, 6,487] | 6,423 [6,389, 6,583] |
| android | rust | Zip | 59 [57, 66] | 61 [54, 69] |
| android | rust | Manifest | 161 [149, 175] | 190 [174, 194] |
| android | rust | Shaped zip | 6,417 [6,411, 6,420] | 6,418 [6,412, 6,424] |
| android | c | Zip | 65 [62, 90] | 61 [49, 63] |
| android | c | Manifest | 143 [123, 171] | 193 [167, 204] |
| android | c | Shaped zip | 6,393 [6,391, 6,403] | 6,394 [6,389, 6,408] |

The shaped zip takes about 6.4 seconds, close to the 6.3-second payload lower
bound plus the configured response delay. A faster transport cannot remove that
server bandwidth limit.

### Android latency and loss

The rooted Android emulator uses Linux netem on eth0 egress and an ingress IFB,
with 75 ms delay, 1% configured random loss and a 1,000-packet queue in each
direction. Counters include both random loss and queue-limit drops, so observed
loss need not be exactly 1%. An ICMP check measured 151.3 to 154.1 ms RTT,
compared with 0.14 to 0.17 ms before shaping. Receive coalescing
was disabled before the runs; segmentation offload was already off. Per-run
queue counters record actual drops. QEMU's TCP proxy is still part of this path.

These runs start a fresh app without payload warm-ups. All settings use the same
32 manifest workers on the four-CPU emulator. HTTP/1.1 may open one connection
per active worker; HTTP/3 is tested with pools of 4, 8 and 32. Zip uses one
connection, so its HTTP/3 comparison only uses the default pool size.

All 60 updates succeeded on the first attempt. The tail of host core-test
execution overlapped the first lossy Rust HTTP/1.1 sample; that sample is retained.
Every payload response was 200,
and all HTTP/3-labeled payloads used HTTP/3. The configured loss is 1% per queue;
observed invocation-level drop rates across the original and follow-up runs were
0.57% to 1.37% on egress and 0.80% to 2.78% on ingress, including the queue limit.

Median seconds, with minimum and maximum in brackets; five runs per cell:

| Workload | Transport / pool | Rust seconds | C seconds |
| --- | --- | ---: | ---: |
| Zip, 3 MiB | HTTP/1.1 | 65.56 [61.13, 69.03] | 68.87 [61.59, 72.95] |
| Zip, 3 MiB | HTTP/3, 4 connections | 18.52 [2.03, 20.37] | 20.01 [16.91, 21.81] |
| Manifest, 200 files / 20 MiB | HTTP/1.1 | 16.17 [15.55, 17.77] | 17.55 [16.49, 22.45] |
| Manifest, 200 files / 20 MiB | HTTP/3, 4 connections | 32.90 [30.20, 35.65] | 34.60 [28.57, 35.42] |
| Manifest, 200 files / 20 MiB | HTTP/3, 8 connections | 15.53 [13.93, 16.35] | 14.96 [12.44, 16.15] |
| Manifest, 200 files / 20 MiB | HTTP/3, requested 32 | 6.05 [5.07, 7.28], actually 16 | 4.88 [4.49, 5.03], actually 32 |

HTTP/3 is faster for the zip on this profile. For the manifest, the four-connection
pool is slower than HTTP/1.1. C with 32 connections outperforms its baseline.
The initial Rust requested-32 arm actually used 16 connections, as confirmed by
Caddy remote ports. Rust had a hidden 16-connection cap; a shared regression test
now enforces the documented cap of 32. The corrected Rust comparison follows
below. Eight connections are intermediate, and Rust's eight-connection range
overlaps its HTTP/1.1 range. The Rust zip range includes a 2.03-second outlier;
its request count, full response bytes and HTTP/3 protocol were verified.

This supports testing an opt-in transport with a tuned pool. It does not support
turning HTTP/3 on by default or declaring a general winner between the C and Rust
libraries. QEMU's TCP proxy, these payloads and this queue configuration are part
of the result. Physical phones and carrier paths remain unmeasured.

[Raw result records and summaries](benchmarks/core-http3/) include request and
byte counts. The protocol log records Caddy's independently observed protocol.

### Corrected Rust pool comparison

After the cap fix, five new cold-launch rounds interleave the corrected Rust
HTTP/1.1 and HTTP/3 apps, reversing their order between rounds. All ten updates
succeeded on the first attempt. Caddy confirms 32 connections for every manifest
in both arms, with 202 successful payload responses and the expected bytes.

| Rust follow-up | Median seconds | Minimum | Maximum |
| --- | ---: | ---: | ---: |
| HTTP/1.1 | 17.38 | 15.84 | 23.79 |
| HTTP/3, actual 32 connections | 4.80 | 4.44 | 4.88 |

The corrected Rust median is close to C's 4.88-second median in the original
32-connection arm, with overlapping ranges. Those two library arms were not
interleaved in the follow-up, so this is not evidence of a general library
performance ranking.

### Diagnostic runs

Separate instrumented runs record waits in futex and poll/epoll. These correspond
to the C connection loop and stream condition waits in `h3.c`, and Rust's blocking
body reader over the Tokio driver in `h3.rs`. The traces sum waiting time across
threads and add instrumentation overhead. They do not isolate a CPU cause for a
cross-library speed difference. The inference from the pool sweep is limited to
transport concurrency being important under this emulated network profile.

## Binary size

Baseline `da0ce184` and the final experiment source were built with the same
toolchains and release flags. Android entries are stripped `.so` files, one ABI per device.
Gzip columns use level 9; they estimate compression, not an app-store download.

| Core | Android ABI | Baseline bytes | With HTTP/3 | Added bytes | Added gzip bytes |
| --- | --- | ---: | ---: | ---: | ---: |
| c | arm64-v8a | 911,224 | 1,408,696 | 497,472 | 235,675 |
| c | armeabi-v7a | 671,548 | 1,044,080 | 372,532 | 231,568 |
| c | x86 | 942,516 | 1,508,888 | 566,372 | 266,507 |
| c | x86_64 | 929,288 | 1,460,792 | 531,504 | 246,442 |
| rust | arm64-v8a | 3,159,616 | 4,446,064 | 1,286,448 | 529,623 |
| rust | armeabi-v7a | 2,109,216 | 2,953,976 | 844,760 | 485,490 |
| rust | x86 | 3,704,608 | 5,202,784 | 1,498,176 | 644,431 |
| rust | x86_64 | 3,606,064 | 5,000,688 | 1,394,624 | 563,645 |

For iOS, a small arm64 simulator executable calls the engine ABI and links each
core with `-Os` and dead stripping. Both baseline and experiment drivers are
relinked with the same flags. This measures linked executables rather than
static archive size. It is not a measurement of the final production IPA.

| Core | Baseline executable bytes | With HTTP/3 | Added bytes |
| --- | ---: | ---: | ---: |
| c | 873,872 | 1,357,008 | 483,136 |
| rust | 3,927,808 | 5,885,936 | 1,958,128 |

The libraries are compiled into the core even when the runtime `http3` option is
off, so opting out does not remove this size cost.

## Correctness checks

- Both cores pass 275 core tests, including the same 22 HTTP/3 C ABI tests.
- C passes the HTTP/3 suite under AddressSanitizer, UndefinedBehaviorSanitizer and
  ThreadSanitizer, including concurrent connection failures.
- Both implementations pass a 20-second Alt-Svc fuzz smoke using the shared
  corpus. Rust executed 296,623 inputs; C executed 2,770,024.
- Full project verification builds iOS and Android, runs Android JVM tests, and
  builds Web for both cores.
- Formatting, lint and Rust Clippy checks pass.

## Limits

No physical-device, carrier-network or lossy iOS measurements are included. The
new native performance runs cover plain bundles in background mode. Encryption,
direct updates and larger data matrices remain covered by the existing behavior
tests or earlier benchmarks, not by this new transport comparison. A short fuzz
smoke and sanitizers do not establish that the protocol libraries are free of
bugs. At a 32-connection limit, C can own 32 QUIC threads; Rust uses two Tokio
driver threads. This trial does not measure battery use or the memory cost of
that choice.
