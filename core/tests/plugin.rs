//! Plugin layer scenarios: the update cycle, direct updates, rollback, delays,
//! channels and previews, driven like the Capacitor hosts drive the engine.

mod support;

use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use capgo_updater_core::host::Host;
use serde_json::{json, Value};
use support::{FakeServer, TestEngine};

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
    zip_of(&[("index.html", format!("<html>{marker}</html>").as_bytes())])
}

/// Update server: `/updates` answers `latest`, `/b.zip` serves `bundle`, `/stats` and `/channel_self` accept.
struct Backend {
    server: FakeServer,
    latest: Arc<Mutex<Value>>,
    bundle: Arc<Mutex<Vec<u8>>>,
    channel_reply: Arc<Mutex<(u16, Value)>>,
}

impl Backend {
    fn start() -> Self {
        let latest = Arc::new(Mutex::new(
            json!({ "error": "no_new_version_available", "kind": "up_to_date" }),
        ));
        let bundle = Arc::new(Mutex::new(Vec::new()));
        let channel_reply = Arc::new(Mutex::new((200, json!({ "status": "ok" }))));
        let (l, b, c) = (latest.clone(), bundle.clone(), channel_reply.clone());
        let server = FakeServer::start(move |request| {
            let path = request.url.split('?').next().unwrap_or_default().to_string();
            match path.as_str() {
                "/updates" => FakeServer::json(200, l.lock().unwrap().clone()),
                "/b.zip" => {
                    let body = b.lock().unwrap().clone();
                    // Resumed transfers (`Range: bytes=N-`) get the rest of the bundle.
                    let start = request
                        .header("Range")
                        .and_then(|range| range.strip_prefix("bytes=")?.strip_suffix('-')?.parse::<usize>().ok())
                        .filter(|start| *start < body.len());
                    match start {
                        Some(start) => (
                            206,
                            vec![(
                                "Content-Range".into(),
                                format!("bytes {start}-{}/{}", body.len() - 1, body.len()),
                            )],
                            body[start..].to_vec(),
                        ),
                        None => (200, vec![], body),
                    }
                }
                "/channel_self" => {
                    let (status, body) = c.lock().unwrap().clone();
                    FakeServer::json(status, body)
                }
                _ => (200, vec![], b"{}".to_vec()),
            }
        });
        Self {
            server,
            latest,
            bundle,
            channel_reply,
        }
    }

    fn offer(&self, version: &str, bundle: Vec<u8>) {
        *self.latest.lock().unwrap() = json!({
            "version": version,
            "url": format!("{}/b.zip", self.server.url),
            "checksum": sha256(&bundle),
        });
        *self.bundle.lock().unwrap() = bundle;
    }
}

struct Plugin {
    t: TestEngine,
    backend: Backend,
}

impl Plugin {
    fn load(config: Value) -> Self {
        Self::load_with(config, json!({}))
    }

    fn load_with(config: Value, native: Value) -> Self {
        let backend = Backend::start();
        let t = TestEngine::new(json!({ "platform": "ios", "builtinServerPath": "" }));
        t.host.reply_to_hook("applyBundle", json!({ "ok": true }));
        t.host.reply_to_hook("previewNotice", json!({ "shown": true }));
        let mut config = config;
        let object = config.as_object_mut().unwrap();
        object
            .entry("updateUrl")
            .or_insert(json!(format!("{}/updates", backend.server.url)));
        object
            .entry("statsUrl")
            .or_insert(json!(format!("{}/stats", backend.server.url)));
        object
            .entry("channelUrl")
            .or_insert(json!(format!("{}/channel_self", backend.server.url)));
        object.entry("appReadyTimeout").or_insert(json!(1000));
        let mut native_info = json!({
            "versionName": "1.0.0",
            "versionCode": "10",
            "noBackupDir": t.root().join("nobackup").to_string_lossy(),
            // Tests use short readiness windows; the 30 s pending-bundle minimum has its own test.
            "pendingBundleMinAppReadyTimeoutMs": 0,
        });
        for (key, value) in native.as_object().unwrap() {
            native_info[key] = value.clone();
        }
        t.call("pluginLoad", json!({ "config": config, "native": native_info }));
        // The launch cleanup sweeps unknown bundle folders: let it finish before tests add some.
        t.engine.wait_for_cleanup_for_tests();
        let plugin = Self { t, backend };
        // The initial page is ready.
        plugin.resolve("notifyAppReady", json!({}));
        plugin
    }

    /// Makes `id` current and confirmed (as if its page called notifyAppReady).
    fn use_bundle(&self, id: &str, version: &str) {
        self.t.install_bundle(id, version, "success");
        self.t.call("bundleSet", json!({ "id": id }));
        self.resolve("notifyAppReady", json!({ "loadGeneration": self.last_generation() }));
    }

    fn last_generation(&self) -> i64 {
        self.t
            .host
            .hooks_named("applyBundle")
            .last()
            .map_or(0, |hook| hook["readyGeneration"].as_i64().unwrap())
    }

    fn method(&self, name: &str, args: Value) -> Value {
        self.t.call("pluginMethod", json!({ "name": name, "args": args }))
    }

    fn resolve(&self, name: &str, args: Value) -> Value {
        let result = self.method(name, args);
        assert!(result.get("resolve").is_some(), "{name} rejected: {result}");
        result["resolve"].clone()
    }

    fn reject(&self, name: &str, args: Value) -> Value {
        let result = self.method(name, args);
        assert!(result.get("reject").is_some(), "{name} resolved: {result}");
        result["reject"].clone()
    }

    fn events(&self, name: &str) -> Vec<Value> {
        self.t.host.events_named(name)
    }

    fn wait_for_event(&self, name: &str, count: usize) -> Vec<Value> {
        let deadline = Instant::now() + Duration::from_secs(8);
        loop {
            let events = self.events(name);
            if events.len() >= count {
                return events;
            }
            assert!(Instant::now() < deadline, "timed out waiting for {name}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn foreground(&self) {
        self.t.call("appForeground", json!({}));
    }

    fn background(&self) {
        self.t.call("appBackground", json!({}));
    }

    fn current(&self) -> Value {
        self.resolve("current", json!({}))["bundle"].clone()
    }

    fn stats_actions(&self) -> Vec<String> {
        // Stats reach the fake server in batches: wait until the queue is drained.
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            self.t.engine.flush_stats();
            if self.t.engine.pending_stats_count() == 0 || Instant::now() > deadline {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        std::thread::sleep(Duration::from_millis(50));
        self.backend
            .server
            .requests()
            .iter()
            .filter(|request| request.url.starts_with("/stats"))
            .flat_map(|request| {
                let body = request.json();
                let events = match body {
                    Value::Array(events) => events,
                    other => vec![other],
                };
                events
                    .into_iter()
                    .filter_map(|event| event["action"].as_str().map(str::to_string))
                    .collect::<Vec<_>>()
            })
            .collect()
    }
}

// ---- config and methods -------------------------------------------------------------------------

#[test]
fn load_reports_launch_and_resolves_basic_methods() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    assert_eq!(p.resolve("getBuiltinVersion", json!({}))["version"], "1.0.0");
    assert_eq!(p.resolve("current", json!({}))["native"], "1.0.0");
    assert_eq!(p.resolve("current", json!({}))["bundle"]["id"], "builtin");
    assert_eq!(p.resolve("isAutoUpdateEnabled", json!({}))["enabled"], false);
    assert_eq!(p.resolve("getNextBundle", json!({})), Value::Null);
    assert_eq!(p.resolve("getFailedUpdate", json!({})), Value::Null);
    assert!(p.stats_actions().contains(&"app_launch_start".to_string()));
    // First run snapshots native versions without an event.
    assert_eq!(p.t.kv("CapacitorUpdater.lastVersionCode").unwrap(), "10");
}

#[test]
fn url_and_app_id_setters_are_gated() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    assert!(p.reject("setUpdateUrl", json!({ "url": "https://x" }))["message"]
        .as_str()
        .unwrap()
        .contains("allowModifyUrl"));
    assert!(p.reject("setAppId", json!({ "appId": "x" }))["message"]
        .as_str()
        .unwrap()
        .contains("allowModifyAppId"));
    let p = Plugin::load(
        json!({ "autoUpdate": false, "allowModifyUrl": true, "persistModifyUrl": true, "allowModifyAppId": true }),
    );
    p.resolve("setStatsUrl", json!({ "url": "https://stats.example.com" }));
    assert_eq!(
        p.t.kv("CapacitorUpdater.statsUrl").unwrap(),
        "https://stats.example.com"
    );
    assert_eq!(
        p.reject("setChannelUrl", json!({}))["message"],
        "setChannelUrl called without url"
    );
    p.resolve("setAppId", json!({ "appId": "com.other" }));
    assert_eq!(p.resolve("getAppId", json!({}))["appId"], "com.other");
}

#[test]
fn url_setters_change_the_live_endpoints() {
    let p = Plugin::load(json!({ "autoUpdate": false, "allowModifyUrl": true }));
    let url = &p.backend.server.url;
    p.resolve("setUpdateUrl", json!({ "url": format!("{url}/updates2") }));
    p.resolve("setChannelUrl", json!({ "url": format!("{url}/channel2") }));
    p.resolve("setStatsUrl", json!({ "url": format!("{url}/stats2") }));
    p.method("getLatest", json!({}));
    p.method("getChannel", json!({}));
    p.t.call("statsSend", json!({ "action": "set" }));
    p.t.engine.flush_stats();
    wait_until("requests to the new urls", || {
        let paths: Vec<String> = p.backend.server.requests().iter().map(|r| r.url.clone()).collect();
        ["/updates2", "/channel2", "/stats2"]
            .iter()
            .all(|path| paths.iter().any(|url| url.starts_with(path)))
    });
}

/// The engine `download` operation waits for the launch cleanup like the plugin paths.
#[test]
fn download_operation_waits_for_the_launch_cleanup() {
    let backend = Backend::start();
    let bundle = web_bundle("v2");
    backend.offer("2.0.0", bundle.clone());
    let t = TestEngine::new(json!({ "platform": "ios", "builtinServerPath": "" }));
    t.host.reply_to_hook("applyBundle", json!({ "ok": true }));
    // A native update with resetWhenUpdate: the cleanup deletes every bundle, 75 ms apart.
    for index in 0..20 {
        t.install_bundle(&format!("bundle{index:04}"), &format!("1.0.{index}"), "success");
    }
    t.host
        .store
        .lock()
        .unwrap()
        .insert("LatestNativeBuildVersion".into(), "9".into());
    let config = json!({ "autoUpdate": false, "updateUrl": format!("{}/updates", backend.server.url) });
    let native = json!({ "versionName": "1.0.0", "versionCode": "10", "noBackupDir": t.root().join("nobackup").to_string_lossy() });
    t.call("pluginLoad", json!({ "config": config, "native": native }));
    t.call(
        "download",
        json!({ "url": format!("{}/b.zip", backend.server.url), "version": "2.0.0", "checksum": sha256(&bundle) }),
    );
    let logs: Vec<String> = t
        .host
        .logs
        .lock()
        .unwrap()
        .iter()
        .map(|(_, message)| message.clone())
        .collect();
    let cleaned = logs.iter().position(|message| message == "Cleanup complete");
    let proceeded = logs
        .iter()
        .position(|message| message == "Cleanup finished, proceeding with download");
    assert!(cleaned.is_some() && proceeded > cleaned, "{logs:?}");
}

#[test]
fn custom_id_persists_only_when_configured() {
    let p = Plugin::load(json!({ "autoUpdate": false, "persistCustomId": true }));
    p.resolve("setCustomId", json!({ "customId": "user-1" }));
    assert_eq!(p.t.kv("CapacitorUpdater.customId").unwrap(), "user-1");
    p.resolve("setCustomId", json!({ "customId": "" }));
    assert!(p.t.kv("CapacitorUpdater.customId").is_none());
}

#[test]
fn set_bundle_error_rules() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    assert!(p.reject("setBundleError", json!({ "id": "x" }))["message"]
        .as_str()
        .unwrap()
        .contains("allowManualBundleError"));
    let p = Plugin::load(json!({ "autoUpdate": false, "allowManualBundleError": true }));
    assert_eq!(
        p.reject("setBundleError", json!({ "id": "builtin" }))["message"],
        "Cannot set builtin bundle to error state"
    );
    assert_eq!(
        p.reject("setBundleError", json!({ "id": "nope000000" }))["message"],
        "Bundle nope000000 does not exist"
    );
    p.t.install_bundle("abcdefghij", "2.0.0", "success");
    assert_eq!(
        p.resolve("setBundleError", json!({ "id": "abcdefghij" }))["bundle"]["status"],
        "error"
    );
}

