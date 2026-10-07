//! HTTP client used by the engine (update checks, channels, stats, bundle
//! downloads). Plain HTTP/1.1 over rustls; certificate chains are verified by
//! the operating system trust store through the host (Android
//! `X509TrustManager`, iOS `SecTrust`), host names by rustls.

use crate::sync::{LockRecover, RwLockRecover};
use std::io::Read;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use serde_json::Value;

use crate::host::{Host, HttpProxy};

/// Largest non-download response body accepted (JSON API responses).
const MAX_API_BODY_BYTES: u64 = 16 * 1024 * 1024;
const MAX_REDIRECTS: usize = 5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetErrorKind {
    Timeout,
    Network,
    Tls,
    InvalidUrl,
    InsecureRedirect,
    Io,
}

#[derive(Debug, Clone)]
pub struct NetError {
    pub kind: NetErrorKind,
    pub message: String,
}

impl NetError {
    pub fn is_timeout(&self) -> bool {
        self.kind == NetErrorKind::Timeout
    }
}

impl std::fmt::Display for NetError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

#[derive(Debug, Clone)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    pub fn is_success(&self) -> bool {
        (200..300).contains(&self.status)
    }

    pub fn json(&self) -> Option<Value> {
        serde_json::from_slice(&self.body).ok()
    }
}

/// Response head of a streamed download.
#[derive(Debug, Clone)]
pub struct StreamHead {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub content_length: Option<u64>,
}

impl StreamHead {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

pub struct Http {
    agent: RwLock<ureq::Agent>,
    /// Bundle transfers: per-read timeout of at least 60 s (large files on slow links).
    download_agent: RwLock<ureq::Agent>,
    tls: Arc<ClientConfig>,
    user_agent: RwLock<String>,
    timeout: RwLock<Duration>,
    allow_https_to_http_redirect: std::sync::atomic::AtomicBool,
    host: Arc<dyn Host>,
    /// Cleartext decisions per host name.
    cleartext: Mutex<std::collections::HashMap<String, bool>>,
    /// Agents for system HTTP proxies (ureq sets the proxy per agent), keyed
    /// by (download agent, proxy). Rebuilt when the timeout changes.
    proxied: Mutex<std::collections::HashMap<(bool, HttpProxy), ureq::Agent>>,
}

fn classify_io(error: &std::io::Error) -> NetErrorKind {
    match error.kind() {
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => NetErrorKind::Timeout,
        _ => {
            let text = error.to_string().to_ascii_lowercase();
            if text.contains("timed out") || text.contains("timeout") {
                NetErrorKind::Timeout
            } else if text.contains("certificate") || text.contains("tls") || text.contains("handshake") {
                NetErrorKind::Tls
            } else {
                NetErrorKind::Network
            }
        }
    }
}

fn transport_error(error: ureq::Transport) -> NetError {
    let message = error.to_string();
    let kind = match error.kind() {
        ureq::ErrorKind::InvalidUrl | ureq::ErrorKind::UnknownScheme => NetErrorKind::InvalidUrl,
        ureq::ErrorKind::Io | ureq::ErrorKind::ConnectionFailed => {
            let lower = message.to_ascii_lowercase();
            if lower.contains("timed out") || lower.contains("timeout") {
                NetErrorKind::Timeout
            } else if lower.contains("certificate") || lower.contains("tls") {
                NetErrorKind::Tls
            } else {
                NetErrorKind::Network
            }
        }
        _ => NetErrorKind::Network,
    };
    NetError { kind, message }
}

fn headers_of(response: &ureq::Response) -> Vec<(String, String)> {
    response
        .headers_names()
        .into_iter()
        .filter_map(|name| response.header(&name).map(|value| (name.clone(), value.to_string())))
        .collect()
}

impl Http {
    pub fn new(host: Arc<dyn Host>, user_agent: String, timeout: Duration) -> Self {
        let timeout = if timeout.is_zero() {
            Duration::from_secs(20)
        } else {
            timeout
        };
        let tls = Arc::new(tls_config(host.clone()));
        let agent = build_agent(tls.clone(), timeout);
        let download_agent = build_agent(tls.clone(), timeout.max(Duration::from_secs(60)));
        Self {
            agent: RwLock::new(agent),
            download_agent: RwLock::new(download_agent),
            tls,
            user_agent: RwLock::new(user_agent),
            timeout: RwLock::new(timeout),
            allow_https_to_http_redirect: std::sync::atomic::AtomicBool::new(false),
            host,
            cleartext: Mutex::new(std::collections::HashMap::new()),
            proxied: Mutex::new(std::collections::HashMap::new()),
        }
    }

