use std::sync::Arc;
use std::time::Duration;

use capgo_updater_core::host::MemoryHost;
use capgo_updater_core::net::Http;

fn http() -> Http {
    Http::new(
        Arc::new(MemoryHost::default()),
        "CapacitorUpdater/test".into(),
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
    assert_eq!(error.kind, capgo_updater_core::net::NetErrorKind::Network);
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
        assert_eq!(
            error.kind,
            capgo_updater_core::net::NetErrorKind::Tls,
            "{untrusted}: {error:?}"
        );
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
    let http = Http::new(Arc::new(NoPolicy), "test".into(), Duration::from_secs(5));
    let error = http.get("http://127.0.0.1:1/").unwrap_err();
    assert!(error.message.contains("Cleartext HTTP traffic"), "{error:?}");
}
