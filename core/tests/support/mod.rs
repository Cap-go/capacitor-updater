#![allow(dead_code)]

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use capgo_updater_core::engine::Engine;
use capgo_updater_core::host::MemoryHost;
use serde_json::{json, Value};

pub struct TestEngine {
    pub engine: Arc<Engine>,
    pub host: Arc<MemoryHost>,
    pub dir: tempfile::TempDir,
}

impl TestEngine {
    pub fn new(extra: Value) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let host = Arc::new(MemoryHost::default());
        let mut config = json!({
            "platform": "android",
            "appId": "app.capgo.test",
            "pluginVersion": "8.0.0",
            "versionBuild": "1.0.0",
            "versionCode": "10",
            "versionOs": "14",
            "deviceId": "device-1",
            "builtinServerPath": "public",
            "bundleRoot": dir.path().join("versions").to_string_lossy(),
            "storageRoot": dir.path().to_string_lossy(),
            "cacheDir": dir.path().join("cache/capgo_downloads").to_string_lossy(),
        });
        if let (Some(config), Some(extra)) = (config.as_object_mut(), extra.as_object()) {
            for (key, value) in extra {
                config.insert(key.clone(), value.clone());
            }
        }
        let engine = Engine::new(host.clone(), &config).unwrap();
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

/// Minimal HTTP server answering with scripted responses and recording requests.
pub struct FakeServer {
    pub url: String,
    pub requests: Arc<Mutex<Vec<RecordedRequest>>>,
    responder: Arc<
        Mutex<Box<dyn FnMut(&RecordedRequest) -> (u16, Vec<(String, String)>, Vec<u8>) + Send>>,
    >,
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
        responder: impl FnMut(&RecordedRequest) -> (u16, Vec<(String, String)>, Vec<u8>)
            + Send
            + 'static,
    ) -> Self {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let url = format!("http://{}", server.server_addr().to_ip().unwrap());
        let requests: Arc<Mutex<Vec<RecordedRequest>>> = Arc::default();
        let responder: Arc<
            Mutex<Box<dyn FnMut(&RecordedRequest) -> (u16, Vec<(String, String)>, Vec<u8>) + Send>>,
        > = Arc::new(Mutex::new(Box::new(responder)));
        let (requests_clone, responder_clone) = (requests.clone(), responder.clone());
        std::thread::spawn(move || {
            for mut request in server.incoming_requests() {
                let mut body = Vec::new();
                let _ = request.as_reader().read_to_end(&mut body);
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
                let (status, headers, body) = (responder_clone.lock().unwrap())(&recorded);
                let mut response = tiny_http::Response::from_data(body).with_status_code(status);
                for (key, value) in headers {
                    response.add_header(
                        tiny_http::Header::from_bytes(key.as_bytes(), value.as_bytes()).unwrap(),
                    );
                }
                let _ = request.respond(response);
            }
        });
        Self {
            url,
            requests,
            responder,
        }
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
