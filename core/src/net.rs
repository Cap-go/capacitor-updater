//! HTTP client used by the engine (update checks, channels, stats, bundle
//! downloads).
//!
//! Requests go through the host's network stack when it has one
//! ([`Host::http_request`]: URLSession on iOS, `HttpEngine` on Android 14+, with
//! HTTP/2, HTTP/3, the system proxy and the platform trust rules). The engine keeps
//! its rules there too: it follows redirects itself (count, HTTPS -> HTTP guard),
//! checks the cleartext policy, caps API bodies and checks every downloaded length.
//! Without a host transport (or with `systemHttp: false`), plain HTTP/1.1 over
//! rustls; certificate chains are then verified by the operating system trust store
//! through the host (Android `X509TrustManager`, iOS `SecTrust`), host names by rustls.

use crate::sync::{LockRecover, RwLockRecover};
use std::io::Read;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use serde_json::Value;

use crate::host::{Host, HttpProxy, HttpTransportEvent, HttpTransportOutcome, HttpTransportRequest};

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
    /// Negotiated protocol (`http/1.1` for the engine's own client).
    pub protocol: Option<String>,
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
    /// The host transport appends the body to the file given to [`Http::download_to`]
    /// itself ([`Stream::Written`] events): the head handler only prepares that file
    /// (truncated for a whole body, kept for an append) and writes nothing.
    pub body_in_file: bool,
    /// Negotiated protocol, known once the transfer ended (`http/1.1` for the engine's own client).
    pub protocol: Option<String>,
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
    /// Send through the host's network stack when it has one (`systemHttp`).
    system_http: std::sync::atomic::AtomicBool,
    /// Last protocol the host transport reported per host name (logged when it changes).
    protocols: Mutex<std::collections::HashMap<String, String>>,
}

/// The engine's own client speaks HTTP/1.1 only.
const OWN_PROTOCOL: &str = "http/1.1";

/// One request hop through the host transport.
enum HostHop {
    /// No host transport for this request: the engine's own client sends it.
    Unavailable,
    /// A redirect (status, `Location`) for the engine to follow.
    Redirect(u16, String),
    /// The final response; its body went to the event handler.
    Final(StreamHead),
}

/// Who answered a request.
enum Exchange {
    /// The host transport: the body was already handed over.
    Host(StreamHead),
    /// The engine's own client: the body is still to be read.
    Own(ureq::Response),
}

/// Response headers the way the engine's own client reports them (ureq `headers_names`):
/// lower-case names, each with the first value of that name.
fn normalize_headers(headers: &[(String, String)]) -> Vec<(String, String)> {
    headers
        .iter()
        .map(|(name, _)| {
            let value = find_header(headers, name).unwrap_or_default().to_string();
            (name.to_ascii_lowercase(), value)
        })
        .collect()
}

fn find_header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

/// Drops the headers of a content coding that was removed from the body.
fn strip_content_coding(headers: &mut Vec<(String, String)>) {
    headers.retain(|(name, _)| {
        !name.eq_ignore_ascii_case("Content-Encoding") && !name.eq_ignore_ascii_case("Content-Length")
    });
}

fn is_gzip(headers: &[(String, String)]) -> bool {
    find_header(headers, "Content-Encoding")
        .is_some_and(|value| value.trim().eq_ignore_ascii_case("gzip") || value.trim().eq_ignore_ascii_case("x-gzip"))
}

/// Error kind of a failed host transport request.
fn transport_error_kind(kind: &str) -> NetErrorKind {
    match kind {
        "timeout" => NetErrorKind::Timeout,
        "tls" => NetErrorKind::Tls,
        "invalid_url" => NetErrorKind::InvalidUrl,
        "io" => NetErrorKind::Io,
        _ => NetErrorKind::Network,
    }
}

