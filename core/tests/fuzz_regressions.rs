//! Regression tests of the inputs the fuzz targets (core/fuzz, core-c/fuzz, scripts/fuzz.sh)
//! found. They run on both cores (`CAPGO_CORE_LIB` selects the C library).
mod support;

use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener};
use std::sync::Arc;
use std::time::Duration;

use capgo_updater_core::host::MemoryHost;
use support::TestHttp;

/// A server that answers every connection with `response` (raw bytes), then closes.
fn raw_server(response: &'static [u8]) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            std::thread::spawn(move || {
                let mut request = Vec::new();
                let mut buffer = [0u8; 4096];
                let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                    match stream.read(&mut buffer) {
                        Ok(0) | Err(_) => return,
                        Ok(read) => request.extend_from_slice(&buffer[..read]),
                    }
                }
                let _ = stream.write_all(response);
                let _ = stream.shutdown(Shutdown::Write);
                let _ = stream.read_to_end(&mut request);
            });
        }
    });
    url
}

fn http() -> TestHttp {
    TestHttp::new(Arc::new(MemoryHost::default()), "test", Duration::from_secs(10))
}

/// A response header line without `:` is skipped (C, ureq's intent) or refuses the response
/// (Rust: ureq 2.12 panics on it, net.rs contains the panic). Either way no crash, no panic
/// through the ABI, and the client keeps working.
#[test]
fn a_header_line_without_a_colon_never_crashes() {
    let ok = raw_server(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
    for response in [
        &b"HTTP/1.1 200 OK\r\nX-Broken\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"[..],
        &b"HTTP/1.1 200 OK\r\nContent-Length\r\nConnection: close\r\n\r\nok"[..],
        &b"HTTP/1.1 200 OK\r\nContent-Encozip\r\nContent-Length: 2\r\n\r\nok"[..],
    ] {
        let url = raw_server(response);
        let client = http();
        for result in [client.get(&url), client.download(&url)] {
            match result {
                Ok(response) => {
                    assert_eq!(response.status, 200);
                    assert_eq!(response.text(), "ok");
                    assert!(
                        response
                            .headers
                            .iter()
                            .all(|(name, _)| !name.contains("Broken") && !name.eq_ignore_ascii_case("Content-Encozip")),
                        "{:?}",
                        response.headers
                    );
                }
                Err(error) => assert_eq!(error.code, "network", "{error:?}"),
            }
        }
        assert_eq!(client.get(&ok).expect("the client still works").text(), "ok");
    }
}

/// Floats in JSON input are parsed correctly rounded on both cores (Rust: serde_json's
/// `float_roundtrip`; its default parser was one bit off on long literals and printed
/// `1.8446699999999998e+42` back).
#[test]
fn json_floats_are_parsed_correctly_rounded() {
    let server = support::FakeServer::start(|_| support::FakeServer::json(200, serde_json::json!({})));
    let t = support::TestEngine::new(serde_json::json!({ "statsUrl": format!("{}/stats", server.url) }));
    let reply = t.engine.call_raw(
        "statsSend",
        Some(
            r#"{"action":"probe","versionName":"1.0.0","metadata":{"a":1844670000000000000000791150157654596454443.0,"b":311111111111111111111111111111111111111111111111111111111111111111185477508,"c":1.095507833264775808}}"#,
        ),
    );
    assert!(reply.contains("\"ok\":true"), "{reply}");
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    let body = loop {
        t.engine.flush_stats();
        if let Some(request) = server
            .requests()
            .into_iter()
            .find(|request| request.url.starts_with("/stats"))
        {
            break String::from_utf8(request.body).unwrap();
        }
        assert!(std::time::Instant::now() < deadline, "no stats request");
        std::thread::sleep(Duration::from_millis(20));
    };
    for expected in [
        r#""a":1.84467e+42"#,
        r#""b":3.111111111111111e+74"#,
        r#""c":1.0955078332647759"#,
    ] {
        assert!(body.contains(expected), "{expected} not in {body}");
    }
}
