//! Downloads run as host-scheduled jobs (`scheduleDownload` hook, Android WorkManager):
//! the caller waits for the job, retries resume the partial file, definitive failures
//! settle, and a job whose caller is gone (process killed) still records the bundle.

mod support;

use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use capgo_updater_core::host::MemoryHost;
use serde_json::{json, Value};
use support::{core, AbiEngine, AbiResult, FakeServer, TestEngine};

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
    // Large enough for a meaningful partial transfer.
    let filler = vec![b'x'; 64 * 1024];
    zip_of(&[
        ("index.html", format!("<html>{marker}</html>").as_bytes()),
        ("filler.txt", &filler),
    ])
}

fn scheduling(t: &TestEngine) {
    t.host.reply_to_hook("scheduleDownload", json!({ "scheduled": true }));
}

/// Waits until the engine scheduled `count` jobs; returns the id of the last one.
fn scheduled_job(host: &MemoryHost, count: usize) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let hooks = host.hooks_named("scheduleDownload");
        if hooks.len() >= count {
            return hooks[count - 1]["id"].as_str().unwrap().to_string();
        }
        assert!(Instant::now() < deadline, "no scheduleDownload hook");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn run_job(engine: &AbiEngine, id: &str) -> Value {
    engine.call("runScheduledDownload", &json!({ "id": id })).unwrap()
}

/// Calls `download` on another thread, like a plugin method lane.
fn download_async(engine: &Arc<AbiEngine>, input: Value) -> std::thread::JoinHandle<AbiResult<Value>> {
    let engine = engine.clone();
    std::thread::spawn(move || engine.call("download", &input))
}

fn job_file(root: &std::path::Path, id: &str) -> std::path::PathBuf {
    root.join("capgo_download_jobs").join(format!("{id}.json"))
}

fn record_status(t: &TestEngine, id: &str) -> String {
    t.call("bundleGet", json!({ "id": id }))["status"]
        .as_str()
        .unwrap()
        .to_string()
}

#[test]
fn caller_waits_for_the_scheduled_job() {
    let bundle = web_bundle("v2");
    let served = bundle.clone();
    let server = FakeServer::start(move |_| (200, vec![], served.clone()));
    let t = TestEngine::new(json!({}));
    scheduling(&t);
    let caller = download_async(
        &t.engine,
        json!({ "url": format!("{}/b.zip", server.url), "version": "2.0.0", "checksum": sha256(&bundle) }),
    );
    let id = scheduled_job(&t.host, 1);
    // Nothing runs until the scheduler starts the job.
    std::thread::sleep(Duration::from_millis(100));
    assert!(!caller.is_finished());
    assert!(server.requests().is_empty());
    assert_eq!(record_status(&t, &id), "downloading");
    assert!(job_file(t.root(), &id).exists());

    let reply = run_job(&t.engine, &id);
    assert_eq!(reply["result"], "success", "{reply}");
    let installed = caller.join().unwrap().unwrap();
    assert_eq!(installed["id"], id.as_str());
    assert_eq!(installed["status"], "pending");
    assert!(t.root().join("versions").join(&id).join("index.html").exists());
    assert!(!job_file(t.root(), &id).exists());
    assert_eq!(t.host.events_named("updateAvailable").len(), 1);
    assert!(t
        .host
        .events_named("download")
        .iter()
        .any(|event| event["percent"] == 100));
}

/// Serves the first request truncated (connection closed midway), then the rest on a
/// Range request. Records the Range header of every request.
fn truncating_server(body: Vec<u8>) -> (String, Arc<Mutex<Vec<Option<String>>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/b.zip", listener.local_addr().unwrap());
    let ranges: Arc<Mutex<Vec<Option<String>>>> = Arc::default();
    let seen = ranges.clone();
    std::thread::spawn(move || {
        for (index, stream) in listener.incoming().enumerate() {
            let Ok(mut stream) = stream else { continue };
            let mut request = Vec::new();
            let mut buffer = [0u8; 1024];
            while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                match stream.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(read) => request.extend_from_slice(&buffer[..read]),
                }
            }
            let text = String::from_utf8_lossy(&request).to_string();
            let range = text
                .lines()
                .find(|line| line.to_ascii_lowercase().starts_with("range:"))
                .map(|line| line[6..].trim().to_string());
            seen.lock().unwrap().push(range.clone());
            if index == 0 {
                let head = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(head.as_bytes());
                let _ = stream.write_all(&body[..body.len() / 2]);
                let _ = stream.flush();
                // Dropped midway.
                continue;
            }
            let start: usize = range
                .as_deref()
                .and_then(|range| range.strip_prefix("bytes="))
                .and_then(|range| range.trim_end_matches('-').parse().ok())
                .unwrap_or(0);
            let head = if start > 0 {
                format!(
                    "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{}/{}\r\nConnection: close\r\n\r\n",
                    body.len() - start,
                    body.len() - 1,
                    body.len()
                )
            } else {
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                )
            };
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&body[start..]);
        }
    });
    (url, ranges)
}