    /// The agent for `url`: through the system HTTP proxy the host reports
    /// (Android `ProxySelector`, iOS system proxy settings), else direct.
    fn agent_for(&self, download: bool, url: &str) -> ureq::Agent {
        let direct = || {
            if download {
                self.download_agent.read_or_recover().clone()
            } else {
                self.agent.read_or_recover().clone()
            }
        };
        let Some(proxy) = self.host.proxy_for_url(url) else {
            return direct();
        };
        let mut proxied = self.proxied.lock_or_recover();
        if let Some(agent) = proxied.get(&(download, proxy.clone())) {
            return agent.clone();
        }
        // ureq parses the proxy `host:port` by splitting on ':', so it gets a placeholder name
        // that `ProxyResolver` maps to the real host (IPv6 literals included).
        let Ok(ureq_proxy) = ureq::Proxy::new(format!("http://{PROXY_PLACEHOLDER}:{}", proxy.port)) else {
            return direct();
        };
        let timeout = *self.timeout.read_or_recover();
        let timeout = if download {
            timeout.max(Duration::from_secs(60))
        } else {
            timeout
        };
        self.host.log(
            crate::host::LogLevel::Debug,
            &format!("Using system HTTP proxy {}:{}", proxy.host, proxy.port),
        );
        let agent = agent_builder(self.tls.clone(), timeout)
            .proxy(ureq_proxy)
            .resolver(ProxyResolver(proxy.clone()))
            .build();
        proxied.insert((download, proxy), agent.clone());
        agent
    }

    /// Plain HTTP must be allowed by the app's own policy (the OS stacks enforce
    /// it for their clients; this client has to ask).
    fn check_cleartext(&self, url: &str) -> Result<(), NetError> {
        let Ok(parsed) = url::Url::parse(url) else {
            return Ok(());
        };
        if parsed.scheme() != "http" {
            return Ok(());
        }
        let host = parsed.host_str().unwrap_or_default().to_ascii_lowercase();
        let cached = self.cleartext.lock_or_recover().get(&host).copied();
        let permitted = match cached {
            Some(permitted) => permitted,
            // No answer (no policy hook, hook error): fail closed, as the OS HTTP stacks do.
            None => match self.host.cleartext_permitted(&host) {
                Some(permitted) => {
                    self.cleartext.lock_or_recover().insert(host.clone(), permitted);
                    permitted
                }
                None => false,
            },
        };
        if permitted {
            Ok(())
        } else {
            Err(NetError {
                kind: NetErrorKind::InvalidUrl,
                message: format!(
                    "Cleartext HTTP traffic to {host} is not permitted by the app's network security policy"
                ),
            })
        }
    }

    pub fn set_user_agent(&self, user_agent: String) {
        *self.user_agent.write_or_recover() = user_agent;
    }

    pub fn user_agent(&self) -> String {
        self.user_agent.read_or_recover().clone()
    }