// ---- update cycle -------------------------------------------------------------------------------

#[test]
fn background_mode_downloads_then_installs_at_background() {
    let p = Plugin::load(json!({}));
    p.backend.offer("2.0.0", web_bundle("v2"));
    p.foreground();
    let ready = p.wait_for_event("appReady", 1);
    assert_eq!(ready[0]["status"], "update downloaded, will install next background");
    let available = p.events("updateAvailable");
    assert_eq!(available[0]["bundle"]["version"], "2.0.0");
    // Only onlyDownload checks keep updateAvailable for late listeners.
    assert_eq!(p.t.host.retained_count("updateAvailable"), 0);
    assert_eq!(p.t.host.retained_count("appReady"), p.events("appReady").len());
    let next = p.resolve("getNextBundle", json!({}));
    assert_eq!(next["version"], "2.0.0");
    assert!(p.events("download").iter().any(|event| event["percent"] == 100));

    p.background();
    let set = p.wait_for_event("set", 1);
    assert_eq!(set[0]["bundle"]["version"], "2.0.0");
    assert_eq!(p.t.host.retained_count("set"), 1);
    assert_eq!(p.current()["version"], "2.0.0");
    assert_eq!(p.resolve("getNextBundle", json!({})), Value::Null);
    let applied = p.t.host.hooks_named("applyBundle");
    assert!(applied.last().unwrap()["path"]
        .as_str()
        .unwrap()
        .contains(next["id"].as_str().unwrap()));
}

#[test]
fn always_mode_installs_right_away() {
    let p = Plugin::load(json!({ "autoUpdate": "always" }));
    p.backend.offer("2.0.0", web_bundle("v2"));
    p.foreground();
    assert_eq!(p.wait_for_event("set", 1)[0]["bundle"]["version"], "2.0.0");
    // The new page confirms itself; appReady is emitted after that.
    p.resolve("notifyAppReady", json!({ "loadGeneration": p.last_generation() }));
    let ready = p.wait_for_event("appReady", 1);
    assert_eq!(ready[0]["status"], "update installed");
    assert_eq!(p.current()["version"], "2.0.0");
    assert_eq!(p.current()["status"], "success");
}

#[test]
fn only_download_mode_never_schedules() {
    let p = Plugin::load(json!({ "autoUpdate": "onlyDownload" }));
    p.backend.offer("2.0.0", web_bundle("v2"));
    p.foreground();
    let ready = p.wait_for_event("appReady", 1);
    assert_eq!(ready[0]["status"], "update downloaded, autoUpdate onlyDownload");
    assert_eq!(p.events("updateAvailable").len(), 1);
    assert_eq!(p.t.host.retained_count("updateAvailable"), 1);
    assert_eq!(p.resolve("getNextBundle", json!({})), Value::Null);
    assert!(p.events("noNeedUpdate").is_empty());
}

// ---- scheduled downloads (Android WorkManager) ---------------------------------------------------

impl Plugin {
    /// The host runs downloads as scheduled jobs (`scheduleDownload` answered).
    fn schedule_downloads(&self) {
        self.t
            .host
            .reply_to_hook("scheduleDownload", json!({ "scheduled": true }));
    }

    fn scheduled_job(&self, count: usize) -> String {
        let deadline = Instant::now() + Duration::from_secs(8);
        loop {
            let hooks = self.t.host.hooks_named("scheduleDownload");
            if hooks.len() >= count {
                return hooks[count - 1]["id"].as_str().unwrap().to_string();
            }
            assert!(Instant::now() < deadline, "no scheduleDownload hook");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    fn run_job(&self, id: &str) -> Value {
        self.t.call("runScheduledDownload", json!({ "id": id }))
    }

    /// A new process: same preferences and files, new engine and plugin load.
    fn relaunch(&self) -> Arc<capgo_updater_core::engine::Engine> {
        let root = self.t.root();
        let engine = capgo_updater_core::engine::Engine::new(
            self.t.host.clone(),
            &json!({
                "platform": "ios",
                "appId": "app.capgo.test",
                "pluginVersion": "8.0.0",
                "versionBuild": "1.0.0",
                "versionCode": "10",
                "versionOs": "14",
                "deviceId": "device-1",
                "builtinServerPath": "",
                "bundleRoot": root.join("versions").to_string_lossy(),
                "storageRoot": root.to_string_lossy(),
                "cacheDir": root.join("cache/capgo_downloads").to_string_lossy(),
            }),
        )
        .unwrap();
        let url = &self.backend.server.url;
        engine
            .call(
                "pluginLoad",
                &json!({
                    "config": {
                        "updateUrl": format!("{url}/updates"),
                        "statsUrl": format!("{url}/stats"),
                        "channelUrl": format!("{url}/channel_self"),
                        "appReadyTimeout": 1000,
                    },
                    "native": { "versionName": "1.0.0", "versionCode": "10", "noBackupDir": root.join("nobackup").to_string_lossy() },
                }),
            )
            .unwrap();
        engine.wait_for_cleanup_for_tests();
        engine
    }

    /// Points the stored job of `id` at another bundle URL (the server comes back elsewhere).
    fn retarget_job(&self, id: &str, url: &str) {
        let path = self.t.root().join("capgo_download_jobs").join(format!("{id}.json"));
        let mut job: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        job["request"]["url"] = json!(url);
        std::fs::write(&path, job.to_string()).unwrap();
    }
}

#[test]
fn scheduled_cycle_download_finishes_the_cycle_like_an_in_process_one() {
    let p = Plugin::load(json!({}));
    p.schedule_downloads();
    p.backend.offer("2.0.0", web_bundle("v2"));
    p.foreground();
    let id = p.scheduled_job(1);
    std::thread::sleep(Duration::from_millis(100));
    // The cycle waits for the job (offline: as long as it takes).
    assert!(p.events("appReady").is_empty());
    assert_eq!(p.resolve("triggerUpdateCheck", json!({}))["status"], "already_running");
    assert_eq!(p.run_job(&id)["result"], "success");
    let ready = p.wait_for_event("appReady", 1);
    assert_eq!(ready[0]["status"], "update downloaded, will install next background");
    assert_eq!(p.events("updateAvailable")[0]["bundle"]["version"], "2.0.0");
    assert_eq!(p.resolve("getNextBundle", json!({}))["id"], id.as_str());
}

#[test]
fn manual_download_resolves_when_its_job_succeeds() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.schedule_downloads();
    let bundle = web_bundle("manual");
    p.backend.offer("2.0.0", bundle.clone());
    let engine = p.t.engine.clone();
    let args =
        json!({ "url": format!("{}/b.zip", p.backend.server.url), "version": "2.0.0", "checksum": sha256(&bundle) });
    let call = std::thread::spawn(move || {
        engine
            .call("pluginMethod", &json!({ "name": "download", "args": args }))
            .unwrap()
    });
    let id = p.scheduled_job(1);
    std::thread::sleep(Duration::from_millis(100));
    assert!(!call.is_finished(), "download() stays pending until the job ends");
    assert_eq!(p.run_job(&id)["result"], "success");
    let result = call.join().unwrap();
    assert_eq!(result["resolve"]["version"], "2.0.0");
    assert_eq!(result["resolve"]["status"], "pending");
    assert_eq!(p.events("updateAvailable").len(), 1);
}

#[test]
fn retrying_scheduled_download_releases_a_direct_update_launch() {
    let p = Plugin::load(json!({ "autoUpdate": "always" }));
    p.schedule_downloads();
    p.backend.offer("2.0.0", web_bundle("v2"));
    let online = format!("{}/b.zip", p.backend.server.url);
    // Offline: nothing listens there.
    p.backend.latest.lock().unwrap()["url"] = json!("http://127.0.0.1:9/b.zip");
    p.foreground();
    let id = p.scheduled_job(1);
    assert_eq!(p.run_job(&id)["result"], "retry");
    let ready = p.wait_for_event("appReady", 1);
    assert_eq!(
        ready[0]["status"],
        "Direct update download is retrying, continuing launch on the current bundle"
    );
    // The network is back: the bundle waits for the next background instead of reloading now.
    p.retarget_job(&id, &online);
    assert_eq!(p.run_job(&id)["result"], "success");
    let deadline = Instant::now() + Duration::from_secs(8);
    while p.resolve("getNextBundle", json!({})).is_null() {
        assert!(Instant::now() < deadline, "bundle not queued");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(p.resolve("getNextBundle", json!({}))["id"], id.as_str());
    std::thread::sleep(Duration::from_millis(100));
    assert!(p.events("set").is_empty());
    assert_eq!(p.events("appReady").len(), 1);
    assert_eq!(p.current()["id"], "builtin");
}

/// The scheduler stops a running attempt (network lost): like a failed attempt, the direct
/// update stops holding the launch while the job waits to run again.
#[test]
fn a_stopped_scheduled_download_releases_a_direct_update_launch() {
    use std::io::{Read, Write as _};
    let p = Plugin::load(json!({ "autoUpdate": "always" }));
    p.schedule_downloads();
    p.backend.offer("2.0.0", web_bundle("v2"));
    // A transfer that never ends: headers, then a byte every 20 ms.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let slow = format!("http://{}/b.zip", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            std::thread::spawn(move || {
                let mut buffer = [0u8; 1024];
                let _ = stream.read(&mut buffer);
                let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\n");
                while stream.write_all(b"x").and_then(|()| stream.flush()).is_ok() {
                    std::thread::sleep(Duration::from_millis(20));
                }
            });
        }
    });
    p.backend.latest.lock().unwrap()["url"] = json!(slow);
    p.foreground();
    let id = p.scheduled_job(1);
    let engine = p.t.engine.clone();
    let job = id.clone();
    let attempt = std::thread::spawn(move || engine.call("runScheduledDownload", &json!({ "id": job })).unwrap());
    std::thread::sleep(Duration::from_millis(300));
    assert!(p.events("appReady").is_empty(), "the launch waits for the download");
    p.t.call("stopScheduledDownload", json!({ "id": id }));
    assert_eq!(attempt.join().unwrap()["result"], "retry");
    let ready = p.wait_for_event("appReady", 1);
    assert_eq!(
        ready[0]["status"],
        "Direct update download is retrying, continuing launch on the current bundle"
    );
}

