#![allow(dead_code)]

pub mod abi;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use capgo_updater_core::ffi::CapgoHostCallbacks;
use capgo_updater_core::host::{Host, MemoryHost};
use capgo_updater_core::text::hex_decode;
use serde_json::{json, Value};

#[allow(unused_imports)]
pub use abi::{core, AbiEngine, AbiError, AbiResult};

/// The engine configuration of the tests, storage under `dir`, `extra` keys merged in.
pub fn engine_config(dir: &Path, extra: Value) -> Value {
    let mut config = json!({
        "platform": "android",
        "appId": "app.capgo.test",
        "pluginVersion": "8.0.0",
        "versionBuild": "1.0.0",
        "versionCode": "10",
        "versionOs": "14",
        "deviceId": "device-1",
        "builtinServerPath": "public",
        "bundleRoot": dir.join("versions").to_string_lossy(),
        "storageRoot": dir.to_string_lossy(),
        "cacheDir": dir.join("cache/capgo_downloads").to_string_lossy(),
    });
    if let (Some(config), Some(extra)) = (config.as_object_mut(), extra.as_object()) {
        for (key, value) in extra {
            config.insert(key.clone(), value.clone());
        }
    }
    config
}

pub struct TestEngine {
    pub engine: Arc<AbiEngine>,
    pub host: Arc<MemoryHost>,
    pub dir: tempfile::TempDir,
}

impl TestEngine {
    pub fn new(extra: Value) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let host = Arc::new(MemoryHost::default());
        let engine = AbiEngine::new(host.clone(), &engine_config(dir.path(), extra)).expect("engine config refused");
        Self { engine, host, dir }
    }

    pub fn call(&self, op: &str, input: Value) -> Value {
        self.engine
            .call(op, &input)
            .unwrap_or_else(|error| panic!("{op} failed: {error}"))
    }

    pub fn root(&self) -> &Path {
        self.dir.path()
    }

    /// Creates a bundle folder with index.html and a stored record.
    pub fn install_bundle(&self, id: &str, version: &str, status: &str) -> PathBuf {
        let dir = self.dir.path().join("versions").join(id);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("index.html"), "<html></html>").unwrap();
        self.call(
            "bundleSave",
            json!({ "id": id, "bundle": { "id": id, "version": version, "downloaded": "2024-01-01T00:00:00.000Z", "checksum": "abc", "status": status } }),
        );
        dir
    }

    pub fn kv(&self, key: &str) -> Option<String> {
        self.host.store.lock().unwrap().get(key).cloned()
    }
}

pub type Reply = (u16, Vec<(String, String)>, Vec<u8>);
type Responder = Arc<dyn Fn(&RecordedRequest) -> Reply + Send + Sync>;

/// Minimal HTTP server answering with scripted responses and recording requests.
pub struct FakeServer {
    pub url: String,
    pub requests: Arc<Mutex<Vec<RecordedRequest>>>,
}

#[derive(Clone, Debug)]
pub struct RecordedRequest {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl RecordedRequest {
    pub fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or(Value::Null)
    }
    pub fn header(&self, name: &str) -> Option<String> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.clone())
    }
}

impl FakeServer {
    pub fn start(
        responder: impl Fn(&RecordedRequest) -> (u16, Vec<(String, String)>, Vec<u8>) + Send + Sync + 'static,
    ) -> Self {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let url = format!("http://{}", server.server_addr().to_ip().unwrap());
        let requests: Arc<Mutex<Vec<RecordedRequest>>> = Arc::default();
        let responder: Responder = Arc::new(responder);
        let requests_clone = requests.clone();
        std::thread::spawn(move || {
            for mut request in server.incoming_requests() {
                // One thread per request: a slow response must not stall other connections.
                let (requests_clone, responder) = (requests_clone.clone(), responder.clone());
                std::thread::spawn(move || {
                    let mut body = Vec::new();
                    let _ = std::io::Read::read_to_end(request.as_reader(), &mut body);
                    let recorded = RecordedRequest {
                        method: request.method().to_string(),
                        url: request.url().to_string(),
                        headers: request
                            .headers()
                            .iter()
                            .map(|h| (h.field.to_string(), h.value.to_string()))
                            .collect(),
                        body,
                    };
                    requests_clone.lock().unwrap().push(recorded.clone());
                    // No lock around the responder: a slow response must not delay the others.
                    let (status, headers, body) = responder(&recorded);
                    // No keep-alive: tiny_http can stall a reused connection under load.
                    let mut response = tiny_http::Response::from_data(body)
                        .with_status_code(status)
                        .with_header(tiny_http::Header::from_bytes(&b"Connection"[..], &b"close"[..]).unwrap());
                    for (key, value) in headers {
                        response.add_header(tiny_http::Header::from_bytes(key.as_bytes(), value.as_bytes()).unwrap());
                    }
                    let _ = request.respond(response);
                });
            }
        });
        Self { url, requests }
    }

