//! Launch, lifecycle, health and WebView statistics, and download progress events.

use serde_json::{json, Map, Value};

use super::keys;
use crate::bundle::BundleInfo;
use crate::engine::Engine;

const APP_SESSION_ID: &str = "CapacitorUpdater.appSessionId";
const APP_SESSION_FOREGROUND: &str = "CapacitorUpdater.appSessionForeground";
const APP_SESSION_STARTED_AT: &str = "CapacitorUpdater.appSessionStartedAt";
const LAST_REPORTED_UNCLEAN_SESSION: &str = "CapacitorUpdater.lastReportedUncleanSessionId";
const LAST_REPORTED_APP_EXIT: &str = "CapacitorUpdater.lastReportedAppExitTimestamp";
const LAST_RENDER_PROCESS_GONE: &str = "CapacitorUpdater.lastWebViewRenderProcessGone";

fn truncate(value: &str, max: usize) -> String {
    value.chars().take(max).collect()
}

fn is_sensitive_segment(segment: &str) -> bool {
    let all = |check: fn(char) -> bool| !segment.is_empty() && segment.chars().all(check);
    let uuid = segment.len() == 36
        && segment.char_indices().all(|(index, character)| match index {
            8 | 13 | 18 | 23 => character == '-',
            _ => character.is_ascii_hexdigit(),
        });
    (segment.len() >= 6 && all(|character| character.is_ascii_digit()))
        || (segment.len() >= 16 && all(|character| character.is_ascii_hexdigit()))
        || uuid
}

