//! Regression: a config read kept across a host callback (or a second read) deadlocked as
//! soon as a config writer queued in between; every later call then hung, including the
//! ones hosts make on the main thread (an ANR on Android, a watchdog kill on iOS).
//! Own binary: a host whose storage read is slow widens the window deterministically.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

use capgo_updater_core::engine::Engine;
use capgo_updater_core::host::{Host, LogLevel, MemoryHost};
use serde_json::{json, Value};

static SLOW: AtomicBool = AtomicBool::new(false);

/// Storage reads of the fallback bundle pointer take 200 ms (I/O pressure).
struct SlowStorage(MemoryHost);

impl Host for SlowStorage {
    fn log(&self, level: LogLevel, message: &str) {
        self.0.log(level, message)
    }
    fn kv_get(&self, key: &str, default: Option<&str>) -> Option<String> {
        if key == "pastVersion" && SLOW.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(200));
        }
        self.0.kv_get(key, default)
    }
    fn kv_set(&self, key: &str, value: Option<&str>) {
        self.0.kv_set(key, value)
    }
    fn kv_keys(&self) -> Vec<String> {
        self.0.kv_keys()
    }
    fn emit(&self, event: &str, payload: &Value) {
        self.0.emit(event, payload)
    }
    fn hook(&self, name: &str, payload: &Value) -> Option<Value> {
        self.0.hook(name, payload)
    }
}

fn spawn_call(engine: &Arc<Engine>, op: &'static str, input: Value) -> mpsc::Receiver<()> {
    let (done, finished) = mpsc::channel();
    let engine = engine.clone();
    std::thread::spawn(move || {
        let _ = engine.call(op, &input);
        let _ = done.send(());
    });
    finished
}

#[test]
fn a_config_writer_during_a_reset_capture_does_not_hang_the_engine() {
    let dir = tempfile::tempdir().unwrap();
    let config = json!({
        "platform": "ios", "appId": "app.capgo.test", "pluginVersion": "8.0.0", "versionBuild": "1.0.0",
        "deviceId": "device-1",
        "bundleRoot": dir.path().join("versions").to_string_lossy(),
        "storageRoot": dir.path().to_string_lossy(),
    });
    let engine = Engine::new(Arc::new(SlowStorage(MemoryHost::default())), &config).unwrap();
    engine
        .call(
            "pluginLoad",
            &json!({
                "config": { "updateUrl": "http://127.0.0.1:9/u", "statsUrl": "", "autoUpdate": false },
                "native": { "versionName": "1.0.0" },
            }),
        )
        .unwrap();
    engine.wait_for_cleanup_for_tests();
    SLOW.store(true, Ordering::SeqCst);
    // The set / reload / reset / rollback path reads the fallback and next pointers...
    let capture = spawn_call(&engine, "bundleCaptureResetState", json!({}));
    std::thread::sleep(Duration::from_millis(50));
    // ...while a config writer (setChannel, setCustomId, preview toggles) queues.
    let writer = spawn_call(&engine, "configure", json!({ "customId": "x" }));
    let limit = Duration::from_secs(5);
    assert!(capture.recv_timeout(limit).is_ok(), "the reset capture hung");
    assert!(writer.recv_timeout(limit).is_ok(), "the config writer hung");
    SLOW.store(false, Ordering::SeqCst);
    // Main-thread calls keep answering.
    for op in ["appBackground", "reportMemoryWarning", "appTerminate"] {
        assert!(
            spawn_call(&engine, op, json!({})).recv_timeout(limit).is_ok(),
            "{op} hung"
        );
    }
}