#[test]
fn a_dropped_transfer_is_retried_and_resumed() {
    let bundle = web_bundle("resume");
    let (url, ranges) = truncating_server(bundle.clone());
    let t = TestEngine::new(json!({}));
    scheduling(&t);
    let caller = download_async(
        &t.engine,
        json!({ "url": url, "version": "2.0.0", "checksum": sha256(&bundle) }),
    );
    let id = scheduled_job(&t.host, 1);

    let first = run_job(&t.engine, &id);
    assert_eq!(first["result"], "retry", "{first}");
    // One network attempt per run: the scheduler owns the backoff.
    assert_eq!(ranges.lock().unwrap().len(), 1);
    assert!(!caller.is_finished());
    assert_eq!(record_status(&t, &id), "downloading");
    assert!(t.root().join(format!("temp_{id}.tmp")).exists());

    let second = run_job(&t.engine, &id);
    assert_eq!(second["result"], "success", "{second}");
    let installed = caller.join().unwrap().unwrap();
    assert_eq!(installed["status"], "pending");
    let ranges = ranges.lock().unwrap().clone();
    assert_eq!(ranges.len(), 2);
    assert_eq!(ranges[0], None);
    assert_eq!(ranges[1], Some(format!("bytes={}-", bundle.len() / 2)));
    assert!(!t.root().join(format!("temp_{id}.tmp")).exists());
}

#[test]
fn a_checksum_mismatch_fails_the_job() {
    let bundle = web_bundle("bad");
    let served = bundle.clone();
    let server = FakeServer::start(move |_| (200, vec![], served.clone()));
    let t = TestEngine::new(json!({}));
    scheduling(&t);
    let caller = download_async(
        &t.engine,
        json!({ "url": format!("{}/b.zip", server.url), "version": "2.0.0", "checksum": sha256(b"other") }),
    );
    let id = scheduled_job(&t.host, 1);
    let reply = run_job(&t.engine, &id);
    assert_eq!(reply["result"], "failure", "{reply}");
    assert_eq!(reply["error"]["code"], "checksum_fail");
    let error = caller.join().unwrap().unwrap_err();
    assert_eq!(error.code, "checksum_fail");
    assert_eq!(record_status(&t, &id), "error");
    assert_eq!(t.host.events_named("downloadFailed").len(), 1);
    assert!(!job_file(t.root(), &id).exists());
    let leftovers: Vec<String> = std::fs::read_dir(t.root())
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with("temp_") || name.starts_with("update_"))
        .collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");
}

/// A local file error (the partial cannot be written) is no network error: the job fails
/// instead of being retried by the scheduler forever.
#[test]
fn local_file_errors_fail_the_job() {
    let bundle = web_bundle("local");
    let served = bundle.clone();
    let server = FakeServer::start(move |_| (200, vec![], served.clone()));
    let content = b"<html>local</html>".to_vec();
    let file_content = content.clone();
    let files = FakeServer::start(move |_| (200, vec![], file_content.clone()));
    let t = TestEngine::new(json!({}));
    scheduling(&t);

    let caller = download_async(
        &t.engine,
        json!({ "url": format!("{}/b.zip", server.url), "version": "2.0.0", "checksum": sha256(&bundle) }),
    );
    let id = scheduled_job(&t.host, 1);
    // A directory where the partial file goes: opening it fails, as root too.
    std::fs::create_dir_all(t.root().join(format!("temp_{id}.tmp"))).unwrap();
    let reply = run_job(&t.engine, &id);
    assert_eq!(reply["result"], "failure", "{reply}");
    assert_eq!(caller.join().unwrap().unwrap_err().code, "io_error");

    let manifest = json!([{
        "file_name": "index.html",
        "file_hash": sha256(&content),
        "download_url": format!("{}/files/index.html", files.url),
    }]);
    let partial = core().test(
        "manifestPartialName",
        json!({ "hash": sha256(&content), "fileName": "index.html" }),
    )["name"]
        .as_str()
        .unwrap()
        .to_string();
    std::fs::create_dir_all(t.root().join("cache/capgo_downloads").join(partial)).unwrap();
    let caller = download_async(&t.engine, json!({ "version": "3.0.0", "manifest": manifest }));
    let id = scheduled_job(&t.host, 2);
    let reply = run_job(&t.engine, &id);
    assert_eq!(reply["result"], "failure", "{reply}");
    assert!(caller.join().unwrap().is_err());
}

