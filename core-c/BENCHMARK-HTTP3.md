# HTTP/3 through the platform network stack: benchmark

Measured on October 17, 2026, on one Apple silicon Mac, with the live-update bench
(`scripts/bench`) on the iOS simulator (iPhone 18 Pro) and on a fresh clone of the
`capgo_mem_api36` emulator (API 36, arm64).

Each core is measured in two builds of the same app:

- **host**: the plugin as shipped. Requests go through the `http_request` host transport
  (URLSession on iOS, `HttpEngine` on Android).
- **HTTP/1.1**: the same core with `systemHttp: false`, so the core's own HTTP/1.1 client
  over TLS is used (rustls in the Rust core, Mbed TLS in the C core).

## Setup

- **Server.** Caddy 2.11.7 served the updater: update, stats and channel endpoints, zips
  and manifest files. It ran on port 9443 with `protocols h1 h2 h3`, its internal CA, and
  `Alt-Svc: h3`. Caddy reverse-proxies to the bench server. bench.js still drives the cases
  over plain HTTP (`BENCH_UPDATER_BASE_URL`).
- **iOS.** The Caddy root was added to the simulator keychain with
  `simctl keychain add-root-cert`.
- **Android.** The Caddy root was trusted two ways:
  - in the release network security config of the bench build only (`BENCH_TRUST_CA`);
  - in the emulator's system CA store (a tmpfs over the conscrypt APEX directory, as root).

  The system store is needed for HTTP/3. HttpEngine (Chromium) only uses QUIC for
  certificates that chain to a system root. With the CA in the app's network security
  config only, every request used HTTP/2. Production servers with public certificates are
  system roots.
- **Interleaving.** For each platform, the 4 apps (Rust/C × host/HTTP/1.1) were built
  first. Then 3 rounds ran, each running the 4 apps in turn. Every cell has 3 runs, shown
  as median (min-max) of `totalMs`. Two warm-up cases per app launch are excluded.
- **Suites.**
  - main: zip 3/30/300 MB and manifests of 2/20/200/2000 files, background and direct,
    plain and encrypted;
  - shaped: plain, background, 80 ms before every payload response, 40 Mbit/s shared.
- **Lossy profile.** It ran on Android only, with `tc netem` inside the emulator on eth0,
  with ingress going through ifb0. Each direction had 75 ms delay and 1% loss, so the
  round trip was 150 ms with about 2% loss. The rules are the same for TCP and UDP.
  - It could not run on iOS: the simulator uses the Mac's network stack, and shaping it
    (`dnctl` + `pfctl`) needs sudo, which was not available.
  - The emulator's own `network delay` command has no effect on eth0.

## Protocol actually negotiated

From Caddy's access log (`request.proto`). Manifest file paths carry the app label, so
each request can be counted per app.

| App | iOS | Android |
| --- | --- | --- |
| Rust, host | HTTP/3.0 (33,372 of 33,372 manifest files) | HTTP/3.0 (33,372 of 33,372) |
| C, host | HTTP/3.0 (33,372 of 33,372) | HTTP/3.0 (33,372 of 33,372) |
| Rust / C, `systemHttp: false` | HTTP/1.1 (all) | HTTP/1.1 (all) |

- **iOS.** URLSession uses HTTP/3 from the first request, because of
  `assumesHTTP3Capable`.
- **Android, first request.** HttpEngine's first request to an origin uses HTTP/2. Its
  `Alt-Svc` gives the origin a QUIC hint, the transport builds a new engine, and every
  later request uses HTTP/3.
  - Without that rebuild, HttpEngine kept the origin on its HTTP/2 connection for the
    whole process.
  - The hints are kept for the next launches.
- **Core log.** The core logs `System HTTP transport: h3 with <host>` at debug level when
  the protocol for a host changes.

## Pinning checks

Both runs used the HTTP/3 build.

| Platform | Wrong pin | Correct pin (Caddy root key) |
| --- | --- | --- |
| iOS (ATS `NSPinnedDomains`, `NSPinnedCAIdentities`) | refused ("The certificate for this server is invalid"); no request reached Caddy | ok over HTTP/3 |
| Android (network security config `pin-set`) | refused (`net::ERR_CERT_AUTHORITY_INVALID`, mapped to `tls`); no request reached Caddy | ok over HTTP/3 |