    /// Updates connect/read/write timeouts (0 keeps the 20 s default).
    pub fn set_timeout(&self, timeout: Duration) {
        let timeout = if timeout.is_zero() {
            Duration::from_secs(20)
        } else {
            timeout
        };
        let mut current = self.timeout.write_or_recover();
        if *current == timeout {
            return;
        }
        *current = timeout;
        *self.agent.write_or_recover() = build_agent(self.tls.clone(), timeout);
        *self.download_agent.write_or_recover() = build_agent(self.tls.clone(), timeout.max(Duration::from_secs(60)));
        // `agent_for` reads the timeout while holding `proxied`: release the timeout first
        // (lock order). Clearing afterwards drops any agent built with the old timeout.
        drop(current);
        self.proxied.lock_or_recover().clear();
    }

    fn prepare(&self, agent: ureq::Agent, method: &str, url: &str, headers: &[(&str, &str)]) -> ureq::Request {
        let mut request = agent.request(method, url).set("User-Agent", &self.user_agent());
        for (name, value) in headers {
            request = request.set(name, value);
        }
        request
    }

    /// Sends a request, following up to 5 redirects. A redirect from HTTPS to
    /// plain HTTP is refused unless `allowHttpsToHttpRedirect` is set.
    fn execute(
        &self,
        download: bool,
        method: &str,
        url: &str,
        headers: &[(&str, &str)],
        body: Option<&[u8]>,
    ) -> Result<ureq::Response, NetError> {
        crate::host::release_method_lane();
        let mut current = url.to_string();
        let mut method = method.to_string();
        let mut body = body;
        for _ in 0..=MAX_REDIRECTS {
            self.check_cleartext(&current)?;
            let request = self.prepare(self.agent_for(download, &current), &method, &current, headers);
            let response = Self::finish(match body {
                Some(body) => request.send_bytes(body),
                None => request.call(),
            })?;
            let status = response.status();
            if !(300..400).contains(&status) || status == 304 {
                return Ok(response);
            }
            let Some(location) = response.header("Location").map(str::to_string) else {
                return Ok(response);
            };
            let base = url::Url::parse(&current).map_err(|error| NetError {
                kind: NetErrorKind::InvalidUrl,
                message: error.to_string(),
            })?;
            let next = base.join(&location).map_err(|error| NetError {
                kind: NetErrorKind::InvalidUrl,
                message: error.to_string(),
            })?;
            if !redirect_allowed(
                base.scheme(),
                next.scheme(),
                self.allow_https_to_http_redirect
                    .load(std::sync::atomic::Ordering::SeqCst),
            ) {
                return Err(NetError {
                    kind: NetErrorKind::InsecureRedirect,
                    message: format!("Refused redirect from HTTPS to HTTP: {next}"),
                });
            }
            // 303 (and 301/302 for POST, like browsers) switch to GET without a body.
            if status == 303 || ((status == 301 || status == 302) && method != "GET" && method != "HEAD") {
                method = "GET".into();
                body = None;
            }
            current = next.to_string();
        }
        Err(NetError {
            kind: NetErrorKind::Network,
            message: "Too many redirects".into(),
        })
    }

    pub fn set_allow_https_to_http_redirect(&self, allow: bool) {
        self.allow_https_to_http_redirect
            .store(allow, std::sync::atomic::Ordering::SeqCst);
    }

    fn finish(result: Result<ureq::Response, ureq::Error>) -> Result<ureq::Response, NetError> {
        match result {
            Ok(response) => Ok(response),
            // Non-2xx responses are still responses; callers decide.
            Err(ureq::Error::Status(_, response)) => Ok(response),
            Err(ureq::Error::Transport(transport)) => Err(transport_error(transport)),
        }
    }

