mod support;

use std::sync::Arc;
use std::time::Duration;

use capgo_updater_core::host::MemoryHost;
use support::TestHttp;

fn http() -> TestHttp {
    TestHttp::new(
        Arc::new(MemoryHost::default()),
        "CapacitorUpdater/test",
        Duration::from_secs(10),
    )
}

#[test]
fn plain_http_round_trip_sends_user_agent_and_returns_non_2xx() {
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let port = server.server_addr().to_ip().unwrap().port();
    let handle = std::thread::spawn(move || {
        let request = server.recv().unwrap();
        let agent = request
            .headers()
            .iter()
            .find(|h| h.field.equiv("User-Agent"))
            .map(|h| h.value.to_string())
            .unwrap_or_default();
        request
            .respond(tiny_http::Response::from_string(format!("{{\"ua\":\"{agent}\"}}")).with_status_code(429))
            .unwrap();
    });
    let response = http().get(&format!("http://127.0.0.1:{port}/check")).unwrap();
    handle.join().unwrap();
    assert_eq!(response.status, 429);
    assert_eq!(response.json().unwrap()["ua"], "CapacitorUpdater/test");
}

#[test]
fn connection_refused_is_a_network_error() {
    let error = http().get("http://127.0.0.1:1/").unwrap_err();
    assert_eq!(error.code, "network", "{error:?}");
}

/// Needs internet; run with `cargo test -- --ignored`.
#[test]
#[ignore]
fn https_uses_platform_trust_store() {
    let response = http().get("https://capgo.app/").unwrap();
    assert!(response.status < 500);
    for untrusted in [
        "https://self-signed.badssl.com/",
        "https://wrong.host.badssl.com/",
        "https://expired.badssl.com/",
    ] {
        let error = http().get(untrusted).unwrap_err();
        assert_eq!(error.code, "tls", "{untrusted}: {error:?}");
    }
}

/// A host without a cleartext policy answer (no hook, hook error): plain HTTP is refused.
#[test]
fn cleartext_without_a_policy_answer_is_refused() {
    struct NoPolicy;
    impl capgo_updater_core::host::Host for NoPolicy {
        fn log(&self, _: capgo_updater_core::host::LogLevel, _: &str) {}
        fn kv_get(&self, _: &str, default: Option<&str>) -> Option<String> {
            default.map(str::to_string)
        }
        fn kv_set(&self, _: &str, _: Option<&str>) {}
        fn kv_keys(&self) -> Vec<String> {
            Vec::new()
        }
        fn emit(&self, _: &str, _: &serde_json::Value) {}
    }
    let http = TestHttp::new(Arc::new(NoPolicy), "test", Duration::from_secs(5));
    let error = http.get("http://127.0.0.1:1/").unwrap_err();
    assert!(error.message.contains("Cleartext HTTP traffic"), "{error:?}");
}

/// IDN support is dropped (idna_adapter pinned to the ASCII-only 1.0.0): punycode
/// host names still parse and reach DNS, Unicode host names are invalid URLs.
#[test]
fn punycode_hosts_parse_and_unicode_hosts_are_rejected() {
    // A proxy from the environment (HTTP_PROXY) may answer instead of DNS failing: either way
    // the URL was accepted.
    if let Err(error) = http().get("http://xn--bcher-kva.invalid/") {
        assert_ne!(error.code, "invalid_url", "{error:?}");
    }
    let error = http().get("http://b\u{fc}cher.invalid/").unwrap_err();
    assert_eq!(error.code, "invalid_url", "{error:?}");
}

/// API calls ask for gzip and decode it transparently (OkHttp / URLSession did).
#[test]
fn api_responses_are_gzip_decoded_transparently() {
    use std::io::Write;
    let json = br#"{"version":"1.2.3","message":"compressed"}"#.repeat(50);
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(&json).unwrap();
    let compressed = encoder.finish().unwrap();
    assert!(compressed.len() < json.len());

    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let port = server.server_addr().to_ip().unwrap().port();
    let handle = std::thread::spawn(move || {
        let mut accepted = Vec::new();
        for body in [compressed, Vec::new()] {
            let request = server.recv().unwrap();
            accepted.push(
                request
                    .headers()
                    .iter()
                    .find(|h| h.field.equiv("Accept-Encoding"))
                    .map(|h| h.value.to_string()),
            );
            let response = tiny_http::Response::from_data(body)
                .with_header("Content-Encoding: gzip".parse::<tiny_http::Header>().unwrap());
            request.respond(response).unwrap();
        }
        accepted
    });
    let http = http();
    let response = http.get(&format!("http://127.0.0.1:{port}/latest")).unwrap();
    assert_eq!(response.body, json);
    assert_eq!(response.header("Content-Encoding"), None);
    // An empty gzip-labelled body (e.g. 204) is just empty.
    let empty = http
        .send_json(
            "POST",
            &format!("http://127.0.0.1:{port}/stats"),
            &serde_json::json!({}),
        )
        .unwrap();
    assert!(empty.body.is_empty());
    let accepted = handle.join().unwrap();
    assert_eq!(accepted, vec![Some("gzip".to_string()), Some("gzip".to_string())]);
}

/// Bundle downloads ask for the identity encoding: stored bytes must match the
/// checksum and Content-Length / Content-Range offsets.
#[test]
fn downloads_request_identity_encoding() {
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let port = server.server_addr().to_ip().unwrap().port();
    let handle = std::thread::spawn(move || {
        let request = server.recv().unwrap();
        let accepted = request
            .headers()
            .iter()
            .find(|h| h.field.equiv("Accept-Encoding"))
            .map(|h| h.value.to_string());
        request
            .respond(tiny_http::Response::from_data(b"zip bytes".to_vec()))
            .unwrap();
        accepted
    });
    let body = http().download(&format!("http://127.0.0.1:{port}/b.zip")).unwrap().body;
    assert_eq!(body, b"zip bytes");
    assert_eq!(handle.join().unwrap().as_deref(), Some("identity"));
}