## Results

### iOS simulator (loopback, no RTT)

| Cell | Rust, HTTP/1.1 | Rust, host | Change | C, HTTP/1.1 | C, host | Change |
| --- | --- | --- | --- | --- | --- | --- |
| zip-3MB-plain-background | 12 ms (11 ms-19 ms) | 66 ms (42 ms-237 ms) | +450% | 13 ms (12 ms-14 ms) | 128 ms (23 ms-297 ms) | +885% |
| zip-30MB-plain-background | 35 ms (33 ms-50 ms) | 1146 ms (154 ms-1191 ms) | +3174% | 48 ms (32 ms-54 ms) | 1446 ms (177 ms-1536 ms) | +2913% |
| zip-300MB-plain-background | 471 ms (229 ms-513 ms) | 9903 ms (1524 ms-11.3 s) | +2003% | 420 ms (219 ms-506 ms) | 11.5 s (2088 ms-11.7 s) | +2629% |
| manifest-2f-20KB-plain-background | 8 ms (8 ms-14 ms) | 12 ms (7 ms-97 ms) | +50% | 16 ms (10 ms-18 ms) | 38 ms (7 ms-115 ms) | +138% |
| manifest-20f-2MB-plain-background | 15 ms (12 ms-24 ms) | 119 ms (22 ms-154 ms) | +693% | 35 ms (17 ms-44 ms) | 95 ms (28 ms-196 ms) | +171% |
| manifest-200f-20MB-plain-background | 63 ms (62 ms-179 ms) | 1454 ms (142 ms-1796 ms) | +2208% | 135 ms (61 ms-136 ms) | 1518 ms (175 ms-2083 ms) | +1024% |
| manifest-2000f-200MB-plain-background | 585 ms (584 ms-1097 ms) | 14.4 s (1575 ms-17.5 s) | +2366% | 1140 ms (556 ms-1184 ms) | 7958 ms (1899 ms-15.3 s) | +598% |
| zip-3MB-plain-direct | 35 ms (33 ms-53 ms) | 148 ms (78 ms-239 ms) | +323% | 49 ms (31 ms-51 ms) | 265 ms (46 ms-313 ms) | +441% |
| zip-30MB-plain-direct | 71 ms (59 ms-92 ms) | 963 ms (253 ms-1223 ms) | +1256% | 84 ms (55 ms-84 ms) | 1041 ms (204 ms-1186 ms) | +1139% |
| zip-300MB-plain-direct | 250 ms (237 ms-650 ms) | 9084 ms (1980 ms-10.2 s) | +3534% | 478 ms (237 ms-535 ms) | 10.5 s (1683 ms-10.7 s) | +2088% |
| manifest-2f-20KB-plain-direct | 31 ms (30 ms-48 ms) | 79 ms (33 ms-84 ms) | +155% | 45 ms (32 ms-48 ms) | 54 ms (34 ms-73 ms) | +20% |
| manifest-20f-2MB-plain-direct | 36 ms (35 ms-65 ms) | 96 ms (48 ms-335 ms) | +167% | 51 ms (36 ms-53 ms) | 304 ms (50 ms-448 ms) | +496% |
| manifest-200f-20MB-plain-direct | 84 ms (84 ms-139 ms) | 1183 ms (207 ms-2068 ms) | +1308% | 133 ms (84 ms-220 ms) | 1527 ms (231 ms-1787 ms) | +1048% |
| manifest-2000f-200MB-plain-direct | 601 ms (589 ms-1205 ms) | 14.9 s (1842 ms-17.4 s) | +2378% | 1122 ms (597 ms-1303 ms) | 14.5 s (1790 ms-16.6 s) | +1195% |
| shaped-zip-30MB-plain-background | 6385 ms (6384 ms-6394 ms) | 6401 ms (6395 ms-6462 ms) | +0% | 6386 ms (6382 ms-6410 ms) | 6437 ms (6394 ms-6520 ms) | +1% |
| shaped-manifest-200f-20MB-plain-background | 4279 ms (4273 ms-4288 ms) | 4278 ms (4275 ms-4638 ms) | 0% | 4283 ms (4275 ms-4290 ms) | 4281 ms (4276 ms-4730 ms) | 0% |
| shaped-manifest-2000f-20MB-plain-background | 4301 ms (4298 ms-4360 ms) | 4299 ms (4298 ms-12.7 s) | 0% | 4321 ms (4295 ms-4323 ms) | 10.4 s (4296 ms-11.8 s) | +142% |
| zip-3MB-enc-background | 18 ms (15 ms-33 ms) | 27 ms (26 ms-289 ms) | +50% | 16 ms (10 ms-31 ms) | 44 ms (25 ms-81 ms) | +175% |
| zip-30MB-enc-background | 57 ms (36 ms-91 ms) | 164 ms (163 ms-1017 ms) | +188% | 53 ms (38 ms-57 ms) | 881 ms (182 ms-1296 ms) | +1562% |
| zip-300MB-enc-background | 561 ms (283 ms-642 ms) | 1673 ms (1631 ms-10.7 s) | +198% | 463 ms (228 ms-586 ms) | 8099 ms (1647 ms-9650 ms) | +1649% |
| manifest-2f-20KB-enc-background | 11 ms (9 ms-16 ms) | 9 ms (7 ms-171 ms) | -18% | 17 ms (11 ms-27 ms) | 93 ms (7 ms-170 ms) | +447% |
| manifest-20f-2MB-enc-background | 25 ms (15 ms-27 ms) | 24 ms (24 ms-215 ms) | -4% | 39 ms (16 ms-74 ms) | 337 ms (27 ms-464 ms) | +764% |
| manifest-200f-20MB-enc-background | 123 ms (98 ms-144 ms) | 231 ms (194 ms-1792 ms) | +88% | 159 ms (94 ms-174 ms) | 1973 ms (230 ms-2048 ms) | +1141% |
| manifest-2000f-200MB-enc-background | 1167 ms (887 ms-1421 ms) | 2346 ms (2186 ms-15.6 s) | +101% | 1417 ms (900 ms-1454 ms) | 13.5 s (1840 ms-15.9 s) | +853% |
| zip-3MB-enc-direct | 65 ms (35 ms-112 ms) | 50 ms (50 ms-190 ms) | -23% | 54 ms (31 ms-68 ms) | 94 ms (45 ms-358 ms) | +74% |
| zip-30MB-enc-direct | 95 ms (62 ms-121 ms) | 201 ms (184 ms-1164 ms) | +112% | 86 ms (57 ms-99 ms) | 1026 ms (185 ms-1241 ms) | +1093% |
| zip-300MB-enc-direct | 494 ms (300 ms-682 ms) | 1845 ms (1639 ms-10.1 s) | +273% | 365 ms (303 ms-613 ms) | 9447 ms (1537 ms-9865 ms) | +2488% |
| manifest-2f-20KB-enc-direct | 43 ms (31 ms-46 ms) | 32 ms (31 ms-128 ms) | -26% | 34 ms (32 ms-65 ms) | 50 ms (30 ms-86 ms) | +47% |
| manifest-20f-2MB-enc-direct | 59 ms (40 ms-63 ms) | 51 ms (50 ms-218 ms) | -14% | 39 ms (37 ms-64 ms) | 294 ms (48 ms-306 ms) | +654% |
| manifest-200f-20MB-enc-direct | 186 ms (124 ms-224 ms) | 269 ms (198 ms-1507 ms) | +45% | 122 ms (121 ms-201 ms) | 1927 ms (208 ms-2345 ms) | +1480% |
| manifest-2000f-200MB-enc-direct | 1386 ms (918 ms-1602 ms) | 1934 ms (1873 ms-15.5 s) | +40% | 903 ms (861 ms-1452 ms) | 14.4 s (1910 ms-15.2 s) | +1496% |

