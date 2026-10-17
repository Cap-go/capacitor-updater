//! A local HTTPS origin for the HTTP/3 tests: the same scripted responses over TCP + TLS
//! (HTTP/1.1, announcing `Alt-Svc: h3`) and over QUIC (HTTP/3, quinn + h3), with the
//! self-signed `localhost` certificate below. Every request is recorded with its protocol.

use std::io::{Read, Write};
use std::net::{TcpListener, UdpSocket};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::{Buf, Bytes};
use capgo_updater_core::text::base64_decode;

/// Self-signed EC P-256 certificate for `localhost` (SAN DNS:localhost only), valid until 2126.
pub const CERT_DER_BASE64: &str = "MIIBlTCCATugAwIBAgIUJ5aRle5e8iK9YLs/MZNuxZYugd0wCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAwMTAzMTY1MVoYDzIxMjYwOTA3MDMxNjUxWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQPuthMBpvhPqOhuFEwC3eYmswof9VhLzrSNCLx7zY3Rc2nS3tQvldeDafMd3KqdSwm5Em0rWqI57+KpSTHmUf+o2kwZzAdBgNVHQ4EFgQUYt8DOmvp6RcdA1LBK7EHHfW5gGgwHwYDVR0jBBgwFoAUYt8DOmvp6RcdA1LBK7EHHfW5gGgwDwYDVR0TAQH/BAUwAwEB/zAUBgNVHREEDTALgglsb2NhbGhvc3QwCgYIKoZIzj0EAwIDSAAwRQIhAI5s0aFIxwPQtpTmjpdv2WZ0cAeCznQ5KTwV1L+Jj5k8AiA9dehLNJAhExhzonmiMWF0qIR1juFPqLYcjoXW4Ty+Ng==";
/// PKCS#8 private key of [`CERT_DER_BASE64`].
pub const KEY_DER_BASE64: &str = "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgNQgLefPtIfW+OBi7uhUe+lNioJW9XcDaw9Y3x+N+IyehRANCAAQPuthMBpvhPqOhuFEwC3eYmswof9VhLzrSNCLx7zY3Rc2nS3tQvldeDafMd3KqdSwm5Em0rWqI57+KpSTHmUf+";

pub fn cert_der() -> Vec<u8> {
    base64_decode(CERT_DER_BASE64).unwrap()
}

fn key_der() -> Vec<u8> {
    base64_decode(KEY_DER_BASE64).unwrap()
}

pub const HTTP1: &str = "http/1.1";
pub const H3: &str = "h3";

/// A request as the server saw it.
#[derive(Clone, Debug)]
pub struct Seen {
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub protocol: &'static str,
    /// QUIC connection number (1-based) for HTTP/3, 0 for HTTP/1.1.
    pub connection: usize,
}

impl Seen {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

/// A scripted answer.
#[derive(Clone, Debug, Default)]
pub struct Reply {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    /// Wait before the head.
    pub delay: Duration,
    /// Stop after this many body bytes (HTTP/3: stream reset, HTTP/1.1: connection closed).
    pub abort_after: Option<usize>,
    /// Close the QUIC connection before sending the response head.
    pub close_connection: bool,
    /// Content-Length to announce (default: the body length); `Some(None)`: none.
    pub length: Option<Option<u64>>,
    /// Wait between body chunks of 16 KiB.
    pub chunk_delay: Duration,
}

impl Reply {
    pub fn ok(body: impl Into<Vec<u8>>) -> Self {
        Self {
            status: 200,
            body: body.into(),
            ..Self::default()
        }
    }

    pub fn status(status: u16) -> Self {
        Self {
            status,
            ..Self::default()
        }
    }

    pub fn header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.to_string(), value.to_string()));
        self
    }

    fn announced_length(&self) -> Option<u64> {
        self.length.unwrap_or(Some(self.body.len() as u64))
    }
}

type Responder = Arc<dyn Fn(&Seen) -> Reply + Send + Sync>;

pub struct H3Server {
    /// TCP (HTTPS) port: the origin is `https://localhost:<port>`.
    pub port: u16,
    /// UDP port of the HTTP/3 endpoint.
    pub udp_port: u16,
    seen: Arc<Mutex<Vec<Seen>>>,
    /// QUIC connections accepted.
    pub quic_connections: Arc<AtomicUsize>,
    /// `Alt-Svc` value added to HTTP/1.1 responses (none when empty).
    pub advertise: Arc<Mutex<String>>,
}

fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap()
    })
}

