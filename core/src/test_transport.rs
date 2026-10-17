//! A stand-in for the platform network stacks behind [`Host::http_request`] (tests only).
//!
//! It behaves like URLSession / Android `HttpEngine` as the hosts drive them: no redirect
//! is followed, the system proxy (the host's `proxyForUrl` answer) is used, gzip bodies
//! are decoded (the `Content-Encoding` header stays, as URLSession leaves it), the body
//! goes to the sink or is appended to `body_path`, and the timeout is an idle timeout.
//! It speaks plain HTTP/1.1 only: HTTPS requests are reported unavailable and fall back
//! to the engine's own client (whose TLS the TLS tests cover).
//!
//! `CAPGO_TEST_HOST_TRANSPORT=1` gives every [`MemoryHost`] without a scripted transport
//! this one, so the whole suite can run through the host transport path.
//!
//! [`MemoryHost`]: crate::host::MemoryHost

use std::io::{Read, Write};

use crate::host::{Host, HttpTransportEvent, HttpTransportOutcome, HttpTransportRequest};

/// Protocol this stand-in reports.
pub const PROTOCOL: &str = "http/1.1";

pub fn enabled_by_env() -> bool {
    std::env::var("CAPGO_TEST_HOST_TRANSPORT").is_ok_and(|value| value == "1")
}

fn failed(kind: &str, message: impl Into<String>) -> HttpTransportOutcome {
    HttpTransportOutcome::Failed {
        kind: kind.into(),
        message: message.into(),
    }
}

fn io_kind(error: &std::io::Error) -> &'static str {
    match error.kind() {
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => "timeout",
        _ if error.to_string().to_ascii_lowercase().contains("timed out") => "timeout",
        _ => "network",
    }
}

/// Sends `request` like a platform stack would (see the module documentation).
pub fn send(
    host: &dyn Host,
    request: &HttpTransportRequest<'_>,
    sink: &mut dyn FnMut(HttpTransportEvent<'_>) -> bool,
) -> HttpTransportOutcome {
    let Ok(url) = url::Url::parse(request.url) else {
        return failed("invalid_url", format!("Invalid URL: {}", request.url));
    };
    if url.scheme() != "http" {
        return HttpTransportOutcome::Unavailable;
    }
    let mut builder = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(request.timeout)
        .timeout_read(request.timeout)
        .timeout_write(request.timeout);
    if let Some(proxy) = host.proxy_for_url(request.url) {
        // ureq splits the proxy address on ':': a placeholder name resolves to the real proxy
        // (IPv6 literals included).
        const PLACEHOLDER: &str = "capgo-test-proxy";
        match ureq::Proxy::new(format!("http://{PLACEHOLDER}:{}", proxy.port)) {
            Ok(ureq_proxy) => {
                builder = builder.proxy(ureq_proxy).resolver(move |netloc: &str| {
                    use std::net::ToSocketAddrs;
                    if netloc.split(':').next() == Some(PLACEHOLDER) {
                        (proxy.host.as_str(), proxy.port)
                            .to_socket_addrs()
                            .map(Iterator::collect)
                    } else {
                        netloc.to_socket_addrs().map(Iterator::collect)
                    }
                })
            }
            Err(error) => return failed("network", error.to_string()),
        }
    }
    let agent = builder.build();
    let mut call = agent.request(request.method, request.url);
    for (name, value) in request.headers {
        call = call.set(name, value);
    }
    let result = match request.body {
        Some(body) => call.send_bytes(body),
        None => call.call(),
    };
    let response = match result {
        Ok(response) | Err(ureq::Error::Status(_, response)) => response,
        Err(ureq::Error::Transport(transport)) => {
            let message = transport.to_string();
            let lower = message.to_ascii_lowercase();
            let kind = match transport.kind() {
                ureq::ErrorKind::InvalidUrl | ureq::ErrorKind::UnknownScheme => "invalid_url",
                _ if lower.contains("timed out") || lower.contains("timeout") => "timeout",
                _ => "network",
            };
            return failed(kind, message);
        }
    };
    let mut headers = Vec::new();
    let mut names = response.headers_names();
    names.dedup();
    for name in names {
        for value in response.all(&name) {
            if !headers
                .iter()
                .any(|(seen, other): &(String, String)| *seen == name && other == value)
            {
                headers.push((name.clone(), value.to_string()));
            }
        }
    }
    let gzip = response
        .header("Content-Encoding")
        .is_some_and(|value| value.trim().eq_ignore_ascii_case("gzip") || value.trim().eq_ignore_ascii_case("x-gzip"));
    if !sink(HttpTransportEvent::Head {
        status: response.status(),
        headers,
    }) {
        return failed("cancelled", "Request cancelled");
    }
    // An empty gzip-labelled body (e.g. 204) is just empty, as the platform stacks see it.
    let mut raw = std::io::BufReader::new(response.into_reader());
    let empty = match std::io::BufRead::fill_buf(&mut raw) {
        Ok(bytes) => bytes.is_empty(),
        Err(error) => return failed(io_kind(&error), error.to_string()),
    };
    let mut reader: Box<dyn Read> = if gzip && !empty {
        Box::new(flate2::read::MultiGzDecoder::new(raw))
    } else {
        Box::new(raw)
    };
    let mut file = match request.body_path {
        Some(path) => match std::fs::OpenOptions::new().create(true).append(true).open(path) {
            Ok(file) => Some(file),
            Err(error) => return failed("io", error.to_string()),
        },
        None => None,
    };
    let mut buffer = vec![0u8; 16 * 1024];
    let mut written: u64 = 0;
    loop {
        let read = match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => read,
            Err(error) => return failed(io_kind(&error), error.to_string()),
        };
        let accepted = match file.as_mut() {
            Some(file) => {
                if let Err(error) = file.write_all(&buffer[..read]) {
                    return failed("io", error.to_string());
                }
                written += read as u64;
                sink(HttpTransportEvent::Written(written))
            }
            None => sink(HttpTransportEvent::Data(&buffer[..read])),
        };
        if !accepted {
            return failed("cancelled", "Request cancelled");
        }
    }
    HttpTransportOutcome::Completed {
        protocol: Some(PROTOCOL.into()),
    }
}
