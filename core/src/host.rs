//! What the updater engine needs from the platform it runs on.
//!
//! Everything else (network, file system, crypto, update decisions) is in
//! Rust. A host only provides persistence that already exists on user devices
//! (SharedPreferences / UserDefaults, kept for backward compatibility),
//! logging, event delivery to the app, and, where the OS owns TLS trust
//! (Android network security config), certificate verification.

use serde_json::Value;

use crate::engine::plugin::hooks::{CLEARTEXT_PERMITTED, PROXY_FOR_URL};

/// Payload flag of [`Host::emit_retained`] events: keep the event for listeners
/// registered after it fired. Hosts strip it from the payload.
pub const RETAIN_EVENT_KEY: &str = "__retainUntilConsumed";

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum LogLevel {
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3,
}

/// An HTTP proxy (plain HTTP to the proxy; HTTPS goes through `CONNECT`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct HttpProxy {
    pub host: String,
    pub port: u16,
}

impl HttpProxy {
    /// Parses a `proxyForUrl` hook reply: `{"type":"http","host":...,"port":...}`;
    /// `{"type":"direct"}` or anything else means no proxy.
    pub fn from_reply(reply: &Value) -> Option<Self> {
        if !reply.get("type")?.as_str()?.eq_ignore_ascii_case("http") {
            return None;
        }
        let host = reply.get("host")?.as_str()?.trim();
        let port = reply.get("port")?.as_u64()?;
        if host.is_empty() || !(1..=u64::from(u16::MAX)).contains(&port) {
            return None;
        }
        Some(Self {
            host: host.to_string(),
            port: port as u16,
        })
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

    /// Delivers an event the app must still receive when its listener is registered
    /// later (Capacitor `retainUntilConsumed`). Bridged hosts get it through [`emit`]
    /// with [`RETAIN_EVENT_KEY`] set in the payload and remove that key before delivery.
    ///
    /// [`emit`]: Host::emit
    fn emit_retained(&self, event: &str, payload: &Value) {
        let mut payload = payload.clone();
        if let Value::Object(object) = &mut payload {
            object.insert(RETAIN_EVENT_KEY.into(), Value::Bool(true));
        }
        self.emit(event, &payload);
    }

    /// Platform hook by name (see [`crate::engine::plugin::hooks`]): WebView,
    /// splash screen, loaders, alerts. `None` means "not handled".
    fn hook(&self, _name: &str, _payload: &Value) -> Option<Value> {
        None
    }

    /// Whether plain HTTP to `host` is allowed by the app (Android network
    /// security config, iOS App Transport Security). `None` (no answer) is
    /// treated as "not allowed".
    fn cleartext_permitted(&self, host: &str) -> Option<bool> {
        self.hook(CLEARTEXT_PERMITTED, &serde_json::json!({ "host": host }))
            .and_then(|reply| reply.get("permitted").and_then(Value::as_bool))
    }

    /// System HTTP proxy for `url` (Android `ProxySelector`, iOS system proxy
    /// settings), asked before every request; `None` connects directly.
    fn proxy_for_url(&self, url: &str) -> Option<HttpProxy> {
        HttpProxy::from_reply(&self.hook(PROXY_FOR_URL, &serde_json::json!({ "url": url }))?)
    }

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
    /// store (`server_name` lets platform policies such as pins apply; the
    /// engine checks the name itself too). `None` (no verifier) refuses every
    /// HTTPS connection: there is no built-in fallback.
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

/// In-memory host for tests.
#[cfg(any(test, feature = "test-support"))]
#[derive(Default)]
pub struct MemoryHost {
    pub store: std::sync::Mutex<std::collections::BTreeMap<String, String>>,
    pub events: std::sync::Mutex<Vec<(String, Value)>>,
    /// Names of the events emitted with [`Host::emit_retained`], in order.
    pub retained_events: std::sync::Mutex<Vec<String>>,
    pub logs: std::sync::Mutex<Vec<(LogLevel, String)>>,
    /// Hooks the engine called, in order.
    pub hooks: std::sync::Mutex<Vec<(String, Value)>>,
    /// Scripted hook replies by name.
    pub hook_replies: std::sync::Mutex<std::collections::BTreeMap<String, Value>>,
    /// Scripted TLS verdict; unset uses the test machine's trust store.
    pub certificate_verdict: std::sync::Mutex<Option<Option<Result<(), String>>>>,
    /// `(chain, server name)` of every TLS verification request.
    pub certificate_requests: std::sync::Mutex<Vec<(Vec<Vec<u8>>, String)>>,
}

#[cfg(any(test, feature = "test-support"))]
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

    /// How many `name` events were emitted with [`Host::emit_retained`].
    pub fn retained_count(&self, name: &str) -> usize {
        self.retained_events
            .lock()
            .unwrap()
            .iter()
            .filter(|event| *event == name)
            .count()
    }

    pub fn hooks_named(&self, name: &str) -> Vec<Value> {
        self.hooks
            .lock()
            .unwrap()
            .iter()
            .filter(|(hook, _)| hook == name)
            .map(|(_, payload)| payload.clone())
            .collect()
    }

    pub fn reply_to_hook(&self, name: &str, reply: Value) {
        self.hook_replies.lock().unwrap().insert(name.to_string(), reply);
    }
}

#[cfg(any(test, feature = "test-support"))]
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