HTTP/3 on the iOS simulator over loopback is slower than the core's HTTP/1.1, and the
results are bimodal. The same cell runs either at about 200 MB/s (the minima, for example
300 MB in 1.5 s) or at about 30 MB/s (300 MB in 10-11 s). Most medians fall in the slow
mode.

The cost comes from QUIC over loopback, not from the transport. The same URLSession
transport over HTTP/2 (Caddy restarted with `protocols h1 h2`, run right after, plain
only) is close to the core's client, except for some Rust cells:

| Cell | Rust, HTTP/1.1 | Rust, host h2 | Change | C, HTTP/1.1 | C, host h2 | Change |
| --- | --- | --- | --- | --- | --- | --- |
| zip-3MB-plain-background | 12 ms (11 ms-19 ms) | 15 ms (14 ms-16 ms) | +25% | 13 ms (12 ms-14 ms) | 13 ms (13 ms-14 ms) | 0% |
| zip-30MB-plain-background | 35 ms (33 ms-50 ms) | 64 ms (58 ms-78 ms) | +83% | 48 ms (32 ms-54 ms) | 56 ms (55 ms-57 ms) | +17% |
| zip-300MB-plain-background | 471 ms (229 ms-513 ms) | 492 ms (431 ms-548 ms) | +4% | 420 ms (219 ms-506 ms) | 431 ms (423 ms-483 ms) | +3% |
| manifest-2f-20KB-plain-background | 8 ms (8 ms-14 ms) | 7 ms (6 ms-8 ms) | -12% | 16 ms (10 ms-18 ms) | 6 ms (6 ms-7 ms) | -62% |
| manifest-20f-2MB-plain-background | 15 ms (12 ms-24 ms) | 18 ms (16 ms-19 ms) | +20% | 35 ms (17 ms-44 ms) | 16 ms (15 ms-16 ms) | -54% |
| manifest-200f-20MB-plain-background | 63 ms (62 ms-179 ms) | 102 ms (96 ms-113 ms) | +62% | 135 ms (61 ms-136 ms) | 89 ms (87 ms-94 ms) | -34% |
| manifest-2000f-200MB-plain-background | 585 ms (584 ms-1097 ms) | 833 ms (820 ms-834 ms) | +42% | 1140 ms (556 ms-1184 ms) | 885 ms (803 ms-899 ms) | -22% |
| zip-3MB-plain-direct | 35 ms (33 ms-53 ms) | 37 ms (35 ms-45 ms) | +6% | 49 ms (31 ms-51 ms) | 34 ms (33 ms-34 ms) | -31% |
| zip-30MB-plain-direct | 71 ms (59 ms-92 ms) | 81 ms (81 ms-86 ms) | +14% | 84 ms (55 ms-84 ms) | 81 ms (78 ms-83 ms) | -4% |
| zip-300MB-plain-direct | 250 ms (237 ms-650 ms) | 467 ms (458 ms-493 ms) | +87% | 478 ms (237 ms-535 ms) | 474 ms (445 ms-521 ms) | -1% |
| manifest-2f-20KB-plain-direct | 31 ms (30 ms-48 ms) | 33 ms (32 ms-33 ms) | +6% | 45 ms (32 ms-48 ms) | 32 ms (29 ms-33 ms) | -29% |
| manifest-20f-2MB-plain-direct | 36 ms (35 ms-65 ms) | 42 ms (40 ms-42 ms) | +17% | 51 ms (36 ms-53 ms) | 39 ms (39 ms-43 ms) | -24% |
| manifest-200f-20MB-plain-direct | 84 ms (84 ms-139 ms) | 118 ms (116 ms-156 ms) | +40% | 133 ms (84 ms-220 ms) | 119 ms (113 ms-133 ms) | -11% |
| manifest-2000f-200MB-plain-direct | 601 ms (589 ms-1205 ms) | 897 ms (886 ms-950 ms) | +49% | 1122 ms (597 ms-1303 ms) | 880 ms (871 ms-903 ms) | -22% |

