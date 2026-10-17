//! Requests through the host's network stack (`http_request` host callback: URLSession,
//! Android `HttpEngine`): the engine keeps its own rules there (redirect policy, body cap,
//! length checks, resume, cancellation, timeouts), downloads go straight to their file,
//! and a host without a transport (or `systemHttp: false`) gets the engine's own client.
//!
//! The whole suite also runs through a stand-in for the platform stacks with
//! `CAPGO_TEST_HOST_TRANSPORT=1` (`capgo_updater_core::test_transport`).

mod support;

use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use capgo_updater_core::host::{HttpTransportEvent, HttpTransportOutcome, HttpTransportRequest, LogLevel, MemoryHost};
use serde_json::{json, Value};
use support::{AbiEngine, AbiResult, FakeServer, TestEngine, TestHttp};

fn sha256(bytes: &[u8]) -> String {
    capgo_updater_core::crypto::checksum::sha256_hex(bytes)
}

fn zip_of(files: &[(&str, &[u8])]) -> Vec<u8> {
    let mut buffer = std::io::Cursor::new(Vec::new());
    {
        let mut writer = zip::ZipWriter::new(&mut buffer);
        for (name, content) in files {
            writer
                .start_file(*name, zip::write::SimpleFileOptions::default())
                .unwrap();
            writer.write_all(content).unwrap();
        }
        writer.finish().unwrap();
    }
    buffer.into_inner()
}

fn web_bundle(marker: &str) -> Vec<u8> {
    zip_of(&[
        ("index.html", format!("<html>{marker}</html>").as_bytes()),
        ("js/app.js", &vec![b'x'; 200 * 1024]),
    ])
}

/// A request the host transport received.
#[derive(Clone, Debug)]
struct Seen {
    method: String,
    url: String,
    headers: Vec<(String, String)>,
    timeout: Duration,
    body_path: Option<PathBuf>,
    body: Option<Vec<u8>>,
}

impl Seen {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

/// What the scripted transports saw.
#[derive(Default)]
struct Log {
    requests: Mutex<Vec<Seen>>,
    /// Requests a sink function cancelled.
    cancelled: AtomicUsize,
    in_flight: AtomicUsize,
    max_in_flight: AtomicUsize,
}

impl Log {
    fn requests(&self) -> Vec<Seen> {
        self.requests.lock().unwrap().clone()
    }
}

type Answer = dyn Fn(&HttpTransportRequest<'_>, &mut dyn FnMut(HttpTransportEvent<'_>) -> bool) -> HttpTransportOutcome
    + Send
    + Sync;

/// Gives `host` a transport that records every request, then answers with `answer`.
fn install(host: &MemoryHost, answer: Arc<Answer>) -> Arc<Log> {
    let log = Arc::new(Log::default());
    let seen = log.clone();
    *host.http_transport.lock().unwrap() = Some(Arc::new(move |request, sink| {
        seen.requests.lock().unwrap().push(Seen {
            method: request.method.to_string(),
            url: request.url.to_string(),
            headers: request.headers.to_vec(),
            timeout: request.timeout,
            body_path: request.body_path.map(PathBuf::from),
            body: request.body.map(<[u8]>::to_vec),
        });
        let now = seen.in_flight.fetch_add(1, Ordering::SeqCst) + 1;
        seen.max_in_flight.fetch_max(now, Ordering::SeqCst);
        let cancelled = AtomicBool::new(false);
        let outcome = answer(request, &mut |event| {
            let accepted = sink(event);
            if !accepted {
                cancelled.store(true, Ordering::SeqCst);
            }
            accepted
        });
        seen.in_flight.fetch_sub(1, Ordering::SeqCst);
        if cancelled.load(Ordering::SeqCst) {
            seen.cancelled.fetch_add(1, Ordering::SeqCst);
        }
        outcome
    }));
    log
}

/// The platform-stack stand-in over real sockets, reporting `protocol`.
fn relay(protocol: &'static str) -> Arc<Answer> {
    Arc::new(move |request, sink| {
        match capgo_updater_core::test_transport::send(&MemoryHost::default(), request, sink) {
            HttpTransportOutcome::Completed { .. } => HttpTransportOutcome::Completed {
                protocol: Some(protocol.into()),
            },
            other => other,
        }
    })
}