/// Plugin released while its download waits (process killed, activity destroyed): the job
/// still records the bundle, and the next update check installs it without downloading.
#[test]
fn a_job_finished_without_its_cycle_is_installed_by_the_next_check() {
    let p = Plugin::load(json!({}));
    p.schedule_downloads();
    p.backend.offer("2.0.0", web_bundle("v2"));
    p.foreground();
    let id = p.scheduled_job(1);
    p.t.call("detachScheduledDownloads", json!({}));
    let deadline = Instant::now() + Duration::from_secs(8);
    while p
        .t
        .engine
        .call("pluginMethod", &json!({ "name": "triggerUpdateCheck", "args": {} }))
        .unwrap()["resolve"]["status"]
        == "already_running"
    {
        assert!(Instant::now() < deadline, "cycle still waiting");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(p.events("downloadFailed").is_empty());
    assert_eq!(p.run_job(&id)["result"], "success");
    assert_eq!(p.t.call("bundleGet", json!({ "id": id }))["status"], "pending");
    let zip_requests = || {
        p.backend
            .server
            .requests()
            .iter()
            .filter(|request| request.url.starts_with("/b.zip"))
            .count()
    };
    let downloads = zip_requests();
    p.background();
    p.foreground();
    let deadline = Instant::now() + Duration::from_secs(8);
    while p.resolve("getNextBundle", json!({})).is_null() {
        assert!(Instant::now() < deadline, "bundle not queued");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(p.resolve("getNextBundle", json!({}))["id"], id.as_str());
    assert_eq!(zip_requests(), downloads, "no second download");
}

/// The app was killed while its download job waited: the next launch's update check resumes
/// that job (same bundle id, partial file kept) instead of downloading again.
#[test]
fn the_next_launch_resumes_the_job_of_a_killed_process() {
    let p = Plugin::load(json!({}));
    p.schedule_downloads();
    let bundle = web_bundle("v2");
    p.backend.offer("2.0.0", bundle.clone());
    p.foreground();
    let id = p.scheduled_job(1);
    // A first attempt was dropped halfway: its partial file waits for the next one.
    let half = bundle.len() / 2;
    std::fs::write(p.t.root().join(format!("temp_{id}.tmp")), &bundle[..half]).unwrap();
    std::fs::write(p.t.root().join(format!("update_{id}.dat")), "2.0.0").unwrap();
    // Process death: the cycle that waited is gone, the job stays.
    p.t.call("detachScheduledDownloads", json!({}));
    let engine = p.relaunch();
    let ready_before = p.events("appReady").len();
    engine.call("appForeground", &json!({})).unwrap();
    // Same job handed to the scheduler again (it keeps the one it has).
    assert_eq!(p.scheduled_job(2), id);
    let reply = engine.call("runScheduledDownload", &json!({ "id": id })).unwrap();
    assert_eq!(reply["result"], "success", "{reply}");
    let deadline = Instant::now() + Duration::from_secs(8);
    while p.events("appReady").len() == ready_before {
        assert!(Instant::now() < deadline, "cycle did not finish");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        p.events("appReady").last().unwrap()["status"],
        "update downloaded, will install next background"
    );
    let next = engine
        .call("pluginMethod", &json!({ "name": "getNextBundle", "args": {} }))
        .unwrap();
    assert_eq!(next["resolve"]["id"], id.as_str());
    let zip_requests: Vec<Option<String>> = p
        .backend
        .server
        .requests()
        .iter()
        .filter(|request| request.url.starts_with("/b.zip"))
        .map(|request| request.header("Range"))
        .collect();
    assert_eq!(
        zip_requests,
        [Some(format!("bytes={half}-"))],
        "the job resumed the partial file"
    );
}

/// The job of an earlier process finishes while the next launch's check finds no job to
/// adopt: the check uses the finished bundle instead of deleting it and downloading again.
#[test]
fn a_job_that_finishes_during_the_check_is_not_deleted() {
    let p = Plugin::load(json!({}));
    p.schedule_downloads();
    p.backend.offer("2.0.0", web_bundle("v2"));
    p.foreground();
    let id = p.scheduled_job(1);
    p.t.call("detachScheduledDownloads", json!({}));
    let engine = p.relaunch();
    // The new process cannot hand the job over (no adoption) ...
    p.t.host
        .reply_to_hook("scheduleDownload", json!({ "scheduled": false }));
    // ... and the job completes while the check reads the bundles (the log after "New bundle").
    let job_engine = p.t.engine.clone();
    let job_id = id.clone();
    let job_result: Arc<Mutex<Option<Value>>> = Arc::default();
    let result = job_result.clone();
    let armed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    *p.t.host.on_log.lock().unwrap() = Some(Arc::new(move |message: &str| {
        use std::sync::atomic::Ordering;
        if message.starts_with("New bundle: 2.0.0 found") {
            armed.store(true, Ordering::SeqCst);
        } else if armed.swap(false, Ordering::SeqCst) {
            *result.lock().unwrap() = Some(
                job_engine
                    .call("runScheduledDownload", &json!({ "id": job_id }))
                    .unwrap(),
            );
        }
    }));
    let ready_before = p.events("appReady").len();
    engine.call("appForeground", &json!({})).unwrap();
    let deadline = Instant::now() + Duration::from_secs(8);
    while p.events("appReady").len() == ready_before {
        assert!(Instant::now() < deadline, "cycle did not finish");
        std::thread::sleep(Duration::from_millis(10));
    }
    *p.t.host.on_log.lock().unwrap() = None;
    assert_eq!(job_result.lock().unwrap().as_ref().unwrap()["result"], "success");
    let next = engine
        .call("pluginMethod", &json!({ "name": "getNextBundle", "args": {} }))
        .unwrap();
    assert_eq!(next["resolve"]["id"], id.as_str(), "the job's bundle is kept");
    let zip_requests = p
        .backend
        .server
        .requests()
        .iter()
        .filter(|request| request.url.starts_with("/b.zip"))
        .count();
    assert_eq!(zip_requests, 1, "no second download");
}

#[test]
fn up_to_date_and_failed_checks_report_results() {
    let p = Plugin::load(json!({}));
    p.foreground();
    let ready = p.wait_for_event("appReady", 1);
    assert_eq!(p.events("updateCheckResult")[0]["kind"], "up_to_date");
    assert!(p.events("downloadFailed").is_empty());
    assert_eq!(p.events("noNeedUpdate").len(), 1);
    assert_eq!(ready[0]["status"], "server did not provide a message");

    let p = Plugin::load(json!({}));
    *p.backend.latest.lock().unwrap() = json!({ "error": "boom", "message": "server broke" });
    p.foreground();
    p.wait_for_event("appReady", 1);
    assert_eq!(p.events("updateCheckResult")[0]["kind"], "failed");
    assert_eq!(p.events("downloadFailed").len(), 1);
}

#[test]
fn breaking_flag_with_a_failed_check_emits_both_events() {
    let p = Plugin::load(json!({}));
    *p.backend.latest.lock().unwrap() = json!({ "error": "no_channel", "breaking": true, "version": "3.0.0" });
    p.foreground();
    p.wait_for_event("appReady", 1);
    assert_eq!(p.events("breakingAvailable")[0]["version"], "3.0.0");
    assert_eq!(p.events("majorAvailable")[0]["version"], "3.0.0");
    assert_eq!(p.events("downloadFailed").len(), 1);
}

#[test]
fn breaking_update_emits_both_events() {
    let p = Plugin::load(json!({}));
    *p.backend.latest.lock().unwrap() =
        json!({ "error": "disable_auto_update_to_major", "kind": "blocked", "version": "3.0.0" });
    p.foreground();
    p.wait_for_event("appReady", 1);
    assert_eq!(p.events("breakingAvailable")[0]["version"], "3.0.0");
    assert_eq!(p.events("majorAvailable")[0]["version"], "3.0.0");
    assert!(p.events("downloadFailed").is_empty());
}

#[test]
fn builtin_latest_queues_builtin_or_notifies() {
    let p = Plugin::load(json!({}));
    p.use_bundle("abcdefghij", "2.0.0");
    *p.backend.latest.lock().unwrap() = json!({ "version": "builtin" });
    p.foreground();
    let ready = p.wait_for_event("appReady", 1);
    assert_eq!(ready[0]["status"], "Next update will be to builtin version");
    assert_eq!(p.resolve("getNextBundle", json!({}))["id"], "builtin");
}

#[test]
fn checksum_mismatch_ends_cycle_with_failure() {
    let p = Plugin::load(json!({}));
    let bundle = web_bundle("v2");
    p.backend.offer("2.0.0", bundle);
    p.backend.latest.lock().unwrap()["checksum"] = json!(sha256(b"other"));
    p.foreground();
    let ready = p.wait_for_event("appReady", 1);
    assert_eq!(ready[0]["status"], "Error checksum");
    assert_eq!(p.events("downloadFailed")[0]["version"], "2.0.0");
    assert_eq!(p.resolve("getNextBundle", json!({})), Value::Null);
}

#[test]
fn trigger_update_check_statuses() {
    let p = Plugin::load(json!({}));
    let first = p.resolve("triggerUpdateCheck", json!({}));
    assert_eq!(first["status"], "queued");
    assert_eq!(first["queued"], true);

    let p = Plugin::load(json!({ "updateUrl": "not a url" }));
    let unavailable = p.resolve("triggerUpdateCheck", json!({}));
    assert_eq!(unavailable["status"], "unavailable");
    assert_eq!(unavailable["queued"], false);
}

#[test]
fn trigger_update_check_downloads_when_auto_update_is_off() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.backend.offer("2.0.0", web_bundle("v2"));
    assert_eq!(p.resolve("triggerUpdateCheck", json!({}))["status"], "queued");
    // Like onlyDownload: the bundle is downloaded and announced, never scheduled.
    wait_until("onlyDownload appReady", || {
        p.events("appReady")
            .iter()
            .any(|ready| ready["status"] == "update downloaded, autoUpdate onlyDownload")
    });
    assert_eq!(p.events("updateAvailable")[0]["bundle"]["version"], "2.0.0");
    assert_eq!(p.resolve("getNextBundle", json!({})), Value::Null);
    assert_eq!(p.current()["id"], "builtin");
}

#[test]
fn trigger_update_check_reports_preview_sessions() {
    let p = Plugin::load(json!({ "allowPreview": true }));
    p.resolve("startPreviewSession", json!({}));
    let status = p.resolve("triggerUpdateCheck", json!({}));
    assert_eq!(status["status"], "preview_session");
    assert_eq!(status["queued"], false);
}

#[test]
fn server_url_disables_auto_update() {
    let p = Plugin::load_with(json!({}), json!({ "serverUrlConfigured": true }));
    assert_eq!(p.resolve("isAutoUpdateAvailable", json!({}))["available"], false);
    p.foreground();
    assert_eq!(p.wait_for_event("appReady", 1)[0]["status"], "disabled");
    assert!(p.stats_actions().contains(&"blocked_by_server_url".to_string()));
}

// ---- delays -------------------------------------------------------------------------------------

#[test]
fn background_delay_blocks_one_install() {
    let p = Plugin::load(json!({}));
    let id = "abcdefghij";
    p.t.install_bundle(id, "2.0.0", "pending");
    p.resolve("next", json!({ "id": id }));
    p.resolve(
        "setMultiDelay",
        json!({ "delayConditions": [{ "kind": "background" }] }),
    );
    assert!(p
        .t
        .kv("DELAY_CONDITION_PREFERENCES_CAPGO")
        .unwrap()
        .contains("\"value\":\"0\""));
    p.background();
    std::thread::sleep(Duration::from_millis(200));
    assert!(p.events("set").is_empty(), "delayed");
    // Foreground clears the elapsed background condition, next background installs.
    std::thread::sleep(Duration::from_millis(5));
    p.t.engine.plugin_foreground_for_tests();
    assert!(p.t.kv("DELAY_CONDITION_PREFERENCES_CAPGO").is_none());
    p.background();
    assert_eq!(p.wait_for_event("set", 1)[0]["bundle"]["id"], id);
}

#[test]
fn kill_and_date_delays() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.resolve(
        "setMultiDelay",
        json!({ "delayConditions": [{ "kind": "kill" }, { "kind": "date", "value": "2000-01-01T00:00:00Z" }, { "kind": "date", "value": "2999-01-01T00:00:00Z" }, { "kind": "nativeVersion", "value": "0.9.0" }] }),
    );
    p.t.engine.plugin_terminate_for_tests();
    let stored = p.t.kv("DELAY_CONDITION_PREFERENCES_CAPGO").unwrap();
    assert!(!stored.contains("kill"));
    assert!(!stored.contains("2000-01-01"));
    assert!(stored.contains("2999-01-01"));
    assert!(!stored.contains("nativeVersion"));
    p.resolve("cancelDelay", json!({}));
    assert!(p.t.kv("DELAY_CONDITION_PREFERENCES_CAPGO").is_none());
}

