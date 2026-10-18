# HTTP/3 trial records

See [the report](../../BENCHMARK-CORE-HTTP3.md) for the method and interpretation.

- `main-runs.jsonl` contains the three primary normal-network workloads, excluding
  warm-ups and exploratory cases. Each case has five repeats per core, protocol
  configuration and platform.
- `lossy-runs.jsonl` contains the Android latency/loss trials, including failed
  attempts if any. The app starts without payload warm-ups in this profile.
- `retune-runs.jsonl` contains the matched Rust manifest follow-up after fixing
  its 16-connection cap. The requested-32 Rust arm in the original loss matrix
  used 16 connections, as the server log confirms. The follow-up uses binary
  behavior from `2d0c91b4` and compares HTTP/1.1 with actual 32-connection HTTP/3.
- `manifest-connections.json` counts distinct Caddy remote ports per manifest
  version and checks its status, request count and bytes against the updater record.
- `*-summary.json` groups successful attempts and retains every timing sample.
  Failure counts must be read from the result records, not from these summaries.
- `protocol-runs.jsonl` counts payload requests observed independently by Caddy
  during each app invocation. Main round 1 on iOS includes four extra exploratory
  workloads. Other main invocations include two payload warm-ups. Lossy invocations
  have no payload warm-ups. Older records without `network` belong to `main`.
- `qdisc-deltas.json` retains per-invocation packet, byte and drop deltas for
  both Linux netem queues. These include queue-limit drops as well as random loss.
- `diagnostic-*-syscalls.txt` contains separate instrumented runs, excluded from
  the timing matrix. `strace -f -cw` sums time across threads, so these seconds
  are not elapsed download time or a CPU comparison.
- `sizes-android.json` compares stripped shared libraries and gzip level 9 sizes.
  `sizes-ios.json` compares tiny linked arm64 simulator ABI drivers with dead
  stripping. Neither is an app-store download measurement.

The baseline is `da0ce184`. The measured transport implementation is `e07b3026`.
Later shared tests align filtering of caller-supplied `TE` headers, enforce a
32-connection cap in both cores, and verify that failed Rust origins release
their pools. A test-only C batch runner now obeys its requested concurrency. The
engine's original measured requests never send `TE`; the original workloads use
one origin. The corrected cap is measured separately in `retune-runs.jsonl`.

Times are milliseconds. A successful record means the updater resolved its
installation operation after its checksum checks. `requests == expectedDownloads`
and `requestBytes == servedBytes` are also checked by the collection script.
Manifest byte counts vary slightly with the generated version identifier.