The HTTP/2 rows were measured after the interleaved session, not inside it.

With a 40 Mbit/s link and 80 ms before each response (the shaped rows), HTTP/3 matches
HTTP/1.1. The exception is the C core with 2000 files of 10 KB: 2 of its 3 runs took
10-12 s, and the Rust core had one such run.

### Android emulator (loopback through QEMU user networking)

| Cell | Rust, HTTP/1.1 | Rust, host | Change | C, HTTP/1.1 | C, host | Change |
| --- | --- | --- | --- | --- | --- | --- |
| zip-3MB-plain-background | 55 ms (52 ms-56 ms) | 63 ms (59 ms-63 ms) | +15% | 61 ms (58 ms-61 ms) | 60 ms (54 ms-67 ms) | -2% |
| zip-30MB-plain-background | 358 ms (357 ms-365 ms) | 435 ms (413 ms-468 ms) | +22% | 394 ms (340 ms-402 ms) | 403 ms (363 ms-435 ms) | +2% |
| zip-300MB-plain-background | 3510 ms (3502 ms-3643 ms) | 4176 ms (4084 ms-4592 ms) | +19% | 3387 ms (3289 ms-3605 ms) | 3910 ms (3509 ms-4391 ms) | +15% |
| manifest-2f-20KB-plain-background | 17 ms (15 ms-18 ms) | 18 ms (17 ms-19 ms) | +6% | 18 ms (17 ms-22 ms) | 13 ms (12 ms-22 ms) | -28% |
| manifest-20f-2MB-plain-background | 41 ms (36 ms-48 ms) | 56 ms (45 ms-69 ms) | +37% | 41 ms (39 ms-52 ms) | 50 ms (43 ms-55 ms) | +22% |
| manifest-200f-20MB-plain-background | 145 ms (140 ms-159 ms) | 314 ms (296 ms-334 ms) | +117% | 142 ms (128 ms-180 ms) | 313 ms (286 ms-357 ms) | +120% |
| manifest-2000f-200MB-plain-background | 1352 ms (1307 ms-1554 ms) | 2850 ms (2716 ms-3075 ms) | +111% | 1095 ms (1091 ms-1189 ms) | 2864 ms (2558 ms-2983 ms) | +162% |
| zip-3MB-plain-direct | 71 ms (71 ms-72 ms) | 79 ms (75 ms-84 ms) | +11% | 65 ms (63 ms-71 ms) | 73 ms (70 ms-84 ms) | +12% |
| zip-30MB-plain-direct | 399 ms (385 ms-411 ms) | 445 ms (426 ms-454 ms) | +12% | 366 ms (361 ms-395 ms) | 432 ms (422 ms-461 ms) | +18% |
| zip-300MB-plain-direct | 3660 ms (3610 ms-3882 ms) | 3958 ms (3844 ms-4036 ms) | +8% | 3829 ms (3631 ms-4878 ms) | 3843 ms (3455 ms-3950 ms) | +0% |
| manifest-2f-20KB-plain-direct | 31 ms (31 ms-35 ms) | 29 ms (29 ms-30 ms) | -6% | 26 ms (24 ms-58 ms) | 31 ms (29 ms-40 ms) | +19% |
| manifest-20f-2MB-plain-direct | 49 ms (45 ms-54 ms) | 79 ms (73 ms-87 ms) | +61% | 45 ms (42 ms-53 ms) | 69 ms (56 ms-78 ms) | +53% |
| manifest-200f-20MB-plain-direct | 165 ms (162 ms-165 ms) | 312 ms (309 ms-332 ms) | +89% | 149 ms (132 ms-161 ms) | 300 ms (295 ms-301 ms) | +101% |
| manifest-2000f-200MB-plain-direct | 1335 ms (1324 ms-1340 ms) | 2751 ms (2717 ms-2897 ms) | +106% | 1186 ms (1135 ms-1441 ms) | 2708 ms (2626 ms-2831 ms) | +128% |
| shaped-zip-30MB-plain-background | 6411 ms (6396 ms-6412 ms) | 6436 ms (6423 ms-6437 ms) | +0% | 6390 ms (6388 ms-6398 ms) | 6405 ms (6401 ms-6406 ms) | +0% |
| shaped-manifest-200f-20MB-plain-background | 4280 ms (4278 ms-4282 ms) | 4281 ms (4281 ms-4282 ms) | +0% | 4276 ms (4276 ms-4278 ms) | 4282 ms (4281 ms-4282 ms) | +0% |
| shaped-manifest-2000f-20MB-plain-background | 5299 ms (5273 ms-5306 ms) | 5353 ms (5344 ms-5357 ms) | +1% | 5228 ms (5217 ms-5229 ms) | 5291 ms (5284 ms-5321 ms) | +1% |
| zip-3MB-enc-background | 67 ms (64 ms-70 ms) | 71 ms (70 ms-71 ms) | +6% | 69 ms (48 ms-70 ms) | 64 ms (59 ms-75 ms) | -7% |
| zip-30MB-enc-background | 386 ms (361 ms-400 ms) | 462 ms (435 ms-528 ms) | +20% | 370 ms (350 ms-377 ms) | 450 ms (427 ms-577 ms) | +22% |
| zip-300MB-enc-background | 3585 ms (3486 ms-3645 ms) | 4256 ms (4030 ms-4577 ms) | +19% | 3509 ms (3400 ms-3548 ms) | 4168 ms (4095 ms-4331 ms) | +19% |
| manifest-2f-20KB-enc-background | 15 ms (14 ms-17 ms) | 17 ms (14 ms-19 ms) | +13% | 17 ms (16 ms-40 ms) | 14 ms (12 ms-15 ms) | -18% |
| manifest-20f-2MB-enc-background | 35 ms (30 ms-48 ms) | 62 ms (50 ms-66 ms) | +77% | 45 ms (41 ms-47 ms) | 55 ms (41 ms-66 ms) | +22% |
| manifest-200f-20MB-enc-background | 161 ms (155 ms-164 ms) | 314 ms (288 ms-517 ms) | +95% | 144 ms (134 ms-155 ms) | 297 ms (293 ms-344 ms) | +106% |
| manifest-2000f-200MB-enc-background | 1378 ms (1371 ms-1576 ms) | 2763 ms (2705 ms-4032 ms) | +101% | 1280 ms (1258 ms-1364 ms) | 2904 ms (2696 ms-2935 ms) | +127% |
| zip-3MB-enc-direct | 72 ms (70 ms-83 ms) | 75 ms (70 ms-75 ms) | +4% | 72 ms (68 ms-74 ms) | 88 ms (78 ms-89 ms) | +22% |
| zip-30MB-enc-direct | 425 ms (395 ms-503 ms) | 453 ms (397 ms-463 ms) | +7% | 389 ms (379 ms-552 ms) | 436 ms (423 ms-651 ms) | +12% |
| zip-300MB-enc-direct | 3795 ms (3698 ms-3906 ms) | 4084 ms (3961 ms-4458 ms) | +8% | 3693 ms (3461 ms-4147 ms) | 4144 ms (3643 ms-4153 ms) | +12% |
| manifest-2f-20KB-enc-direct | 32 ms (30 ms-32 ms) | 34 ms (26 ms-83 ms) | +6% | 31 ms (30 ms-39 ms) | 33 ms (31 ms-54 ms) | +6% |
| manifest-20f-2MB-enc-direct | 48 ms (47 ms-51 ms) | 76 ms (65 ms-79 ms) | +58% | 44 ms (37 ms-48 ms) | 71 ms (63 ms-86 ms) | +61% |
| manifest-200f-20MB-enc-direct | 153 ms (152 ms-158 ms) | 325 ms (316 ms-328 ms) | +112% | 133 ms (120 ms-139 ms) | 302 ms (284 ms-303 ms) | +127% |
| manifest-2000f-200MB-enc-direct | 1377 ms (1329 ms-1379 ms) | 2785 ms (2774 ms-2908 ms) | +102% | 1143 ms (1091 ms-1165 ms) | 2720 ms (2704 ms-2803 ms) | +138% |

