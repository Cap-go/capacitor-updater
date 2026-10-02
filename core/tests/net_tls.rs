//! TLS trust is a host decision (Android TrustManager, iOS SecTrust): these
//! tests run a local HTTPS server and check that the engine's client only
//! talks to it when the host trusts the chain AND the name matches, and fails
//! closed otherwise (rejection, no answer, no callback). Requests go through
//! the system HTTP proxy the host reports, with the same TLS rules.

use std::ffi::{c_char, c_void, CStr, CString};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use capgo_updater_core::ffi::{host_from_callbacks_for_tests, CapgoHostCallbacks};
use capgo_updater_core::host::{Host, MemoryHost};
use capgo_updater_core::net::{Http, NetErrorKind};
use capgo_updater_core::text::base64_decode;

/// Self-signed EC P-256 certificate for `localhost` (SAN DNS:localhost only), valid until 2126.
const CERT_DER_BASE64: &str = "MIIBlTCCATugAwIBAgIUJ5aRle5e8iK9YLs/MZNuxZYugd0wCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAwMTAzMTY1MVoYDzIxMjYwOTA3MDMxNjUxWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQPuthMBpvhPqOhuFEwC3eYmswof9VhLzrSNCLx7zY3Rc2nS3tQvldeDafMd3KqdSwm5Em0rWqI57+KpSTHmUf+o2kwZzAdBgNVHQ4EFgQUYt8DOmvp6RcdA1LBK7EHHfW5gGgwHwYDVR0jBBgwFoAUYt8DOmvp6RcdA1LBK7EHHfW5gGgwDwYDVR0TAQH/BAUwAwEB/zAUBgNVHREEDTALgglsb2NhbGhvc3QwCgYIKoZIzj0EAwIDSAAwRQIhAI5s0aFIxwPQtpTmjpdv2WZ0cAeCznQ5KTwV1L+Jj5k8AiA9dehLNJAhExhzonmiMWF0qIR1juFPqLYcjoXW4Ty+Ng==";
/// PKCS#8 private key of [`CERT_DER_BASE64`].
const KEY_DER_BASE64: &str = "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgNQgLefPtIfW+OBi7uhUe+lNioJW9XcDaw9Y3x+N+IyehRANCAAQPuthMBpvhPqOhuFEwC3eYmswof9VhLzrSNCLx7zY3Rc2nS3tQvldeDafMd3KqdSwm5Em0rWqI57+KpSTHmUf+";

fn cert_der() -> Vec<u8> {
    base64_decode(CERT_DER_BASE64).unwrap()
}

/// HTTPS server answering `200 ok` to every request it fully receives.
struct TlsServer {
    port: u16,
    /// HTTP requests that made it through the handshake.
    requests: Arc<AtomicUsize>,
}

impl TlsServer {
    fn start() -> Self {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let config = rustls::ServerConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![rustls::pki_types::CertificateDer::from(cert_der())],
                rustls::pki_types::PrivateKeyDer::Pkcs8(base64_decode(KEY_DER_BASE64).unwrap().into()),
            )
            .unwrap();
        let config = Arc::new(config);
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(AtomicUsize::new(0));
        let served = requests.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { continue };
                let config = config.clone();
                let served = served.clone();
                std::thread::spawn(move || {
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                    let connection = rustls::ServerConnection::new(config).unwrap();
                    let mut tls = rustls::StreamOwned::new(connection, stream);
                    let mut request = Vec::new();
                    let mut buffer = [0u8; 1024];
                    while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                        match tls.read(&mut buffer) {
                            Ok(0) | Err(_) => return,
                            Ok(read) => request.extend_from_slice(&buffer[..read]),
                        }
                    }
                    served.fetch_add(1, Ordering::SeqCst);
                    let _ = tls.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
                    let _ = tls.flush();
                    tls.conn.send_close_notify();
                    let _ = tls.flush();
                });
            }
        });
        Self { port, requests }
    }
}

fn http(host: Arc<dyn Host>) -> Http {
    Http::new(host, "CapacitorUpdater/test".into(), Duration::from_secs(5))
}

fn memory_host(verdict: Option<Result<(), String>>) -> Arc<MemoryHost> {
    let host = Arc::new(MemoryHost::default());
    *host.certificate_verdict.lock().unwrap() = Some(verdict);
    host
}

