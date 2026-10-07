//! Capgo backend client: update checks, channels, bundle size, and the
//! process-wide 429 (rate limit) block shared by every request.

use crate::sync::LockRecover;
use std::sync::Mutex;

use serde_json::{json, Map, Value};

use super::Engine;
use crate::host::HostLog;
use crate::net::Response;

struct RateLimitState {
    blocked_until_ms: i64,
    error: String,
    message: String,
    statistic_sent: bool,
}

// Process-wide like the previous static fields: every engine (plugin, download
// workers) honours the same Retry-After window.
static RATE_LIMIT: Mutex<RateLimitState> = Mutex::new(RateLimitState {
    blocked_until_ms: 0,
    error: String::new(),
    message: String::new(),
    statistic_sent: false,
});

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default()
}

pub struct RemoteBlock {
    pub blocked: bool,
    pub error: String,
    pub message: String,
}

type Json = Map<String, Value>;

fn error_map(error: &str, message: impl Into<String>) -> Json {
    let mut map = Json::new();
    map.insert("error".into(), json!(error));
    map.insert("message".into(), json!(message.into()));
    map
}

impl Engine {
    /// Device/app facts sent with every backend request.
    pub fn info_object(&self, app_id_override: Option<&str>) -> Json {
        let config = self.config().clone();
        let mut info = Json::new();
        info.insert("platform".into(), json!(config.platform));
        info.insert("device_id".into(), json!(config.device_id));
        let app_id = app_id_override
            .filter(|id| !id.trim().is_empty())
            .unwrap_or(&config.app_id);
        info.insert("app_id".into(), json!(app_id));
        info.insert("custom_id".into(), json!(config.custom_id));
        info.insert("version_build".into(), json!(config.version_build));
        info.insert("version_code".into(), json!(config.version_code));
        info.insert("version_os".into(), json!(config.version_os));
        info.insert("version_name".into(), json!(self.current_bundle().version_name()));
        info.insert("plugin_version".into(), json!(config.plugin_version));
        info.insert("is_emulator".into(), json!(config.is_emulator));
        info.insert("is_prod".into(), json!(config.is_prod));
        info.insert("install_source".into(), json!(config.install_source));
        info.insert("defaultChannel".into(), json!(config.default_channel));
        if !config.key_id.is_empty() {
            info.insert("key_id".into(), json!(config.key_id));
        }
        info
    }

    pub fn is_remote_blocked(&self) -> bool {
        let mut state = RATE_LIMIT.lock_or_recover();
        if state.blocked_until_ms <= 0 {
            return false;
        }
        if now_ms() >= state.blocked_until_ms {
            state.blocked_until_ms = 0;
            return false;
        }
        true
    }

    fn remote_blocked_error(&self) -> Json {
        let state = RATE_LIMIT.lock_or_recover();
        let error = if state.error.is_empty() {
            "too_many_requests"
        } else {
            &state.error
        };
        let message = if state.message.is_empty() {
            "Too many requests"
        } else {
            &state.message
        };
        error_map(error, message)
    }

    /// Handles a 429: records the Retry-After block (longest wins) and sends
    /// the `rate_limit_reached` statistic once.
    pub(crate) fn handle_rate_limit(&self, response: &Response) -> RemoteBlock {
        if response.status != 429 {
            return RemoteBlock {
                blocked: false,
                error: String::new(),
                message: String::new(),
            };
        }
        let body = response.text();
        let (parsed_error, parsed_message) = crate::http::parse_remote_error(Some(&body));
        let error = if parsed_error.is_empty() {
            "too_many_requests".to_string()
        } else {
            parsed_error
        };
        let message = if parsed_message.is_empty() {
            "Too many requests".to_string()
        } else {
            parsed_message
        };
        let now = now_ms();
        let until = crate::http::rate_limit_blocked_until_ms(response.header("Retry-After"), Some(&body), now);
        let claim = {
            let mut state = RATE_LIMIT.lock_or_recover();
            if until > state.blocked_until_ms {
                state.blocked_until_ms = until;
                state.error = error.clone();
                state.message = message.clone();
            } else if state.blocked_until_ms <= 0 {
                state.error = error.clone();
                state.message = message.clone();
            }
            let config = self.config();
            let claim = error == "too_many_requests"
                && !config.preview_session
                && !config.stats_url.is_empty()
                && !state.statistic_sent;
            if claim {
                state.statistic_sent = true;
            }
            claim
        };
        if claim {
            self.send_rate_limit_statistic();
        }
        let retry_after = ((until.max(now) - now + 999) / 1000).max(0);
        self.host.warn(format!(
            "Received 429 ({error}). Honouring Retry-After: {retry_after}s."
        ));
        RemoteBlock {
            blocked: true,
            error,
            message,
        }
    }

