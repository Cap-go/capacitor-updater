//! HTTP/3 transport of the engine's client (quinn + h3 over the same rustls configuration
//! and host trust decision as HTTP/1.1). `net.rs` decides when to use it (Alt-Svc
//! discovery, fallback); this module only moves requests.
//!
//! - Up to `max_connections` QUIC connections per origin. A request goes to the connection
//!   with the fewest requests in flight; a new connection is opened while every existing one
//!   is busy and the limit is not reached. A single transfer (zip, API call) uses one stream
//!   on one connection; parallel manifest files spread over several connections, each with
//!   its own congestion window (one loss-limited window for all files was up to 7x slower on
//!   a lossy link: core-c/BENCHMARK-CORE-HTTP3.md).
//! - A connection that cannot be established, or a request that fails before its response
//!   head, is reported as [`H3Error::Fallback`]: the caller marks the origin broken and sends
//!   the request over HTTP/1.1 (only idempotent requests once something was sent).
//! - The C core implements the same rules over ngtcp2 + nghttp3 (`core-c/src/h3.c`).

use std::collections::HashMap;
use std::io::Read;
use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use bytes::{Buf, Bytes};
use rustls::ClientConfig;

use crate::net::{NetError, NetErrorKind};
use crate::sync::LockRecover;

/// Longest QUIC handshake before the origin falls back to HTTP/1.1 (bounded by the request
/// timeout). A network that drops UDP costs this once per broken period.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(3);
/// Connections idle for this long are closed (QUIC idle timeout).
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(30);
/// Receive windows: per stream and per connection.
pub const STREAM_WINDOW: u32 = 2 * 1024 * 1024;
pub const CONNECTION_WINDOW: u32 = 16 * 1024 * 1024;
/// Largest response header section accepted, and most header fields (as HTTP/1.1).
pub const MAX_FIELD_SECTION_SIZE: u64 = 100 * 1024;
pub const MAX_HEADER_COUNT: usize = 100;

pub const MESSAGE_TIMEOUT: &str = "timed out reading response";
pub const MESSAGE_SHORT_BODY: &str = "response body closed before all bytes were read";
pub const MESSAGE_LONG_BODY: &str = "HTTP/3 response body longer than Content-Length";
pub const MESSAGE_RESET: &str = "HTTP/3 stream reset by the server";
pub const MESSAGE_CLOSED: &str = "HTTP/3 connection closed";
pub const MESSAGE_PROTOCOL: &str = "HTTP/3 protocol error";
pub const MESSAGE_TOO_MANY_HEADERS: &str = "more than 100 header fields in response";
pub const MESSAGE_REQUEST_FAILED: &str = "HTTP/3 request failed";

/// Why an HTTP/3 attempt did not produce a response.
#[derive(Debug)]
pub enum H3Error {
    /// The origin is not usable over HTTP/3 right now (no connection, or the request failed
    /// before its response): fall back to HTTP/1.1. The text is for the debug log.
    Fallback(String),
    /// A real failure of this request (timeout, invalid response, or a non-idempotent request
    /// that may have reached the server).
    Fail(NetError),
}

/// A request to send over HTTP/3.
pub struct H3Request<'a> {
    pub method: &'a str,
    /// Absolute https URL without user info.
    pub url: &'a str,
    pub host: &'a str,
    /// The announced HTTP/3 port.
    pub port: u16,
    /// Field lines (lowercase names), without pseudo-headers.
    pub headers: &'a [(String, String)],
    pub body: Option<&'a [u8]>,
    /// Connect, write and per-read timeout.
    pub timeout: Duration,
    pub idempotent: bool,
}

/// The response head and a blocking body reader.
pub struct H3Response {
    pub status: u16,
    /// Raw field lines in order: lowercase name, value bytes.
    pub fields: Vec<(String, Vec<u8>)>,
    pub body: Box<dyn Read + Send>,
}

type SendRequest = h3::client::SendRequest<h3_quinn::OpenStreams, Bytes>;
type RequestStream = h3::client::RequestStream<h3_quinn::BidiStream<Bytes>, Bytes>;