#[test]
fn native_version_delay_orders_prerelease_numbers_numerically() {
    let p = Plugin::load_with(
        json!({ "autoUpdate": false }),
        json!({ "versionName": "1.0.0-beta.10" }),
    );
    p.resolve(
        "setMultiDelay",
        json!({ "delayConditions": [{ "kind": "nativeVersion", "value": "1.0.0-beta.2" }, { "kind": "nativeVersion", "value": "1.0.0-beta.11" }] }),
    );
    p.t.engine.plugin_foreground_for_tests();
    let stored = p.t.kv("DELAY_CONDITION_PREFERENCES_CAPGO").unwrap();
    assert!(!stored.contains("beta.2\""), "beta.10 reached beta.2: {stored}");
    assert!(stored.contains("beta.11"), "beta.10 has not reached beta.11: {stored}");
}

// ---- readiness and rollback ---------------------------------------------------------------------

#[test]
fn missing_notify_app_ready_rolls_back() {
    let p = Plugin::load(json!({ "autoUpdate": false, "autoDeleteFailed": true }));
    let id = "abcdefghij";
    p.t.install_bundle(id, "2.0.0", "pending");
    p.resolve("set", json!({ "id": id }));
    assert_eq!(p.events("set")[0]["bundle"]["id"], id);
    let failed = p.wait_for_event("updateFailed", 1);
    assert_eq!(failed[0]["bundle"]["id"], id);
    wait_until("rollback to builtin", || p.current()["id"] == "builtin");
    let failed_update = p.resolve("getFailedUpdate", json!({}));
    assert_eq!(failed_update["bundle"]["id"], id);
    assert_eq!(p.resolve("getFailedUpdate", json!({})), Value::Null, "one-shot");
    assert!(p.stats_actions().contains(&"update_fail".to_string()));
}

/// An unconfirmed bundle gets at least 30 s on both platforms (no host override), even with a
/// short appReadyTimeout: a slow first load is not rolled back.
#[test]
fn pending_bundle_gets_the_shared_minimum_before_rollback() {
    let p = Plugin::load_with(
        json!({ "autoUpdate": false, "appReadyTimeout": 1000 }),
        json!({ "pendingBundleMinAppReadyTimeoutMs": null }),
    );
    let id = "abcdefghij";
    p.t.install_bundle(id, "2.0.0", "pending");
    p.resolve("set", json!({ "id": id }));
    wait_until("the 30 s readiness check", || {
        p.t.host
            .logs
            .lock()
            .unwrap()
            .iter()
            .any(|(_, message)| message == "Wait for 30000 ms, then check for notifyAppReady")
    });
    std::thread::sleep(Duration::from_millis(1200));
    assert!(p.events("updateFailed").is_empty(), "still inside the 30 s window");
    assert_eq!(p.current()["id"], id);
    let generation = p.t.host.hooks_named("applyBundle").last().unwrap()["readyGeneration"].clone();
    p.resolve("notifyAppReady", json!({ "loadGeneration": generation }));
    assert_eq!(p.current()["status"], "success");
}

/// notifyAppReady arriving while the rollback check runs (after it saw the bundle
/// unconfirmed) wins: the bundle stays.
#[test]
fn notify_app_ready_racing_the_rollback_check_keeps_the_bundle() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    let id = "abcdefghij";
    p.t.install_bundle(id, "2.0.0", "pending");
    p.resolve("set", json!({ "id": id }));
    let generation = p.last_generation();
    let engine = Arc::downgrade(&p.t.engine);
    let fired = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let fired_in_hook = fired.clone();
    *p.t.host.on_log.lock().unwrap() = Some(Arc::new(move |message: &str| {
        if message.starts_with("notifyAppReady was not called")
            && !fired_in_hook.swap(true, std::sync::atomic::Ordering::SeqCst)
        {
            let engine = engine.upgrade().unwrap();
            let args = json!({ "name": "notifyAppReady", "args": { "loadGeneration": generation } });
            engine.call("pluginMethod", &args).unwrap();
        }
    }));
    wait_until("rollback check", || fired.load(std::sync::atomic::Ordering::SeqCst));
    std::thread::sleep(Duration::from_millis(300));
    assert!(p.events("updateFailed").is_empty());
    assert_eq!(p.current()["id"], id);
    assert_eq!(p.current()["status"], "success");
}

/// iOS reports the launch foreground twice (load() and the scene's willEnterForeground): one
/// update check, until the app really goes to the background and comes back.
#[test]
fn a_repeated_foreground_runs_one_update_check() {
    let p = Plugin::load(json!({ "autoUpdate": true }));
    let checks = || {
        p.backend
            .server
            .requests()
            .iter()
            .filter(|request| request.url.starts_with("/updates"))
            .count()
    };
    p.foreground();
    wait_until("first check", || checks() >= 1);
    // The first cycle has ended when the repeated event arrives (a fast up-to-date reply).
    std::thread::sleep(Duration::from_millis(500));
    p.foreground();
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(checks(), 1, "the repeated foreground is ignored");
    p.background();
    p.foreground();
    wait_until("check after a real background", || checks() >= 2);
}

#[test]
fn notify_app_ready_confirms_and_ignores_stale_pages() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    let id = "abcdefghij";
    p.t.install_bundle(id, "2.0.0", "pending");
    p.resolve("set", json!({ "id": id }));
    let generation = p.t.host.hooks_named("applyBundle").last().unwrap()["readyGeneration"]
        .as_i64()
        .unwrap();
    // A page from before the reload reports an old generation: ignored.
    p.resolve("notifyAppReady", json!({ "loadGeneration": generation - 1 }));
    assert_eq!(p.current()["status"], "pending");
    p.resolve("notifyAppReady", json!({ "loadGeneration": generation }));
    assert_eq!(p.current()["status"], "success");
    std::thread::sleep(Duration::from_millis(1200));
    assert!(p.events("updateFailed").is_empty());
}