// Deliberately corrupt CertificateVerify while retaining a valid certificate chain.
#[derive(Debug)]
struct BadSignatureResolver(Arc<dyn rustls::server::ResolvesServerCert>);
#[derive(Debug)]
struct BadSignatureKey(Arc<dyn rustls::sign::SigningKey>);
#[derive(Debug)]
struct BadSigner(Box<dyn rustls::sign::Signer>);
impl rustls::server::ResolvesServerCert for BadSignatureResolver {
    fn resolve(&self, hello: rustls::server::ClientHello<'_>) -> Option<Arc<rustls::sign::CertifiedKey>> {
        let key = self.0.resolve(hello)?;
        Some(Arc::new(rustls::sign::CertifiedKey::new(
            key.cert.clone(),
            Arc::new(BadSignatureKey(key.key.clone())),
        )))
    }
}
impl rustls::sign::SigningKey for BadSignatureKey {
    fn choose_scheme(&self, offered: &[rustls::SignatureScheme]) -> Option<Box<dyn rustls::sign::Signer>> {
        Some(Box::new(BadSigner(self.0.choose_scheme(offered)?)))
    }
    fn algorithm(&self) -> rustls::SignatureAlgorithm {
        self.0.algorithm()
    }
}
impl rustls::sign::Signer for BadSigner {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, rustls::Error> {
        let mut signature = self.0.sign(message)?;
        if let Some(byte) = signature.last_mut() {
            *byte ^= 1;
        }
        Ok(signature)
    }
    fn scheme(&self) -> rustls::SignatureScheme {
        self.0.scheme()
    }
}
fn corrupt_signature(config: &mut rustls::ServerConfig, corrupt: bool) {
    if corrupt {
        config.cert_resolver = Arc::new(BadSignatureResolver(config.cert_resolver.clone()));
    }
}