struct Live {
    connection: quinn::Connection,
    send: SendRequest,
    _endpoint: quinn::Endpoint,
}

/// One pooled connection (connecting, live or dead).
struct Slot {
    cell: tokio::sync::OnceCell<Result<Live, String>>,
    active: AtomicUsize,
    dead: AtomicBool,
}

impl Slot {
    fn is_dead(&self) -> bool {
        self.dead.load(Ordering::SeqCst)
            || self.cell.get().is_some_and(|live| match live {
                Ok(live) => live.connection.close_reason().is_some(),
                Err(_) => true,
            })
    }
}

/// Keeps a slot's in-flight count while a request (and its body) is alive.
struct SlotUse(Arc<Slot>);

impl Drop for SlotUse {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::SeqCst);
    }
}

pub struct H3Client {
    runtime: OnceLock<Option<tokio::runtime::Runtime>>,
    tls: Arc<ClientConfig>,
    pools: Mutex<HashMap<String, Vec<Arc<Slot>>>>,
    /// QUIC connections opened since creation (tests, bench).
    opened: AtomicUsize,
}

impl Drop for H3Client {
    fn drop(&mut self) {
        let slots: Vec<Arc<Slot>> = self
            .pools
            .lock_or_recover()
            .drain()
            .flat_map(|(_, slots)| slots)
            .collect();
        for slot in &slots {
            if let Some(Ok(live)) = slot.cell.get() {
                live.connection.close(0u32.into(), b"");
            }
        }
        drop(slots);
        if let Some(Some(runtime)) = self.runtime.take() {
            runtime.shutdown_background();
        }
    }
}

