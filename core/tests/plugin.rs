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
                "/b.zip" => (200, vec![], b.lock().unwrap().clone()),
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
    let next = p.resolve("getNextBundle", json!({}));
    assert_eq!(next["version"], "2.0.0");
    assert!(p.events("download").iter().any(|event| event["percent"] == 100));

    p.background();
    let set = p.wait_for_event("set", 1);
    assert_eq!(set[0]["bundle"]["version"], "2.0.0");
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
    assert_eq!(p.resolve("getNextBundle", json!({})), Value::Null);
    assert!(p.events("noNeedUpdate").is_empty());
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
    let p = Plugin::load(json!({ "autoUpdate": false }));
    assert_eq!(p.resolve("triggerUpdateCheck", json!({}))["status"], "unavailable");
    let p = Plugin::load(json!({}));
    let first = p.resolve("triggerUpdateCheck", json!({}));
    assert_eq!(first["status"], "queued");
    assert_eq!(first["queued"], true);
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
    assert_eq!(p.resolve("triggerUpdateCheck", json!({}))["status"], "unavailable");
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
        json!({ "action": "webview_page_loaded", "metadata": { "href": "https://a.b/p/1234567?t=1", "source": "android_webview_listener" } }),
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
