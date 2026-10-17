//! HTTP/3 (QUIC) in the engine's client, through the C ABI (`CAPGO_CORE_LIB` runs the same
//! tests on the C core): discovery with `Alt-Svc`, persistence, fallback to HTTP/1.1 when
//! QUIC fails, and every rule of the HTTP/1.1 path (redirects, Range resume, body caps,
//! Content-Length, timeouts, cancellation, trust) on the HTTP/3 path. Manifest-style
//! parallel downloads spread over several QUIC connections per origin.

mod support;

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use capgo_updater_core::host::{Host, LogLevel, MemoryHost};
use capgo_updater_core::text::hex_decode;
use serde_json::{json, Value};
use support::h3server::{blackhole_udp, cert_der, H3Server, Reply, H3, HTTP1};
use support::{TestEngine, TestHttp};

const ALT_SVC_KEY: &str = "CapacitorUpdater.altSvc";

fn trusting_host() -> Arc<MemoryHost> {
    let host = Arc::new(MemoryHost::default());
    *host.certificate_verdict.lock().unwrap() = Some(Some(Ok(())));
    host
}

fn client(host: Arc<MemoryHost>, timeout: Duration) -> TestHttp {
    TestHttp::new(host, "CapacitorUpdater/test", timeout)
}

/// Stores an announcement as a previous launch would have (skips discovery).
fn remember_h3(host: &MemoryHost, origin: &str, port: u16) {
    let expires = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
        + 3_600_000;
    host.kv_set(
        ALT_SVC_KEY,
        Some(&json!({ origin: { "port": port, "expires": expires } }).to_string()),
    );
}

fn get(http: &TestHttp, url: &str, extra: Value) -> Result<Value, support::AbiError> {
    let mut input = json!({ "url": url, "http3": true });
    if let (Some(input), Some(extra)) = (input.as_object_mut(), extra.as_object()) {
        for (key, value) in extra {
            input.insert(key.clone(), value.clone());
        }
    }
    http.call("http", input)
}

fn body(reply: &Value) -> Vec<u8> {
    hex_decode(reply["bodyHex"].as_str().unwrap()).unwrap()
}

fn logged(host: &MemoryHost, needle: &str) -> bool {
    host.logs
        .lock()
        .unwrap()
        .iter()
        .any(|(level, message)| *level == LogLevel::Debug && message.contains(needle))
}

#[test]
fn alt_svc_moves_the_origin_to_http3_and_is_persisted() {
    let server = H3Server::start(|_| Reply::ok("hello"));
    let host = trusting_host();
    let http = client(host.clone(), Duration::from_secs(5));
    let first = get(&http, &server.url("/a"), json!({})).unwrap();
    assert_eq!(
        (first["status"].as_u64(), first["protocol"].as_str()),
        (Some(200), Some(HTTP1))
    );
    let stored: Value = serde_json::from_str(&host.kv_get(ALT_SVC_KEY, None).expect("persisted")).unwrap();
    assert_eq!(stored[server.origin()]["port"], server.udp_port);
    // A new client (next launch) reads the announcement back and starts on HTTP/3.
    let second = get(&http, &server.url("/b"), json!({})).unwrap();
    assert_eq!(second["protocol"], H3);
    assert_eq!(body(&second), b"hello");
    assert_eq!(server.protocols(), vec![HTTP1, H3]);
    assert!(logged(&host, &format!("HTTP protocol for {}: h3", server.origin())));
    // The request carried the same fields as over HTTP/1.1.
    let seen = server.seen();
    let h3 = &seen[1];
    assert_eq!(h3.header("user-agent"), Some("CapacitorUpdater/test"));
    assert_eq!(h3.header("accept-encoding"), Some("gzip"));
    assert_eq!(
        h3.header("host").map(str::to_string),
        Some(format!("localhost:{}", server.port))
    );
}

#[test]
fn http3_off_keeps_http1_and_ignores_announcements() {
    let server = H3Server::start(|_| Reply::ok("x"));
    let host = trusting_host();
    let http = client(host.clone(), Duration::from_secs(5));
    for _ in 0..2 {
        let reply = get(&http, &server.url("/"), json!({ "http3": false })).unwrap();
        assert_eq!(reply["protocol"], HTTP1);
    }
    assert!(host.kv_get(ALT_SVC_KEY, None).is_none());
    // Off also means a stored announcement is not used.
    remember_h3(&host, &server.origin(), server.udp_port);
    let reply = get(&http, &server.url("/"), json!({ "http3": false })).unwrap();
    assert_eq!(reply["protocol"], HTTP1);
    assert_eq!(server.quic_connections.load(Ordering::SeqCst), 0);
}

