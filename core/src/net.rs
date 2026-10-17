//! HTTP client used by the engine (update checks, channels, stats, bundle
//! downloads). HTTP/1.1 over rustls, and HTTP/3 (QUIC, `h3.rs`) for origins that
//! announced it with `Alt-Svc` (`altsvc.rs`); certificate chains are verified by
//! the operating system trust store through the host (Android
//! `X509TrustManager`, iOS `SecTrust`), host names by rustls, on both.
//!
//! HTTP/3 is used for an https origin when it is enabled (`http3`), no proxy applies,
//! the URL has no user info, and a fresh `Alt-Svc: h3` announcement for the same host is
//! known. A QUIC failure (no connection, or a request that failed before its response
//! head) sends the request over HTTP/1.1 and keeps the origin on HTTP/1.1 for 5 minutes,
//! doubling up to 80 minutes while it keeps failing.

use crate::sync::{LockRecover, RwLockRecover};
use std::collections::{BTreeMap, HashMap};
use std::io::Read;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use serde_json::Value;

use crate::altsvc::{self, AltSvcCache};
use crate::h3::{H3Client, H3Error, H3Request};
use crate::host::{Host, HttpProxy, LogLevel};

/// Largest non-download response body accepted (JSON API responses).
const MAX_API_BODY_BYTES: u64 = 16 * 1024 * 1024;
const MAX_REDIRECTS: usize = 5;
/// QUIC connections per origin when the configuration does not say.
pub const DEFAULT_HTTP3_CONNECTIONS: usize = 4;
/// Most QUIC connections per origin a configuration can ask for.
pub const MAX_HTTP3_CONNECTIONS: usize = 16;
/// An origin whose QUIC attempt failed stays on HTTP/1.1 for this long, doubled for each
/// further failure in a row (at most 16 times).
const BROKEN_BASE: Duration = Duration::from_secs(300);
const BROKEN_MAX_DOUBLINGS: u32 = 4;
/// Protocol names (logs, `test.http`).
pub const PROTOCOL_HTTP1: &str = "http/1.1";
pub const PROTOCOL_H3: &str = "h3";

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
    /// [`PROTOCOL_HTTP1`] or [`PROTOCOL_H3`] (the last hop).
    pub protocol: &'static str,
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
    /// [`PROTOCOL_HTTP1`] or [`PROTOCOL_H3`] (the last hop).
    pub protocol: &'static str,
}

/// A response head with its body reader, from either protocol.
struct RawResponse {
    status: u16,
    /// As [`headers_of`]: lowercase names, each with the first valid value of that name.
    headers: Vec<(String, String)>,
    body: Box<dyn Read + Send>,
    protocol: &'static str,
}