    fn send_rate_limit_statistic(&self) {
        let stats_url = self.config().stats_url.clone();
        let release = || RATE_LIMIT.lock_or_recover().statistic_sent = false;
        if stats_url.is_empty() {
            release();
            return;
        }
        let mut event = self.info_object(None);
        event.insert("version_name".into(), json!(self.current_bundle().version_name()));
        event.insert("old_version_name".into(), json!(""));
        event.insert("action".into(), json!("rate_limit_reached"));
        let Some(engine) = self.weak_self().upgrade() else {
            release();
            return;
        };
        self.spawn("stats", move || {
            match engine.http.post_json(&stats_url, &Value::Object(event)) {
                Ok(response) if response.is_success() => engine.host.info("Rate limit statistic sent"),
                Ok(response) => {
                    release();
                    engine.host.error("Error sending rate limit statistic");
                    engine.host.debug(format!("Response code: {}", response.status));
                }
                Err(error) => {
                    release();
                    engine.host.error("Failed to send rate limit statistic");
                    engine.host.debug(format!("Error: {error}"));
                }
            }
        });
    }

    /// POSTs `body` and normalizes the reply like every previous plugin version:
    /// errors carry `error`, `message`, `kind` and `statusCode`; success returns the
    /// JSON fields (with `session_key` renamed `sessionKey`) plus `statusCode`.
    /// A JSON reply with `error` or `kind` keeps every other server field too
    /// (`breaking`, `major`, `link`, `comment`, `data`, `manifest`, ...).
    fn json_request(&self, url: &str, body: &Json) -> Json {
        let response = match self.http.post_json(url, &Value::Object(body.clone())) {
            Ok(response) => response,
            Err(error) => {
                let mut ret = error_map("network_error", format!("Request failed: {error}"));
                ret.insert("kind".into(), json!("failed"));
                return ret;
            }
        };
        let status = response.status;
        let parsed = response.json().and_then(|value| value.as_object().cloned());
        if let Some(object) = parsed
            .as_ref()
            .filter(|object| object.contains_key("error") || object.contains_key("kind"))
        {
            let text = |key: &str| {
                object
                    .get(key)
                    .filter(|value| !value.is_null())
                    .map(|value| value.as_str().map_or_else(|| value.to_string(), str::to_string))
            };
            let mut ret = Json::new();
            for (key, value) in object {
                match key.as_str() {
                    "error" | "kind" | "message" | "version" | "statusCode" => {}
                    "session_key" => {
                        ret.insert("sessionKey".into(), value.clone());
                    }
                    _ => {
                        ret.insert(key.clone(), value.clone());
                    }
                }
            }
            if status == 429 {
                let block = self.handle_rate_limit(&response);
                ret.insert(
                    "error".into(),
                    json!(if block.error.is_empty() {
                        text("error").unwrap_or_else(|| "too_many_requests".into())
                    } else {
                        block.error
                    }),
                );
                ret.insert(
                    "message".into(),
                    json!(if block.message.is_empty() {
                        text("message").unwrap_or_else(|| "Too many requests".into())
                    } else {
                        block.message
                    }),
                );
                ret.insert("kind".into(), json!(text("kind").unwrap_or_else(|| "failed".into())));
            } else {
                if let Some(error) = text("error") {
                    ret.insert("error".into(), json!(error));
                }
                if let Some(kind) = text("kind") {
                    ret.insert("kind".into(), json!(kind));
                }
                ret.insert(
                    "message".into(),
                    json!(text("message").unwrap_or_else(|| "server did not provide a message".into())),
                );
            }
            if let Some(version) = text("version") {
                ret.insert("version".into(), json!(version));
            }
            ret.insert("statusCode".into(), json!(status));
            return ret;
        }
        let block = self.handle_rate_limit(&response);
        if block.blocked {
            let mut ret = error_map(&block.error, block.message);
            ret.insert("kind".into(), json!("failed"));
            ret.insert("statusCode".into(), json!(status));
            return ret;
        }
        if !response.is_success() {
            // Keep the server's explanation when the error body only carries a message.
            let message = parsed
                .as_ref()
                .and_then(|object| object.get("message"))
                .and_then(Value::as_str)
                .filter(|message| !message.is_empty())
                .map_or_else(|| format!("Server error: {status}"), str::to_string);
            let mut ret = error_map("response_error", message);
            ret.insert("kind".into(), json!("failed"));
            ret.insert("statusCode".into(), json!(status));
            return ret;
        }
        let Some(object) = parsed else {
            let mut ret = error_map("parse_error", "JSON parse error: Response is not a JSON object");
            ret.insert("kind".into(), json!("failed"));
            return ret;
        };
        let mut ret = Json::new();
        ret.insert("statusCode".into(), json!(status));
        for (key, value) in object {
            if key == "session_key" {
                ret.insert("sessionKey".into(), value);
            } else {
                ret.insert(key, value);
            }
        }
        ret
    }

