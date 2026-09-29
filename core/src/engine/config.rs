//! Engine configuration: device facts, endpoints and storage layout provided
//! by the host at creation, plus runtime-mutable settings.

use std::path::PathBuf;

use serde_json::{Map, Value};

use crate::error::{CoreError, CoreResult};

/// Storage keys. Defaults are the keys every plugin version has used, so
/// existing installs keep their state.
#[derive(Debug, Clone)]
pub struct Keys {
    pub server_path: String,
    pub info_suffix: String,
    pub fallback: String,
    pub next: String,
    pub preview_fallback: String,
    pub pending_deletes: String,
    pub native_build_version: String,
    pub legacy_native_build_version: String,
}

impl Default for Keys {
    fn default() -> Self {
        Self {
            server_path: "serverBasePath".into(),
            info_suffix: "_info".into(),
            fallback: "pastVersion".into(),
            next: "nextVersion".into(),
            preview_fallback: "previewFallbackVersion".into(),
            pending_deletes: "pendingDeleteIds".into(),
            native_build_version: "LatestNativeBuildVersion".into(),
            legacy_native_build_version: "LatestVersionNative".into(),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct EngineConfig {
    /// `android`, `ios`, or another host name; sent as `platform` to the backend.
    pub platform: String,
    pub app_id: String,
    pub plugin_version: String,
    /// Builtin bundle version name (app marketing version).
    pub version_build: String,
    pub version_code: String,
    pub version_os: String,
    pub device_id: String,
    pub custom_id: String,
    pub default_channel: String,
    pub is_emulator: bool,
    pub is_prod: bool,
    pub install_source: String,
    pub update_url: String,
    pub stats_url: String,
    pub channel_url: String,
    pub public_key: String,
    pub key_id: String,
    pub preview_session: bool,
    /// Follow redirects that downgrade HTTPS to HTTP (off by default).
    pub allow_https_to_http_redirect: bool,
    pub timeout_ms: u64,
    /// Directory holding one sub-directory per downloaded bundle id.
    pub bundle_root: PathBuf,
    /// Updater-owned storage root (temp unzip folders, download temp files).
    pub storage_root: PathBuf,
    /// Directory for the persisted stats queue.
    pub stats_dir: PathBuf,
    /// Delta cache directory (`capgo_downloads`).
    pub cache_dir: PathBuf,
    /// Builtin web assets on disk (iOS `Bundle.main/public`, Android `filesDir/public`).
    pub builtin_dir: PathBuf,
    /// Android APK holding `assets/public/...` (builtin reuse for delta downloads).
    pub builtin_apk: PathBuf,
    /// Stored server path meaning "builtin" (`public` on Android, empty on iOS).
    pub builtin_server_path: String,
    pub keys: Keys,
}

fn text(object: &Map<String, Value>, key: &str) -> String {
    object
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn flag(object: &Map<String, Value>, key: &str, default: bool) -> bool {
    object.get(key).and_then(Value::as_bool).unwrap_or(default)
}

impl EngineConfig {
    pub fn from_json(value: &Value) -> CoreResult<Self> {
        let empty = Map::new();
        let object = value.as_object().unwrap_or(&empty);
        let path = |key: &str| PathBuf::from(text(object, key));
        let mut config = Self {
            platform: text(object, "platform"),
            timeout_ms: object
                .get("timeoutMs")
                .and_then(Value::as_u64)
                .unwrap_or(20_000),
            is_prod: flag(object, "isProd", true),
            bundle_root: path("bundleRoot"),
            storage_root: path("storageRoot"),
            stats_dir: path("statsDir"),
            cache_dir: path("cacheDir"),
            builtin_dir: path("builtinDir"),
            builtin_apk: path("builtinApk"),
            builtin_server_path: text(object, "builtinServerPath"),
            keys: Keys::default(),
            ..Self::default()
        };
        config.apply(value)?;
        if config.bundle_root.as_os_str().is_empty() {
            return Err(CoreError::invalid_input("bundleRoot is required"));
        }
        if config.storage_root.as_os_str().is_empty() {
            config.storage_root = config
                .bundle_root
                .parent()
                .map(PathBuf::from)
                .unwrap_or_default();
        }
        if config.stats_dir.as_os_str().is_empty() {
            config.stats_dir = config.storage_root.clone();
        }
        if let Some(keys) = object.get("keys").and_then(Value::as_object) {
            let set = |field: &mut String, key: &str| {
                if let Some(value) = keys.get(key).and_then(Value::as_str) {
                    *field = value.to_string();
                }
            };
            set(&mut config.keys.server_path, "serverPath");
            set(&mut config.keys.fallback, "fallback");
            set(&mut config.keys.next, "next");
            set(&mut config.keys.preview_fallback, "previewFallback");
            set(&mut config.keys.pending_deletes, "pendingDeletes");
        }
        Ok(config)
    }

    /// Applies runtime-mutable fields present in `value` (`configure` operation).
    pub fn apply(&mut self, value: &Value) -> CoreResult<()> {
        let Some(object) = value.as_object() else {
            return Ok(());
        };
        let set_text = |field: &mut String, key: &str| {
            if let Some(value) = object.get(key) {
                *field = value.as_str().unwrap_or_default().to_string();
            }
        };
        set_text(&mut self.app_id, "appId");
        set_text(&mut self.plugin_version, "pluginVersion");
        set_text(&mut self.version_build, "versionBuild");
        set_text(&mut self.version_code, "versionCode");
        set_text(&mut self.version_os, "versionOs");
        set_text(&mut self.device_id, "deviceId");
        set_text(&mut self.custom_id, "customId");
        set_text(&mut self.default_channel, "defaultChannel");
        set_text(&mut self.install_source, "installSource");
        set_text(&mut self.update_url, "updateUrl");
        set_text(&mut self.stats_url, "statsUrl");
        set_text(&mut self.channel_url, "channelUrl");
        if let Some(value) = object.get("isEmulator").and_then(Value::as_bool) {
            self.is_emulator = value;
        }
        if let Some(value) = object.get("isProd").and_then(Value::as_bool) {
            self.is_prod = value;
        }
        if let Some(value) = object.get("previewSession").and_then(Value::as_bool) {
            self.preview_session = value;
        }
        if let Some(value) = object
            .get("allowHttpsToHttpRedirect")
            .and_then(Value::as_bool)
        {
            self.allow_https_to_http_redirect = value;
        }
        if let Some(value) = object.get("timeoutMs").and_then(Value::as_u64) {
            self.timeout_ms = value;
        }
        if let Some(public_key) = object.get("publicKey") {
            let public_key = public_key.as_str().unwrap_or_default();
            if public_key.is_empty() {
                self.public_key.clear();
                self.key_id.clear();
            } else {
                crate::crypto::RsaPublicKey::from_pem(public_key).map_err(|_| {
                    CoreError::new(
                        "invalid_public_key",
                        "Invalid public key in capacitor.config.json: failed to parse RSA key. Remove the key or provide a valid PEM-formatted RSA public key.",
                    )
                })?;
                self.public_key = public_key.to_string();
                self.key_id = crate::crypto::key_id(public_key);
            }
        }
        Ok(())
    }
}