#[test]
fn trusted_chain_with_matching_name_connects_and_host_sees_the_chain() {
    let server = TlsServer::start();
    let host = memory_host(Some(Ok(())));
    let response = http(host.clone())
        .get(&format!("https://localhost:{}/", server.port))
        .unwrap();
    assert_eq!((response.status, response.text().as_str()), (200, "ok"));
    let requests = host.certificate_requests.lock().unwrap();
    assert_eq!(requests[0], (vec![cert_der()], "localhost".to_string()));
}

#[test]
fn host_rejection_fails_closed_before_any_request() {
    let server = TlsServer::start();
    let host = memory_host(Some(Err("untrusted root".into())));
    let error = http(host)
        .get(&format!("https://localhost:{}/", server.port))
        .unwrap_err();
    assert_eq!(error.kind, NetErrorKind::Tls, "{error:?}");
    assert!(error.message.contains("untrusted root"), "{error:?}");
    assert_eq!(server.requests.load(Ordering::SeqCst), 0);
}

#[test]
fn no_host_answer_fails_closed() {
    let server = TlsServer::start();
    let error = http(memory_host(None))
        .get(&format!("https://localhost:{}/", server.port))
        .unwrap_err();
    assert_eq!(error.kind, NetErrorKind::Tls, "{error:?}");
    assert_eq!(server.requests.load(Ordering::SeqCst), 0);
}

/// A trusted chain for another name is refused: the engine checks the name itself.
#[test]
fn trusted_chain_for_another_name_is_refused() {
    let server = TlsServer::start();
    let host = memory_host(Some(Ok(())));
    let error = http(host.clone())
        .get(&format!("https://127.0.0.1:{}/", server.port))
        .unwrap_err();
    assert_eq!(error.kind, NetErrorKind::Tls, "{error:?}");
    assert_eq!(server.requests.load(Ordering::SeqCst), 0);
    assert_eq!(host.certificate_requests.lock().unwrap()[0].1, "127.0.0.1");
}

/// The test machine's trust store does not know the self-signed certificate.
#[test]
fn platform_trust_store_rejects_self_signed_certificate() {
    let server = TlsServer::start();
    let error = http(Arc::new(MemoryHost::default()))
        .get(&format!("https://localhost:{}/", server.port))
        .unwrap_err();
    assert_eq!(error.kind, NetErrorKind::Tls, "{error:?}");
    assert_eq!(server.requests.load(Ordering::SeqCst), 0);
}

// ---------------------------------------------------------------------------
// The same rules through the C ABI host callbacks (iOS).

#[derive(Default)]
struct CallbackState {
    verdict: i32,
    error: Option<&'static str>,
    seen: Mutex<Vec<(String, Vec<Vec<u8>>)>>,
}

unsafe extern "C" fn free_string(_: *mut c_void, value: *mut c_char) {
    drop(CString::from_raw(value));
}

unsafe extern "C" fn log(_: *mut c_void, _: i32, _: *const c_char) {}

unsafe extern "C" fn verify(
    context: *mut c_void,
    server_name: *const c_char,
    certificates: *const *const u8,
    lengths: *const usize,
    count: usize,
    error: *mut *mut c_char,
) -> i32 {
    let state = &*(context as *const CallbackState);
    let chain = (0..count)
        .map(|index| std::slice::from_raw_parts(*certificates.add(index), *lengths.add(index)).to_vec())
        .collect();
    let name = CStr::from_ptr(server_name).to_string_lossy().into_owned();
    state.seen.lock().unwrap().push((name, chain));
    if let Some(message) = state.error {
        *error = CString::new(message).unwrap().into_raw();
    }
    state.verdict
}

fn c_host(state: &CallbackState, with_verifier: bool) -> Arc<dyn Host> {
    host_from_callbacks_for_tests(CapgoHostCallbacks {
        context: state as *const CallbackState as *mut c_void,
        log: Some(log),
        kv_get: None,
        kv_set: None,
        kv_keys: None,
        emit: None,
        free_string: Some(free_string),
        hook: None,
        release: None,
        verify_server_certificate: if with_verifier { Some(verify) } else { None },
    })
}

