# Experimental HTTP/3 in the shared cores

This branch adds HTTP/3 to the libraries themselves. Rust uses quinn + h3 over
rustls; C uses ngtcp2 + nghttp3 over picotls with Mbed TLS crypto. Android and iOS
keep the existing host certificate-verification callback. No platform HTTP
transport callback is needed.

`http3` defaults to `false`. Set it in the CapacitorUpdater plugin configuration
to enable the experiment. `http3Connections` limits the QUIC connections per
origin, defaults to 4, and is capped at 32. Zero selects the default. The same
options and rules apply to both cores.

## Request rules

- An HTTPS response must advertise `h3` in Alt-Svc before the core tries QUIC.
  Alternatives on a different host are ignored. At most 16 origins are persisted,
  with an expiry capped at seven days.
- HTTP proxies keep the existing HTTP/1.1 path. Cleartext URLs also keep HTTP/1.1.
- A QUIC connection attempt takes at most three seconds, bounded further by the
  request timeout. Failure falls back to HTTP/1.1 and backs off that origin for
  five minutes, doubling after later failures. A non-idempotent request is not
  replayed after it may have reached the server.
- Parallel manifest files spread across several QUIC connections. A single zip
  transfer uses one connection.
- Redirect limits, HTTPS downgrade guards, response size limits, Range resume,
  cancellation, checksums, encryption and signature checks stay in the core.
- Certificate-chain trust and pinning remain the host's decision. The library also
  checks the hostname and the TLS handshake signature before application traffic.

## C dependency integration

CMake downloads pinned archives and checks their SHA-256 digests. The sources are
compiled into the same static archive or shared library, including on iOS.

- ngtcp2 1.25.0 and nghttp3 1.18.0 implement QUIC and HTTP/3.
- picotls commit `112054bc74e6d2be646421a7a134ebdf7ea038f9` implements TLS 1.3.
- The ngtcp2 picotls adapter uses Mbed TLS's picotls algorithm objects in place of
  the OpenSSL objects. It retains the upstream protocol implementation.
- picotls's Mbed TLS adapter passes the actual output capacity to PSA. Its
  upstream SIZE_MAX capacity caused Mbed TLS 3.6 to attempt an impossible
  allocation and abort. The configure-time patch is in CMakeLists.txt.
- The optional picotls event logger is disabled. ThreadSanitizer found a race in
  its lazy log-point cache. Core protocol logging remains enabled.
- Connection failure marks the connection before releasing the request reference.
  This prevents a use-after-free when another request concurrently retires it.
  Enqueueing also checks for a connection that closed after selection.

The C client owns one thread per QUIC connection. Rust drives its connections on
two Tokio threads. Building the Rust core requires Rust 1.85 or newer. Dependency
license notices ship in `core/HTTP3-LICENSES.txt`.

## Verification

The same C ABI tests in `core/tests/net_h3.rs` run against either implementation.
They cover discovery and persistence, disabling HTTP/3, blocked UDP and connection
failure, redirects, resume, body limits and length mismatches, timeouts,
cancellation, parallel connections, request header filtering, certificate rejection, forged handshake
signatures, ChaCha20-Poly1305, concurrent connection failures, and installation/checksum rejection of manifest
files delivered over HTTP/3.

`alt_svc` is a shared fuzz target with the same seed corpus for both cores. CI's
fuzz smoke includes it. The new C paths also run under AddressSanitizer,
UndefinedBehaviorSanitizer and ThreadSanitizer.

See [the benchmark report](BENCHMARK-CORE-HTTP3.md) for native runs, size costs and
limits of the experiment.