    /// Sends a request and buffers the (API sized) response body.
    pub fn send(
        &self,
        method: &str,
        url: &str,
        headers: &[(&str, &str)],
        body: Option<&[u8]>,
    ) -> Result<Response, NetError> {
        // Transparent gzip, as OkHttp and URLSession did for API calls.
        let headers = with_accept_encoding(headers, "gzip");
        let response = self.execute(false, method, url, &headers, body)?;
        let status = response.status();
        let mut headers = headers_of(&response);
        let gzip = response.header("Content-Encoding").is_some_and(|value| {
            value.trim().eq_ignore_ascii_case("gzip") || value.trim().eq_ignore_ascii_case("x-gzip")
        });
        let read_error = |error: std::io::Error| NetError {
            kind: classify_io(&error),
            message: error.to_string(),
        };
        let mut buffer = Vec::new();
        response
            .into_reader()
            .take(MAX_API_BODY_BYTES)
            .read_to_end(&mut buffer)
            .map_err(read_error)?;
        if gzip {
            // The decoded size is capped too (gzip bomb).
            let mut decoded = Vec::new();
            if !buffer.is_empty() {
                flate2::read::MultiGzDecoder::new(buffer.as_slice())
                    .take(MAX_API_BODY_BYTES)
                    .read_to_end(&mut decoded)
                    .map_err(read_error)?;
            }
            buffer = decoded;
            headers.retain(|(name, _)| {
                !name.eq_ignore_ascii_case("Content-Encoding") && !name.eq_ignore_ascii_case("Content-Length")
            });
        }
        Ok(Response {
            status,
            headers,
            body: buffer,
        })
    }

    pub fn get(&self, url: &str) -> Result<Response, NetError> {
        self.send("GET", url, &[], None)
    }

    pub fn post_json(&self, url: &str, body: &Value) -> Result<Response, NetError> {
        self.send_json("POST", url, body)
    }

    pub fn send_json(&self, method: &str, url: &str, body: &Value) -> Result<Response, NetError> {
        let bytes = serde_json::to_vec(body).unwrap_or_default();
        self.send(
            method,
            url,
            &[
                ("Content-Type", "application/json; charset=utf-8"),
                ("Accept", "application/json"),
            ],
            Some(&bytes),
        )
    }