impl RawResponse {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

/// HTTP/3 settings and state shared by the requests of one client.
struct Http3State {
    enabled: AtomicBool,
    connections: AtomicUsize,
    client: H3Client,
    alt_svc: AltSvcCache,
    /// Origins kept on HTTP/1.1 after a QUIC failure: until when, failures in a row.
    broken: Mutex<HashMap<String, (Instant, u32)>>,
    /// Last protocol used per origin (logged when it changes).
    protocols: Mutex<BTreeMap<String, &'static str>>,
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
    http3: Http3State,
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

/// ureq 2.12 (its last 2.x release) panics when it reads a response header line that has no
/// `:` (`Header::value` slices past the end of the line). Such a response is refused with a
/// network error instead of unwinding through the engine's threads. The C core skips the line
/// (core-c/COMPARISON.md, Crash safety).
fn contain_ureq_panic<T>(work: impl FnOnce() -> Result<T, NetError>) -> Result<T, NetError> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(work)).unwrap_or_else(|_| {
        Err(NetError {
            kind: NetErrorKind::Network,
            message: "Invalid HTTP response header".into(),
        })
    })
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
        let provider = provider();
        let verifier: Arc<dyn ServerCertVerifier> = Arc::new(HostVerifier {
            host: host.clone(),
            provider: provider.clone(),
        });
        let tls = Arc::new(tls_config(verifier.clone(), provider.clone()));
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
            http3: Http3State {
                enabled: AtomicBool::new(false),
                connections: AtomicUsize::new(DEFAULT_HTTP3_CONNECTIONS),
                client: H3Client::new(verifier, provider),
                alt_svc: AltSvcCache::default(),
                broken: Mutex::new(HashMap::new()),
                protocols: Mutex::new(BTreeMap::new()),
            },
        }
    }

    /// Turns HTTP/3 on or off and sets the QUIC connections per origin (0: the default,
    /// at most [`MAX_HTTP3_CONNECTIONS`]).
    pub fn set_http3(&self, enabled: bool, connections: usize) {
        let connections = if connections == 0 {
            DEFAULT_HTTP3_CONNECTIONS
        } else {
            connections.min(MAX_HTTP3_CONNECTIONS)
        };
        self.http3.enabled.store(enabled, Ordering::SeqCst);
        self.http3.connections.store(connections, Ordering::SeqCst);
    }

    /// The protocol last used per origin (`https://host:port`).
    pub fn protocols(&self) -> BTreeMap<String, String> {
        self.http3
            .protocols
            .lock_or_recover()
            .iter()
            .map(|(origin, protocol)| (origin.clone(), protocol.to_string()))
            .collect()
    }

    /// QUIC connections opened by this client.
    pub fn http3_connections_opened(&self) -> usize {
        self.http3.client.opened_connections()
    }

    /// The agent for `url`: through the system HTTP proxy the host reports
    /// (Android `ProxySelector`, iOS system proxy settings, `proxy`), else direct.
    fn agent_for(&self, download: bool, proxy: Option<HttpProxy>) -> ureq::Agent {
        let direct = || {
            if download {
                self.download_agent.read_or_recover().clone()
            } else {
                self.agent.read_or_recover().clone()
            }
        };
        let Some(proxy) = proxy else {
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
    /// plain HTTP is refused unless `allowHttpsToHttpRedirect` is set. Each hop goes over
    /// HTTP/3 when its origin qualifies (see the module comment), else HTTP/1.1.
    fn execute(
        &self,
        download: bool,
        method: &str,
        url: &str,
        headers: &[(&str, &str)],
        body: Option<&[u8]>,
    ) -> Result<RawResponse, NetError> {
        crate::host::release_method_lane();
        let mut current = url.to_string();
        let mut method = method.to_string();
        let mut body = body;
        for _ in 0..=MAX_REDIRECTS {
            self.check_cleartext(&current)?;
            let response = self.send_hop(download, &method, &current, headers, body)?;
            self.note_alt_svc(&current, &response);
            let status = response.status;
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

    /// One hop: HTTP/3 when the origin qualifies, HTTP/1.1 otherwise or after a QUIC failure.
    fn send_hop(
        &self,
        download: bool,
        method: &str,
        url: &str,
        headers: &[(&str, &str)],
        body: Option<&[u8]>,
    ) -> Result<RawResponse, NetError> {
        let proxy = self.host.proxy_for_url(url);
        if let Some(target) = self.h3_target(url, proxy.is_some()) {
            if let Some(fields) = self.h3_fields(headers, body) {
                let timeout = self.request_timeout(download);
                let request = H3Request {
                    method,
                    url: target.url.as_str(),
                    host: &target.host,
                    port: target.port,
                    headers: &fields,
                    body,
                    timeout,
                    idempotent: idempotent(method),
                };
                let connections = self.http3.connections.load(Ordering::SeqCst);
                match self.http3.client.request(&request, connections) {
                    Ok(response) => {
                        self.http3.broken.lock_or_recover().remove(&target.origin);
                        self.note_protocol(&target.origin, PROTOCOL_H3);
                        return Ok(RawResponse {
                            status: response.status,
                            headers: h3_headers(&response.fields),
                            body: response.body,
                            protocol: PROTOCOL_H3,
                        });
                    }
                    Err(H3Error::Fail(error)) => return Err(error),
                    Err(H3Error::Fallback(reason)) => self.h3_failed(&target.origin, &reason),
                }
            }
        }
        let request = self.prepare(self.agent_for(download, proxy), method, url, headers);
        let response = Self::finish(match body {
            Some(body) => request.send_bytes(body),
            None => request.call(),
        })?;
        self.note_protocol(&origin_of(url), PROTOCOL_HTTP1);
        Ok(RawResponse {
            status: response.status(),
            headers: headers_of(&response),
            body: Box::new(response.into_reader()),
            protocol: PROTOCOL_HTTP1,
        })
    }

    /// Read timeout of a request (downloads: at least 60 s).
    fn request_timeout(&self, download: bool) -> Duration {
        let timeout = *self.timeout.read_or_recover();
        if download {
            timeout.max(Duration::from_secs(60))
        } else {
            timeout
        }
    }

    /// The HTTP/3 target of `url`, when HTTP/3 is on, no proxy applies, the URL is https
    /// without user info, the origin is not broken and announced `h3` on its own host.
    fn h3_target(&self, url: &str, proxied: bool) -> Option<H3Target> {
        if !self.http3.enabled.load(Ordering::SeqCst) || proxied || env_proxy_configured() {
            return None;
        }
        let parsed = url::Url::parse(url).ok()?;
        if parsed.scheme() != "https" || !parsed.username().is_empty() || parsed.password().is_some() {
            return None;
        }
        let host = parsed.host_str()?.to_ascii_lowercase();
        let origin = format!("https://{host}:{}", parsed.port_or_known_default()?);
        if let Some((until, _)) = self.http3.broken.lock_or_recover().get(&origin) {
            if Instant::now() < *until {
                return None;
            }
        }
        let port = self.http3.alt_svc.lookup(self.host.as_ref(), &origin, now_ms())?;
        Some(H3Target {
            url: parsed,
            host,
            port,
            origin,
        })
    }

    /// The HTTP/3 field lines of a request, as the HTTP/1.1 client would send them; `None`
    /// when a header is not valid (the HTTP/1.1 client then reports it).
    fn h3_fields(&self, headers: &[(&str, &str)], body: Option<&[u8]>) -> Option<Vec<(String, String)>> {
        let user_agent = self.user_agent();
        let mut fields: Vec<(String, String)> = vec![("user-agent".into(), user_agent)];
        for (name, value) in headers {
            if name.is_empty() || !name.bytes().all(is_tchar) || !value.bytes().all(is_field_char) {
                return None;
            }
            let name = name.to_ascii_lowercase();
            // Connection-specific fields do not exist in HTTP/3; :authority replaces Host.
            if CONNECTION_FIELDS.contains(&name.as_str()) {
                continue;
            }
            if !name.starts_with("x-") {
                fields.retain(|(existing, _)| *existing != name);
            }
            fields.push((name, value.trim().to_string()));
        }
        if !fields.iter().any(|(name, _)| name == "accept") {
            fields.push(("accept".into(), "*/*".into()));
        }
        if let Some(body) = body {
            if !fields.iter().any(|(name, _)| name == "content-length") {
                fields.push(("content-length".into(), body.len().to_string()));
            }
        }
        Some(fields)
    }

    /// A QUIC failure: the origin stays on HTTP/1.1 for a while.
    fn h3_failed(&self, origin: &str, reason: &str) {
        let mut broken = self.http3.broken.lock_or_recover();
        let failures = broken.get(origin).map_or(0, |(_, failures)| *failures) + 1;
        let period = BROKEN_BASE * (1u32 << (failures - 1).min(BROKEN_MAX_DOUBLINGS));
        broken.insert(origin.to_string(), (Instant::now() + period, failures));
        drop(broken);
        self.host.log(
            LogLevel::Debug,
            &format!(
                "HTTP/3 to {origin} failed ({reason}), using HTTP/1.1 for {} s",
                period.as_secs()
            ),
        );
    }

    /// Logs the protocol of `origin` when it changes.
    fn note_protocol(&self, origin: &str, protocol: &'static str) {
        let previous = self
            .http3
            .protocols
            .lock_or_recover()
            .insert(origin.to_string(), protocol);
        if previous != Some(protocol) {
            self.host
                .log(LogLevel::Debug, &format!("HTTP protocol for {origin}: {protocol}"));
        }
    }

    /// Records the `Alt-Svc` announcement of an https response (HTTP/3 on only).
    fn note_alt_svc(&self, url: &str, response: &RawResponse) {
        if !self.http3.enabled.load(Ordering::SeqCst) {
            return;
        }
        let Some(value) = response.header("alt-svc") else {
            return;
        };
        let Ok(parsed) = url::Url::parse(url) else {
            return;
        };
        if parsed.scheme() != "https" {
            return;
        }
        let (Some(host), Some(port)) = (parsed.host_str(), parsed.port_or_known_default()) else {
            return;
        };
        let host = host.to_ascii_lowercase();
        let origin = format!("https://{host}:{port}");
        let announcement = altsvc::parse(value, &host);
        self.http3
            .alt_svc
            .update(self.host.as_ref(), &origin, announcement, now_ms());
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
        let read_error = |error: std::io::Error| NetError {
            kind: classify_io(&error),
            message: error.to_string(),
        };
        let (status, mut headers, gzip, mut buffer, protocol) = contain_ureq_panic(|| {
            let response = self.execute(false, method, url, &headers, body)?;
            let status = response.status;
            let gzip = response.header("Content-Encoding").is_some_and(|value| {
                value.trim().eq_ignore_ascii_case("gzip") || value.trim().eq_ignore_ascii_case("x-gzip")
            });
            let protocol = response.protocol;
            let headers = response.headers;
            let mut buffer = Vec::new();
            response
                .body
                .take(MAX_API_BODY_BYTES)
                .read_to_end(&mut buffer)
                .map_err(read_error)?;
            Ok((status, headers, gzip, buffer, protocol))
        })?;
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
            protocol,
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
        let (head, mut reader) = contain_ureq_panic(|| {
            let response = self.execute(true, "GET", url, &headers, None)?;
            let head = StreamHead {
                status: response.status,
                content_length: response
                    .header("Content-Length")
                    .and_then(|value| value.trim().parse().ok()),
                headers: response.headers,
                protocol: response.protocol,
            };
            Ok((head, response.body))
        })?;
        handler(Stream::Head(&head))?;
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

/// Where an HTTP/3 request goes.
struct H3Target {
    url: url::Url,
    /// URL host, lowercase (IPv6 in brackets).
    host: String,
    /// Announced HTTP/3 port.
    port: u16,
    /// `https://host:port` of the URL.
    origin: String,
}

/// Fields HTTP/3 forbids or replaces (RFC 9114 4.2).
const CONNECTION_FIELDS: [&str; 7] = [
    "host",
    "connection",
    "keep-alive",
    "proxy-connection",
    "transfer-encoding",
    "upgrade",
    "te",
];

fn is_tchar(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte)
}

fn is_field_char(byte: u8) -> bool {
    byte == b' ' || byte == b'\t' || (0x21..=0x7e).contains(&byte)
}

/// Methods a QUIC failure may resend over HTTP/1.1 once something was sent (ureq's list).
fn idempotent(method: &str) -> bool {
    matches!(method, "DELETE" | "GET" | "HEAD" | "OPTIONS" | "PUT" | "TRACE")
}

/// `scheme://host:port` of a URL (empty when it does not parse).
fn origin_of(url: &str) -> String {
    match url::Url::parse(url) {
        Ok(parsed) => format!(
            "{}://{}:{}",
            parsed.scheme(),
            parsed.host_str().unwrap_or_default().to_ascii_lowercase(),
            parsed.port_or_known_default().unwrap_or(0)
        ),
        Err(_) => String::new(),
    }
}

/// An HTTP proxy from the environment (`ALL_PROXY`, `HTTPS_PROXY`, `HTTP_PROXY`, any case):
/// such traffic stays on the proxied HTTP/1.1 path.
fn env_proxy_configured() -> bool {
    [
        "ALL_PROXY",
        "all_proxy",
        "HTTPS_PROXY",
        "https_proxy",
        "HTTP_PROXY",
        "http_proxy",
    ]
    .iter()
    .any(|name| std::env::var_os(name).is_some_and(|value| !value.is_empty()))
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis() as i64)
}

/// HTTP/3 field lines as [`headers_of`] gives HTTP/1.1 ones (ureq semantics): each name
/// with the first value of that name, when that value is valid (UTF-8, no NUL, visible
/// ASCII, spaces and tabs after trimming).
pub fn h3_headers(fields: &[(String, Vec<u8>)]) -> Vec<(String, String)> {
    let raw: Vec<(String, Option<String>)> = fields
        .iter()
        .map(|(name, value)| {
            let text = std::str::from_utf8(value)
                .ok()
                .filter(|text| !text.contains('\0'))
                .map(str::trim)
                .filter(|text| text.bytes().all(is_field_char))
                .map(str::to_string);
            (name.to_ascii_lowercase(), text)
        })
        .collect();
    raw.iter()
        .filter_map(|(name, _)| {
            let (_, first) = raw.iter().find(|(other, _)| other == name)?;
            first.as_ref().map(|value| (name.clone(), value.clone()))
        })
        .collect()
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

fn tls_config(verifier: Arc<dyn ServerCertVerifier>, provider: Arc<CryptoProvider>) -> ClientConfig {
    let builder = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("ring supports the default TLS versions");
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

/// Longest server certificate chain passed to the host verifier.
const MAX_CERTIFICATE_CHAIN: usize = 32;

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
        // Real chains have a handful of certificates. A server can send thousands before any
        // trust decision: refused here instead of handing them all to the host.
        if intermediates.len() >= MAX_CERTIFICATE_CHAIN {
            return Err(certificate_rejected(format!(
                "Certificate chain longer than {MAX_CERTIFICATE_CHAIN} certificates"
            )));
        }
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

    /// A server can send thousands of certificates before any trust decision: the host
    /// (JNI on Android 7: 512 local references at most) never sees more than the cap.
    #[test]
    fn huge_certificate_chains_are_refused_before_the_host() {
        let host = Arc::new(crate::host::MemoryHost::default());
        let verifier = HostVerifier {
            host: host.clone(),
            provider: provider(),
        };
        let end_entity = CertificateDer::from(vec![1u8]);
        let intermediates = vec![CertificateDer::from(vec![2u8]); 3000];
        let server_name = ServerName::try_from("example.com").unwrap();
        let verdict = verifier.verify_server_cert(&end_entity, &intermediates, &server_name, &[], UnixTime::now());
        assert!(verdict.is_err());
        assert!(host.certificate_requests.lock_or_recover().is_empty());
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
                        let proxy = http.host.proxy_for_url("http://updates.invalid/");
                        let _ = http.agent_for(round % 2 == 0, proxy);
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