#[test]
fn alt_svc_clear_and_other_hosts_are_not_followed() {
    let server = H3Server::start(|_| Reply::ok("x"));
    let host = trusting_host();
    let http = client(host.clone(), Duration::from_secs(5));
    server.set_advertise(&format!("h3=\"evil.example:{}\"", server.udp_port));
    get(&http, &server.url("/"), json!({})).unwrap();
    assert!(host.kv_get(ALT_SVC_KEY, None).is_none(), "another host is never used");
    server.set_advertise(&format!("h3-29=\":{0}\", h3=\":{0}\"; ma=60", server.udp_port));
    get(&http, &server.url("/"), json!({})).unwrap();
    assert!(host.kv_get(ALT_SVC_KEY, None).is_some());
    server.set_advertise("clear");
    // The stored announcement sends this request over HTTP/3; its `clear` forgets it.
    let reply = get(&http, &server.url("/"), json!({})).unwrap();
    assert_eq!(reply["protocol"], H3);
    assert!(host.kv_get(ALT_SVC_KEY, None).is_none());
    let reply = get(&http, &server.url("/"), json!({})).unwrap();
    assert_eq!(reply["protocol"], HTTP1);
}

#[test]
fn blocked_udp_falls_back_to_http1_and_the_origin_stays_there() {
    let server = H3Server::start(|_| Reply::ok("ok"));
    let (_socket, dead_port) = blackhole_udp();
    let host = trusting_host();
    remember_h3(&host, &server.origin(), dead_port);
    server.set_advertise(&format!("h3=\":{dead_port}\""));
    let http = client(host.clone(), Duration::from_secs(10));
    let started = Instant::now();
    let batch = http
        .call(
            "httpBatch",
            json!({ "http3": true, "parallel": 1, "requests": [{ "url": server.url("/1") }, { "url": server.url("/2") }] }),
        )
        .unwrap();
    let elapsed = started.elapsed();
    for result in batch["results"].as_array().unwrap() {
        assert_eq!(
            (result["status"].as_u64(), result["protocol"].as_str()),
            (Some(200), Some(HTTP1)),
            "{batch}"
        );
    }
    // One handshake timeout (3 s, split over localhost's addresses), not one per request.
    assert!(elapsed < Duration::from_millis(5500), "{elapsed:?}");
    assert!(elapsed >= Duration::from_millis(1400), "{elapsed:?}");
    assert!(logged(&host, &format!("HTTP/3 to {} failed", server.origin())));
    assert!(logged(&host, "using HTTP/1.1 for 300 s"));
    assert_eq!(server.protocols(), vec![HTTP1, HTTP1]);
}

#[test]
fn closed_udp_port_falls_back_quickly() {
    let server = H3Server::start(|_| Reply::ok("ok"));
    let closed = {
        let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        socket.local_addr().unwrap().port()
    };
    let host = trusting_host();
    remember_h3(&host, &server.origin(), closed);
    server.set_advertise("");
    let http = client(host, Duration::from_secs(10));
    let reply = get(&http, &server.url("/"), json!({})).unwrap();
    assert_eq!(
        (reply["status"].as_u64(), reply["protocol"].as_str()),
        (Some(200), Some(HTTP1))
    );
}