/// Whether the host transport may carry `url`: any other URL keeps the exact error of
/// the engine's own client.
fn host_transport_url(url: &str) -> bool {
    url::Url::parse(url).is_ok_and(|parsed| {
        matches!(parsed.scheme(), "http" | "https") && parsed.host_str().is_some_and(|host| !host.is_empty())
    })
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
            system_http: std::sync::atomic::AtomicBool::new(true),
            protocols: Mutex::new(std::collections::HashMap::new()),
        }
    }

    /// Uses the host's network stack when it has one (default), or always the engine's
    /// own HTTP/1.1 client (`systemHttp: false`).
    pub fn set_system_http(&self, enabled: bool) {
        self.system_http.store(enabled, std::sync::atomic::Ordering::SeqCst);
    }

    /// Idle timeout of a host transport request: bundle transfers get at least 60 s,
    /// like the engine's own download agent.
    fn timeout_for(&self, download: bool) -> Duration {
        let timeout = *self.timeout.read_or_recover();
        if download {
            timeout.max(Duration::from_secs(60))
        } else {
            timeout
        }
    }

    /// Logs the protocol the host transport negotiated with a host when it changes.
    fn note_protocol(&self, url: &str, protocol: Option<&str>) {
        let Some(protocol) = protocol.filter(|protocol| !protocol.is_empty()) else {
            return;
        };
        let host = url::Url::parse(url)
            .ok()
            .and_then(|parsed| parsed.host_str().map(str::to_ascii_lowercase))
            .unwrap_or_default();
        let changed = {
            let mut protocols = self.protocols.lock_or_recover();
            if protocols.get(&host).map(String::as_str) == Some(protocol) {
                false
            } else {
                protocols.insert(host.clone(), protocol.to_string());
                true
            }
        };
        if changed {
            self.host.log(
                crate::host::LogLevel::Debug,
                &format!("System HTTP transport: {protocol} with {host}"),
            );
        }
    }

    /// Sends one hop through the host transport. The head, body chunks and written byte
    /// counts of a final response go to `on_event`; an error from it cancels the request
    /// and is returned as is.
    #[allow(clippy::too_many_arguments)]
    fn host_hop(
        &self,
        download: bool,
        method: &str,
        url: &str,
        headers: &[(&str, &str)],
        body: Option<&[u8]>,
        body_path: Option<&std::path::Path>,
        on_event: &mut dyn FnMut(Stream<'_>) -> Result<(), NetError>,
    ) -> Result<HostHop, NetError> {
        if !self.system_http.load(std::sync::atomic::Ordering::SeqCst) || !host_transport_url(url) {
            return Ok(HostHop::Unavailable);
        }
        // What the engine's own client sends: its User-Agent first, `Accept: */*` by default.
        let mut request_headers: Vec<(String, String)> = vec![("User-Agent".into(), self.user_agent())];
        request_headers.extend(
            headers
                .iter()
                .map(|(name, value)| (name.to_string(), value.to_string())),
        );
        if !headers.iter().any(|(name, _)| name.eq_ignore_ascii_case("Accept")) {
            request_headers.push(("Accept".into(), "*/*".into()));
        }
        let request = HttpTransportRequest {
            method,
            url,
            headers: &request_headers,
            body,
            timeout: self.timeout_for(download),
            body_path,
        };
        let mut head: Option<StreamHead> = None;
        let mut redirect: Option<(u16, String)> = None;
        let mut failure: Option<NetError> = None;
        let violation = |message: &str| NetError {
            kind: NetErrorKind::Network,
            message: format!("Invalid response from the system HTTP transport: {message}"),
        };
        let outcome = self.host.http_request(&request, &mut |event| {
            let result = match event {
                HttpTransportEvent::Head { .. } if head.is_some() => Err(violation("second response head")),
                HttpTransportEvent::Head { status, headers } => {
                    let headers = normalize_headers(&headers);
                    match find_header(&headers, "location") {
                        // The engine follows redirects itself: no body needed.
                        Some(location) if (300..400).contains(&status) && status != 304 => {
                            redirect = Some((status, location.to_string()));
                            return false;
                        }
                        _ => {
                            let stream_head = StreamHead {
                                status,
                                content_length: find_header(&headers, "content-length")
                                    .and_then(|value| value.trim().parse().ok()),
                                headers,
                                body_in_file: body_path.is_some(),
                                protocol: None,
                            };
                            let accepted = on_event(Stream::Head(&stream_head));
                            head = Some(stream_head);
                            accepted
                        }
                    }
                }
                HttpTransportEvent::Data(_) | HttpTransportEvent::Written(_) if head.is_none() => {
                    Err(violation("body before the response head"))
                }
                HttpTransportEvent::Data(chunk) => on_event(Stream::Chunk(chunk)),
                HttpTransportEvent::Written(total) => on_event(Stream::Written(total)),
            };
            match result {
                Ok(()) => true,
                Err(error) => {
                    failure = Some(error);
                    false
                }
            }
        });
        if let Some(error) = failure {
            return Err(error);
        }
        if let Some((status, location)) = redirect {
            return Ok(HostHop::Redirect(status, location));
        }
        match (outcome, head) {
            (HttpTransportOutcome::Unavailable, None) => Ok(HostHop::Unavailable),
            (HttpTransportOutcome::Completed { protocol }, Some(mut head)) => {
                self.note_protocol(url, protocol.as_deref());
                head.protocol = protocol;
                Ok(HostHop::Final(head))
            }
            (HttpTransportOutcome::Failed { kind, message }, _) => Err(NetError {
                kind: transport_error_kind(&kind),
                message,
            }),
            (HttpTransportOutcome::Completed { .. }, None) => Err(violation("no response head")),
            (HttpTransportOutcome::Unavailable, Some(_)) => Err(violation("unavailable after the response head")),
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
    /// plain HTTP is refused unless `allowHttpsToHttpRedirect` is set. Each hop goes
    /// through the host transport when it takes it, else through the engine's own client
    /// (whose body the caller then reads).
    #[allow(clippy::too_many_arguments)]
    fn exchange(
        &self,
        download: bool,
        method: &str,
        url: &str,
        headers: &[(&str, &str)],
        body: Option<&[u8]>,
        body_path: Option<&std::path::Path>,
        on_event: &mut dyn FnMut(Stream<'_>) -> Result<(), NetError>,
    ) -> Result<Exchange, NetError> {
        crate::host::release_method_lane();
        let mut current = url.to_string();
        let mut method = method.to_string();
        let mut body = body;
        for _ in 0..=MAX_REDIRECTS {
            self.check_cleartext(&current)?;
            let (status, location) =
                match self.host_hop(download, &method, &current, headers, body, body_path, on_event)? {
                    HostHop::Final(head) => return Ok(Exchange::Host(head)),
                    HostHop::Redirect(status, location) => (status, location),
                    HostHop::Unavailable => {
                        let request = self.prepare(self.agent_for(download, &current), &method, &current, headers);
                        let response = Self::finish(match body {
                            Some(body) => request.send_bytes(body),
                            None => request.call(),
                        })?;
                        let status = response.status();
                        if !(300..400).contains(&status) || status == 304 {
                            return Ok(Exchange::Own(response));
                        }
                        let Some(location) = response.header("Location").map(str::to_string) else {
                            return Ok(Exchange::Own(response));
                        };
                        (status, location)
                    }
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
        // Host transport: the decoded body arrives in chunks; the cap ends it (like `Read::take`).
        let mut head: Option<StreamHead> = None;
        let mut buffer = Vec::new();
        let capped = std::cell::Cell::new(false);
        let exchange = self.exchange(false, method, url, &headers, body, None, &mut |event| {
            match event {
                Stream::Head(stream_head) => head = Some(stream_head.clone()),
                Stream::Chunk(chunk) => {
                    let room = MAX_API_BODY_BYTES as usize - buffer.len();
                    if chunk.len() >= room {
                        buffer.extend_from_slice(&chunk[..room]);
                        capped.set(true);
                        return Err(NetError {
                            kind: NetErrorKind::Io,
                            message: "Response body cap reached".into(),
                        });
                    }
                    buffer.extend_from_slice(chunk);
                }
                Stream::Written(_) => {}
            }
            Ok(())
        });
        let response = match exchange {
            Ok(Exchange::Own(response)) => response,
            Ok(Exchange::Host(head)) => return Ok(host_response(head, buffer)),
            Err(error) => {
                return match head {
                    Some(head) if capped.get() => Ok(host_response(head, buffer)),
                    _ => Err(error),
                }
            }
        };
        let status = response.status();
        let mut headers = headers_of(&response);
        let gzip = is_gzip(&headers);
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
            strip_content_coding(&mut headers);
        }
        Ok(Response {
            status,
            headers,
            body: buffer,
            protocol: Some(OWN_PROTOCOL.into()),
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
        self.download_to(url, headers, None, handler)
    }

    /// [`Http::download`] whose body may go straight to `body_path`: when the host
    /// transport carries the request, the head has `body_in_file` set, the handler
    /// prepares the file (truncate, or keep it for an append) and the host appends the
    /// body to it ([`Stream::Written`] events, no bytes through the engine). The
    /// engine's own client still hands every [`Stream::Chunk`] to the handler.
    pub fn download_to(
        &self,
        url: &str,
        headers: &[(&str, &str)],
        body_path: Option<&std::path::Path>,
        handler: &mut dyn FnMut(Stream<'_>) -> Result<(), NetError>,
    ) -> Result<StreamHead, NetError> {
        // Bundle files are stored byte for byte (checksums, Range resume): no content coding.
        let headers = with_accept_encoding(headers, "identity");
        let response = match self.exchange(true, "GET", url, &headers, None, body_path, handler)? {
            Exchange::Host(head) => return Ok(head),
            Exchange::Own(response) => response,
        };
        let head = StreamHead {
            status: response.status(),
            headers: headers_of(&response),
            content_length: response
                .header("Content-Length")
                .and_then(|value| value.trim().parse().ok()),
            body_in_file: false,
            protocol: Some(OWN_PROTOCOL.into()),
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

/// An API response the host transport delivered. Its body is decoded (the platform
/// stacks remove the content coding), so the coding headers go, as after the engine's
/// own gzip decoding.
fn host_response(head: StreamHead, body: Vec<u8>) -> Response {
    let mut headers = head.headers;
    if is_gzip(&headers) {
        strip_content_coding(&mut headers);
    }
    Response {
        status: head.status,
        headers,
        body,
        protocol: head.protocol,
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
    /// Total body bytes the host transport appended to the download file so far
    /// ([`Http::download_to`], heads with `body_in_file`).
    Written(u64),
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