On the emulator, results are stable (no bimodality).

- Zips over HTTP/3 are 0-22% slower.
- Manifests of 20 files or more are about 2× slower over HTTP/3. One QUIC connection
  carries all the parallel downloads, where the core's client opens up to 32 TCP
  connections.
- Shaped runs are at parity.

### Lossy profile (Android, 150 ms RTT, about 1% loss each way)

Plain, background, 3 runs per cell, interleaved like the main suite. The 30 MB zip took
about 220 s with HTTP/3, close to its 240 s case timeout, so it was left out.

| Cell | Rust, HTTP/1.1 | Rust, host | Change | C, HTTP/1.1 | C, host | Change |
| --- | --- | --- | --- | --- | --- | --- |
| zip-3MB-plain-background | 66.3 s (63.5 s-68.9 s) | 21.9 s (20.6 s-25.6 s) | -67% | 74.0 s (72.2 s-82.6 s) | 22.9 s (20.5 s-26.5 s) | -69% |
| manifest-20f-2MB-plain-background | 5704 ms (4189 ms-12.5 s) | 13.7 s (12.4 s-16.2 s) | +140% | 8692 ms (7565 ms-10.1 s) | 12.4 s (11.0 s-13.2 s) | +43% |
| manifest-200f-20MB-plain-background | 21.8 s (19.4 s-24.7 s) | 151.5 s (145.9 s-152.3 s) | +596% | 21.5 s (19.8 s-24.3 s) | 144.4 s (139.2 s-156.3 s) | +571% |