#[test]
fn failed_reload_restores_previous_state() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    let id = "abcdefghij";
    p.t.install_bundle(id, "2.0.0", "pending");
    p.t.host.reply_to_hook("applyBundle", json!({ "ok": false }));
    let rejection = p.reject("set", json!({ "id": id }));
    assert_eq!(rejection["message"], format!("Reload failed after setting bundle {id}"));
    let next = "klmnopqrst";
    p.t.install_bundle(next, "3.0.0", "pending");
    p.resolve("next", json!({ "id": next }));
    let current = p.current()["id"].clone();
    assert!(p.reject("reload", json!({}))["message"]
        .as_str()
        .unwrap()
        .starts_with("Reload failed after applying pending bundle"));
    assert_eq!(p.resolve("getNextBundle", json!({}))["id"], next, "pending kept");
    assert_eq!(p.current()["id"], current, "live bundle kept");
}

#[test]
fn android_reload_waits_for_notify_app_ready() {
    let p = Plugin::load_with(
        json!({ "autoUpdate": false }),
        json!({ "reloadWaitsForAppReady": true, "pendingBundleMinAppReadyTimeoutMs": 1000 }),
    );
    let id = "abcdefghij";
    p.t.install_bundle(id, "2.0.0", "pending");
    let engine = p.t.engine.clone();
    let notifier = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(200));
        engine.call(
            "pluginMethod",
            &json!({ "name": "notifyAppReady", "args": { "loadGeneration": 1 } }),
        )
    });
    p.resolve("set", json!({ "id": id }));
    notifier.join().unwrap().unwrap();
    assert_eq!(p.current()["status"], "success");
    // Without notifyAppReady the reload times out and the switch is rejected.
    let other = "klmnopqrst";
    p.t.install_bundle(other, "3.0.0", "pending");
    assert_eq!(
        p.reject("set", json!({ "id": other }))["message"],
        format!("Reload failed after setting bundle {other}")
    );
}

/// Hosts keep their method lane while a detached method runs, until the engine says it
/// waits (`releaseMethodLane`): `set` switches the bundle first, `getLatest` releases before
/// its request, and lane methods never release.
#[test]
fn detached_methods_release_the_method_lane_when_they_wait() {
    let p = Plugin::load_with(
        json!({ "autoUpdate": false }),
        json!({ "reloadWaitsForAppReady": true, "pendingBundleMinAppReadyTimeoutMs": 1000 }),
    );
    let hook_names = || -> Vec<String> {
        p.t.host
            .hooks
            .lock()
            .unwrap()
            .iter()
            .map(|(name, _)| name.clone())
            .collect()
    };
    let releases = || hook_names().iter().filter(|name| *name == "releaseMethodLane").count();
    p.t.host.hooks.lock().unwrap().clear();
    p.resolve("current", json!({}));
    p.resolve("setShakeMenu", json!({ "enabled": true }));
    assert_eq!(releases(), 0, "lane methods: {:?}", hook_names());

    p.method("getLatest", json!({}));
    assert_eq!(releases(), 1, "once per call: {:?}", hook_names());
    assert!(!p.backend.server.requests().is_empty());

    p.t.host.hooks.lock().unwrap().clear();
    let id = "abcdefghij";
    p.t.install_bundle(id, "2.0.0", "pending");
    let engine = p.t.engine.clone();
    let set = std::thread::spawn(move || engine.call("pluginMethod", &json!({ "name": "set", "args": { "id": id } })));
    wait_until("set waits for notifyAppReady", || releases() == 1);
    let names = hook_names();
    let apply = names
        .iter()
        .position(|name| name == "applyBundle")
        .expect("applyBundle");
    let release = names.iter().position(|name| name == "releaseMethodLane").unwrap();
    assert!(apply < release, "switched before releasing: {names:?}");
    p.resolve("notifyAppReady", json!({ "loadGeneration": p.last_generation() }));
    assert!(set.join().unwrap().unwrap().get("resolve").is_some());
    assert_eq!(releases(), 1);
}

#[test]
fn reset_methods() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.use_bundle("abcdefghij", "2.0.0");
    p.resolve("reset", json!({}));
    assert_eq!(p.current()["id"], "builtin");
    assert_eq!(
        p.reject("reset", json!({ "usePendingBundle": true }))["message"],
        "Reset failed"
    );
}

// ---- download method ----------------------------------------------------------------------------

#[test]
fn download_method_events_and_errors() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    let bundle = web_bundle("v2");
    *p.backend.bundle.lock().unwrap() = bundle.clone();
    let url = format!("{}/b.zip", p.backend.server.url);
    let installed = p.resolve(
        "download",
        json!({ "url": url, "version": "2.0.0", "checksum": sha256(&bundle) }),
    );
    assert_eq!(installed["status"], "pending");
    assert_eq!(p.events("updateAvailable").len(), 1);
    assert_eq!(p.t.host.retained_count("updateAvailable"), 0);
    assert_eq!(p.events("downloadComplete").len(), 1);

    let rejection = p.reject("download", json!({ "url": url, "version": "3.0.0" }));
    assert!(
        rejection["message"].as_str().unwrap().contains("Checksum required"),
        "{rejection}"
    );
    assert_eq!(p.events("downloadFailed")[0]["version"], "3.0.0");
    assert_eq!(
        p.reject("download", json!({ "version": "1" }))["message"],
        "Download called without url"
    );
}

// ---- channels -----------------------------------------------------------------------------------

#[test]
fn set_channel_persists_state_and_reports_private_channels() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.resolve("setChannel", json!({ "channel": "beta" }));
    assert_eq!(p.t.kv("CapacitorUpdater.defaultChannel").unwrap(), "beta");
    let state = std::fs::read(p.t.root().join("nobackup/CapacitorUpdater.defaultChannelState")).unwrap();
    assert_eq!(state, b"beta");
    assert!(p
        .t
        .host
        .hooks_named("excludeFromBackup")
        .iter()
        .any(|hook| hook["path"].as_str().unwrap().ends_with("defaultChannelState")));

    *p.backend.channel_reply.lock().unwrap() = (
        400,
        json!({ "error": "channel_self_set_not_allowed", "message": "private" }),
    );
    let rejection = p.reject("setChannel", json!({ "channel": "secret" }));
    assert_eq!(rejection["code"], "SETCHANNEL_FAILED");
    assert_eq!(rejection["data"]["error"], "channel_self_set_not_allowed");
    assert_eq!(p.events("channelPrivate")[0]["channel"], "secret");
    assert_eq!(p.reject("setChannel", json!({}))["code"], "SETCHANNEL_INVALID_PARAMS");
}

#[test]
fn channel_methods_resolve_every_server_field() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    *p.backend.channel_reply.lock().unwrap() = (200, json!({ "channel": "beta", "status": "ok", "extra": 1 }));
    let channel = p.resolve("getChannel", json!({}));
    assert_eq!(channel["channel"], "beta");
    assert_eq!(channel["extra"], 1);
    assert_eq!(channel["allowSet"], true, "allowSet defaults to true");
    *p.backend.channel_reply.lock().unwrap() = (200, json!({ "channel": "beta", "allowSet": false }));
    assert_eq!(p.resolve("getChannel", json!({}))["allowSet"], false);

    *p.backend.channel_reply.lock().unwrap() = (200, json!({ "extra": "x" }));
    let set = p.resolve("setChannel", json!({ "channel": "beta" }));
    assert_eq!(set["extra"], "x");
    assert_eq!(set["status"], "");
    assert_eq!(set["message"], "");
    assert_eq!(set["statusCode"], 200);
    *p.backend.channel_reply.lock().unwrap() = (200, json!({ "unset": true }));
    let unset = p.resolve("setChannel", json!({ "channel": "production" }));
    assert_eq!(unset["status"], "ok");
    assert_eq!(unset["unset"], true);
    assert_eq!(
        unset["message"],
        "Public channel requested, channel override removed. Device will use public channel automatically."
    );
}

#[test]
fn channel_rejections_carry_the_raw_error_code() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    *p.backend.channel_reply.lock().unwrap() = (403, json!({ "error": "not_allowed", "message": "No access" }));
    let rejection = p.reject("getChannel", json!({}));
    assert_eq!(rejection["code"], "GETCHANNEL_FAILED");
    assert_eq!(rejection["message"], "No access");
    assert_eq!(rejection["data"]["error"], "not_allowed");
    let rejection = p.reject("listChannels", json!({}));
    assert_eq!(rejection["code"], "LISTCHANNELS_FAILED");
    assert_eq!(rejection["data"]["error"], "not_allowed");
    *p.backend.channel_reply.lock().unwrap() = (500, json!({}));
    let rejection = p.reject("getChannel", json!({}));
    assert_eq!(rejection["message"], "Server error: 500");
    assert_eq!(rejection["data"]["error"], "response_error");
    let rejection = p.reject("setChannel", json!({ "channel": "beta" }));
    assert_eq!(rejection["code"], "SETCHANNEL_FAILED");
    assert_eq!(rejection["data"]["error"], "response_error");
}

#[test]
fn channel_state_file_failures_do_not_reject() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    // A non-empty directory where the state file goes: it can be neither written nor removed.
    let state = p.t.root().join("nobackup/CapacitorUpdater.defaultChannelState");
    let _ = std::fs::remove_file(&state);
    std::fs::create_dir_all(state.join("blocker")).unwrap();
    assert_eq!(p.resolve("setChannel", json!({ "channel": "beta" }))["status"], "ok");
    assert_eq!(p.t.kv("CapacitorUpdater.defaultChannel").unwrap(), "beta");
    *p.backend.channel_reply.lock().unwrap() = (200, json!({ "channel": "beta" }));
    assert_eq!(p.resolve("getChannel", json!({}))["channel"], "beta");
    p.resolve("unsetChannel", json!({}));
    assert!(p.t.kv("CapacitorUpdater.defaultChannel").is_none());
    assert!(p
        .t
        .host
        .logs
        .lock()
        .unwrap()
        .iter()
        .any(|(_, message)| message.contains("default channel state file could not be updated")));
}

/// Makes `dir` read-only. False (and `dir` left writable) when permissions are not
/// enforced, as for tests running as root.
fn make_read_only(dir: &std::path::Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o555)).unwrap();
    let probe = dir.join(".write-probe");
    if std::fs::write(&probe, b"").is_ok() {
        let _ = std::fs::remove_file(&probe);
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        eprintln!("skipped: permissions are not enforced (running as root)");
        return false;
    }
    true
}