/// `%XX` escapes decoded (the previous plugins tested the decoded path, so an
/// encoded id is redacted too).
fn percent_decoded(segment: &str) -> String {
    let bytes = segment.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let hex = |offset: usize| bytes.get(index + offset).and_then(|byte| (*byte as char).to_digit(16));
        match (bytes[index], hex(1), hex(2)) {
            (b'%', Some(high), Some(low)) => {
                out.push((high * 16 + low) as u8);
                index += 3;
            }
            (byte, _, _) => {
                out.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn strip_query_and_fragment(value: &str) -> &str {
    let end = value.find(['?', '#']).unwrap_or(value.len());
    &value[..end]
}

/// Drops credentials, query and fragment; redacts id-like path segments.
pub fn sanitize_stats_url(value: &str) -> String {
    if value.is_empty() {
        return String::new();
    }
    if let Ok(url) = url::Url::parse(value) {
        if let Some(host) = url.host_str() {
            let path: Vec<String> = url
                .path()
                .split('/')
                .map(|segment| {
                    if is_sensitive_segment(&percent_decoded(segment)) {
                        "redacted".to_string()
                    } else {
                        segment.to_string()
                    }
                })
                .collect();
            let path = path.join("/");
            let port = url.port().map(|port| format!(":{port}")).unwrap_or_default();
            let path = if path == "/" && !value.contains(&format!("{host}{port}/")) {
                String::new()
            } else {
                path
            };
            return format!("{}://{host}{port}{path}", url.scheme());
        }
    }
    strip_query_and_fragment(value).to_string()
}

/// Stats metadata for a WebView error report (`reportWebViewError`).
pub fn webview_error_metadata(data: &Value) -> Map<String, Value> {
    let text = |key: &str| -> String {
        match data.get(key) {
            Some(Value::String(value)) => value.clone(),
            Some(Value::Number(value)) => value.to_string(),
            Some(Value::Bool(value)) => value.to_string(),
            _ => String::new(),
        }
    };
    let or = |key: &str, fallback: &str| {
        let value = text(key);
        if value.is_empty() {
            text(fallback)
        } else {
            value
        }
    };
    let error_type = {
        let value = text("type");
        if value.is_empty() {
            "javascript_error".to_string()
        } else {
            value
        }
    };
    let fields: [(&str, String, usize); 16] = [
        ("error_type", error_type, 64),
        ("message", text("message"), 1024),
        ("source", sanitize_stats_url(&text("source")), 512),
        ("line", or("line", "lineno"), 32),
        ("column", or("column", "colno"), 32),
        ("stack", text("stack"), 2048),
        ("tag_name", text("tag_name"), 64),
        ("href", sanitize_stats_url(&text("href")), 512),
        ("user_agent", text("user_agent"), 256),
        ("session_id", text("session_id"), 128),
        ("duration_ms", text("duration_ms"), 32),
        ("page_started_at", text("page_started_at"), 64),
        ("previous_session_id", text("previous_session_id"), 128),
        ("previous_href", sanitize_stats_url(&text("previous_href")), 512),
        ("previous_started_at", text("previous_started_at"), 64),
        ("previous_updated_at", text("previous_updated_at"), 64),
    ];
    let mut metadata = Map::new();
    for (key, value, max) in fields {
        if !value.is_empty() {
            metadata.insert(key.into(), json!(truncate(&value, max)));
        }
    }
    metadata
}

/// Android `ApplicationExitInfo.REASON_*` -> stats action (expected exits are ignored).
pub fn exit_reason_action(reason: i64) -> Option<&'static str> {
    match reason {
        4 => Some("app_crash"),
        5 => Some("app_crash_native"),
        6 => Some("app_anr"),
        3 => Some("app_killed_low_memory"),
        9 => Some("app_killed_excessive_resource_usage"),
        7 => Some("app_initialization_failure"),
        _ => None,
    }
}

pub fn exit_reason_name(reason: i64) -> &'static str {
    match reason {
        1 => "exit_self",
        2 => "signaled",
        3 => "low_memory",
        4 => "crash",
        5 => "crash_native",
        6 => "anr",
        7 => "initialization_failure",
        8 => "permission_change",
        9 => "excessive_resource_usage",
        10 => "user_requested",
        12 => "dependency_died",
        _ => "unknown",
    }
}

fn metadata_of(pairs: &[(&str, String)]) -> Map<String, Value> {
    pairs
        .iter()
        .map(|(key, value)| (key.to_string(), json!(value)))
        .collect()
}

impl Engine {
    fn stats_enabled(&self) -> bool {
        !self.config().stats_url.is_empty()
    }

    fn current_version_name(&self) -> String {
        self.current_bundle().version_name().to_string()
    }

    pub(crate) fn report_app_launch_start(&self) {
        let started_at = {
            let mut state = self.plugin_state();
            if state.launch_start_reported {
                return;
            }
            state.launch_start_reported = true;
            state.launch_started_at_ms
        };
        if !self.stats_enabled() {
            return;
        }
        let metadata = metadata_of(&[
            ("launch_started_at", started_at.to_string()),
            ("source", "plugin_load".into()),
        ]);
        self.send_stats(
            "app_launch_start",
            Some(&self.current_version_name()),
            Some(""),
            Some(&metadata),
        );
    }

    pub(crate) fn report_app_launch_ready(&self, bundle: &BundleInfo) {
        let started_at = {
            let mut state = self.plugin_state();
            if state.launch_ready_reported || state.launch_timeout_reported {
                return;
            }
            state.launch_ready_reported = true;
            state.launch_started_at_ms
        };
        if !self.stats_enabled() {
            return;
        }
        let metadata = metadata_of(&[
            ("duration_ms", (super::now_ms() - started_at).max(0).to_string()),
            ("launch_started_at", started_at.to_string()),
            ("source", "notify_app_ready".into()),
        ]);
        self.send_stats(
            "app_launch_ready",
            Some(bundle.version_name()),
            Some(""),
            Some(&metadata),
        );
    }

    pub(crate) fn report_app_launch_timeout(&self, bundle: &BundleInfo) {
        let started_at = {
            let mut state = self.plugin_state();
            if state.launch_ready_reported || state.launch_timeout_reported {
                return;
            }
            state.launch_timeout_reported = true;
            state.launch_started_at_ms
        };
        if !self.stats_enabled() {
            return;
        }
        let metadata = metadata_of(&[
            ("duration_ms", (super::now_ms() - started_at).max(0).to_string()),
            ("launch_started_at", started_at.to_string()),
            ("timeout_ms", self.app_ready_check_timeout().as_millis().to_string()),
            ("source", "app_ready_timeout".into()),
        ]);
        self.send_stats(
            "app_launch_timeout",
            Some(bundle.version_name()),
            Some(""),
            Some(&metadata),
        );
    }

    /// Sends `event` and applies `writes` once the server acknowledged it.
    fn send_stats_then_persist(
        &self,
        action: &str,
        metadata: &Map<String, Value>,
        writes: Vec<(String, Option<String>)>,
    ) {
        let callback_id = format!("capgo-ack-{}", super::super::store::random_id());
        self.stats.acks.lock().unwrap().insert(callback_id.clone(), writes);
        self.send_stats_with_callback(
            action,
            Some(&self.current_version_name()),
            Some(""),
            Some(metadata),
            Some(callback_id),
        );
    }

    /// `os_version_changed` / `native_app_version_changed`; a changed snapshot is
    /// persisted only once its event was delivered.
    pub(crate) fn report_native_version_stats_if_changed(&self) {
        let config = self.config().clone();
        let version_build = config.version_build.clone();
        let version_code = if config.version_code.is_empty() {
            self.plugin_config().native_build
        } else {
            config.version_code.clone()
        };
        let version_os = config.version_os.clone();
        let previous_os = self.kv_text(keys::LAST_VERSION_OS).unwrap_or_default();
        let previous_build = self.kv_text(keys::LAST_VERSION_BUILD).unwrap_or_default();
        let previous_code = self.kv_text(keys::LAST_VERSION_CODE).unwrap_or_default();

        let os_changed = !version_os.is_empty() && !previous_os.is_empty() && previous_os != version_os;
        if os_changed {
            let metadata = metadata_of(&[
                ("previous_version_os", previous_os.clone()),
                ("current_version_os", version_os.clone()),
            ]);
            self.send_stats_then_persist(
                "os_version_changed",
                &metadata,
                vec![(keys::LAST_VERSION_OS.into(), Some(version_os.clone()))],
            );
        }
        let has_previous_native = !previous_build.is_empty() || !previous_code.is_empty();
        let native_changed = has_previous_native && (previous_build != version_build || previous_code != version_code);
        if native_changed {
            let metadata = metadata_of(&[
                ("previous_version_build", previous_build),
                ("current_version_build", version_build.clone()),
                ("previous_version_code", previous_code),
                ("current_version_code", version_code.clone()),
            ]);
            self.send_stats_then_persist(
                "native_app_version_changed",
                &metadata,
                vec![
                    (keys::LAST_VERSION_BUILD.into(), Some(version_build.clone())),
                    (keys::LAST_VERSION_CODE.into(), Some(version_code.clone())),
                ],
            );
        }
        if !os_changed {
            self.kv_write(keys::LAST_VERSION_OS, Some(&version_os));
        }
        if !native_changed {
            self.kv_write(keys::LAST_VERSION_BUILD, Some(&version_build));
            self.kv_write(keys::LAST_VERSION_CODE, Some(&version_code));
        }
    }

    /// Sends a stats event; URL fields (`href`, `source`, `previous_href`) are sanitized.
    pub(crate) fn report_webview_stats(&self, action: &str, metadata: &Map<String, Value>) {
        let mut metadata = metadata.clone();
        for key in ["href", "source", "previous_href"] {
            if let Some(url) = metadata.get(key).and_then(Value::as_str).map(str::to_string) {
                metadata.insert(key.into(), json!(truncate(&sanitize_stats_url(&url), 512)));
            }
        }
        self.send_stats(action, Some(&self.current_version_name()), Some(""), Some(&metadata));
    }

    /// `reportWebViewError` from the injected page script.
    pub(crate) fn report_webview_error(&self, data: &Value) {
        let error_type = data
            .get("type")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .unwrap_or("javascript_error");
        let action = crate::policy::stats_action_for_webview_error_type(error_type);
        self.report_webview_stats(action, &webview_error_metadata(data));
    }

    /// Android process exits (`ApplicationExitInfo`, newest first) not reported yet.
    pub(crate) fn report_previous_exits(&self, exits: &[Value]) {
        if !self.stats_enabled() {
            return;
        }
        let last_reported: i64 = self
            .kv_text(LAST_REPORTED_APP_EXIT)
            .and_then(|value| value.parse().ok())
            .unwrap_or(0);
        let mut newest = last_reported;
        for exit in exits.iter().take(8) {
            let number = |key: &str| exit.get(key).and_then(Value::as_i64).unwrap_or(0);
            let timestamp = number("timestamp");
            if timestamp <= last_reported {
                continue;
            }
            let reason = number("reason");
            let Some(action) = exit_reason_action(reason) else {
                continue;
            };
            let mut metadata = metadata_of(&[
                ("exit_reason", exit_reason_name(reason).into()),
                ("exit_reason_code", reason.to_string()),
                ("exit_status", number("status").to_string()),
                ("exit_importance", number("importance").to_string()),
                ("exit_timestamp", timestamp.to_string()),
                ("pid", number("pid").to_string()),
                ("pss_kb", number("pss").to_string()),
                ("rss_kb", number("rss").to_string()),
            ]);
            for (key, source, max) in [
                ("process_name", "processName", 128),
                ("exit_description", "description", 512),
            ] {
                if let Some(value) = exit
                    .get(source)
                    .and_then(Value::as_str)
                    .filter(|value| !value.is_empty())
                {
                    metadata.insert(key.into(), json!(truncate(value, max)));
                }
            }
            self.report_webview_stats(action, &metadata);
            newest = newest.max(timestamp);
        }
        if newest > last_reported {
            self.kv_write(LAST_REPORTED_APP_EXIT, Some(&newest.to_string()));
        }
    }

    /// Session markers (iOS): a session that was in the foreground and never
    /// reached background/terminate ended in a crash.
    pub(crate) fn report_previous_unclean_exit_and_start_session(&self) {
        let previous = self.kv_text(APP_SESSION_ID).filter(|id| !id.is_empty());
        let last_reported = self.kv_text(LAST_REPORTED_UNCLEAN_SESSION);
        let was_foreground = self.kv_flag(APP_SESSION_FOREGROUND).unwrap_or(false);
        if let Some(previous) = previous.filter(|previous| was_foreground && Some(previous) != last_reported.as_ref()) {
            let mut metadata = metadata_of(&[
                ("exit_reason", "unclean_foreground_exit".into()),
                ("exit_source", "ios_session_marker".into()),
                ("previous_session_id", previous.clone()),
            ]);
            if let Some(started) = self.kv_text(APP_SESSION_STARTED_AT).filter(|value| !value.is_empty()) {
                metadata.insert("session_started_at".into(), json!(started));
            }
            self.report_webview_stats("app_crash", &metadata);
            self.kv_write(LAST_REPORTED_UNCLEAN_SESSION, Some(&previous));
        }
        let session = format!("{}-{}", super::super::store::random_id(), super::now_ms());
        self.kv_write(APP_SESSION_ID, Some(&session));
        self.kv_write_flag(APP_SESSION_FOREGROUND, true);
        self.kv_write(APP_SESSION_STARTED_AT, Some(&super::now_ms().to_string()));
    }

    pub(crate) fn mark_session_foreground(&self, foreground: bool) {
        if self.plugin_state().config.track_unclean_exits() {
            self.kv_write_flag(APP_SESSION_FOREGROUND, foreground);
        }
    }

    pub(crate) fn report_memory_warning(&self) {
        let metadata = metadata_of(&[("source", "ios_memory_warning".into())]);
        self.report_webview_stats("app_memory_warning", &metadata);
    }

    /// Android WebView renderer crash: persisted now, reported at next launch.
    pub(crate) fn persist_render_process_gone(&self, metadata: &Value) {
        self.kv_write(LAST_RENDER_PROCESS_GONE, Some(&metadata.to_string()));
    }

    pub(crate) fn report_previous_render_process_gone(&self) {
        let Some(raw) = self.kv_text(LAST_RENDER_PROCESS_GONE) else {
            return;
        };
        self.kv_write(LAST_RENDER_PROCESS_GONE, None);
        let Ok(Value::Object(stored)) = serde_json::from_str::<Value>(&raw) else {
            return;
        };
        let mut metadata: Map<String, Value> = stored
            .into_iter()
            .map(|(key, value)| {
                let text = value.as_str().map_or_else(|| value.to_string(), str::to_string);
                (key, json!(text))
            })
            .collect();
        metadata.insert("reported_after_restart".into(), json!("true"));
        self.report_webview_stats("webview_render_process_gone", &metadata);
    }

    /// Download progress: `download` events, `downloadComplete` and bucketed stats.
    pub(crate) fn notify_download(&self, id: &str, percent: i64) {
        let bundle = self.get_bundle_info(Some(id));
        self.host
            .emit("download", &json!({ "percent": percent, "bundle": bundle.to_js() }));
        if percent >= 100 {
            self.emit_bundle_event("downloadComplete", &bundle);
            self.send_stats("download_complete", Some(bundle.version_name()), None, None);
            self.plugin_state().last_notified_stat_percent.remove(id);
            return;
        }
        let bucket = (percent / 10) * 10;
        let should_send = {
            // Per download: concurrent downloads must not suppress each other's buckets.
            let mut state = self.plugin_state();
            let last = state.last_notified_stat_percent.entry(id.to_string()).or_insert(0);
            if percent == 0 {
                *last = 0;
            }
            if bucket > *last {
                *last = bucket;
                true
            } else {
                false
            }
        };
        if should_send {
            self.send_stats(&format!("download_{bucket}"), Some(bundle.version_name()), None, None);
        }
    }

    /// A download failed: its progress buckets go (new attempts get new ids).
    pub(crate) fn forget_download_progress(&self, id: &str) {
        self.plugin_state().last_notified_stat_percent.remove(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_urls() {
        assert_eq!(
            sanitize_stats_url("https://user:pw@example.com:8443/a/1234567/b?token=x#frag"),
            "https://example.com:8443/a/redacted/b"
        );
        assert_eq!(
            sanitize_stats_url("https://example.com/u/0123456789abcdef0123/x"),
            "https://example.com/u/redacted/x"
        );
        assert_eq!(
            sanitize_stats_url("capacitor://localhost/123e4567-e89b-12d3-a456-426614174000"),
            "capacitor://localhost/redacted"
        );
        assert_eq!(sanitize_stats_url("not a url?x=1"), "not a url");
        assert_eq!(sanitize_stats_url("https://example.com"), "https://example.com");
        // Cases from the former Android page-load sanitizer.
        assert_eq!(
            sanitize_stats_url("https://user:pass@app.example.com/users/123456789/profile?token=secret#frag"),
            "https://app.example.com/users/redacted/profile"
        );
        assert_eq!(sanitize_stats_url("http://localhost/?a=1"), "http://localhost/");
        assert_eq!(sanitize_stats_url("not a url?secret=1"), "not a url");
        assert_eq!(sanitize_stats_url(""), "");
        // Encoded ids are redacted like plain ones; other segments keep their encoding.
        assert_eq!(
            sanitize_stats_url("https://example.com/u/%31%32%33%34%35%36%37/a%20b"),
            "https://example.com/u/redacted/a%20b"
        );
        assert_eq!(
            sanitize_stats_url("https://example.com/%31%32%33e4567-e89b-12d3-a456-426614174000"),
            "https://example.com/redacted"
        );
    }

    #[test]
    fn webview_metadata_truncates_and_falls_back() {
        let metadata =
            webview_error_metadata(&json!({ "message": "x".repeat(2000), "lineno": 12, "href": "https://a.b/c?q" }));
        assert_eq!(metadata["error_type"], "javascript_error");
        assert_eq!(metadata["message"].as_str().unwrap().len(), 1024);
        assert_eq!(metadata["line"], "12");
        assert_eq!(metadata["href"], "https://a.b/c");
        assert!(!metadata.contains_key("stack"));
    }

    /// Two downloads in parallel each report their own progress buckets.
    #[test]
    fn progress_buckets_are_tracked_per_download() {
        let dir = tempfile::tempdir().unwrap();
        let engine = Engine::new(
            std::sync::Arc::new(crate::host::MemoryHost::default()),
            &json!({
                "bundleRoot": dir.path().join("versions").to_string_lossy(),
                "statsUrl": "http://127.0.0.1:1/stats",
            }),
        )
        .unwrap();
        for (id, percent) in [
            ("a", 0),
            ("a", 10),
            ("b", 0),
            ("b", 10),
            ("a", 25),
            ("b", 25),
            ("b", 26),
        ] {
            engine.notify_download(id, percent);
        }
        let actions: Vec<String> = engine
            .stats
            .queue
            .lock()
            .unwrap()
            .iter()
            .map(|queued| queued.event["action"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(actions, ["download_10", "download_10", "download_20", "download_20"]);
        // Failed downloads leave no progress entry behind.
        engine.fail_download(
            &crate::bundle::BundleInfo::new(
                "a",
                Some("1.0.0".into()),
                crate::bundle::BundleStatus::Downloading,
                "",
                "",
            ),
            &crate::error::CoreError::new("network_error", "lost"),
            false,
        );
        assert_eq!(
            engine
                .plugin_state()
                .last_notified_stat_percent
                .keys()
                .collect::<Vec<_>>(),
            ["b"]
        );
    }

    #[test]
    fn exit_reasons() {
        assert_eq!(exit_reason_action(4), Some("app_crash"));
        assert_eq!(exit_reason_action(1), None);
        assert_eq!(exit_reason_name(11), "unknown");
    }
}