    /// Asks the backend for the latest bundle of this device's channel.
    pub fn get_latest(&self, update_url: Option<&str>, channel: Option<&str>, app_id_override: Option<&str>) -> Json {
        if self.is_remote_blocked() {
            let mut ret = self.remote_blocked_error();
            self.host
                .debug(format!("Skipping getLatest due to remote block ({}).", ret["error"]));
            ret.insert("kind".into(), json!("failed"));
            return ret;
        }
        let mut info = self.info_object(app_id_override);
        if let Some(channel) = channel {
            info.insert("defaultChannel".into(), json!(channel));
        }
        self.host
            .info(format!("Auto-update parameters: {}", Value::Object(info.clone())));
        let url = update_url
            .map(str::to_string)
            .unwrap_or_else(|| self.config().update_url.clone());
        self.json_request(&url, &info)
    }

    fn channel_url(&self, missing_message: &str) -> Result<String, Json> {
        let url = self.config().channel_url.clone();
        if url.is_empty() {
            self.host.error("Channel URL is not set");
            return Err(error_map("missing_config", missing_message));
        }
        Ok(url)
    }

    fn persist_default_channel(&self, key: Option<&str>, channel: Option<&str>) {
        if let Some(key) = key.filter(|key| !key.is_empty()) {
            self.host.kv_set(key, channel);
        }
    }

    pub fn unset_channel(
        &self,
        persist_key: Option<&str>,
        config_default_channel: &str,
        allow_set_default_channel: bool,
    ) -> Json {
        if !allow_set_default_channel {
            self.host
                .error("unsetChannel is disabled by allowSetDefaultChannel config");
            return error_map("disabled_by_config", "unsetChannel is disabled by configuration");
        }
        self.persist_default_channel(persist_key, None);
        self.config_mut().default_channel = config_default_channel.to_string();
        self.host.info(format!(
            "Persisted defaultChannel cleared, reverted to config value: {config_default_channel}"
        ));
        let mut ret = Json::new();
        ret.insert("status".into(), json!("ok"));
        ret.insert("message".into(), json!("Channel override removed"));
        ret
    }

    pub fn set_channel(
        &self,
        channel: &str,
        persist_key: Option<&str>,
        allow_set_default_channel: bool,
        config_default_channel: &str,
    ) -> Json {
        if !allow_set_default_channel {
            self.host
                .error("setChannel is disabled by allowSetDefaultChannel config");
            return error_map("disabled_by_config", "setChannel is disabled by configuration");
        }
        if self.is_remote_blocked() {
            return self.remote_blocked_error();
        }
        let url = match self.channel_url("channelUrl missing") {
            Ok(url) => url,
            Err(error) => return error,
        };
        let mut info = self.info_object(None);
        info.insert("channel".into(), json!(channel));
        let res = self.json_request(&url, &info);
        if res.contains_key("error") {
            return res;
        }
        if res.get("unset").and_then(Value::as_bool) == Some(true) {
            self.persist_default_channel(persist_key, None);
            self.config_mut().default_channel = config_default_channel.to_string();
            self.host.info("Public channel requested, channel override removed");
        } else {
            self.config_mut().default_channel = channel.to_string();
            self.persist_default_channel(persist_key, Some(channel));
            self.host.info(format!("defaultChannel persisted locally: {channel}"));
        }
        res
    }