#[test]
fn not_found_is_definitive_and_server_errors_retry() {
    let calls = Arc::new(Mutex::new(0));
    let bundle = web_bundle("5xx");
    let (served, counter) = (bundle.clone(), calls.clone());
    let server = FakeServer::start(move |_| {
        let mut calls = counter.lock().unwrap();
        *calls += 1;
        match *calls {
            1 => (503, vec![], vec![]),
            _ => (200, vec![], served.clone()),
        }
    });
    let t = TestEngine::new(json!({}));
    scheduling(&t);
    let caller = download_async(
        &t.engine,
        json!({ "url": format!("{}/b.zip", server.url), "version": "2.0.0", "checksum": sha256(&bundle) }),
    );
    let id = scheduled_job(&t.host, 1);
    assert_eq!(run_job(&t.engine, &id)["result"], "retry");
    assert_eq!(run_job(&t.engine, &id)["result"], "success");
    caller.join().unwrap().unwrap();

    let missing = FakeServer::start(|_| (404, vec![], vec![]));
    let caller = download_async(
        &t.engine,
        json!({ "url": format!("{}/b.zip", missing.url), "version": "3.0.0", "checksum": "abc" }),
    );
    let id = scheduled_job(&t.host, 2);
    let reply = run_job(&t.engine, &id);
    assert_eq!(reply["result"], "failure", "{reply}");
    assert_eq!(caller.join().unwrap().unwrap_err().code, "http_error");
}

#[test]
fn manifest_jobs_retry_then_install() {
    let content = b"<html>manifest</html>".to_vec();
    let calls = Arc::new(Mutex::new(0));
    let (served, counter) = (content.clone(), calls.clone());
    let server = FakeServer::start(move |_| {
        let mut calls = counter.lock().unwrap();
        *calls += 1;
        if *calls == 1 {
            (502, vec![], vec![])
        } else {
            (200, vec![], served.clone())
        }
    });
    let t = TestEngine::new(json!({}));
    scheduling(&t);
    let manifest = json!([{
        "file_name": "index.html",
        "file_hash": sha256(&content),
        "download_url": format!("{}/files/index.html", server.url),
    }]);
    let caller = download_async(&t.engine, json!({ "version": "2.0.0", "manifest": manifest }));
    let id = scheduled_job(&t.host, 1);
    assert_eq!(run_job(&t.engine, &id)["result"], "retry");
    assert_eq!(run_job(&t.engine, &id)["result"], "success");
    let installed = caller.join().unwrap().unwrap();
    assert_eq!(installed["status"], "pending");
    let dir = t.root().join("versions").join(&id);
    assert_eq!(std::fs::read(dir.join("index.html")).unwrap(), content);
}

/// The launch cleanup keeps the partial files of a pending manifest job (named by file, not
/// job) so its next attempt resumes them; once no manifest job is pending they go.
#[test]
fn launch_cleanup_keeps_partials_of_pending_manifest_jobs() {
    let t = TestEngine::new(json!({}));
    scheduling(&t);
    let content = b"<html>partial</html>".to_vec();
    let manifest = json!([{
        "file_name": "index.html",
        "file_hash": sha256(&content),
        "download_url": "http://127.0.0.1:9/files/index.html",
    }]);
    let caller = download_async(&t.engine, json!({ "version": "2.0.0", "manifest": manifest }));
    let id = scheduled_job(&t.host, 1);
    let two_hours_ago = std::time::SystemTime::now() - Duration::from_secs(7200);
    let old_file = |name: &str| {
        let path = t.root().join(name);
        std::fs::write(&path, b"part").unwrap();
        std::fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_modified(two_hours_ago)
            .unwrap();
        path
    };
    let partial = old_file(&format!("partial_{}_abcdef.tmp", sha256(&content)));
    let leftover = old_file("temp_other.tmp");
    t.call("test.cleanupDownloadTempFiles", json!({}));
    assert!(partial.exists(), "kept for the pending manifest job");
    assert!(!leftover.exists());

    t.call("bundleDelete", json!({ "id": id }));
    let _ = caller.join().unwrap();
    t.call("test.cleanupDownloadTempFiles", json!({}));
    assert!(!partial.exists(), "no manifest job pending");
}

