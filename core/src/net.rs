//! HTTP client used by the engine (update checks, channels, stats, bundle
//! downloads). Plain HTTP/1.1 over rustls; certificates are verified by the
//! operating system trust store (Security.framework on Apple platforms, the
//! Android `X509TrustManager` through the host, rustls-native roots elsewhere).

use std::io::Read;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use serde_json::Value;

use crate::host::Host;

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
        }
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
        let cached = self.cleartext.lock().unwrap().get(&host).copied();
        let permitted = match cached {
            Some(permitted) => permitted,
            None => {
                let permitted = self.host.cleartext_permitted(&host).unwrap_or(true);
                self.cleartext.lock().unwrap().insert(host.clone(), permitted);
                permitted
            }
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
        *self.user_agent.write().unwrap() = user_agent;
    }

    pub fn user_agent(&self) -> String {
        self.user_agent.read().unwrap().clone()
    }

    pub fn timeout(&self) -> Duration {
        *self.timeout.read().unwrap()
    }

    /// Updates connect/read/write timeouts (0 keeps the 20 s default).
    pub fn set_timeout(&self, timeout: Duration) {
        let timeout = if timeout.is_zero() {
            Duration::from_secs(20)
        } else {
            timeout
        };
        let mut current = self.timeout.write().unwrap();
        if *current == timeout {
            return;
        }
        *current = timeout;
        *self.agent.write().unwrap() = build_agent(self.tls.clone(), timeout);
        *self.download_agent.write().unwrap() = build_agent(self.tls.clone(), timeout.max(Duration::from_secs(60)));
    }

    fn prepare(&self, agent: &RwLock<ureq::Agent>, method: &str, url: &str, headers: &[(&str, &str)]) -> ureq::Request {
        let agent = agent.read().unwrap().clone();
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
        agent: &RwLock<ureq::Agent>,
        method: &str,
        url: &str,
        headers: &[(&str, &str)],
        body: Option<&[u8]>,
    ) -> Result<ureq::Response, NetError> {
        let mut current = url.to_string();
        let mut method = method.to_string();
        let mut body = body;
        for _ in 0..=MAX_REDIRECTS {
            self.check_cleartext(&current)?;
            let request = self.prepare(agent, &method, &current, headers);
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
        let response = self.execute(&self.agent, method, url, headers, body)?;
        let status = response.status();
        let headers = headers_of(&response);
        let mut buffer = Vec::new();
        response
            .into_reader()
            .take(MAX_API_BODY_BYTES)
            .read_to_end(&mut buffer)
            .map_err(|error| NetError {
                kind: classify_io(&error),
                message: error.to_string(),
            })?;
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
        let response = self.execute(&self.download_agent, "GET", url, headers, None)?;
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

/// A redirect may never downgrade HTTPS to plain HTTP unless explicitly allowed.
pub fn redirect_allowed(from_scheme: &str, to_scheme: &str, allow_downgrade: bool) -> bool {
    !(from_scheme.eq_ignore_ascii_case("https") && to_scheme.eq_ignore_ascii_case("http")) || allow_downgrade
}

/// Events of [`Http::download`].
pub enum Stream<'a> {
    Head(&'a StreamHead),
    Chunk(&'a [u8]),
}

fn build_agent(tls: Arc<ClientConfig>, timeout: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new()
        .tls_config(tls)
        .timeout_connect(timeout)
        .timeout_read(timeout)
        .timeout_write(timeout)
        .max_idle_connections(64)
        .max_idle_connections_per_host(64)
        .try_proxy_from_env(true)
        .redirects(0)
        .build()
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

fn tls_config(host: Arc<dyn Host>) -> ClientConfig {
    let provider = provider();
    let builder = ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .expect("ring supports the default TLS versions");
    let verifier: Arc<dyn ServerCertVerifier> = Arc::new(HostVerifier {
        host,
        provider: provider.clone(),
        fallback: platform_verifier(provider),
    });
    builder
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth()
}

#[cfg(not(target_os = "android"))]
fn platform_verifier(provider: Arc<CryptoProvider>) -> Option<Arc<dyn ServerCertVerifier>> {
    Some(Arc::new(
        rustls_platform_verifier::Verifier::new().with_provider(provider),
    ))
}

#[cfg(target_os = "android")]
fn platform_verifier(_provider: Arc<CryptoProvider>) -> Option<Arc<dyn ServerCertVerifier>> {
    None
}

/// Asks the host first (Android trust manager, honouring network security
/// config and user CAs), then falls back to the platform verifier.
#[derive(Debug)]
struct HostVerifier {
    host: Arc<dyn Host>,
    provider: Arc<CryptoProvider>,
    fallback: Option<Arc<dyn ServerCertVerifier>>,
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
        ocsp_response: &[u8],
        now: UnixTime,
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
                // The host checks the chain against the platform trust store; the
                // name is checked here.
                let parsed = rustls::server::ParsedCertificate::try_from(end_entity)?;
                rustls::client::verify_server_name(&parsed, server_name)?;
                Ok(ServerCertVerified::assertion())
            }
            Some(Err(message)) => Err(rustls::Error::General(message)),
            None => match &self.fallback {
                Some(fallback) => {
                    fallback.verify_server_cert(end_entity, intermediates, server_name, ocsp_response, now)
                }
                None => Err(rustls::Error::General("No certificate verifier available".into())),
            },
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