    pub fn get_channel(&self, persist_key: Option<&str>) -> Json {
        if self.is_remote_blocked() {
            return self.remote_blocked_error();
        }
        let url = match self.channel_url("Channel URL is not set") {
            Ok(url) => url,
            Err(error) => return error,
        };
        let info = self.info_object(None);
        let response = match self.http.send_json("PUT", &url, &Value::Object(info)) {
            Ok(response) => response,
            Err(error) => return error_map("network_error", format!("Request failed: {error}")),
        };
        let block = self.handle_rate_limit(&response);
        if block.blocked {
            return error_map(&block.error, block.message);
        }
        let body = response.text();
        let default_channel = self.config().default_channel.clone();
        if response.status == 400 && body.contains("channel_not_found") && !default_channel.is_empty() {
            let mut ret = Json::new();
            ret.insert("channel".into(), json!(default_channel));
            ret.insert("status".into(), json!("default"));
            return ret;
        }
        if !response.is_success() {
            return Self::channel_status_error(&response);
        }
        if body.is_empty() {
            return error_map("no_response_body", "Empty response body");
        }
        let Some(object) = response.json().and_then(|value| value.as_object().cloned()) else {
            return error_map("parse_error", "JSON parse error: Response is not a JSON object");
        };
        if let Some(error) = object.get("error") {
            let mut ret = Json::new();
            ret.insert(
                "error".into(),
                json!(error.as_str().map_or_else(|| error.to_string(), str::to_string)),
            );
            ret.insert(
                "message".into(),
                json!(object
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("server did not provide a message")),
            );
            return ret;
        }
        if let Some(channel) = object.get("channel").and_then(Value::as_str).map(str::trim) {
            if !channel.is_empty() && channel != crate::bundle::ID_BUILTIN {
                self.config_mut().default_channel = channel.to_string();
                self.persist_default_channel(persist_key, Some(channel));
                self.host
                    .info(format!("defaultChannel synchronized from getChannel(): {channel}"));
            }
        }
        object
    }

    pub fn list_channels(&self) -> Json {
        if self.is_remote_blocked() {
            return self.remote_blocked_error();
        }
        let url = match self.channel_url("Channel URL is not set") {
            Ok(url) => url,
            Err(error) => return error,
        };
        let info = self.info_object(None);
        let query: Vec<String> = info
            .iter()
            .map(|(key, value)| {
                let value = value.as_str().map_or_else(|| value.to_string(), str::to_string);
                format!("{}={}", encode_query(key), encode_query(&value))
            })
            .collect();
        let separator = if url.contains('?') { '&' } else { '?' };
        let response = match self.http.get(&format!("{url}{separator}{}", query.join("&"))) {
            Ok(response) => response,
            Err(error) => return error_map("network_error", format!("Request failed: {error}")),
        };
        let block = self.handle_rate_limit(&response);
        if block.blocked {
            return error_map(&block.error, block.message);
        }
        if !response.is_success() {
            return Self::channel_status_error(&response);
        }
        if response.body.is_empty() {
            return error_map("no_response_body", "Empty response body");
        }
        match response.json() {
            Some(Value::Array(channels)) => {
                let mut list = Vec::new();
                for channel in channels {
                    let Some(object) = channel.as_object() else {
                        return error_map("parse_error", "JSON parse error: channel is not an object");
                    };
                    let Some(id) = object.get("id").filter(|id| id.is_number()) else {
                        return error_map("parse_error", "JSON parse error: Channel id must be a number");
                    };
                    list.push(json!({
                        "id": id,
                        "name": object.get("name").and_then(Value::as_str).unwrap_or_default(),
                        "public": object.get("public").and_then(Value::as_bool).unwrap_or(false),
                        "allow_self_set": object.get("allow_self_set").and_then(Value::as_bool).unwrap_or(false),
                    }));
                }
                self.host.info("Channels listed successfully");
                let mut ret = Json::new();
                ret.insert("channels".into(), Value::Array(list));
                ret
            }
            Some(Value::Object(object)) if object.contains_key("error") => {
                let mut ret = Json::new();
                ret.insert("error".into(), object["error"].clone());
                ret.insert(
                    "message".into(),
                    json!(object
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("server did not provide a message")),
                );
                ret
            }
            Some(_) => error_map("parse_error", "Unexpected channels response format"),
            None => error_map("parse_error", "JSON parse error: invalid JSON"),
        }
    }

    /// Non-2xx channel reply: the server's `error` / `message` when the body has them
    /// (like `setChannel`), else `response_error` / `Server error: <status>`.
    fn channel_status_error(response: &Response) -> Json {
        let body = response.json();
        let field = |key: &str| {
            body.as_ref()
                .and_then(|body| body.get(key))
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
        };
        let fallback = format!("Server error: {}", response.status);
        let mut ret = match field("error") {
            Some(error) => error_map(
                &error,
                field("message").unwrap_or_else(|| "server did not provide a message".into()),
            ),
            None => error_map("response_error", field("message").unwrap_or(fallback)),
        };
        ret.insert("statusCode".into(), json!(response.status));
        ret
    }