#[test]
fn c_abi_verifier_marshals_the_chain_and_only_one_trusts() {
    let server = TlsServer::start();
    let url = format!("https://localhost:{}/", server.port);

    let trusted = CallbackState {
        verdict: 1,
        ..Default::default()
    };
    let response = http(c_host(&trusted, true)).get(&url).unwrap();
    assert_eq!(response.status, 200);
    assert_eq!(
        trusted.seen.lock().unwrap()[0],
        ("localhost".to_string(), vec![cert_der()])
    );

    for verdict in [0, -1, 2] {
        let rejected = CallbackState {
            verdict,
            error: Some("SecTrust: not trusted"),
            ..Default::default()
        };
        let error = http(c_host(&rejected, true)).get(&url).unwrap_err();
        assert_eq!(error.kind, NetErrorKind::Tls, "{verdict}: {error:?}");
        assert!(error.message.contains("SecTrust: not trusted"), "{error:?}");
    }

    let silent = CallbackState::default();
    let error = http(c_host(&silent, true)).get(&url).unwrap_err();
    assert_eq!(error.kind, NetErrorKind::Tls, "{error:?}");

    let error = http(c_host(&CallbackState::default(), false)).get(&url).unwrap_err();
    assert_eq!(error.kind, NetErrorKind::Tls, "{error:?}");
    assert_eq!(server.requests.load(Ordering::SeqCst), 1);
}

// ---------------------------------------------------------------------------
// System proxy (host `proxyForUrl` hook): plain HTTP is sent to the proxy in
// absolute form, HTTPS is tunnelled with CONNECT (TLS still verified end to end).

/// HTTP proxy recording request lines: answers absolute-form requests itself
/// and tunnels `CONNECT` to the target.
struct ProxyServer {
    port: u16,
    seen: Arc<Mutex<Vec<String>>>,
}

impl ProxyServer {
    fn start() -> Self {
        Self::start_on("127.0.0.1:0")
    }

    fn start_on(address: &str) -> Self {
        let listener = TcpListener::bind(address).unwrap();
        let port = listener.local_addr().unwrap().port();
        let seen: Arc<Mutex<Vec<String>>> = Arc::default();
        let recorded = seen.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let recorded = recorded.clone();
                std::thread::spawn(move || {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut request_line = String::new();
                    if reader.read_line(&mut request_line).unwrap_or(0) == 0 {
                        return;
                    }
                    loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                            break;
                        }
                    }
                    let request_line = request_line.trim().to_string();
                    recorded.lock().unwrap().push(request_line.clone());
                    if let Some(target) = request_line.strip_prefix("CONNECT ") {
                        let target = target.split(' ').next().unwrap().replace("localhost", "127.0.0.1");
                        let Ok(upstream) = TcpStream::connect(target) else {
                            return;
                        };
                        stream
                            .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
                            .unwrap();
                        let (mut client_read, mut upstream_write) =
                            (stream.try_clone().unwrap(), upstream.try_clone().unwrap());
                        let forward = std::thread::spawn(move || {
                            let _ = std::io::copy(&mut client_read, &mut upstream_write);
                            let _ = upstream_write.shutdown(std::net::Shutdown::Write);
                        });
                        let (mut upstream_read, mut client_write) = (upstream, stream);
                        let _ = std::io::copy(&mut upstream_read, &mut client_write);
                        let _ = client_write.shutdown(std::net::Shutdown::Both);
                        let _ = forward.join();
                    } else {
                        let _ = stream
                            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\nvia-proxy");
                    }
                });
            }
        });
        Self { port, seen }
    }

    fn seen(&self) -> Vec<String> {
        self.seen.lock().unwrap().clone()
    }
}

fn proxied_host(proxy: &ProxyServer) -> Arc<MemoryHost> {
    let host = memory_host(Some(Ok(())));
    host.reply_to_hook(
        "proxyForUrl",
        serde_json::json!({ "type": "http", "host": "127.0.0.1", "port": proxy.port }),
    );
    host
}

#[test]
fn plain_http_goes_through_the_system_proxy() {
    let proxy = ProxyServer::start();
    let host = proxied_host(&proxy);
    // `.invalid` never resolves: only the proxy can answer.
    let response = http(host.clone()).get("http://updates.invalid/latest?x=1").unwrap();
    assert_eq!(response.text(), "via-proxy");
    assert_eq!(
        proxy.seen(),
        vec!["GET http://updates.invalid/latest?x=1 HTTP/1.1".to_string()]
    );
    assert_eq!(
        host.hooks_named("proxyForUrl"),
        vec![serde_json::json!({ "url": "http://updates.invalid/latest?x=1" })]
    );
}