/// The restored channel is only final once the preview snapshot is invalidated: when that
/// write fails, the restore stays pending (like the previous iOS plugin) instead of
/// leaving a snapshot that would override a later setChannel on the next launch.
#[test]
fn preview_channel_restore_retries_when_the_snapshot_cannot_be_invalidated() {
    use std::os::unix::fs::PermissionsExt;
    let nobackup = tempfile::tempdir().unwrap();
    let snapshot = nobackup.path().join("CapacitorUpdater.defaultChannelPreviewSnapshot");
    std::fs::write(&snapshot, b"\x02beta").unwrap();
    if !make_read_only(nobackup.path()) {
        return;
    }
    let p = Plugin::load_with(
        json!({ "autoUpdate": false }),
        json!({ "noBackupDir": nobackup.path().to_string_lossy() }),
    );
    std::fs::set_permissions(nobackup.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
    let logs: Vec<String> =
        p.t.host
            .logs
            .lock()
            .unwrap()
            .iter()
            .map(|(_, message)| message.clone())
            .collect();
    assert!(logs
        .iter()
        .any(|message| message == "Default channel preview restore will retry on next launch"));
    assert!(!logs
        .iter()
        .any(|message| message == "Restored defaultChannel after preview"));
    assert_eq!(std::fs::read(&snapshot).unwrap(), b"\x02beta");
}

/// A preview session that cannot snapshot the default channel does not start, and leaves
/// no preview fallback behind.
#[test]
fn failed_preview_start_leaves_no_preview_state() {
    let p = Plugin::load(json!({ "autoUpdate": false, "allowPreview": true }));
    // A non-empty directory where the snapshot goes: it cannot be written, as root too.
    let snapshot =
        p.t.root()
            .join("nobackup/CapacitorUpdater.defaultChannelPreviewSnapshot");
    std::fs::create_dir_all(snapshot.join("blocker")).unwrap();
    let rejection = p.reject("startPreviewSession", json!({}));
    assert_eq!(
        rejection["message"],
        "Could not save current bundle as preview fallback"
    );
    assert!(p.resolve("listPreviews", json!({})).get("liveBundle").is_none());
    assert!(p.t.kv("CapacitorUpdater.previewPreviousAppId").is_none());
}

/// Leaving a preview restores the channel in use at once, even when the restore must be
/// retried at the next launch (the previous iOS plugin applied it the same way).
#[test]
fn leaving_a_preview_uses_the_restored_channel_even_when_the_restore_retries() {
    let p = Plugin::load(json!({ "autoUpdate": false, "allowPreview": true }));
    assert_eq!(p.resolve("setChannel", json!({ "channel": "beta" }))["status"], "ok");
    p.resolve("startPreviewSession", json!({}));
    assert_eq!(
        p.resolve("setChannel", json!({ "channel": "preview-channel" }))["status"],
        "ok"
    );
    // A non-empty directory where the channel state file goes: the restore cannot be final.
    let state = p.t.root().join("nobackup/CapacitorUpdater.defaultChannelState");
    let _ = std::fs::remove_file(&state);
    std::fs::create_dir_all(state.join("blocker")).unwrap();
    p.resolve("resetPreview", json!({}));
    assert_eq!(p.t.kv("CapacitorUpdater.defaultChannel").unwrap(), "beta");
    p.method("getLatest", json!({}));
    let request = p
        .backend
        .server
        .requests()
        .into_iter()
        .rev()
        .find(|request| request.url.starts_with("/updates"))
        .unwrap();
    assert_eq!(request.json()["defaultChannel"], "beta");
}

#[test]
fn default_channel_is_cleared_on_native_update_when_not_persisted() {
    let backend_config =
        json!({ "autoUpdate": false, "persistDefaultChannelOnReinstall": false, "defaultChannel": "prod" });
    let p = Plugin::load(backend_config.clone());
    p.resolve("setChannel", json!({ "channel": "beta" }));
    assert_eq!(p.t.engine.config().default_channel, "beta");
    // Same storage, new native build.
    let native = json!({ "versionName": "1.1.0", "versionCode": "11", "noBackupDir": p.t.root().join("nobackup").to_string_lossy() });
    p.t.call("pluginLoad", json!({ "config": backend_config, "native": native }));
    assert!(p.t.kv("CapacitorUpdater.defaultChannel").is_none());
    assert_eq!(p.t.engine.config().default_channel, "prod");
}

// ---- previews -----------------------------------------------------------------------------------

#[test]
fn preview_session_lifecycle() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    assert!(p.reject("startPreviewSession", json!({}))["message"]
        .as_str()
        .unwrap()
        .contains("allowPreview"));
    let p = Plugin::load(json!({ "autoUpdate": false, "allowPreview": true }));
    let id = "abcdefghij";
    p.t.install_bundle(id, "2.0.0-preview", "success");
    assert_eq!(
        p.reject("startPreviewSession", json!({ "payloadUrl": "ftp://x" }))["message"],
        "Invalid preview payloadUrl"
    );
    p.resolve("startPreviewSession", json!({ "name": "PR 12", "source": "github" }));
    assert_eq!(p.resolve("isAutoUpdateEnabled", json!({}))["enabled"], false);
    p.resolve("set", json!({ "id": id }));
    let previews = p.resolve("listPreviews", json!({}));
    assert_eq!(previews["previews"][0]["id"], id);
    assert_eq!(previews["previews"][0]["name"], "PR 12");
    assert_eq!(previews["current"]["id"], id);
    assert_eq!(previews["liveBundle"]["id"], "builtin");
    assert_eq!(
        p.reject("deletePreview", json!({ "id": id }))["message"],
        "Cannot delete the active preview"
    );
    // Preview bundles are never rolled back.
    std::thread::sleep(Duration::from_millis(1200));
    assert!(p.events("updateFailed").is_empty());

    p.resolve("resetPreview", json!({}));
    assert_eq!(p.current()["id"], "builtin");
    let deleted = p.resolve("deletePreview", json!({ "id": id }));
    assert_eq!(deleted["removed"], true);
    assert_eq!(deleted["deleted"], true);
}

#[test]
fn preview_deep_link_leaves_preview() {
    let p = Plugin::load(json!({ "autoUpdate": false, "allowPreview": true }));
    p.resolve("startPreviewSession", json!({}));
    let leaving = p.t.call("openUrl", json!({ "url": "capgo://preview/bundle?id=1" }));
    assert_eq!(leaving["leavingPreview"], true);
    let deadline = Instant::now() + Duration::from_secs(5);
    while p.t.call("previewSessionActive", json!({}))["active"] == true {
        assert!(Instant::now() < deadline, "preview not left");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        p.t.call("openUrl", json!({ "url": "https://x.dev/other" }))["leavingPreview"],
        false
    );
}

// ---- telemetry ----------------------------------------------------------------------------------

#[test]
fn native_version_change_is_reported_until_acknowledged() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    let native = json!({ "versionName": "1.0.0", "versionCode": "11", "noBackupDir": p.t.root().join("nobackup").to_string_lossy() });
    p.t.call("configure", json!({ "versionCode": "11" }));
    p.t.call("pluginLoad", json!({ "config": { "autoUpdate": false, "statsUrl": format!("{}/stats", p.backend.server.url) }, "native": native }));
    let actions = p.stats_actions();
    assert!(
        actions.contains(&"native_app_version_changed".to_string()),
        "{actions:?}"
    );
    assert_eq!(
        p.t.kv("CapacitorUpdater.lastVersionCode").unwrap(),
        "11",
        "persisted after ack"
    );
}

#[test]
fn web_view_errors_are_sanitized() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.resolve(
        "reportWebViewError",
        json!({ "type": "unhandled_rejection", "message": "boom", "href": "https://a.b/u/1234567?token=x" }),
    );
    let actions = p.stats_actions();
    assert!(actions.contains(&"webview_unhandled_rejection".to_string()));
    let body = p
        .backend
        .server
        .requests()
        .iter()
        .filter(|request| request.url.starts_with("/stats"))
        .map(|request| String::from_utf8_lossy(&request.body).to_string())
        .collect::<String>();
    assert!(body.contains("https://a.b/u/redacted"));
    assert!(!body.contains("token"));
}

// ---- edge cases ported from the native plugin tests ---------------------------------------------

fn wait_until(what: &str, mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(8);
    while !condition() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn contract_public_key() -> String {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../native-contract-tests/crypto-rsa.json");
    let fixture: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    fixture["publicKeyPem"].as_str().unwrap().to_string()
}

#[test]
fn reset_to_pending_without_installable_bundle_keeps_state() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.use_bundle("abcdefghij", "2.0.0");
    assert_eq!(
        p.reject("reset", json!({ "usePendingBundle": true }))["message"],
        "Reset failed"
    );
    assert_eq!(p.current()["id"], "abcdefghij");
    p.t.install_bundle("klmnopqrst", "3.0.0", "pending");
    p.resolve("next", json!({ "id": "klmnopqrst" }));
    std::fs::remove_dir_all(p.t.root().join("versions/klmnopqrst")).unwrap();
    assert_eq!(
        p.reject("reset", json!({ "usePendingBundle": true }))["message"],
        "Reset failed"
    );
    assert_eq!(p.current()["id"], "abcdefghij", "live bundle kept");
}

#[test]
fn reset_to_last_successful_falls_back_to_builtin_when_fallback_is_gone() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.use_bundle("abcdefghij", "2.0.0");
    p.use_bundle("klmnopqrst", "3.0.0");
    std::fs::remove_dir_all(p.t.root().join("versions/klmnopqrst")).unwrap();
    p.resolve("reset", json!({ "toLastSuccessful": true }));
    assert_eq!(p.current()["id"], "builtin");
}

#[test]
fn rollback_deletes_the_failed_bundle() {
    let p = Plugin::load(json!({ "autoUpdate": false, "autoDeleteFailed": true }));
    let id = "abcdefghij";
    p.t.install_bundle(id, "2.0.0", "pending");
    p.resolve("set", json!({ "id": id }));
    p.wait_for_event("updateFailed", 1);
    wait_until("failed bundle deleted", || {
        !p.t.root().join("versions").join(id).exists()
    });
    let bundles = p.resolve("list", json!({}))["bundles"].clone();
    assert!(bundles.as_array().unwrap().iter().all(|bundle| bundle["id"] != id));
}