impl H3Server {
    pub fn start(responder: impl Fn(&Seen) -> Reply + Send + Sync + 'static) -> Self {
        Self::start_inner(responder, false, false)
    }
    pub fn invalid_signature(responder: impl Fn(&Seen) -> Reply + Send + Sync + 'static) -> Self {
        Self::start_inner(responder, true, false)
    }
    pub fn chacha20(responder: impl Fn(&Seen) -> Reply + Send + Sync + 'static) -> Self {
        Self::start_inner(responder, false, true)
    }
    fn start_inner(
        responder: impl Fn(&Seen) -> Reply + Send + Sync + 'static,
        invalid_signature: bool,
        chacha20: bool,
    ) -> Self {
        let responder: Responder = Arc::new(responder);
        let seen: Arc<Mutex<Vec<Seen>>> = Arc::default();
        let quic_connections = Arc::new(AtomicUsize::new(0));
        let advertise = Arc::new(Mutex::new(String::new()));

        // TCP + TLS, HTTP/1.1, one request per connection.
        let tls = {
            let mut provider = rustls::crypto::ring::default_provider();
            if chacha20 {
                provider.cipher_suites = vec![
                    rustls::crypto::ring::cipher_suite::TLS13_CHACHA20_POLY1305_SHA256,
                    rustls::crypto::ring::cipher_suite::TLS13_AES_128_GCM_SHA256,
                ];
            }
            let provider = Arc::new(provider);
            let mut config = rustls::ServerConfig::builder_with_provider(provider)
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(
                    vec![rustls::pki_types::CertificateDer::from(cert_der())],
                    rustls::pki_types::PrivateKeyDer::Pkcs8(key_der().into()),
                )
                .unwrap();
            corrupt_signature(&mut config, invalid_signature);
            Arc::new(config)
        };
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        {
            let (seen, responder, advertise) = (seen.clone(), responder.clone(), advertise.clone());
            std::thread::spawn(move || {
                for stream in listener.incoming() {
                    let Ok(stream) = stream else { continue };
                    let (tls, seen, responder, advertise) =
                        (tls.clone(), seen.clone(), responder.clone(), advertise.clone());
                    std::thread::spawn(move || serve_tcp(stream, tls, &seen, &responder, &advertise));
                }
            });
        }

        // QUIC, HTTP/3.
        let mut provider = rustls::crypto::ring::default_provider();
        if chacha20 {
            provider.cipher_suites = vec![
                rustls::crypto::ring::cipher_suite::TLS13_CHACHA20_POLY1305_SHA256,
                rustls::crypto::ring::cipher_suite::TLS13_AES_128_GCM_SHA256,
            ];
        }
        let mut crypto = rustls::ServerConfig::builder_with_provider(Arc::new(provider))
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![rustls::pki_types::CertificateDer::from(cert_der())],
                rustls::pki_types::PrivateKeyDer::Pkcs8(key_der().into()),
            )
            .unwrap();
        corrupt_signature(&mut crypto, invalid_signature);
        crypto.ignore_client_order = true;
        crypto.alpn_protocols = vec![b"h3".to_vec()];
        crypto.max_early_data_size = 0;
        let server_config = quinn::ServerConfig::with_crypto(Arc::new(
            quinn::crypto::rustls::QuicServerConfig::try_from(Arc::new(crypto)).unwrap(),
        ));
        let endpoint = {
            let _guard = runtime().enter();
            quinn::Endpoint::server(server_config, "127.0.0.1:0".parse().unwrap()).unwrap()
        };
        let udp_port = endpoint.local_addr().unwrap().port();
        {
            let (seen, responder, connections, advertise) = (
                seen.clone(),
                responder.clone(),
                quic_connections.clone(),
                advertise.clone(),
            );
            runtime().spawn(async move {
                while let Some(incoming) = endpoint.accept().await {
                    let (seen, responder, connections, advertise) =
                        (seen.clone(), responder.clone(), connections.clone(), advertise.clone());
                    tokio::spawn(async move {
                        let Ok(connection) = incoming.await else { return };
                        let transport = connection.clone();
                        let number = connections.fetch_add(1, Ordering::SeqCst) + 1;
                        let Ok(mut session) = h3::server::builder()
                            .build::<_, Bytes>(h3_quinn::Connection::new(connection))
                            .await
                        else {
                            return;
                        };
                        while let Ok(Some(resolver)) = session.accept().await {
                            let (seen, responder, advertise, transport) =
                                (seen.clone(), responder.clone(), advertise.clone(), transport.clone());
                            tokio::spawn(async move {
                                let Ok((request, stream)) = resolver.resolve_request().await else {
                                    return;
                                };
                                let advertised = advertise.lock().unwrap().clone();
                                serve_h3(request, stream, number, &transport, &seen, &responder, &advertised).await;
                            });
                        }
                    });
                }
            });
        }
        let server = Self {
            port,
            udp_port,
            seen,
            quic_connections,
            advertise,
        };
        server.set_advertise(&format!("h3=\":{udp_port}\"; ma=3600"));
        server
    }

    pub fn url(&self, path: &str) -> String {
        format!("https://localhost:{}{path}", self.port)
    }

    pub fn origin(&self) -> String {
        format!("https://localhost:{}", self.port)
    }

    pub fn set_advertise(&self, value: &str) {
        *self.advertise.lock().unwrap() = value.to_string();
    }

    pub fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }

    pub fn protocols(&self) -> Vec<&'static str> {
        self.seen().iter().map(|seen| seen.protocol).collect()
    }
}

/// A UDP port where a socket is bound and never answers (UDP "blocked" by a middlebox).
pub fn blackhole_udp() -> (UdpSocket, u16) {
    let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    let port = socket.local_addr().unwrap().port();
    (socket, port)
}