#[test]
fn https_is_tunnelled_with_connect_and_still_verified() {
    let server = TlsServer::start();
    let proxy = ProxyServer::start();
    let host = proxied_host(&proxy);
    let response = http(host.clone())
        .get(&format!("https://localhost:{}/", server.port))
        .unwrap();
    assert_eq!(response.text(), "ok");
    assert_eq!(proxy.seen()[0], format!("CONNECT localhost:{} HTTP/1.1", server.port));
    assert_eq!(host.certificate_requests.lock().unwrap()[0].1, "localhost");

    // Through the proxy too, a host rejection fails closed (a new client: no TLS session to resume).
    *host.certificate_verdict.lock().unwrap() = Some(Some(Err("pinned".into())));
    let error = http(host.clone())
        .get(&format!("https://localhost:{}/again", server.port))
        .unwrap_err();
    assert_eq!(error.kind, NetErrorKind::Tls, "{error:?}");
    assert_eq!(server.requests.load(Ordering::SeqCst), 1);
}

#[test]
fn direct_or_unusable_proxy_replies_connect_directly() {
    let proxy = ProxyServer::start();
    let target = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let port = target.server_addr().to_ip().unwrap().port();
    std::thread::spawn(move || {
        for request in target.incoming_requests() {
            let _ = request.respond(tiny_http::Response::from_string("direct"));
        }
    });
    for reply in [
        serde_json::json!({ "type": "direct" }),
        serde_json::json!({ "type": "socks", "host": "127.0.0.1", "port": proxy.port }),
        serde_json::json!({ "type": "http", "host": "", "port": proxy.port }),
        serde_json::json!({ "type": "http", "host": "127.0.0.1", "port": 0 }),
        serde_json::json!({ "type": "http", "host": "127.0.0.1:1", "port": proxy.port }),
        serde_json::json!({ "type": "http", "host": "user@127.0.0.1", "port": proxy.port }),
        serde_json::json!({}),
    ] {
        let host = memory_host(None);
        host.reply_to_hook("proxyForUrl", reply.clone());
        let response = http(host).get(&format!("http://127.0.0.1:{port}/")).unwrap();
        assert_eq!(response.text(), "direct", "{reply}");
    }
    assert!(proxy.seen().is_empty());
}

/// IPv6 proxy literals (Android `getHostString()` has no brackets, iOS may add them).
#[test]
fn ipv6_proxies_are_used() {
    if TcpListener::bind("[::1]:0").is_err() {
        eprintln!("skipped: no IPv6 loopback");
        return;
    }
    for host_name in ["::1", "[::1]"] {
        let proxy = ProxyServer::start_on("[::1]:0");
        let host = memory_host(Some(Ok(())));
        host.reply_to_hook(
            "proxyForUrl",
            serde_json::json!({ "type": "http", "host": host_name, "port": proxy.port }),
        );
        let response = http(host).get("http://updates.invalid/v6").unwrap();
        assert_eq!(response.text(), "via-proxy", "{host_name}");
        assert_eq!(proxy.seen(), vec!["GET http://updates.invalid/v6 HTTP/1.1".to_string()]);
    }
}

#[test]
fn proxy_replies_parse() {
    use capgo_updater_core::host::HttpProxy;
    assert_eq!(
        HttpProxy::from_reply(&serde_json::json!({ "type": "HTTP", "host": " proxy.corp ", "port": 3128 })),
        Some(HttpProxy {
            host: "proxy.corp".into(),
            port: 3128
        })
    );
    assert_eq!(
        HttpProxy::from_reply(&serde_json::json!({ "type": "http", "host": "[fe80::1]", "port": 8080 })),
        Some(HttpProxy {
            host: "fe80::1".into(),
            port: 8080
        })
    );
    for reply in [
        serde_json::json!({ "type": "http", "host": "fe80::zz", "port": 3128 }),
        serde_json::json!({ "type": "direct", "host": "proxy.corp", "port": 3128 }),
        serde_json::json!({ "type": "http", "host": "proxy.corp", "port": 65536 }),
        serde_json::json!({ "type": "http", "host": "proxy.corp", "port": "3128" }),
        serde_json::json!({ "type": "http", "port": 3128 }),
        serde_json::Value::Null,
    ] {
        assert_eq!(HttpProxy::from_reply(&reply), None, "{reply}");
    }
}