fn cancelled() -> HttpTransportOutcome {
    HttpTransportOutcome::Failed {
        kind: "cancelled".into(),
        message: "cancelled".into(),
    }
}

/// Answers one response like a platform stack: head, then the body to the sink or the file.
fn respond(
    request: &HttpTransportRequest<'_>,
    sink: &mut dyn FnMut(HttpTransportEvent<'_>) -> bool,
    status: u16,
    headers: &[(&str, &str)],
    body: &[u8],
) -> HttpTransportOutcome {
    let headers = headers
        .iter()
        .map(|(name, value)| (name.to_string(), value.to_string()))
        .collect();
    if !sink(HttpTransportEvent::Head { status, headers }) {
        return cancelled();
    }
    let accepted = match request.body_path {
        Some(path) => {
            let mut file = std::fs::OpenOptions::new()
                .append(true)
                .create(true)
                .open(path)
                .unwrap();
            file.write_all(body).unwrap();
            sink(HttpTransportEvent::Written(body.len() as u64))
        }
        None => body.is_empty() || sink(HttpTransportEvent::Data(body)),
    };
    if !accepted {
        return cancelled();
    }
    HttpTransportOutcome::Completed {
        protocol: Some("h3".into()),
    }
}

fn http(host: Arc<MemoryHost>) -> TestHttp {
    TestHttp::new(host, "CapacitorUpdater/test", Duration::from_secs(10))
}

fn json_server() -> FakeServer {
    FakeServer::start(|_| FakeServer::json(200, json!({ "ok": true })))
}

fn debug_logs(host: &MemoryHost, prefix: &str) -> Vec<String> {
    host.logs
        .lock()
        .unwrap()
        .iter()
        .filter(|(level, message)| *level == LogLevel::Debug && message.starts_with(prefix))
        .map(|(_, message)| message.clone())
        .collect()
}

#[test]
fn api_requests_carry_the_engine_headers_and_report_the_protocol() {
    let server = json_server();
    let host = Arc::new(MemoryHost::default());
    let log = install(&host, relay("h3"));
    let response = http(host.clone())
        .send_json("POST", &format!("{}/updates", server.url), &json!({ "a": 1 }))
        .unwrap();
    assert_eq!(response.status, 200);
    assert_eq!(response.json().unwrap(), json!({ "ok": true }));
    let seen = &log.requests()[0];
    assert_eq!(seen.method, "POST");
    assert_eq!(
        seen.headers[0],
        ("User-Agent".to_string(), "CapacitorUpdater/test".to_string())
    );
    assert_eq!(seen.header("Accept-Encoding"), Some("gzip"));
    assert_eq!(seen.header("Accept"), Some("application/json"));
    assert_eq!(seen.header("Content-Type"), Some("application/json; charset=utf-8"));
    assert_eq!(seen.body.as_deref(), Some(&br#"{"a":1}"#[..]));
    assert_eq!(seen.timeout, Duration::from_secs(10));
    assert_eq!(seen.body_path, None);
    // The server saw the request the host sent.
    assert_eq!(
        server.requests()[0].header("User-Agent").as_deref(),
        Some("CapacitorUpdater/test")
    );

    let reply = support::AbiEngine::new(
        host.clone(),
        &support::engine_config(tempfile::tempdir().unwrap().path(), json!({})),
    )
    .unwrap()
    .call(
        "test.http",
        &json!({ "url": format!("{}/plain", server.url), "userAgent": "ua", "timeoutMs": 2500 }),
    )
    .unwrap();
    assert_eq!(reply["protocol"], "h3");
    assert_eq!(log.requests()[1].header("Accept"), Some("*/*"));
    assert_eq!(log.requests()[1].timeout, Duration::from_millis(2500));
}

#[test]
fn the_negotiated_protocol_is_logged_when_it_changes() {
    let server = json_server();
    let t = TestEngine::new(json!({}));
    let protocol = Arc::new(Mutex::new("h2"));
    let current = protocol.clone();
    install(
        &t.host,
        Arc::new(move |request, sink| {
            let label = *current.lock().unwrap();
            match capgo_updater_core::test_transport::send(&MemoryHost::default(), request, sink) {
                HttpTransportOutcome::Completed { .. } => HttpTransportOutcome::Completed {
                    protocol: Some(label.into()),
                },
                other => other,
            }
        }),
    );
    let url = format!("{}/payload", server.url);
    t.engine.fetch_json(&url).unwrap();
    t.engine.fetch_json(&url).unwrap();
    *protocol.lock().unwrap() = "h3";
    t.engine.fetch_json(&url).unwrap();
    t.engine.fetch_json(&url).unwrap();
    assert_eq!(
        debug_logs(&t.host, "System HTTP transport:"),
        vec![
            "System HTTP transport: h2 with 127.0.0.1".to_string(),
            "System HTTP transport: h3 with 127.0.0.1".to_string(),
        ]
    );
}

#[test]
fn zip_bodies_go_straight_to_the_download_file() {
    let bundle = web_bundle("v2");
    let served = bundle.clone();
    let server = FakeServer::start(move |_| (200, vec![], served.clone()));
    let t = TestEngine::new(json!({ "timeoutMs": 5000 }));
    let log = install(&t.host, relay("h3"));
    let installed = t.call(
        "download",
        json!({ "url": format!("{}/b.zip", server.url), "version": "2.0.0", "checksum": sha256(&bundle) }),
    );
    assert_eq!(installed["status"], "pending");
    let seen = &log.requests()[0];
    let path = seen.body_path.clone().expect("the zip went to a file");
    assert_eq!(path.parent().unwrap(), t.root());
    let name = path.file_name().unwrap().to_string_lossy().into_owned();
    assert!(name.starts_with("temp_") && name.ends_with(".tmp"), "{name}");
    assert_eq!(seen.header("Accept-Encoding"), Some("identity"));
    // Bundle transfers get at least 60 s, like the engine's download agent.
    assert_eq!(seen.timeout, Duration::from_secs(60));
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert_eq!(
        std::fs::read_to_string(dir.join("index.html")).unwrap(),
        "<html>v2</html>"
    );
    let percents: Vec<i64> = t
        .host
        .events_named("download")
        .iter()
        .map(|event| event["percent"].as_i64().unwrap())
        .collect();
    assert!(percents.contains(&70), "{percents:?}");
    assert_eq!(percents.last(), Some(&100));
}

#[test]
fn a_zip_the_host_corrupted_fails_its_checksum() {
    let bundle = web_bundle("v2");
    let t = TestEngine::new(json!({}));
    let checksum = sha256(&bundle);
    install(
        &t.host,
        Arc::new(move |request, sink| {
            let mut corrupted = bundle.clone();
            corrupted[10] ^= 0xff;
            let length = corrupted.len().to_string();
            respond(request, sink, 200, &[("Content-Length", &length)], &corrupted)
        }),
    );
    let error = t
        .engine
        .call(
            "download",
            &json!({ "url": "https://cdn.test/b.zip", "version": "2.0.0", "checksum": checksum }),
        )
        .unwrap_err();
    assert_eq!(error.code, "checksum_fail", "{error:?}");
}

#[test]
fn a_short_body_is_an_incomplete_download() {
    let bundle = web_bundle("v2");
    let t = TestEngine::new(json!({}));
    let checksum = sha256(&bundle);
    install(
        &t.host,
        Arc::new(move |request, sink| {
            let length = bundle.len().to_string();
            respond(
                request,
                sink,
                200,
                &[("Content-Length", &length)],
                &bundle[..bundle.len() / 2],
            )
        }),
    );
    let error = t
        .engine
        .call(
            "download",
            &json!({ "url": "https://cdn.test/b.zip", "version": "2.0.0", "checksum": checksum }),
        )
        .unwrap_err();
    assert_eq!(error.code, "incomplete_download", "{error:?}");
}

#[test]
fn the_engine_follows_redirects_itself() {
    let host = Arc::new(MemoryHost::default());
    let log = install(
        &host,
        Arc::new(|request, sink| match request.url {
            "http://a.test/start" => respond(request, sink, 302, &[("Location", "/next")], b"moved"),
            "http://a.test/next" => respond(request, sink, 200, &[], b"done"),
            "http://a.test/post" => respond(request, sink, 303, &[("Location", "http://b.test/get")], b""),
            "http://b.test/get" => respond(request, sink, 200, &[], b"got"),
            "https://a.test/secure" => respond(request, sink, 301, &[("Location", "http://a.test/next")], b""),
            "http://a.test/cached" => respond(request, sink, 304, &[("Location", "/next")], b""),
            _ => respond(request, sink, 302, &[("Location", "/loop")], b""),
        }),
    );
    let client = http(host.clone());
    assert_eq!(client.get("http://a.test/start").unwrap().text(), "done");
    let urls: Vec<String> = log.requests().iter().map(|seen| seen.url.clone()).collect();
    assert_eq!(urls, ["http://a.test/start", "http://a.test/next"]);

    // 303 turns a POST into a GET without a body.
    let response = client
        .send_json("POST", "http://a.test/post", &json!({ "x": 1 }))
        .unwrap();
    assert_eq!(response.text(), "got");
    let after = &log.requests()[3];
    assert_eq!((after.method.as_str(), after.body.is_none()), ("GET", true));

    // HTTPS -> HTTP is refused: the host never sees the HTTP URL.
    let error = client.get("https://a.test/secure").unwrap_err();
    assert_eq!(error.code, "insecure_redirect", "{error:?}");
    assert_eq!(log.requests().len(), 5);

    // 304 is a final response.
    assert_eq!(client.get("http://a.test/cached").unwrap().status, 304);

    // Five redirects at most.
    let before = log.requests().len();
    let error = client.get("http://a.test/loop").unwrap_err();
    assert_eq!(error.message, "Too many redirects");
    assert_eq!(log.requests().len() - before, 6);
}

#[test]
fn api_bodies_stop_at_the_cap() {
    let host = Arc::new(MemoryHost::default());
    let log = install(
        &host,
        Arc::new(|request, sink| {
            if !sink(HttpTransportEvent::Head {
                status: 200,
                headers: vec![],
            }) {
                return cancelled();
            }
            let chunk = vec![b'a'; 1024 * 1024];
            for _ in 0..20 {
                if !sink(HttpTransportEvent::Data(&chunk)) {
                    return cancelled();
                }
            }
            let _ = request;
            HttpTransportOutcome::Completed { protocol: None }
        }),
    );
    let response = http(host).get("http://big.test/").unwrap();
    assert_eq!(response.body.len(), 16 * 1024 * 1024);
    assert_eq!(log.cancelled.load(Ordering::SeqCst), 1);
}

#[test]
fn preview_payloads_stay_capped() {
    let t = TestEngine::new(json!({}));
    let log = install(
        &t.host,
        Arc::new(|request, sink| respond(request, sink, 200, &[], &vec![b' '; 17 * 1024 * 1024])),
    );
    let error = t.engine.fetch_json("https://preview.test/payload").unwrap_err();
    assert_eq!(error.message, "Preview payload is too large");
    assert_eq!(log.cancelled.load(Ordering::SeqCst), 1);
}

#[test]
fn host_failures_keep_their_kind() {
    for (kind, code) in [
        ("timeout", "timeout"),
        ("tls", "tls"),
        ("network", "network"),
        ("invalid_url", "invalid_url"),
        ("io", "io"),
        ("cancelled", "network"),
        ("something", "network"),
    ] {
        let host = Arc::new(MemoryHost::default());
        install(
            &host,
            Arc::new(move |_, _| HttpTransportOutcome::Failed {
                kind: kind.into(),
                message: format!("host says {kind}"),
            }),
        );
        let error = http(host).get("https://api.test/").unwrap_err();
        assert_eq!(
            (error.code.as_str(), error.message.as_str()),
            (code, format!("host says {kind}").as_str())
        );
    }
}

#[test]
fn a_timeout_from_the_host_is_retried_like_one_from_the_engine() {
    let bundle = web_bundle("retry");
    let t = TestEngine::new(json!({}));
    let checksum = sha256(&bundle);
    let attempts = Arc::new(AtomicUsize::new(0));
    let counter = attempts.clone();
    install(
        &t.host,
        Arc::new(move |request, sink| {
            if counter.fetch_add(1, Ordering::SeqCst) == 0 {
                return HttpTransportOutcome::Failed {
                    kind: "timeout".into(),
                    message: "The request timed out.".into(),
                };
            }
            respond(request, sink, 200, &[], &bundle)
        }),
    );
    let installed = t.call(
        "download",
        json!({ "url": "https://cdn.test/b.zip", "version": "2.0.0", "checksum": checksum }),
    );
    assert_eq!(installed["status"], "pending");
    assert_eq!(attempts.load(Ordering::SeqCst), 2);
}

#[test]
fn hosts_without_a_transport_use_the_engine_client() {
    let server = json_server();
    let host = Arc::new(MemoryHost::default());
    let log = install(&host, Arc::new(|_, _| HttpTransportOutcome::Unavailable));
    let reply = AbiEngine::new(
        host.clone(),
        &support::engine_config(tempfile::tempdir().unwrap().path(), json!({})),
    )
    .unwrap()
    .call("test.http", &json!({ "url": format!("{}/x", server.url) }))
    .unwrap();
    assert_eq!(reply["status"], 200);
    assert_eq!(reply["protocol"], "http/1.1");
    assert_eq!(log.requests().len(), 1);
    assert_eq!(server.requests().len(), 1);
}

#[test]
fn system_http_off_keeps_the_engine_client() {
    let bundle = web_bundle("v2");
    let served = bundle.clone();
    let server = FakeServer::start(move |_| (200, vec![], served.clone()));
    let t = TestEngine::new(json!({ "systemHttp": false }));
    let log = install(&t.host, relay("h3"));
    let input = json!({ "url": format!("{}/b.zip", server.url), "version": "2.0.0", "checksum": sha256(&bundle) });
    t.call("download", input.clone());
    assert!(log.requests().is_empty());
    assert_eq!(server.requests().len(), 1);
    // `configure` turns it back on.
    t.call("configure", json!({ "systemHttp": true }));
    t.call(
        "download",
        json!({ "url": input["url"], "version": "3.0.0", "checksum": input["checksum"] }),
    );
    assert_eq!(log.requests().len(), 1);
}

#[test]
fn transport_contract_violations_fail_the_request() {
    let cases: Vec<(&str, Arc<Answer>)> = vec![
        (
            "body before the response head",
            Arc::new(|_, sink| {
                sink(HttpTransportEvent::Data(b"early"));
                HttpTransportOutcome::Completed { protocol: None }
            }),
        ),
        (
            "no response head",
            Arc::new(|_, _| HttpTransportOutcome::Completed { protocol: None }),
        ),
        (
            "second response head",
            Arc::new(|_, sink| {
                for _ in 0..2 {
                    if !sink(HttpTransportEvent::Head {
                        status: 200,
                        headers: vec![],
                    }) {
                        return cancelled();
                    }
                }
                HttpTransportOutcome::Completed { protocol: None }
            }),
        ),
        (
            "unavailable after the response head",
            Arc::new(|_, sink| {
                sink(HttpTransportEvent::Head {
                    status: 200,
                    headers: vec![],
                });
                HttpTransportOutcome::Unavailable
            }),
        ),
    ];
    for (problem, answer) in cases {
        let host = Arc::new(MemoryHost::default());
        install(&host, answer);
        let error = http(host).get("https://api.test/").unwrap_err();
        assert_eq!(
            (error.code.as_str(), error.message.clone()),
            (
                "network",
                format!("Invalid response from the system HTTP transport: {problem}")
            )
        );
    }
}

/// Calls `download` on another thread, like a plugin method lane.
fn download_async(engine: &Arc<AbiEngine>, input: Value) -> std::thread::JoinHandle<AbiResult<Value>> {
    let engine = engine.clone();
    std::thread::spawn(move || engine.call("download", &input))
}

#[test]
fn stopping_a_download_cancels_the_host_request() {
    let t = TestEngine::new(json!({}));
    t.host.reply_to_hook("scheduleDownload", json!({ "scheduled": true }));
    let started = Arc::new(AtomicBool::new(false));
    let flag = started.clone();
    let log = install(
        &t.host,
        Arc::new(move |request, sink| {
            if !sink(HttpTransportEvent::Head {
                status: 200,
                headers: vec![("Content-Length".into(), "100000000".into())],
            }) {
                return cancelled();
            }
            let path = request.body_path.expect("downloads go to a file");
            let mut file = std::fs::OpenOptions::new().append(true).open(path).unwrap();
            let mut written = 0u64;
            let deadline = Instant::now() + Duration::from_secs(20);
            while Instant::now() < deadline {
                file.write_all(&[0u8; 1024]).unwrap();
                written += 1024;
                flag.store(true, Ordering::SeqCst);
                if !sink(HttpTransportEvent::Written(written)) {
                    return cancelled();
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            HttpTransportOutcome::Completed { protocol: None }
        }),
    );
    let caller = download_async(
        &t.engine,
        json!({ "url": "https://cdn.test/b.zip", "version": "2.0.0", "checksum": "abc" }),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    let id = loop {
        if let Some(hook) = t.host.hooks_named("scheduleDownload").first() {
            break hook["id"].as_str().unwrap().to_string();
        }
        assert!(Instant::now() < deadline, "no scheduleDownload hook");
        std::thread::sleep(Duration::from_millis(5));
    };
    let engine = t.engine.clone();
    let job = id.clone();
    let attempt = std::thread::spawn(move || engine.call("runScheduledDownload", &json!({ "id": job })).unwrap());
    while !started.load(Ordering::SeqCst) {
        assert!(Instant::now() < deadline, "the transfer never started");
        std::thread::sleep(Duration::from_millis(5));
    }
    t.call("stopScheduledDownload", json!({ "id": id }));
    assert_eq!(attempt.join().unwrap()["result"], "retry");
    assert_eq!(log.cancelled.load(Ordering::SeqCst), 1);
    t.call("bundleDelete", json!({ "id": id }));
    let _ = caller.join();
}

fn manifest_entry(name: &str, content: &[u8]) -> Value {
    json!({ "file_name": name, "file_hash": sha256(content), "download_url": format!("https://cdn.test/files/{name}") })
}

type Files = Arc<Mutex<Vec<(String, Vec<u8>)>>>;

fn file_of(files: &Files, url: &str) -> Option<Vec<u8>> {
    let name = url.strip_prefix("https://cdn.test/files/")?;
    files
        .lock()
        .unwrap()
        .iter()
        .find(|(file, _)| file == name)
        .map(|(_, body)| body.clone())
}

#[test]
fn manifest_files_download_in_parallel_into_their_partial_files() {
    let files: Files = Arc::default();
    let mut manifest = Vec::new();
    for index in 0..40 {
        let content = format!("file {index}").repeat(100).into_bytes();
        let name = format!("assets/f{index}.js");
        manifest.push(manifest_entry(&name, &content));
        files.lock().unwrap().push((name, content));
    }
    let t = TestEngine::new(json!({}));
    let served = files.clone();
    let log = install(
        &t.host,
        Arc::new(move |request, sink| {
            std::thread::sleep(Duration::from_millis(30));
            match file_of(&served, request.url) {
                Some(body) => respond(request, sink, 200, &[], &body),
                None => respond(request, sink, 404, &[], b""),
            }
        }),
    );
    let installed = t.call("download", json!({ "version": "2", "manifest": manifest }));
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    for (name, content) in files.lock().unwrap().iter() {
        assert_eq!(&std::fs::read(dir.join(name)).unwrap(), content, "{name}");
    }
    let requests = log.requests();
    assert_eq!(requests.len(), 40);
    for seen in &requests {
        let name = seen
            .body_path
            .as_ref()
            .unwrap()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        assert!(name.starts_with("partial_") && name.ends_with(".tmp"), "{name}");
        assert_eq!(seen.header("Accept-Encoding"), Some("identity"));
    }
    assert!(
        log.max_in_flight.load(Ordering::SeqCst) > 1,
        "the files did not overlap"
    );
}

/// A first attempt leaves part of a file; the next one resumes it with `Range`.
fn resumed_manifest(
    second: impl Fn(&HttpTransportRequest<'_>, &mut dyn FnMut(HttpTransportEvent<'_>) -> bool, &[u8]) -> HttpTransportOutcome
        + Send
        + Sync
        + 'static,
) -> (TestEngine, Arc<Log>, Vec<u8>, Value) {
    let content: Vec<u8> = (0..50_000u32).map(|i| (i % 251) as u8).collect();
    let t = TestEngine::new(json!({}));
    let manifest = json!([manifest_entry("big.bin", &content)]);
    let attempts = Arc::new(AtomicUsize::new(0));
    let body = content.clone();
    let log = install(
        &t.host,
        Arc::new(move |request, sink| {
            if attempts.fetch_add(1, Ordering::SeqCst) > 0 {
                return second(request, sink, &body);
            }
            let length = body.len().to_string();
            if !sink(HttpTransportEvent::Head {
                status: 200,
                headers: vec![("Content-Length".into(), length)],
            }) {
                return cancelled();
            }
            let path = request.body_path.unwrap();
            std::fs::OpenOptions::new()
                .append(true)
                .open(path)
                .unwrap()
                .write_all(&body[..20_000])
                .unwrap();
            sink(HttpTransportEvent::Written(20_000));
            HttpTransportOutcome::Failed {
                kind: "network".into(),
                message: "The network connection was lost.".into(),
            }
        }),
    );
    let error = t
        .engine
        .call("download", &json!({ "version": "2", "manifest": manifest }))
        .unwrap_err();
    assert_eq!(error.code, "network_error", "{error:?}");
    (t, log, content, manifest)
}

#[test]
fn manifest_files_resume_with_range_through_the_host() {
    let (t, log, content, manifest) = resumed_manifest(|request, sink, body| {
        let range = request
            .headers
            .iter()
            .find(|(name, _)| name == "Range")
            .map(|(_, value)| value.clone())
            .expect("a Range header");
        let start: usize = range
            .trim_start_matches("bytes=")
            .trim_end_matches('-')
            .parse()
            .unwrap();
        let content_range = format!("bytes {start}-{}/{}", body.len() - 1, body.len());
        respond(request, sink, 206, &[("Content-Range", &content_range)], &body[start..])
    });
    let installed = t.call("download", json!({ "version": "2", "manifest": manifest }));
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert_eq!(std::fs::read(dir.join("big.bin")).unwrap(), content);
    assert_eq!(log.requests()[1].header("Range"), Some("bytes=20000-"));
}

#[test]
fn a_complete_partial_ignores_the_416_body() {
    let (t, log, content, manifest) = resumed_manifest(|request, sink, body| {
        if request
            .headers
            .iter()
            .any(|(name, value)| name == "Range" && value == "bytes=20000-")
        {
            // The first attempt really wrote everything: the partial is complete.
            let path = request.body_path.unwrap();
            std::fs::OpenOptions::new()
                .append(true)
                .open(path)
                .unwrap()
                .write_all(&body[20_000..])
                .unwrap();
            return HttpTransportOutcome::Failed {
                kind: "network".into(),
                message: "The network connection was lost.".into(),
            };
        }
        respond(request, sink, 416, &[], b"<html>Range Not Satisfiable</html>")
    });
    // Second attempt fails after completing the partial; the third gets a 416.
    let _ = t
        .engine
        .call("download", &json!({ "version": "2", "manifest": manifest }));
    let installed = t.call("download", json!({ "version": "2", "manifest": manifest }));
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert_eq!(std::fs::read(dir.join("big.bin")).unwrap(), content);
    assert_eq!(log.requests().len(), 3);
    assert_eq!(log.cancelled.load(Ordering::SeqCst), 1);
}