    fn unavailable_bundle_size(manifest: &[Value], error: &str) -> Json {
        let files: Vec<Value> = manifest
            .iter()
            .map(|entry| {
                let mut entry = entry.as_object().cloned().unwrap_or_default();
                entry.insert("error".into(), json!(error));
                Value::Object(entry)
            })
            .collect();
        let mut ret = Json::new();
        ret.insert("totalSize".into(), json!(0));
        ret.insert("knownFiles".into(), json!(0));
        ret.insert("unknownFiles".into(), json!(manifest.len()));
        ret.insert("files".into(), Value::Array(files));
        ret
    }

    /// Asks the backend (`<updateUrl>/manifest_size`) how much a manifest download weighs.
    pub fn bundle_download_size(&self, update_url: &str, version: Option<&str>, manifest: &[Value]) -> Json {
        if manifest.is_empty() {
            let mut ret = Json::new();
            ret.insert("totalSize".into(), json!(0));
            ret.insert("knownFiles".into(), json!(0));
            ret.insert("unknownFiles".into(), json!(0));
            ret.insert("files".into(), json!([]));
            return ret;
        }
        let mut info = self.info_object(None);
        info.insert("version".into(), json!(version.unwrap_or_default()));
        info.insert("manifest".into(), Value::Array(manifest.to_vec()));
        let url = manifest_size_url(update_url);
        match self.http.post_json(&url, &Value::Object(info)) {
            Ok(response) if response.is_success() && !response.body.is_empty() => match response.json() {
                Some(Value::Object(object)) => object,
                _ => Self::unavailable_bundle_size(manifest, "response_error"),
            },
            Ok(_) => Self::unavailable_bundle_size(manifest, "response_error"),
            Err(error) => {
                self.host.error("Error getting bundle download size");
                self.host.debug(format!("Error: {error}"));
                Self::unavailable_bundle_size(manifest, "response_error")
            }
        }
    }
}

impl Engine {
    /// GETs a JSON document (preview payloads). Non-2xx bodies become the error message.
    ///
    /// Runs on the bundle-transfer client: like every previous version, a preview payload
    /// gets at least 60 s (connect and read) whatever `responseTimeout` is.
    pub fn fetch_json(&self, url: &str) -> crate::error::CoreResult<Value> {
        use crate::error::CoreError;
        use crate::net::{NetError, NetErrorKind, Stream};
        const MAX_PAYLOAD_BYTES: usize = 16 * 1024 * 1024;
        let parsed =
            url::Url::parse(url).map_err(|_| CoreError::new("invalid_url", "Expected an http or https URL"))?;
        if parsed.scheme() != "http" && parsed.scheme() != "https" {
            return Err(CoreError::new("invalid_url", "Expected an http or https URL"));
        }
        let mut body = Vec::new();
        let head = self
            .http
            .download(url, &[("Accept", "application/json")], &mut |event| {
                if let Stream::Chunk(chunk) = event {
                    if body.len() + chunk.len() > MAX_PAYLOAD_BYTES {
                        return Err(NetError {
                            kind: NetErrorKind::Io,
                            message: "Preview payload is too large".into(),
                        });
                    }
                    body.extend_from_slice(chunk);
                }
                Ok(())
            })
            .map_err(|error| CoreError::new("network_error", error.message))?;
        let response = Response {
            status: head.status,
            headers: head.headers,
            body,
        };
        let json = response.json().unwrap_or(Value::Null);
        if !response.is_success() {
            let message = json
                .get("message")
                .or_else(|| json.get("error"))
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| format!("Request failed with HTTP {}", response.status));
            return Err(CoreError::new("response_error", message));
        }
        if !json.is_object() {
            return Err(CoreError::new("parse_error", "Response is not a JSON object"));
        }
        Ok(json)
    }
}

/// `<updateUrl>/manifest_size`, dropping the query string.
pub fn manifest_size_url(update_url: &str) -> String {
    let without_query = update_url.split(['?', '#']).next().unwrap_or(update_url);
    format!("{}/manifest_size", without_query.trim_end_matches('/'))
}

fn encode_query(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(byte as char),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}