#[test]
fn preview_menu_drops_previews_whose_bundle_is_gone() {
    let p = Plugin::load(json!({ "autoUpdate": false, "allowPreview": true }));
    p.t.install_bundle("abcdefghij", "2.0.0", "success");
    p.t.install_bundle("klmnopqrst", "3.0.0", "success");
    p.resolve("startPreviewSession", json!({}));
    p.resolve("set", json!({ "id": "abcdefghij" }));
    p.resolve("set", json!({ "id": "klmnopqrst" }));
    assert_eq!(p.t.call("previewMenuPreviews", json!({})).as_array().unwrap().len(), 2);
    p.t.call("bundleDelete", json!({ "id": "abcdefghij" }));
    let previews = p.t.call("previewMenuPreviews", json!({}));
    assert_eq!(previews.as_array().unwrap().len(), 1);
    assert!(!p
        .t
        .kv("CapacitorUpdater.previewSessions")
        .unwrap()
        .contains("abcdefghij"));
    // Auto update is off during a preview.
    assert_eq!(p.resolve("triggerUpdateCheck", json!({}))["status"], "preview_session");
    assert_eq!(p.t.call("previewMenuLeave", json!({}))["ok"], true);
    assert_eq!(p.current()["id"], "builtin");
}

#[test]
fn on_launch_installs_once_then_queues() {
    let p = Plugin::load(json!({ "autoUpdate": "onLaunch" }));
    p.backend.offer("2.0.0", web_bundle("v2"));
    p.foreground();
    p.wait_for_event("set", 1);
    p.resolve("notifyAppReady", json!({ "loadGeneration": p.last_generation() }));
    assert_eq!(p.wait_for_event("appReady", 1)[0]["status"], "update installed");
    p.backend.offer("3.0.0", web_bundle("v3"));
    p.background();
    p.foreground();
    let ready = p.wait_for_event("appReady", 2);
    assert_eq!(ready[1]["status"], "update downloaded, will install next background");
    assert_eq!(p.resolve("getNextBundle", json!({}))["version"], "3.0.0");
    assert_eq!(p.current()["version"], "2.0.0");
}

#[test]
fn only_download_builtin_latest() {
    let p = Plugin::load(json!({ "autoUpdate": "onlyDownload" }));
    *p.backend.latest.lock().unwrap() = json!({ "version": "builtin" });
    p.foreground();
    p.wait_for_event("appReady", 1);
    assert!(p.events("updateAvailable").is_empty());
    assert_eq!(p.events("noNeedUpdate").len(), 1);

    let p = Plugin::load(json!({ "autoUpdate": "onlyDownload" }));
    p.use_bundle("abcdefghij", "2.0.0");
    *p.backend.latest.lock().unwrap() = json!({ "version": "builtin" });
    p.foreground();
    p.wait_for_event("appReady", 1);
    assert_eq!(p.events("updateAvailable")[0]["bundle"]["id"], "builtin");
    assert_eq!(p.t.host.retained_count("updateAvailable"), 1);
    assert!(p.events("noNeedUpdate").is_empty());
    assert_eq!(p.resolve("getNextBundle", json!({})), Value::Null);
}

#[test]
fn get_latest_method_rejections_and_breaking_events() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    *p.backend.latest.lock().unwrap() = json!({ "error": "no_channel", "message": "No channel" });
    assert_eq!(p.reject("getLatest", json!({}))["message"], "no_channel");
    *p.backend.latest.lock().unwrap() = json!({ "message": "store_update_required", "version": "3.0.0" });
    assert_eq!(p.reject("getLatest", json!({}))["message"], "store_update_required");
    assert_eq!(p.events("breakingAvailable")[0]["version"], "3.0.0");
    assert_eq!(p.events("majorAvailable")[0]["version"], "3.0.0");
    *p.backend.latest.lock().unwrap() = json!({ "error": "no_new_version_available", "kind": "up_to_date" });
    let up_to_date = p.resolve("getLatest", json!({}));
    assert_eq!(up_to_date["kind"], "up_to_date");
    assert_eq!(up_to_date["version"], "1.0.0", "current version filled in");
    assert_eq!(p.events("breakingAvailable").len(), 1);

    // breaking with any error fires both events (current version when the server sends none)
    // and the resolved result keeps every server field.
    *p.backend.latest.lock().unwrap() = json!({
        "error": "some_block", "kind": "blocked", "breaking": true, "major": true,
        "link": "https://example.com", "comment": "note", "data": { "k": "v" },
    });
    let blocked = p.resolve("getLatest", json!({}));
    assert_eq!(blocked["kind"], "blocked");
    assert_eq!(blocked["breaking"], true);
    assert_eq!(blocked["major"], true);
    assert_eq!(blocked["link"], "https://example.com");
    assert_eq!(blocked["comment"], "note");
    assert_eq!(blocked["data"]["k"], "v");
    assert_eq!(p.events("breakingAvailable")[1]["version"], "1.0.0");
    assert_eq!(p.events("majorAvailable")[1]["version"], "1.0.0");
    *p.backend.latest.lock().unwrap() = json!({ "error": "boom", "breaking": true, "version": "4.0.0" });
    assert_eq!(p.reject("getLatest", json!({}))["message"], "boom");
    assert_eq!(p.events("breakingAvailable")[2]["version"], "4.0.0");
    assert!(p.reject("getLatest", json!({ "appId": "other" }))["message"]
        .as_str()
        .unwrap()
        .contains("allowPreview"));
}

#[test]
fn app_ready_is_emitted_after_the_wait_times_out() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.t.install_bundle("abcdefghij", "2.0.0", "success");
    p.resolve("set", json!({ "id": "abcdefghij" }));
    let start = Instant::now();
    p.foreground();
    let ready = p.wait_for_event("appReady", 1);
    assert_eq!(ready[0]["status"], "disabled");
    assert!(
        start.elapsed() >= Duration::from_millis(900),
        "waited for notifyAppReady"
    );
}

#[test]
fn native_update_uses_the_legacy_build_key_and_resets() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.use_bundle("abcdefghij", "2.0.0");
    p.t.host.kv_set("LatestNativeBuildVersion", None);
    p.t.host.kv_set("LatestVersionNative", Some("9"));
    let native = json!({ "versionName": "1.0.0", "versionCode": "10", "noBackupDir": p.t.root().join("nobackup").to_string_lossy() });
    p.t.call(
        "pluginLoad",
        json!({ "config": { "autoUpdate": false }, "native": native }),
    );
    assert_eq!(p.current()["id"], "builtin");
    p.t.engine.wait_for_cleanup_for_tests();
    assert_eq!(p.t.kv("LatestNativeBuildVersion").unwrap(), "10");
    assert!(
        !p.t.root().join("versions/abcdefghij").exists(),
        "obsolete bundle deleted"
    );
}

#[test]
fn os_update_and_app_exits_are_reported_once() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.t.host.kv_set("CapacitorUpdater.lastVersionOs", Some("13"));
    p.t.call("configure", json!({ "versionOs": "14" }));
    let native = json!({
        "versionName": "1.0.0",
        "versionCode": "10",
        "noBackupDir": p.t.root().join("nobackup").to_string_lossy(),
        "previousExits": [
            { "reason": 4, "timestamp": 2000, "pid": 1, "processName": "app" },
            { "reason": 1, "timestamp": 1500 },
            { "reason": 6, "timestamp": 1000 }
        ],
    });
    let config = json!({ "autoUpdate": false, "statsUrl": format!("{}/stats", p.backend.server.url) });
    p.t.call("pluginLoad", json!({ "config": config, "native": native }));
    // The OS snapshot is persisted once the server acknowledged the event.
    p.stats_actions();
    p.t.call("pluginLoad", json!({ "config": config, "native": native }));
    let actions = p.stats_actions();
    assert_eq!(
        actions.iter().filter(|action| *action == "app_crash").count(),
        1,
        "{actions:?}"
    );
    assert_eq!(actions.iter().filter(|action| *action == "app_anr").count(), 1);
    assert_eq!(
        actions.iter().filter(|action| *action == "os_version_changed").count(),
        1
    );
    assert_eq!(p.t.kv("CapacitorUpdater.lastReportedAppExitTimestamp").unwrap(), "2000");
}

#[test]
fn update_cycle_requires_session_key_and_checksum_before_downloading() {
    let p = Plugin::load(json!({ "publicKey": contract_public_key() }));
    p.backend.offer("2.0.0", web_bundle("v2"));
    p.foreground();
    assert_eq!(
        p.wait_for_event("appReady", 1)[0]["status"],
        "Session key required when public key is present"
    );
    assert!(p
        .backend
        .server
        .requests()
        .iter()
        .all(|request| request.url != "/b.zip"));
    assert!(p.stats_actions().contains(&"session_key_required".to_string()));

    let p = Plugin::load(json!({}));
    p.backend.offer("2.0.0", web_bundle("v2"));
    p.backend.latest.lock().unwrap()["checksum"] = json!("");
    p.foreground();
    assert_eq!(p.wait_for_event("appReady", 1)[0]["status"], "Checksum required");
    assert!(p
        .backend
        .server
        .requests()
        .iter()
        .all(|request| request.url != "/b.zip"));
}

#[test]
fn unexpired_background_delay_and_kill_delay() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.resolve(
        "setMultiDelay",
        json!({ "delayConditions": [{ "kind": "background", "value": "600000" }] }),
    );
    p.background();
    std::thread::sleep(Duration::from_millis(100));
    p.t.engine.plugin_foreground_for_tests();
    assert!(
        p.t.kv("DELAY_CONDITION_PREFERENCES_CAPGO").unwrap().contains("600000"),
        "kept"
    );

    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.t.install_bundle("abcdefghij", "2.0.0", "pending");
    p.resolve("next", json!({ "id": "abcdefghij" }));
    p.resolve("setMultiDelay", json!({ "delayConditions": [{ "kind": "kill" }] }));
    p.t.call("appTerminate", json!({}));
    assert!(p.t.kv("DELAY_CONDITION_PREFERENCES_CAPGO").is_none());
    assert!(p.events("set").is_empty(), "killing does not install");
}

#[test]
fn page_load_stats_are_sanitized() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.t.call(
        "reportWebViewStats",
        json!({ "action": "webview_page_loaded", "metadata": { "href": format!("https://u:secret@a.b/p/1234567/{}?t=1", "x".repeat(600)), "source": "android_webview_listener" } }),
    );
    assert!(p.stats_actions().contains(&"webview_page_loaded".to_string()));
    let body = p
        .backend
        .server
        .requests()
        .iter()
        .map(|request| String::from_utf8_lossy(&request.body).to_string())
        .collect::<String>();
    assert!(body.contains("https://a.b/p/redacted"));
    assert!(!body.contains("t=1"));
    assert!(!body.contains("secret"));
    assert!(body.contains(&format!(
        "\"https://a.b/p/redacted/{}\"",
        "x".repeat(512 - "https://a.b/p/redacted/".len())
    )));
}