#[test]
fn redirects_follow_the_same_rules_over_http3() {
    let server = H3Server::start(|seen| match seen.path.as_str() {
        "/a" => Reply::status(302).header("Location", "/b"),
        "/b" => Reply::ok("landed"),
        "/post" => Reply::status(303).header("Location", "/done"),
        "/done" => Reply::ok(seen.method.clone()),
        "/down" => Reply::status(302).header("Location", "http://127.0.0.1:9/insecure"),
        "/loop" => Reply::status(301).header("Location", "/loop"),
        _ => Reply::status(404),
    });
    let host = trusting_host();
    remember_h3(&host, &server.origin(), server.udp_port);
    let http = client(host, Duration::from_secs(5));
    let reply = get(&http, &server.url("/a"), json!({})).unwrap();
    assert_eq!(
        (reply["protocol"].as_str(), body(&reply)),
        (Some(H3), b"landed".to_vec())
    );
    let reply = get(
        &http,
        &server.url("/post"),
        json!({ "method": "POST", "json": { "a": 1 } }),
    )
    .unwrap();
    assert_eq!(body(&reply), b"GET", "303 turns POST into GET");
    let error = get(&http, &server.url("/down"), json!({})).unwrap_err();
    assert_eq!(error.code, "insecure_redirect", "{error:?}");
    let error = get(&http, &server.url("/loop"), json!({})).unwrap_err();
    assert_eq!(
        (error.code.as_str(), error.message.as_str()),
        ("network", "Too many redirects")
    );
    let seen = server.seen();
    assert!(seen.iter().all(|seen| seen.protocol == H3), "{seen:?}");
    assert_eq!(seen.iter().filter(|seen| seen.path == "/loop").count(), 6);
    let post = seen.iter().find(|seen| seen.path == "/post").unwrap();
    assert_eq!(
        (post.method.as_str(), post.body.as_slice()),
        ("POST", br#"{"a":1}"#.as_slice())
    );
    assert_eq!(post.header("content-length"), Some("7"));
}

#[test]
fn range_requests_resume_over_http3() {
    let content: Vec<u8> = (0..100_000u32).map(|index| (index % 251) as u8).collect();
    let served = content.clone();
    let server = H3Server::start(move |seen| match seen.header("range") {
        Some(range) => {
            let start: usize = range
                .trim_start_matches("bytes=")
                .trim_end_matches('-')
                .parse()
                .unwrap();
            Reply::ok(served[start..].to_vec()).header(
                "Content-Range",
                &format!("bytes {start}-{}/{}", served.len() - 1, served.len()),
            )
        }
        None => Reply::ok(served.clone()),
    });
    let host = trusting_host();
    remember_h3(&host, &server.origin(), server.udp_port);
    let http = client(host, Duration::from_secs(5));
    let reply = get(
        &http,
        &server.url("/zip"),
        json!({ "download": true, "headers": [["Range", "bytes=40000-"]] }),
    )
    .unwrap();
    assert_eq!(reply["protocol"], H3);
    assert_eq!(body(&reply), content[40_000..].to_vec());
    let seen = server.seen();
    assert_eq!(seen[0].header("range"), Some("bytes=40000-"));
    assert_eq!(seen[0].header("accept-encoding"), Some("identity"));
}

#[test]
fn api_bodies_are_capped_at_16_mib_over_http3() {
    let server = H3Server::start(|_| Reply::ok(vec![b'a'; 17 * 1024 * 1024]));
    let host = trusting_host();
    remember_h3(&host, &server.origin(), server.udp_port);
    let http = client(host, Duration::from_secs(20));
    let batch = http
        .call(
            "httpBatch",
            json!({ "http3": true, "requests": [{ "url": server.url("/big") }] }),
        )
        .unwrap();
    let result = &batch["results"][0];
    assert_eq!(result["protocol"], H3, "{batch}");
    assert_eq!(result["bodyLength"], 16 * 1024 * 1024);
}

#[test]
fn content_length_mismatches_are_errors_over_http3() {
    let server = H3Server::start(|seen| match seen.path.as_str() {
        "/short" => Reply {
            length: Some(Some(100)),
            ..Reply::ok(vec![1u8; 50])
        },
        "/long" => Reply {
            length: Some(Some(10)),
            ..Reply::ok(vec![1u8; 50])
        },
        _ => Reply::ok(vec![1u8; 50]),
    });
    let host = trusting_host();
    remember_h3(&host, &server.origin(), server.udp_port);
    let http = client(host, Duration::from_secs(5));
    for path in ["/short", "/long"] {
        for download in [false, true] {
            let error = get(&http, &server.url(path), json!({ "download": download })).unwrap_err();
            assert_eq!(error.code, "network", "{path} {download}: {error:?}");
        }
    }
    assert!(server.protocols().iter().all(|protocol| *protocol == H3));
}

#[test]
fn a_slow_server_times_out_without_falling_back() {
    let server = H3Server::start(|_| Reply {
        delay: Duration::from_millis(1500),
        ..Reply::ok("late")
    });
    let host = trusting_host();
    remember_h3(&host, &server.origin(), server.udp_port);
    let http = client(host, Duration::from_millis(600));
    let error = get(&http, &server.url("/"), json!({})).unwrap_err();
    assert_eq!(error.code, "timeout", "{error:?}");
    std::thread::sleep(Duration::from_millis(1200));
    assert_eq!(server.protocols(), vec![H3], "not sent again over HTTP/1.1");
}

#[test]
fn a_stalled_body_times_out_over_http3() {
    let server = H3Server::start(|_| Reply {
        chunk_delay: Duration::from_millis(1500),
        ..Reply::ok(vec![7u8; 64 * 1024])
    });
    let host = trusting_host();
    remember_h3(&host, &server.origin(), server.udp_port);
    let http = client(host, Duration::from_millis(500));
    let error = get(&http, &server.url("/"), json!({ "download": false })).unwrap_err();
    assert_eq!(error.code, "timeout", "{error:?}");
}

#[test]
fn reset_streams_and_cancelled_downloads() {
    let server = H3Server::start(|seen| match seen.path.as_str() {
        "/reset" => Reply {
            abort_after: Some(20_000),
            ..Reply::ok(vec![3u8; 200_000])
        },
        _ => Reply::ok(vec![5u8; 4 * 1024 * 1024]),
    });
    let host = trusting_host();
    remember_h3(&host, &server.origin(), server.udp_port);
    let http = client(host, Duration::from_secs(5));
    let error = get(&http, &server.url("/reset"), json!({ "download": true })).unwrap_err();
    assert_eq!(error.code, "network", "{error:?}");
    let error = get(
        &http,
        &server.url("/big"),
        json!({ "download": true, "cancelAfterBytes": 65_536 }),
    )
    .unwrap_err();
    assert_eq!(
        (error.code.as_str(), error.message.as_str()),
        ("io", "download_stopped")
    );
    // The origin is still on HTTP/3 afterwards.
    let reply = get(&http, &server.url("/big"), json!({ "download": true })).unwrap();
    assert_eq!(
        (reply["protocol"].as_str(), body(&reply).len()),
        (Some(H3), 4 * 1024 * 1024)
    );
    assert!(server.protocols().iter().all(|protocol| *protocol == H3));
}

fn batch_of(server: &H3Server, count: usize, connections: u64) -> Value {
    let host = trusting_host();
    remember_h3(&host, &server.origin(), server.udp_port);
    let http = client(host, Duration::from_secs(20));
    let requests: Vec<Value> = (0..count)
        .map(|index| json!({ "url": server.url(&format!("/files/{index}")), "download": true }))
        .collect();
    http.call(
        "httpBatch",
        json!({ "http3": true, "http3Connections": connections, "parallel": count, "requests": requests }),
    )
    .unwrap()
}

#[test]
fn parallel_downloads_spread_over_several_connections() {
    let server = H3Server::start(|seen| Reply {
        delay: Duration::from_millis(50),
        ..Reply::ok(seen.path.repeat(1000).into_bytes())
    });
    let batch = batch_of(&server, 32, 4);
    for (index, result) in batch["results"].as_array().unwrap().iter().enumerate() {
        assert_eq!(result["protocol"], H3, "{result}");
        let expected = format!("/files/{index}").repeat(1000);
        assert_eq!(
            result["bodySha256"].as_str(),
            Some(capgo_updater_core::crypto::checksum::sha256_hex(expected.as_bytes()).as_str())
        );
    }
    assert_eq!(batch["quicConnections"], 4, "{batch}");
    assert_eq!(server.quic_connections.load(Ordering::SeqCst), 4);
    let used: std::collections::BTreeSet<usize> = server.seen().iter().map(|seen| seen.connection).collect();
    assert_eq!(used.len(), 4, "every connection carried requests");
}

#[test]
fn one_connection_when_configured_or_for_a_single_transfer() {
    let server = H3Server::start(|_| Reply {
        delay: Duration::from_millis(20),
        ..Reply::ok(vec![1u8; 1000])
    });
    let batch = batch_of(&server, 16, 1);
    assert_eq!(batch["quicConnections"], 1, "{batch}");
    let batch = batch_of(&server, 1, 8);
    assert_eq!(batch["quicConnections"], 1, "{batch}");
}

#[test]
fn a_refused_certificate_fails_closed_on_both_protocols() {
    let server = H3Server::start(|_| Reply::ok("secret"));
    let host = Arc::new(MemoryHost::default());
    *host.certificate_verdict.lock().unwrap() = Some(Some(Err("pin mismatch".into())));
    remember_h3(&host, &server.origin(), server.udp_port);
    let http = client(host.clone(), Duration::from_secs(5));
    let error = get(&http, &server.url("/"), json!({})).unwrap_err();
    assert_eq!(error.code, "tls", "{error:?}");
    assert!(error.message.contains("pin mismatch"), "{error:?}");
    assert!(server.seen().is_empty(), "no request reached the server");
    let requests = host.certificate_requests.lock().unwrap().clone();
    assert_eq!(requests.len(), 2, "QUIC and TCP both asked the host");
    for (chain, name) in requests {
        assert_eq!((chain, name.as_str()), (vec![cert_der()], "localhost"));
    }
}

#[test]
fn a_proxy_keeps_requests_on_http1() {
    let server = H3Server::start(|_| Reply::ok("x"));
    let host = trusting_host();
    remember_h3(&host, &server.origin(), server.udp_port);
    // The proxy does not exist: the request fails on the proxied HTTP/1.1 path.
    host.reply_to_hook("proxyForUrl", json!({ "type": "http", "host": "127.0.0.1", "port": 9 }));
    let http = client(host, Duration::from_secs(5));
    let _ = get(&http, &server.url("/"), json!({}));
    assert_eq!(server.quic_connections.load(Ordering::SeqCst), 0);
}

/// The engine itself: the update server announces HTTP/3, the manifest files then come over
/// QUIC on several connections and pass the same checksum gate.
#[test]
fn engine_manifest_download_over_http3() {
    let files: Vec<(String, Vec<u8>)> = (0..40)
        .map(|index| {
            (
                format!("assets/f{index}.js"),
                format!("console.log({index})").repeat(200).into_bytes(),
            )
        })
        .collect();
    let served = files.clone();
    let server = H3Server::start(move |seen| {
        if seen.path == "/ping" {
            return Reply::ok("{}").header("Content-Type", "application/json");
        }
        let name = seen.path.trim_start_matches("/files/");
        match served.iter().find(|(file, _)| file == name) {
            Some((_, content)) => Reply::ok(content.clone()),
            None => Reply::status(404),
        }
    });
    let t = TestEngine::new(json!({ "http3": true, "http3Connections": 4 }));
    *t.host.certificate_verdict.lock().unwrap() = Some(Some(Ok(())));
    t.call("test.fetchJson", json!({ "url": server.url("/ping") }));
    let manifest: Vec<Value> = files
        .iter()
        .map(|(name, content)| {
            json!({
                "file_name": name,
                "file_hash": capgo_updater_core::crypto::checksum::sha256_hex(content),
                "download_url": server.url(&format!("/files/{name}")),
            })
        })
        .collect();
    let installed = t.call("download", json!({ "version": "2", "manifest": manifest }));
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    for (name, content) in &files {
        assert_eq!(&std::fs::read(dir.join(name)).unwrap(), content);
    }
    let file_protocols: Vec<&str> = server
        .seen()
        .iter()
        .filter(|seen| seen.path.starts_with("/files/"))
        .map(|seen| seen.protocol)
        .collect();
    assert_eq!(file_protocols.len(), files.len());
    assert!(
        file_protocols.iter().all(|protocol| *protocol == H3),
        "{file_protocols:?}"
    );
    let protocols = t.call("test.httpProtocols", json!({}));
    assert_eq!(protocols["protocols"][server.origin()], H3);
    assert!(protocols["quicConnections"].as_u64().unwrap() >= 2, "{protocols}");
    assert!(protocols["quicConnections"].as_u64().unwrap() <= 4, "{protocols}");

    // A corrupted file over HTTP/3 still fails the checksum gate before install.
    let bad = json!([{ "file_name": "bad.js", "file_hash": capgo_updater_core::crypto::checksum::sha256_hex(b"original"), "download_url": server.url("/files/assets/f1.js") }]);
    let error = t
        .engine
        .call("download", &json!({ "version": "3", "manifest": bad }))
        .unwrap_err();
    assert!(
        error.message.to_lowercase().contains("checksum") || error.code.contains("checksum"),
        "{error:?}"
    );
}