    pub fn json(status: u16, body: Value) -> (u16, Vec<(String, String)>, Vec<u8>) {
        (
            status,
            vec![("Content-Type".into(), "application/json".into())],
            body.to_string().into_bytes(),
        )
    }

    pub fn requests(&self) -> Vec<RecordedRequest> {
        self.requests.lock().unwrap().clone()
    }
}

/// The engine's HTTP client (`test.http`): every request uses a fresh client (no pooled
/// connection or TLS session) with this user agent and timeout.
pub struct TestHttp {
    engine: Arc<AbiEngine>,
    user_agent: String,
    timeout: Duration,
    _dir: tempfile::TempDir,
}

/// An HTTP answer: `body` is decoded (content coding removed).
#[derive(Debug)]
pub struct HttpResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl HttpResponse {
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    pub fn json(&self) -> serde_json::Result<Value> {
        serde_json::from_slice(&self.body)
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

impl TestHttp {
    pub fn new(host: Arc<dyn Host>, user_agent: &str, timeout: Duration) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let engine = AbiEngine::new(host, &engine_config(dir.path(), json!({}))).expect("engine config refused");
        Self::with_engine(engine, dir, user_agent, timeout)
    }

    /// A client whose host is the given C callbacks (the engine owns them: `release`).
    pub fn with_callbacks(callbacks: CapgoHostCallbacks, user_agent: &str, timeout: Duration) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let engine =
            AbiEngine::with_callbacks(callbacks, &engine_config(dir.path(), json!({}))).expect("engine config refused");
        Self::with_engine(engine, dir, user_agent, timeout)
    }

    fn with_engine(engine: Arc<AbiEngine>, dir: tempfile::TempDir, user_agent: &str, timeout: Duration) -> Self {
        Self {
            engine,
            user_agent: user_agent.to_string(),
            timeout,
            _dir: dir,
        }
    }

    fn request(&self, mut input: Value) -> AbiResult<HttpResponse> {
        input["userAgent"] = json!(self.user_agent);
        input["timeoutMs"] = json!(self.timeout.as_millis() as u64);
        let reply = self.engine.call("test.http", &input)?;
        Ok(HttpResponse {
            status: reply["status"].as_u64().expect("status") as u16,
            headers: reply["headers"]
                .as_array()
                .expect("headers")
                .iter()
                .map(|pair| {
                    (
                        pair[0].as_str().unwrap_or_default().to_string(),
                        pair[1].as_str().unwrap_or_default().to_string(),
                    )
                })
                .collect(),
            body: hex_decode(reply["bodyHex"].as_str().expect("bodyHex")).expect("hex body"),
        })
    }

    /// An API request (`GET`).
    pub fn get(&self, url: &str) -> AbiResult<HttpResponse> {
        self.request(json!({ "url": url }))
    }

    /// An API request with a JSON body.
    pub fn send_json(&self, method: &str, url: &str, body: &Value) -> AbiResult<HttpResponse> {
        self.request(json!({ "url": url, "method": method, "json": body }))
    }

    /// A bundle download (identity encoding, streamed body).
    pub fn download(&self, url: &str) -> AbiResult<HttpResponse> {
        self.request(json!({ "url": url, "download": true }))
    }
}
