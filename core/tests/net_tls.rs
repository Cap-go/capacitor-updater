//! TLS trust is a host decision (Android TrustManager, iOS SecTrust): these
//! tests run a local HTTPS server and check that the engine's client only
//! talks to it when the host trusts the chain AND the name matches, and fails
//! closed otherwise (rejection, no answer, no callback).

use std::ffi::{c_char, c_void, CStr, CString};
use std::io::{Read, Write};
use std::net::TcpListener;
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