    /// Streams a GET response to `handler`: first [`Stream::Head`], then every
    /// [`Stream::Chunk`]. An error from the handler aborts the transfer.
    pub fn download(
        &self,
        url: &str,
        headers: &[(&str, &str)],
        handler: &mut dyn FnMut(Stream<'_>) -> Result<(), NetError>,
    ) -> Result<StreamHead, NetError> {
        // Bundle files are stored byte for byte (checksums, Range resume): no content coding.
        let headers = with_accept_encoding(headers, "identity");
        let response = self.execute(true, "GET", url, &headers, None)?;
        let head = StreamHead {
            status: response.status(),
            headers: headers_of(&response),
            content_length: response
                .header("Content-Length")
                .and_then(|value| value.trim().parse().ok()),
        };
        handler(Stream::Head(&head))?;
        let mut reader = response.into_reader();
        let mut buffer = vec![0u8; crate::crypto::checksum::IO_BUFFER_BYTES];
        loop {
            let read = reader.read(&mut buffer).map_err(|error| NetError {
                kind: classify_io(&error),
                message: error.to_string(),
            })?;
            if read == 0 {
                break;
            }
            handler(Stream::Chunk(&buffer[..read]))?;
        }
        Ok(head)
    }
}

/// `headers` plus `Accept-Encoding: <value>` unless the caller set one.
fn with_accept_encoding<'a>(headers: &[(&'a str, &'a str)], value: &'a str) -> Vec<(&'a str, &'a str)> {
    let mut headers = headers.to_vec();
    if !headers
        .iter()
        .any(|(name, _)| name.eq_ignore_ascii_case("Accept-Encoding"))
    {
        headers.push(("Accept-Encoding", value));
    }
    headers
}

/// A redirect may never downgrade HTTPS to plain HTTP unless explicitly allowed.
pub fn redirect_allowed(from_scheme: &str, to_scheme: &str, allow_downgrade: bool) -> bool {
    !(from_scheme.eq_ignore_ascii_case("https") && to_scheme.eq_ignore_ascii_case("http")) || allow_downgrade
}

/// Events of [`Http::download`].
pub enum Stream<'a> {
    Head(&'a StreamHead),
    Chunk(&'a [u8]),
}

/// Proxy server name given to ureq; [`ProxyResolver`] resolves it to the real proxy.
const PROXY_PLACEHOLDER: &str = "capgo-system-proxy";

/// Resolves the proxy of a proxied agent (the only name such an agent resolves:
/// the target host is sent to the proxy). Host names go through DNS, IPv4 and
/// IPv6 literals are used as they are.
struct ProxyResolver(HttpProxy);

impl ureq::Resolver for ProxyResolver {
    fn resolve(&self, netloc: &str) -> std::io::Result<Vec<std::net::SocketAddr>> {
        use std::net::ToSocketAddrs;
        if netloc.split(':').next() == Some(PROXY_PLACEHOLDER) {
            (self.0.host.as_str(), self.0.port)
                .to_socket_addrs()
                .map(Iterator::collect)
        } else {
            netloc.to_socket_addrs().map(Iterator::collect)
        }
    }
}

fn build_agent(tls: Arc<ClientConfig>, timeout: Duration) -> ureq::Agent {
    agent_builder(tls, timeout).try_proxy_from_env(true).build()
}

fn agent_builder(tls: Arc<ClientConfig>, timeout: Duration) -> ureq::AgentBuilder {
    ureq::AgentBuilder::new()
        .tls_connector(Arc::new(RustlsConnector(tls)))
        .timeout_connect(timeout)
        .timeout_read(timeout)
        .timeout_write(timeout)
        .max_idle_connections(64)
        .max_idle_connections_per_host(64)
        .redirects(0)
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

fn tls_config(host: Arc<dyn Host>) -> ClientConfig {
    let provider = provider();
    let builder = ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .expect("ring supports the default TLS versions");
    let verifier: Arc<dyn ServerCertVerifier> = Arc::new(HostVerifier { host, provider });
    builder
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth()
}

/// A certificate rejection reported by the host trust store.
#[derive(Debug)]
struct CertificateRejected(String);

impl std::fmt::Display for CertificateRejected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for CertificateRejected {}

fn certificate_rejected(message: String) -> rustls::Error {
    rustls::Error::InvalidCertificate(rustls::CertificateError::Other(rustls::OtherError(Arc::new(
        CertificateRejected(message),
    ))))
}

/// Chain trust comes from the host's platform trust store (Android
/// `X509TrustManager` with the network security config and user CAs, iOS
/// `SecTrust`); the host name is checked here. No answer fails closed.
#[derive(Debug)]
struct HostVerifier {
    host: Arc<dyn Host>,
    provider: Arc<CryptoProvider>,
}

impl std::fmt::Debug for dyn Host {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Host")
    }
}

impl ServerCertVerifier for HostVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let name = match server_name {
            ServerName::DnsName(name) => name.as_ref().to_string(),
            ServerName::IpAddress(ip) => std::net::IpAddr::from(*ip).to_string(),
            _ => String::new(),
        };
        let mut chain: Vec<&[u8]> = vec![end_entity.as_ref()];
        chain.extend(intermediates.iter().map(|cert| cert.as_ref()));
        match self.host.verify_server_certificate(&chain, &name) {
            Some(Ok(())) => {
                // The host checked the chain; the name is always checked here too.
                let parsed = rustls::server::ParsedCertificate::try_from(end_entity)?;
                rustls::client::verify_server_name(&parsed, server_name)?;
                Ok(ServerCertVerified::assertion())
            }
            Some(Err(message)) => Err(certificate_rejected(message)),
            None => Err(certificate_rejected("No certificate verifier available".into())),
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

/// TLS for ureq over our own rustls config (ureq's `tls` feature would also
/// compile in the webpki-roots CA table, which this client never uses).
struct RustlsConnector(Arc<ClientConfig>);

struct RustlsStream(rustls::StreamOwned<rustls::ClientConnection, Box<dyn ureq::ReadWrite>>);

impl std::fmt::Debug for RustlsStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RustlsStream")
    }
}

impl std::io::Read for RustlsStream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.0.read(buf)
    }
}