#[test]
fn deleting_the_bundle_cancels_its_job() {
    let t = TestEngine::new(json!({}));
    scheduling(&t);
    let caller = download_async(
        &t.engine,
        json!({ "url": "http://127.0.0.1:9/b.zip", "version": "2.0.0", "checksum": "abc" }),
    );
    let id = scheduled_job(&t.host, 1);
    assert_eq!(t.call("bundleDelete", json!({ "id": id }))["deleted"], true);
    assert_eq!(caller.join().unwrap().unwrap_err().code, "download_stopped");
    assert!(!job_file(t.root(), &id).exists());
    // The deleted record stays deleted.
    assert!(t
        .call("bundleList", json!({ "raw": true }))
        .as_array()
        .unwrap()
        .is_empty());
    // A job the scheduler still runs finds nothing to do.
    assert_eq!(run_job(&t.engine, &id)["result"], "failure");
}

/// The process died: the job runs later on an engine created for it alone (no plugin,
/// no waiting caller) and records the bundle like a normal download.
#[test]
fn a_job_without_its_caller_records_the_bundle() {
    let bundle = web_bundle("cold");
    let served = bundle.clone();
    let server = FakeServer::start(move |_| (200, vec![], served.clone()));
    let t = TestEngine::new(json!({ "statsUrl": "" }));
    scheduling(&t);
    let caller = download_async(
        &t.engine,
        json!({ "url": format!("{}/b.zip", server.url), "version": "2.0.0", "checksum": sha256(&bundle), "emitEvents": false }),
    );
    let id = scheduled_job(&t.host, 1);
    // The plugin goes away: its caller stops waiting, the job stays.
    t.call("detachScheduledDownloads", json!({}));
    assert_eq!(caller.join().unwrap().unwrap_err().code, "download_detached");
    assert_eq!(record_status(&t, &id), "downloading");
    assert!(job_file(t.root(), &id).exists());

    // Same storage (preferences and files), fresh engine, as a worker in a new process.
    let cold = AbiEngine::new(
        t.host.clone(),
        &json!({
            "platform": "android",
            "bundleRoot": t.root().join("versions").to_string_lossy(),
            "storageRoot": t.root().to_string_lossy(),
            "cacheDir": t.root().join("cache/capgo_downloads").to_string_lossy(),
        }),
    )
    .unwrap();
    let reply = run_job(&cold, &id);
    assert_eq!(reply["result"], "success", "{reply}");
    let recorded = t.call("bundleGet", json!({ "id": id }));
    assert_eq!(recorded["status"], "pending");
    assert_eq!(recorded["version"], "2.0.0");
    assert_eq!(recorded["checksum"], sha256(&bundle).as_str());
    assert!(t.root().join("versions").join(&id).join("index.html").exists());
    assert!(!job_file(t.root(), &id).exists());
    // The job settings came with it (identity used by the stats it sends).
    assert_eq!(
        cold.call("config", &json!({})).unwrap()["userAgent"],
        t.call("config", json!({}))["userAgent"]
    );
}

#[test]
fn hosts_that_do_not_schedule_download_in_process() {
    let bundle = web_bundle("inline");
    let served = bundle.clone();
    let server = FakeServer::start(move |_| (200, vec![], served.clone()));
    let t = TestEngine::new(json!({}));
    let installed = t.call(
        "download",
        json!({ "url": format!("{}/b.zip", server.url), "version": "2.0.0", "checksum": sha256(&bundle) }),
    );
    assert_eq!(installed["status"], "pending");
    // The hook was offered and declined: no job left behind.
    assert_eq!(t.host.hooks_named("scheduleDownload").len(), 1);
    assert!(!t
        .root()
        .join("capgo_download_jobs")
        .read_dir()
        .is_ok_and(|mut dir| dir.next().is_some()));
}
