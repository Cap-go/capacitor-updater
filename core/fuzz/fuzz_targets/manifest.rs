//! manifest: the input is the JSON of an update reply (an object with `manifest`) or a
//! manifest array. Reads it like the engine does: the download request
//! (`DownloadRequest::from_json` / `to_json`), the engine's manifest scan
//! (`missingBundleFiles`: file hashes decrypted with the public key, builtin, APK and
//! delta-cache lookups) and the per-entry path and cache-name guards. C: core-c/fuzz/manifest.c.
#![no_main]

use std::sync::{Arc, OnceLock};

use capgo_updater_core::engine::download::DownloadRequest;
use capgo_updater_core::engine::Engine;
use capgo_updater_core::paths;
use capgo_updater_core_fuzz::{check_inside, engine_config, host, scratch_dir, PUBLIC_KEY};
use libfuzzer_sys::fuzz_target;
use serde_json::{json, Map, Value};

fn engine() -> &'static Arc<Engine> {
    static ENGINE: OnceLock<Arc<Engine>> = OnceLock::new();
    ENGINE.get_or_init(|| {
        let config = engine_config(json!({
            "publicKey": PUBLIC_KEY,
            "builtinDir": scratch_dir().join("builtin").to_string_lossy(),
        }));
        Engine::new(host(), &config).expect("engine refused the fuzz configuration")
    })
}

fn check_entry(entry: &Value) {
    let Some(name) = entry.get("file_name").and_then(Value::as_str) else {
        return;
    };
    if name.contains('\0') {
        return;
    }
    let base = "/data/app/versions/b1";
    if let Ok(target) = paths::resolve_manifest_target_path(base, name) {
        check_inside(base, name, &target);
    }
    if let Some(hash) = entry
        .get("file_hash")
        .and_then(Value::as_str)
        .filter(|hash| !hash.contains('\0'))
    {
        let partial = paths::manifest_partial_name(Some(hash), name);
        assert!(!partial.contains('/'), "partial name {partial:?} has a separator");
        if paths::is_safe_cache_hash(Some(hash)) {
            let cache = paths::cache_file_name(hash, name);
            assert!(!cache.contains('/'), "cache name {cache:?} has a separator");
        }
    }
}

fuzz_target!(|data: &[u8]| {
    let engine = engine();
    let Ok(value) = serde_json::from_slice::<Value>(data) else {
        return;
    };
    let manifest = if value.is_array() {
        Some(&value)
    } else {
        value.get("manifest")
    };
    if value.is_object() {
        if let Ok(request) = DownloadRequest::from_json(&value) {
            let _ = request.to_json();
        }
    }
    if let Some(Value::Array(entries)) = manifest {
        for entry in entries {
            check_entry(entry);
        }
        let mut input = Map::new();
        input.insert("manifest".into(), Value::Array(entries.clone()));
        if let Some(session_key) = value.get("sessionKey").filter(|key| key.is_string()) {
            input.insert("sessionKey".into(), session_key.clone());
        }
        let _ = engine.call_json("missingBundleFiles", &Value::Object(input).to_string());
    }
});