    fn emit_retained(&self, event: &str, payload: &Value) {
        self.retained_events.lock().unwrap().push(event.to_string());
        self.emit(event, payload);
    }

    fn hook(&self, name: &str, payload: &Value) -> Option<Value> {
        self.hooks.lock().unwrap().push((name.to_string(), payload.clone()));
        self.hook_replies.lock().unwrap().get(name).cloned()
    }

    fn verify_server_certificate(&self, chain: &[&[u8]], server_name: &str) -> Option<Result<(), String>> {
        self.certificate_requests.lock().unwrap().push((
            chain.iter().map(|cert| cert.to_vec()).collect(),
            server_name.to_string(),
        ));
        if let Some(verdict) = self.certificate_verdict.lock().unwrap().clone() {
            return verdict;
        }
        #[cfg(feature = "test-support")]
        return Some(crate::net::platform_verify_for_tests(chain, server_name));
        #[cfg(not(feature = "test-support"))]
        None
    }

    /// Tests talk to local plain-HTTP servers: allowed unless a reply says otherwise.
    fn cleartext_permitted(&self, host: &str) -> Option<bool> {
        let reply = self.hook(CLEARTEXT_PERMITTED, &serde_json::json!({ "host": host }));
        Some(
            reply
                .and_then(|reply| reply.get("permitted").and_then(Value::as_bool))
                .unwrap_or(true),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Bridged {
        events: std::sync::Mutex<Vec<(String, Value)>>,
    }

    impl Host for Bridged {
        fn log(&self, _level: LogLevel, _message: &str) {}
        fn kv_get(&self, _key: &str, default: Option<&str>) -> Option<String> {
            default.map(str::to_string)
        }
        fn kv_set(&self, _key: &str, _value: Option<&str>) {}
        fn kv_keys(&self) -> Vec<String> {
            Vec::new()
        }
        fn emit(&self, event: &str, payload: &Value) {
            self.events.lock().unwrap().push((event.to_string(), payload.clone()));
        }
    }

    #[test]
    fn retained_events_reach_bridged_hosts_with_the_retain_flag() {
        let host = Bridged::default();
        host.emit_retained("set", &serde_json::json!({ "bundle": { "id": "abc" } }));
        host.emit("download", &serde_json::json!({ "percent": 5 }));
        let events = host.events.lock().unwrap();
        assert_eq!(events[0].1[RETAIN_EVENT_KEY], true);
        assert_eq!(events[0].1["bundle"]["id"], "abc");
        assert!(events[1].1.get(RETAIN_EVENT_KEY).is_none());
    }
}