impl H3Client {
    /// `verifier` and `provider`: those of the HTTP/1.1 client (host trust + name check).
    pub fn new(
        verifier: Arc<dyn rustls::client::danger::ServerCertVerifier>,
        provider: Arc<rustls::crypto::CryptoProvider>,
    ) -> Self {
        // TLS 1.3 only, ALPN h3, the same certificate verifier.
        let mut config = ClientConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS13])
            .expect("ring supports TLS 1.3")
            .dangerous()
            .with_custom_certificate_verifier(verifier)
            .with_no_client_auth();
        config.alpn_protocols = vec![b"h3".to_vec()];
        config.enable_early_data = false;
        Self {
            runtime: OnceLock::new(),
            tls: Arc::new(config),
            pools: Mutex::new(HashMap::new()),
            opened: AtomicUsize::new(0),
        }
    }

    /// QUIC connections opened so far.
    pub fn opened_connections(&self) -> usize {
        self.opened.load(Ordering::SeqCst)
    }

    fn runtime(&self) -> Option<&tokio::runtime::Runtime> {
        self.runtime
            .get_or_init(|| {
                tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(2)
                    .thread_name("capgo-quic")
                    .enable_io()
                    .enable_time()
                    .build()
                    .ok()
            })
            .as_ref()
    }

    fn client_config(&self) -> Result<quinn::ClientConfig, String> {
        let crypto =
            quinn::crypto::rustls::QuicClientConfig::try_from(self.tls.clone()).map_err(|error| error.to_string())?;
        let mut transport = quinn::TransportConfig::default();
        transport
            .max_idle_timeout(Some(
                quinn::IdleTimeout::try_from(IDLE_TIMEOUT).map_err(|error| error.to_string())?,
            ))
            .stream_receive_window(STREAM_WINDOW.into())
            .receive_window(CONNECTION_WINDOW.into())
            .max_concurrent_bidi_streams(0u32.into())
            .max_concurrent_uni_streams(16u32.into());
        let mut config = quinn::ClientConfig::new(Arc::new(crypto));
        config.transport_config(Arc::new(transport));
        Ok(config)
    }

    /// Picks the connection for a new request (see the module comment).
    fn pick(&self, key: &str, max_connections: usize) -> SlotUse {
        let mut pools = self.pools.lock_or_recover();
        let slots = pools.entry(key.to_string()).or_default();
        slots.retain(|slot| !slot.is_dead());
        let best = slots
            .iter()
            .min_by_key(|slot| slot.active.load(Ordering::SeqCst))
            .cloned();
        let slot = match best {
            Some(slot) if slot.active.load(Ordering::SeqCst) == 0 || slots.len() >= max_connections.max(1) => slot,
            _ => {
                let slot = Arc::new(Slot {
                    cell: tokio::sync::OnceCell::new(),
                    active: AtomicUsize::new(0),
                    dead: AtomicBool::new(false),
                });
                slots.push(slot.clone());
                slot
            }
        };
        slot.active.fetch_add(1, Ordering::SeqCst);
        SlotUse(slot)
    }

    /// Sends `request` over HTTP/3 (see [`H3Error`]).
    pub fn request(&self, request: &H3Request<'_>, max_connections: usize) -> Result<H3Response, H3Error> {
        let runtime = self
            .runtime()
            .ok_or_else(|| H3Error::Fallback("no QUIC runtime".into()))?;
        let key = format!("{}:{}", request.host, request.port);
        let server_name = request.host.trim_start_matches('[').trim_end_matches(']').to_string();
        // A connection that went away (GOAWAY, idle) before this request: once more on another.
        for attempt in 0..2 {
            let slot = self.pick(&key, max_connections);
            let fresh = slot.0.cell.get().is_none();
            let connect_timeout = request.timeout.min(HANDSHAKE_TIMEOUT);
            let established = runtime.block_on(
                slot.0
                    .cell
                    .get_or_init(|| self.connect(&server_name, request.port, connect_timeout)),
            );
            let live = match established {
                Ok(live) => live,
                Err(reason) => {
                    slot.0.dead.store(true, Ordering::SeqCst);
                    return Err(H3Error::Fallback(format!("no QUIC connection: {reason}")));
                }
            };
            let mut send = live.send.clone();
            let handle = runtime.handle().clone();
            match runtime.block_on(send_and_receive(&mut send, request)) {
                Ok((status, fields, stream)) => {
                    let no_body = bodiless(request.method, status);
                    let body = Body {
                        runtime: handle,
                        stream: Some(stream),
                        pending: Bytes::new(),
                        timeout: request.timeout,
                        remaining: if no_body { Some(0) } else { content_length(&fields) },
                        bodiless: no_body,
                        finished: false,
                        _slot: slot,
                    };
                    return Ok(H3Response {
                        status,
                        fields,
                        body: Box::new(body),
                    });
                }
                Err(Failure::Timeout) => {
                    return Err(H3Error::Fail(NetError {
                        kind: NetErrorKind::Timeout,
                        message: MESSAGE_TIMEOUT.into(),
                    }))
                }
                Err(Failure::Invalid(message)) => {
                    return Err(H3Error::Fail(NetError {
                        kind: NetErrorKind::Network,
                        message: message.into(),
                    }))
                }
                Err(Failure::Unusable(reason)) => {
                    slot.0.dead.store(true, Ordering::SeqCst);
                    if !fresh && attempt == 0 {
                        continue;
                    }
                    // Nothing was sent: any method may go over HTTP/1.1.
                    return Err(H3Error::Fallback(reason));
                }
                Err(Failure::Sent(reason)) => {
                    slot.0.dead.store(true, Ordering::SeqCst);
                    if request.idempotent {
                        return Err(H3Error::Fallback(reason));
                    }
                    return Err(H3Error::Fail(NetError {
                        kind: NetErrorKind::Network,
                        message: MESSAGE_REQUEST_FAILED.into(),
                    }));
                }
            }
        }
        Err(H3Error::Fallback(format!("no usable QUIC connection to {key}")))
    }

    /// Resolves `host` and establishes a QUIC connection and its HTTP/3 session.
    async fn connect(&self, host: &str, port: u16, timeout: Duration) -> Result<Live, String> {
        let config = self.client_config()?;
        let deadline = Instant::now() + timeout;
        let target = (host.to_string(), port);
        let addresses: Vec<SocketAddr> = tokio::task::spawn_blocking(move || target.to_socket_addrs())
            .await
            .map_err(|error| error.to_string())?
            .map_err(|error| error.to_string())?
            .collect();
        let multiple = addresses.len() > 1;
        let mut last = String::from("no address");
        for address in addresses {
            let now = Instant::now();
            if now >= deadline {
                break;
            }
            let mut budget = deadline - now;
            if multiple {
                budget /= 2;
            }
            let bind: SocketAddr = if address.is_ipv6() {
                (std::net::Ipv6Addr::UNSPECIFIED, 0).into()
            } else {
                (std::net::Ipv4Addr::UNSPECIFIED, 0).into()
            };
            let endpoint = match quinn::Endpoint::client(bind) {
                Ok(endpoint) => endpoint,
                Err(error) => {
                    last = error.to_string();
                    continue;
                }
            };
            let connecting = match endpoint.connect_with(config.clone(), address, host) {
                Ok(connecting) => connecting,
                Err(error) => {
                    last = error.to_string();
                    continue;
                }
            };
            let connection = match tokio::time::timeout(budget, connecting).await {
                Ok(Ok(connection)) => connection,
                Ok(Err(error)) => {
                    last = error.to_string();
                    continue;
                }
                Err(_) => {
                    last = "QUIC handshake timed out".into();
                    continue;
                }
            };
            let mut builder = h3::client::builder();
            builder.max_field_section_size(MAX_FIELD_SECTION_SIZE);
            let session = builder.build::<_, _, Bytes>(h3_quinn::Connection::new(connection.clone()));
            let remaining = deadline.saturating_duration_since(Instant::now());
            let (mut driver, send) = match tokio::time::timeout(remaining, session).await {
                Ok(Ok(parts)) => parts,
                Ok(Err(error)) => {
                    connection.close(0u32.into(), b"");
                    last = error.to_string();
                    continue;
                }
                Err(_) => {
                    connection.close(0u32.into(), b"");
                    last = "HTTP/3 setup timed out".into();
                    continue;
                }
            };
            tokio::spawn(async move {
                let _ = std::future::poll_fn(|cx| driver.poll_close(cx)).await;
            });
            self.opened.fetch_add(1, Ordering::SeqCst);
            return Ok(Live {
                connection,
                send,
                _endpoint: endpoint,
            });
        }
        Err(last)
    }
}