/// Android freezes backgrounded apps: a rollback timer that expires while the
/// app is in background must wait for the next foreground instead of rolling
/// back a bundle whose page could not run yet.
#[test]
fn no_rollback_while_the_app_is_in_background() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    let id = "abcdefghij";
    p.t.install_bundle(id, "2.0.0", "pending");
    p.resolve("next", json!({ "id": id }));
    p.background();
    p.wait_for_event("set", 1);
    std::thread::sleep(Duration::from_millis(1300));
    assert!(p.events("updateFailed").is_empty(), "no rollback in background");
    assert_eq!(p.current()["id"], id);
    // Back in foreground the page confirms itself.
    p.foreground();
    p.resolve("notifyAppReady", json!({ "loadGeneration": p.last_generation() }));
    std::thread::sleep(Duration::from_millis(1300));
    assert!(p.events("updateFailed").is_empty());
    assert_eq!(p.current()["status"], "success");
}

#[test]
fn android_background_install_does_not_wait_for_the_frozen_page() {
    let p = Plugin::load_with(
        json!({ "autoUpdate": false }),
        json!({ "reloadWaitsForAppReady": true, "pendingBundleMinAppReadyTimeoutMs": 1000 }),
    );
    let id = "abcdefghij";
    p.t.install_bundle(id, "2.0.0", "pending");
    p.resolve("next", json!({ "id": id }));
    let start = Instant::now();
    p.background();
    p.wait_for_event("set", 1);
    assert!(
        start.elapsed() < Duration::from_millis(900),
        "installed without waiting"
    );
    assert_eq!(p.resolve("getNextBundle", json!({})), Value::Null);
    p.foreground();
    p.resolve("notifyAppReady", json!({ "loadGeneration": p.last_generation() }));
    assert_eq!(p.current()["status"], "success");
}

/// Resuming before the rollback deadline arms a fresh wait: the check scheduled
/// before the background never fires on thaw.
#[test]
fn background_resets_the_rollback_deadline() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    let id = "abcdefghij";
    p.t.install_bundle(id, "2.0.0", "pending");
    p.resolve("set", json!({ "id": id }));
    let set_at = Instant::now();
    std::thread::sleep(Duration::from_millis(300));
    p.background();
    std::thread::sleep(Duration::from_millis(200));
    p.t.engine.plugin_foreground_for_tests();
    let resumed_at = Instant::now();
    // The first deadline (set + 1 s) passes without a rollback.
    std::thread::sleep(Duration::from_millis(1100).saturating_sub(set_at.elapsed()));
    assert!(p.events("updateFailed").is_empty(), "old check invalidated");
    // The fresh one (resume + 1 s) still rolls back an unconfirmed bundle.
    p.wait_for_event("updateFailed", 1);
    assert!(resumed_at.elapsed() >= Duration::from_millis(950));
}

#[test]
fn a_failed_download_is_one_stat_on_the_failed_version() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    let bundle = web_bundle("v2");
    *p.backend.bundle.lock().unwrap() = bundle;
    let url = format!("{}/b.zip", p.backend.server.url);
    p.reject(
        "download",
        json!({ "url": url, "version": "9.9.9", "checksum": sha256(b"wrong") }),
    );
    let actions = p.stats_actions();
    assert_eq!(
        actions.iter().filter(|action| *action == "download_fail").count(),
        1,
        "{actions:?}"
    );
    let body = p
        .backend
        .server
        .requests()
        .iter()
        .filter(|request| request.url.starts_with("/stats"))
        .map(|request| request.json())
        .flat_map(|body| match body {
            Value::Array(events) => events,
            other => vec![other],
        })
        .find(|event| event["action"] == "download_fail")
        .unwrap();
    assert_eq!(body["version_name"], "9.9.9");
    assert_eq!(p.events("downloadFailed").len(), 1);
}

fn stat_events(p: &Plugin, action: &str) -> Vec<Value> {
    p.stats_actions();
    p.backend
        .server
        .requests()
        .iter()
        .filter(|request| request.url.starts_with("/stats"))
        .map(|request| request.json())
        .flat_map(|body| match body {
            Value::Array(events) => events,
            other => vec![other],
        })
        .filter(|event| event["action"] == action)
        .collect()
}

#[test]
fn finalize_failures_after_the_transfer_send_finish_download_fail() {
    // Checksum mismatch after a complete transfer.
    let p = Plugin::load(json!({ "autoUpdate": false }));
    *p.backend.bundle.lock().unwrap() = web_bundle("v2");
    let url = format!("{}/b.zip", p.backend.server.url);
    p.reject(
        "download",
        json!({ "url": url, "version": "9.9.9", "checksum": sha256(b"wrong") }),
    );
    let finish = stat_events(&p, "finish_download_fail");
    assert_eq!(finish.len(), 1);
    assert_eq!(finish[0]["version_name"], "9.9.9");
    assert_eq!(stat_events(&p, "checksum_fail").len(), 1);
    // The previous Android plugin: checksum_fail, finish_download_fail and download_fail.
    assert_eq!(stat_events(&p, "download_fail").len(), 1);

    // Not a zip: unzip fails.
    let p = Plugin::load(json!({ "autoUpdate": false }));
    let garbage = b"definitely not a zip".to_vec();
    *p.backend.bundle.lock().unwrap() = garbage.clone();
    let url = format!("{}/b.zip", p.backend.server.url);
    p.reject(
        "download",
        json!({ "url": url, "version": "8.8.8", "checksum": sha256(&garbage) }),
    );
    assert_eq!(stat_events(&p, "unzip_fail").len(), 1);
    let finish = stat_events(&p, "finish_download_fail");
    assert_eq!(finish.len(), 1);
    assert_eq!(finish[0]["version_name"], "8.8.8");

    // The transfer itself failed: no finish_download_fail.
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.reject(
        "download",
        json!({ "url": "http://127.0.0.1:1/b.zip", "version": "7.7.7", "checksum": sha256(b"x") }),
    );
    assert_eq!(stat_events(&p, "download_fail").len(), 1);
    assert!(stat_events(&p, "finish_download_fail").is_empty());
}

// ---- shake menu channel switch ----------------------------------------------------------------

fn switch_channel(p: &Plugin, channel: &str) -> Value {
    p.t.call("shakeMenuSwitchChannel", json!({ "channel": channel }))
}

#[test]
fn shake_menu_switch_channel_downloads_and_queues_the_update() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.backend.offer("2.0.0", web_bundle("two"));
    let result = switch_channel(&p, "beta");
    assert_eq!(result["status"], "updateReady", "{result}");
    assert_eq!(result["message"], "Update downloaded! Reload to apply version 2.0.0?");
    assert_eq!(result["version"], "2.0.0");
    let id = result["bundleId"].as_str().unwrap();
    assert_eq!(p.t.call("bundleNext", json!({}))["id"], id);
    let progress: Vec<Value> = p.t.host.hooks_named("shakeMenuProgress");
    assert_eq!(
        progress,
        vec![
            json!({ "message": "Checking for updates..." }),
            json!({ "message": "Downloading update 2.0.0..." }),
        ]
    );
    assert!(p
        .backend
        .server
        .requests()
        .iter()
        .any(|request| request.url.starts_with("/channel_self") && request.json()["channel"] == "beta"));
}

#[test]
fn shake_menu_switch_channel_reports_each_outcome() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    // Already up to date.
    let result = switch_channel(&p, "beta");
    assert_eq!(
        result,
        json!({ "status": "success", "message": "Channel set to beta. Already on latest version." })
    );

    // Blocked.
    *p.backend.latest.lock().unwrap() =
        json!({ "error": "disabled_auto_update", "kind": "blocked", "message": "blocked by policy" });
    let result = switch_channel(&p, "beta");
    assert_eq!(
        result["message"],
        "Channel set to beta. Update check blocked: blocked by policy"
    );
    assert_eq!(result["status"], "error");

    // An update without a version.
    *p.backend.latest.lock().unwrap() = json!({ "url": format!("{}/b.zip", p.backend.server.url) });
    let result = switch_channel(&p, "beta");
    assert_eq!(
        result["message"],
        "Channel set to beta. Update check failed: missing version."
    );

    // Server error.
    *p.backend.latest.lock().unwrap() = json!({ "error": "server_down", "message": "try later" });
    let result = switch_channel(&p, "beta");
    assert_eq!(result["status"], "error");
    assert!(
        result["message"]
            .as_str()
            .unwrap()
            .starts_with("Channel set to beta. Update check failed: "),
        "{result}"
    );

    // Channel refused by the backend.
    *p.backend.channel_reply.lock().unwrap() = (
        400,
        json!({ "error": "channel_not_found", "message": "no such channel" }),
    );
    let result = switch_channel(&p, "nope");
    assert_eq!(result["status"], "error");
    assert!(
        result["message"]
            .as_str()
            .unwrap()
            .starts_with("Failed to set channel: "),
        "{result}"
    );
}

#[test]
fn shake_menu_switch_channel_reports_download_failures() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.backend.offer("2.0.0", web_bundle("two"));
    // The checksum no longer matches what is served.
    *p.backend.bundle.lock().unwrap() = web_bundle("tampered");
    let result = switch_channel(&p, "beta");
    assert_eq!(result["status"], "error");
    assert!(
        result["message"]
            .as_str()
            .unwrap()
            .starts_with("Failed to download update: "),
        "{result}"
    );
    assert!(p.t.call("bundleNext", json!({})).is_null(), "nothing is queued");
}

#[test]
fn apply_bundle_carries_the_ready_generation_script() {
    let p = Plugin::load(json!({ "autoUpdate": false }));
    p.t.install_bundle("abcdefghij", "2.0.0", "pending");
    p.resolve("set", json!({ "id": "abcdefghij" }));
    let hook = p.t.host.hooks_named("applyBundle").last().cloned().unwrap();
    let generation = hook["readyGeneration"].as_i64().unwrap();
    let script = hook["readyScript"].as_str().unwrap();
    assert!(script.starts_with(&format!("(function(){{window.__CAPGO_READY_GEN={generation};")));
    assert!(script.contains("next.loadGeneration=window.__CAPGO_READY_GEN"));
}