- **Single stream: HTTP/3 is about 3× faster.** The 3 MB zip reaches about 140 KB/s,
  what one loss-limited flow can do at this RTT and loss. Over TCP, the core's client
  needs about 3× longer.
- **Many files: HTTP/3 is up to about 7× slower.** All downloads share one QUIC
  connection and its single loss-limited congestion window. The core's client opens up
  to 32 TCP connections, each with its own window, so their throughput adds up.

## Size

Stripped `.so` per Android ABI, and the release iOS bench app executable (simulator
build). Base is `89df6f39`, built with the same toolchains.

| Artifact | Rust base | Rust now | Change | C base | C now | Change |
| --- | --- | --- | --- | --- | --- | --- |
| arm64-v8a `.so` | 3,030,160 | 3,059,856 | +29.7 KB (+1.0%) | 894,992 | 905,648 | +10.7 KB (+1.2%) |
| armeabi-v7a `.so` | 2,022,736 | 2,041,400 | +18.7 KB (+0.9%) | 654,376 | 661,752 | +7.4 KB (+1.1%) |
| x86 `.so` | 3,575,472 | 3,615,136 | +39.7 KB (+1.1%) | 920,144 | 930,720 | +10.6 KB (+1.1%) |
| x86_64 `.so` | 3,470,616 | 3,505,320 | +34.7 KB (+1.0%) | 904,880 | 916,064 | +11.2 KB (+1.2%) |
| iOS app executable (core + plugin, includes the Swift transport) | 4,423,232 | 4,504,480 | +81.2 KB (+1.8%) | 1,552,128 | 1,613,184 | +61.1 KB (+3.9%) |