impl std::io::Write for RustlsStream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.0.flush()
    }
}

impl ureq::ReadWrite for RustlsStream {
    fn socket(&self) -> Option<&std::net::TcpStream> {
        self.0.get_ref().socket()
    }
}

impl ureq::TlsConnector for RustlsConnector {
    fn connect(
        &self,
        dns_name: &str,
        mut io: Box<dyn ureq::ReadWrite>,
    ) -> Result<Box<dyn ureq::ReadWrite>, ureq::Error> {
        let host = dns_name.trim_start_matches('[').trim_end_matches(']');
        let name = ServerName::try_from(host.to_string()).map_err(|_| {
            ureq::Error::from(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("invalid TLS server name {host}"),
            ))
        })?;
        let mut connection = rustls::ClientConnection::new(self.0.clone(), name)
            .map_err(|error| ureq::Error::from(std::io::Error::other(error)))?;
        // Handshake now, so certificate errors surface as connection errors.
        while connection.is_handshaking() {
            connection.complete_io(&mut io).map_err(ureq::Error::from)?;
        }
        Ok(Box::new(RustlsStream(rustls::StreamOwned::new(connection, io))))
    }
}

/// Verifies a chain with the OS trust store of the machine running the tests
/// (what [`crate::host::MemoryHost`] answers); shipped hosts use their own.
#[cfg(feature = "test-support")]
pub fn platform_verify_for_tests(chain: &[&[u8]], server_name: &str) -> Result<(), String> {
    let verifier = rustls_platform_verifier::Verifier::new().with_provider(provider());
    let name = ServerName::try_from(server_name.to_string()).map_err(|error| error.to_string())?;
    let (leaf, intermediates) = chain.split_first().ok_or("Empty certificate chain")?;
    let intermediates: Vec<CertificateDer<'static>> = intermediates
        .iter()
        .map(|cert| CertificateDer::from(cert.to_vec()))
        .collect();
    verifier
        .verify_server_cert(
            &CertificateDer::from(leaf.to_vec()),
            &intermediates,
            &name,
            &[],
            UnixTime::now(),
        )
        .map(|_| ())
        .map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reports one HTTP proxy for every URL.
    struct Proxied;

    impl Host for Proxied {
        fn log(&self, _level: crate::host::LogLevel, _message: &str) {}
        fn kv_get(&self, _key: &str, default: Option<&str>) -> Option<String> {
            default.map(str::to_string)
        }
        fn kv_set(&self, _key: &str, _value: Option<&str>) {}
        fn kv_keys(&self) -> Vec<String> {
            Vec::new()
        }
        fn emit(&self, _event: &str, _payload: &Value) {}
        fn hook(&self, _name: &str, _payload: &Value) -> Option<Value> {
            Some(serde_json::json!({ "type": "http", "host": "127.0.0.1", "port": 3128 }))
        }
    }

    /// `agent_for` reads the timeout under the `proxied` lock, `set_timeout` clears `proxied`:
    /// they must not take the two locks in opposite orders.
    #[test]
    fn proxy_agents_and_timeout_updates_do_not_deadlock() {
        let http = Arc::new(Http::new(Arc::new(Proxied), "test".into(), Duration::from_secs(5)));
        let (done, finished) = std::sync::mpsc::channel();
        for worker in 0..2 {
            let http = http.clone();
            let done = done.clone();
            std::thread::spawn(move || {
                for round in 0..20_000u64 {
                    if worker == 0 {
                        http.set_timeout(Duration::from_secs(1 + round % 2));
                    } else {
                        let _ = http.agent_for(round % 2 == 0, "http://updates.invalid/");
                    }
                }
                let _ = done.send(());
            });
        }
        for _ in 0..2 {
            finished
                .recv_timeout(Duration::from_secs(30))
                .expect("set_timeout and agent_for deadlocked");
        }
    }
}
