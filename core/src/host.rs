//! What the updater engine needs from the platform it runs on.
//!
//! Everything else (network, file system, crypto, update decisions) is in
//! Rust. A host only provides persistence that already exists on user devices
//! (SharedPreferences / UserDefaults, kept for backward compatibility),
//! logging, event delivery to the app, and, where the OS owns TLS trust
//! (Android network security config), certificate verification.

use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum LogLevel {
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3,
}

impl LogLevel {
    pub fn from_i32(value: i32) -> Self {
        match value {
            0 => LogLevel::Debug,
            1 => LogLevel::Info,
            2 => LogLevel::Warn,
            _ => LogLevel::Error,
        }
    }
}

/// Platform services used by the engine. Implementations must be thread-safe:
/// the engine calls them from download and stats worker threads.
pub trait Host: Send + Sync + 'static {
    fn log(&self, level: LogLevel, message: &str);

    /// Reads a persisted string value, `default` when absent (the default is
    /// passed through so hosts can keep their historical storage calls).
    fn kv_get(&self, key: &str, default: Option<&str>) -> Option<String>;

    /// True when `key` is persisted.
    fn kv_contains(&self, key: &str) -> bool {
        self.kv_get(key, None).is_some()
    }

    /// Persists (`Some`) or removes (`None`) a string value, durably.
    fn kv_set(&self, key: &str, value: Option<&str>);

    /// Every persisted key (used to enumerate `<id>_info` bundle records).
    fn kv_keys(&self) -> Vec<String>;

    /// Delivers an event (`download`, `updateAvailable`, ...) to the app.
    fn emit(&self, event: &str, payload: &Value);

    /// Called right before the current bundle path changes (Android reschedules
    /// Background Runner work here).
    fn will_switch_bundle(&self, _path: &str) {}

    /// Cancels a platform-scheduled download of `version` (Android WorkManager)
    /// and waits for it; `false` when it could not be cancelled.
    fn cancel_version_download(&self, _version: &str) -> bool {
        true
    }

    /// Gate run before any download touches disk (e.g. wait for launch cleanup).
    fn before_download(&self) -> Result<(), String> {
        Ok(())
    }

    /// Cancels every platform-scheduled download.
    fn cancel_all_downloads(&self) {}

    /// Lets the host observe (and route) statistics the engine emits itself.
    /// Returns `true` when the host queued the event (by calling the `statsSend`
    /// operation); `false` makes the engine queue it directly.
    fn send_stats(&self, _action: &str, _version_name: &str, _old_version_name: &str) -> bool {
        false
    }

    /// Verifies a TLS server chain (DER, leaf first) with the platform trust
    /// store. `None` means "not handled here": the engine then uses its
    /// built-in platform verifier.
    fn verify_server_certificate(&self, _chain: &[&[u8]], _server_name: &str) -> Option<Result<(), String>> {
        None
    }
}

/// Convenience logging helpers.
pub trait HostLog {
    fn debug(&self, message: impl AsRef<str>);
    fn info(&self, message: impl AsRef<str>);
    fn warn(&self, message: impl AsRef<str>);
    fn error(&self, message: impl AsRef<str>);
}

impl<T: Host + ?Sized> HostLog for T {
    fn debug(&self, message: impl AsRef<str>) {
        self.log(LogLevel::Debug, message.as_ref());
    }
    fn info(&self, message: impl AsRef<str>) {
        self.log(LogLevel::Info, message.as_ref());
    }
    fn warn(&self, message: impl AsRef<str>) {
        self.log(LogLevel::Warn, message.as_ref());
    }
    fn error(&self, message: impl AsRef<str>) {
        self.log(LogLevel::Error, message.as_ref());
    }
}

/// In-memory host for tests and for embedding the engine in tools.
#[derive(Default)]
pub struct MemoryHost {
    pub store: std::sync::Mutex<std::collections::BTreeMap<String, String>>,
    pub events: std::sync::Mutex<Vec<(String, Value)>>,
    pub logs: std::sync::Mutex<Vec<(LogLevel, String)>>,
}

impl MemoryHost {
    pub fn events_named(&self, name: &str) -> Vec<Value> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter(|(event, _)| event == name)
            .map(|(_, payload)| payload.clone())
            .collect()
    }
}

impl Host for MemoryHost {
    fn log(&self, level: LogLevel, message: &str) {
        self.logs.lock().unwrap().push((level, message.to_string()));
    }

    fn kv_get(&self, key: &str, default: Option<&str>) -> Option<String> {
        self.store
            .lock()
            .unwrap()
            .get(key)
            .cloned()
            .or_else(|| default.map(str::to_string))
    }

    fn kv_set(&self, key: &str, value: Option<&str>) {
        let mut store = self.store.lock().unwrap();
        match value {
            Some(value) => {
                store.insert(key.to_string(), value.to_string());
            }
            None => {
                store.remove(key);
            }
        }
    }

    fn kv_keys(&self) -> Vec<String> {
        self.store.lock().unwrap().keys().cloned().collect()
    }

    fn emit(&self, event: &str, payload: &Value) {
        self.events.lock().unwrap().push((event.to_string(), payload.clone()));
    }
}