enum Failure {
    /// The connection could not take the request (nothing was sent).
    Unusable(String),
    /// The request failed after it was (maybe) sent, before the response head.
    Sent(String),
    Timeout,
    /// The response is not acceptable.
    Invalid(&'static str),
}

async fn send_and_receive(
    send: &mut SendRequest,
    request: &H3Request<'_>,
) -> Result<(u16, Vec<(String, Vec<u8>)>, RequestStream), Failure> {
    let mut builder = http::Request::builder().method(request.method).uri(request.url);
    for (name, value) in request.headers {
        builder = builder.header(name.as_str(), value.as_str());
    }
    let http_request = builder.body(()).map_err(|error| Failure::Unusable(error.to_string()))?;
    let timeout = request.timeout;
    let mut stream = match tokio::time::timeout(timeout, send.send_request(http_request)).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(error)) => return Err(Failure::Unusable(error.to_string())),
        Err(_) => return Err(Failure::Timeout),
    };
    if let Some(body) = request.body.filter(|body| !body.is_empty()) {
        match tokio::time::timeout(timeout, stream.send_data(Bytes::copy_from_slice(body))).await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => return Err(Failure::Sent(error.to_string())),
            Err(_) => return Err(Failure::Timeout),
        }
    }
    match tokio::time::timeout(timeout, stream.finish()).await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => return Err(Failure::Sent(error.to_string())),
        Err(_) => return Err(Failure::Timeout),
    }
    loop {
        let response = match tokio::time::timeout(timeout, stream.recv_response()).await {
            Ok(Ok(response)) => response,
            Ok(Err(error)) => return Err(Failure::Sent(error.to_string())),
            Err(_) => return Err(Failure::Timeout),
        };
        let status = response.status().as_u16();
        // Interim responses (1xx) are skipped.
        if (100..200).contains(&status) {
            continue;
        }
        let fields: Vec<(String, Vec<u8>)> = response
            .headers()
            .iter()
            .map(|(name, value)| (name.as_str().to_string(), value.as_bytes().to_vec()))
            .collect();
        if fields.len() > MAX_HEADER_COUNT {
            return Err(Failure::Invalid(MESSAGE_TOO_MANY_HEADERS));
        }
        return Ok((status, fields, stream));
    }
}

