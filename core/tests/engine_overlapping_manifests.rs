//! Regression: two manifest downloads running at the same time that share a file
//! (same name and hash) used the same partial file, so one moved or deleted it
//! under the other. Own binary: a raw server that sends the shared file slowly.

mod support;

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use support::TestEngine;

fn sha256(bytes: &[u8]) -> String {
    capgo_updater_core::crypto::checksum::sha256_hex(bytes)
}

type Files = Arc<Mutex<HashMap<String, Vec<u8>>>>;
type Hits = Arc<Mutex<HashMap<String, usize>>>;

/// Thread-per-connection HTTP/1.1 server; bodies are sent in two halves 300 ms apart.
fn serve(files: Files, hits: Hits) -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let (files, hits) = (files.clone(), hits.clone());
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut request_line = String::new();
                reader.read_line(&mut request_line).unwrap();
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                        break;
                    }
                }
                let path = request_line.split_whitespace().nth(1).unwrap_or("/").to_string();
                *hits.lock().unwrap().entry(path.clone()).or_default() += 1;
                let body = files.lock().unwrap().get(&path).cloned();
                let (status, body) = match body {
                    Some(body) => ("200 OK", body),
                    None => ("404 Not Found", Vec::new()),
                };
                let head = format!(
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(head.as_bytes());
                let (first, rest) = body.split_at(body.len() / 2);
                let _ = stream.write_all(first);
                let _ = stream.flush();
                std::thread::sleep(Duration::from_millis(300));
                let _ = stream.write_all(rest);
                let _ = stream.flush();
            });
        }
    });
    url
}

fn overlapping_downloads(extra: Value) -> (usize, usize) {
    let files: Files = Arc::default();
    let hits: Hits = Arc::default();
    let url = serve(files.clone(), hits.clone());
    let shared: Vec<u8> = (0..(1 << 20)).map(|index: u32| (index * 31 % 251) as u8).collect();
    files.lock().unwrap().insert("/shared.js".into(), shared.clone());
    let manifest = |version: &str| {
        let own = format!("console.log('{version}')").into_bytes();
        files.lock().unwrap().insert(format!("/{version}.js"), own.clone());
        json!([
            { "file_name": "js/shared.js", "file_hash": sha256(&shared), "download_url": format!("{url}/shared.js") },
            { "file_name": format!("js/{version}.js"), "file_hash": sha256(&own), "download_url": format!("{url}/{version}.js") },
        ])
    };
    let (first, second) = (manifest("2"), manifest("3"));
    let t = TestEngine::new(extra);
    let installed: Vec<Value> = std::thread::scope(|scope| {
        let a = scope.spawn(|| t.call("download", json!({ "version": "2", "manifest": first })));
        let b = scope.spawn(|| t.call("download", json!({ "version": "3", "manifest": second })));
        vec![a.join().unwrap(), b.join().unwrap()]
    });
    for bundle in &installed {
        let dir = t.root().join("versions").join(bundle["id"].as_str().unwrap());
        assert_eq!(std::fs::read(dir.join("js/shared.js")).unwrap(), shared, "{bundle}");
    }
    let hits = hits.lock().unwrap();
    (installed.len(), hits.get("/shared.js").copied().unwrap_or(0))
}

#[test]
fn overlapping_downloads_sharing_a_file_both_install() {
    let (installed, fetched) = overlapping_downloads(json!({}));
    assert_eq!(installed, 2);
    // The second transfer waits, then reuses the delta-cache copy of the first.
    assert_eq!(fetched, 1);
}

#[test]
fn overlapping_downloads_without_a_cache_both_install() {
    let (installed, fetched) = overlapping_downloads(json!({ "cacheDir": "" }));
    assert_eq!(installed, 2);
    assert_eq!(fetched, 2);
}

/// New connections open gradually: 16 requests at first, one more worker per
/// finished file up to the full pool.
#[test]
fn manifest_workers_ramp_up() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let started = std::time::Instant::now();
    let arrivals: Arc<Mutex<Vec<Duration>>> = Arc::default();
    let active = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let peak = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    {
        let (arrivals, active, peak) = (arrivals.clone(), active.clone(), peak.clone());
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let (arrivals, active, peak) = (arrivals.clone(), active.clone(), peak.clone());
                std::thread::spawn(move || {
                    use std::sync::atomic::Ordering::SeqCst;
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut request_line = String::new();
                    reader.read_line(&mut request_line).unwrap();
                    loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                            break;
                        }
                    }
                    arrivals.lock().unwrap().push(started.elapsed());
                    let now = active.fetch_add(1, SeqCst) + 1;
                    peak.fetch_max(now, SeqCst);
                    std::thread::sleep(Duration::from_millis(150));
                    let path = request_line.split_whitespace().nth(1).unwrap_or("/");
                    let body = path.as_bytes();
                    let head = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    active.fetch_sub(1, SeqCst);
                    let _ = stream.write_all(head.as_bytes());
                    let _ = stream.write_all(body);
                    let _ = stream.flush();
                });
            }
        });
    }
    let manifest: Vec<Value> = (0..120)
        .map(|index| {
            let path = format!("/f{index}.js");
            json!({ "file_name": format!("js/f{index}.js"), "file_hash": sha256(path.as_bytes()), "download_url": format!("{url}{path}") })
        })
        .collect();
    let t = TestEngine::new(json!({}));
    t.call("download", json!({ "version": "2", "manifest": manifest }));
    let arrivals = arrivals.lock().unwrap();
    assert_eq!(arrivals.len(), 120);
    let first = arrivals[0];
    let in_first_wave = arrivals
        .iter()
        .filter(|at| **at < first + Duration::from_millis(100))
        .count();
    assert!(in_first_wave <= 16, "{in_first_wave} requests before any file finished");
    assert!(
        peak.load(std::sync::atomic::Ordering::SeqCst) > 16,
        "the pool grows past the first wave"
    );
}