fn serve_tcp(
    stream: std::net::TcpStream,
    tls: Arc<rustls::ServerConfig>,
    seen: &Mutex<Vec<Seen>>,
    responder: &Responder,
    advertise: &Mutex<String>,
) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let connection = rustls::ServerConnection::new(tls).unwrap();
    let mut tls = rustls::StreamOwned::new(connection, stream);
    let mut request = Vec::new();
    let mut buffer = [0u8; 4096];
    let head_end = loop {
        if let Some(end) = request.windows(4).position(|window| window == b"\r\n\r\n") {
            break end + 4;
        }
        match tls.read(&mut buffer) {
            Ok(0) | Err(_) => return,
            Ok(read) => request.extend_from_slice(&buffer[..read]),
        }
    };
    let head = String::from_utf8_lossy(&request[..head_end]).into_owned();
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or_default().split(' ');
    let method = first.next().unwrap_or_default().to_string();
    let path = first.next().unwrap_or_default().to_string();
    let headers: Vec<(String, String)> = lines
        .filter_map(|line| line.split_once(':'))
        .map(|(name, value)| (name.trim().to_ascii_lowercase(), value.trim().to_string()))
        .collect();
    let length: usize = headers
        .iter()
        .find(|(name, _)| name == "content-length")
        .and_then(|(_, value)| value.parse().ok())
        .unwrap_or(0);
    let mut body = request[head_end..].to_vec();
    while body.len() < length {
        match tls.read(&mut buffer) {
            Ok(0) | Err(_) => return,
            Ok(read) => body.extend_from_slice(&buffer[..read]),
        }
    }
    let recorded = Seen {
        method,
        path,
        headers,
        body,
        protocol: HTTP1,
        connection: 0,
    };
    seen.lock().unwrap().push(recorded.clone());
    let reply = responder(&recorded);
    std::thread::sleep(reply.delay);
    let mut out = format!("HTTP/1.1 {} X\r\nConnection: close\r\n", reply.status);
    if let Some(length) = reply.announced_length() {
        out.push_str(&format!("Content-Length: {length}\r\n"));
    }
    let advertised = advertise.lock().unwrap().clone();
    if !advertised.is_empty()
        && !reply
            .headers
            .iter()
            .any(|(name, _)| name.eq_ignore_ascii_case("alt-svc"))
    {
        out.push_str(&format!("Alt-Svc: {advertised}\r\n"));
    }
    for (name, value) in &reply.headers {
        out.push_str(&format!("{name}: {value}\r\n"));
    }
    out.push_str("\r\n");
    if tls.write_all(out.as_bytes()).is_err() {
        return;
    }
    let limit = reply.abort_after.unwrap_or(usize::MAX).min(reply.body.len());
    for chunk in reply.body[..limit].chunks(16 * 1024) {
        if tls.write_all(chunk).is_err() {
            return;
        }
        if !reply.chunk_delay.is_zero() {
            let _ = tls.flush();
            std::thread::sleep(reply.chunk_delay);
        }
    }
    let _ = tls.flush();
    if reply.abort_after.is_none() {
        tls.conn.send_close_notify();
        let _ = tls.flush();
    }
}

async fn serve_h3(
    request: http::Request<()>,
    mut stream: h3::server::RequestStream<h3_quinn::BidiStream<Bytes>, Bytes>,
    connection: usize,
    transport: &quinn::Connection,
    seen: &Mutex<Vec<Seen>>,
    responder: &Responder,
    advertised: &str,
) {
    let mut body = Vec::new();
    while let Ok(Some(mut data)) = stream.recv_data().await {
        let bytes = data.copy_to_bytes(data.remaining());
        body.extend_from_slice(&bytes);
    }
    let path = request
        .uri()
        .path_and_query()
        .map(|path| path.as_str().to_string())
        .unwrap_or_default();
    let mut headers: Vec<(String, String)> = request
        .headers()
        .iter()
        .map(|(name, value)| {
            (
                name.as_str().to_string(),
                String::from_utf8_lossy(value.as_bytes()).into_owned(),
            )
        })
        .collect();
    if let Some(authority) = request.uri().authority() {
        headers.push(("host".into(), authority.to_string()));
    }
    let recorded = Seen {
        method: request.method().to_string(),
        path,
        headers,
        body,
        protocol: H3,
        connection,
    };
    seen.lock().unwrap().push(recorded.clone());
    let reply = {
        let responder = responder.clone();
        let recorded = recorded.clone();
        tokio::task::spawn_blocking(move || responder(&recorded)).await.unwrap()
    };
    tokio::time::sleep(reply.delay).await;
    if reply.close_connection {
        transport.close(0u32.into(), b"test close before response");
        return;
    }
    let mut response = http::Response::builder().status(reply.status);
    if let Some(length) = reply.announced_length() {
        response = response.header("content-length", length.to_string());
    }
    if !advertised.is_empty()
        && !reply
            .headers
            .iter()
            .any(|(name, _)| name.eq_ignore_ascii_case("alt-svc"))
    {
        response = response.header("alt-svc", advertised);
    }
    for (name, value) in &reply.headers {
        response = response.header(name.to_ascii_lowercase(), value.as_str());
    }
    if stream.send_response(response.body(()).unwrap()).await.is_err() {
        return;
    }
    let limit = reply.abort_after.unwrap_or(usize::MAX).min(reply.body.len());
    for chunk in reply.body[..limit].chunks(16 * 1024) {
        if stream.send_data(Bytes::copy_from_slice(chunk)).await.is_err() {
            return;
        }
        if !reply.chunk_delay.is_zero() {
            tokio::time::sleep(reply.chunk_delay).await;
        }
    }
    if reply.abort_after.is_some() {
        // Let the client read what was sent: a reset may discard unread data.
        tokio::time::sleep(Duration::from_millis(300)).await;
        stream.stop_stream(h3::error::Code::H3_INTERNAL_ERROR);
        return;
    }
    let _ = stream.finish().await;
}