HttpEngine and URLSession ship with the OS, so they add no size.

## Reading the results

- **Loopback is not a real network.** On loopback and the emulator's QEMU network, the
  link is not the limit, so only CPU cost shows. There, HTTP/3 is slower than the core's
  HTTP/1.1 client: much slower on the iOS simulator, about 2× on the emulator for many
  files.
- **Bandwidth-limited link.** With 40 Mbit/s and 80 ms before each response, both
  protocols take the same time.
- **Loss and real RTT.** Single transfers (zips, API calls) are much faster over HTTP/3.
  Manifests with many files are much slower over HTTP/3, because they lose the core's 32
  parallel TCP connections.
- **What was not measured.**
  - A real device on a real mobile network.
  - The iOS lossy profile (it needs sudo).
  - Packet loss on iOS.

## Reproduce

```bash
# Caddy (h1 h2 h3, internal CA, roll_size raised) in front of the bench server on 3293:
caddy run --config Caddyfile   # https://localhost:9443 (iOS) and https://10.0.2.2:9443 (Android)
xcrun simctl keychain <udid> add-root-cert caddy-root.pem
# Android clone: the root in the bench network security config, plus a system CA (root, tmpfs)
BENCH_DIR=... BENCH_PORT=3293 BENCH_UPDATER_BASE_URL=https://localhost:9443 \
  BENCH_TRUST_CA=caddy-root.pem CAPGO_CORE_IMPL=rust|c [BENCH_SYSTEM_HTTP=0] \
  scripts/bench/run-ios.sh <label> . --variants plain,enc --suites main,shaped --only '-r1$'
# Lossy (Android, as root in the guest): netem 75ms 1% on eth0 egress and on ifb0 (eth0 ingress)
```