/// Blocking reader of a response body; enforces Content-Length.
struct Body {
    runtime: tokio::runtime::Handle,
    stream: Option<RequestStream>,
    pending: Bytes,
    timeout: Duration,
    /// Bytes still expected (Content-Length), `None` when not announced.
    remaining: Option<u64>,
    /// HEAD, 204, 304: no body, whatever the head says.
    bodiless: bool,
    finished: bool,
    _slot: SlotUse,
}

/// `content-length` of a response head (`None` when absent or not a number).
pub fn content_length(fields: &[(String, Vec<u8>)]) -> Option<u64> {
    let (_, value) = fields.iter().find(|(name, _)| name == "content-length")?;
    let text = std::str::from_utf8(value).ok()?;
    if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// Whether a response to `method` with `status` has no body (RFC 9110).
pub fn bodiless(method: &str, status: u16) -> bool {
    method == "HEAD" || status == 204 || status == 304
}

impl Read for Body {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        loop {
            if !self.pending.is_empty() {
                let count = self.pending.len().min(buffer.len());
                buffer[..count].copy_from_slice(&self.pending[..count]);
                self.pending.advance(count);
                return Ok(count);
            }
            if self.finished {
                return Ok(0);
            }
            if self.bodiless {
                // Nothing to read: the stream is closed without waiting for its end.
                self.finish(true);
                return Ok(0);
            }
            let Some(stream) = self.stream.as_mut() else {
                return Ok(0);
            };
            let timeout = self.timeout;
            let next = self
                .runtime
                .block_on(async { tokio::time::timeout(timeout, stream.recv_data()).await });
            match next {
                Err(_) => {
                    self.finish(true);
                    return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, MESSAGE_TIMEOUT));
                }
                Ok(Ok(Some(mut data))) => {
                    let bytes = data.copy_to_bytes(data.remaining());
                    if let Some(remaining) = self.remaining.as_mut() {
                        if bytes.len() as u64 > *remaining {
                            self.finish(true);
                            return Err(std::io::Error::other(MESSAGE_LONG_BODY));
                        }
                        *remaining -= bytes.len() as u64;
                    }
                    self.pending = bytes;
                }
                Ok(Ok(None)) => {
                    self.finish(false);
                    if self.remaining.is_some_and(|remaining| remaining > 0) {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::UnexpectedEof,
                            MESSAGE_SHORT_BODY,
                        ));
                    }
                    return Ok(0);
                }
                Ok(Err(error)) => {
                    self.finish(true);
                    return Err(std::io::Error::other(stream_error_message(&error)));
                }
            }
        }
    }
}

impl Body {
    /// Ends the exchange; `cancel` asks the server to stop sending.
    /// Ends the exchange. A stream dropped before its end is stopped by quinn (STOP_SENDING);
    /// h3-quinn may hold the stream inside a pending read, where an explicit `stop_sending`
    /// panics, so it is only dropped.
    fn finish(&mut self, cancel: bool) {
        let _ = cancel;
        self.finished = true;
        if let Some(stream) = self.stream.take() {
            let _guard = self.runtime.enter();
            drop(stream);
        }
    }
}

impl Drop for Body {
    fn drop(&mut self) {
        // A body dropped before its end (cancelled download, capped API body).
        if !self.finished {
            self.finish(true);
        }
    }
}

fn stream_error_message(error: &h3::error::StreamError) -> &'static str {
    match error {
        h3::error::StreamError::RemoteTerminate { .. } => MESSAGE_RESET,
        h3::error::StreamError::StreamError { .. } | h3::error::StreamError::HeaderTooBig { .. } => MESSAGE_PROTOCOL,
        _ => MESSAGE_CLOSED,
    }
}
