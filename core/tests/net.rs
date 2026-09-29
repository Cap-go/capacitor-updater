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
            .respond(
                tiny_http::Response::from_string(format!("{{\"ua\":\"{agent}\"}}"))
                    .with_status_code(429),
            )
            .unwrap();
    });
    let response = http()
        .get(&format!("http://127.0.0.1:{port}/check"))
        .unwrap();
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
    assert!(http().get("https://self-signed.badssl.com/").is_err());
}
