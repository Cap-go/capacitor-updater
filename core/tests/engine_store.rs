mod support;

use rsa::pkcs1::EncodeRsaPublicKey;
use serde_json::json;
use support::TestEngine;

#[test]
fn engine_operations_reject_non_object_input() {
    let t = TestEngine::new(json!({}));
    t.install_bundle("b1", "1.0.1", "success");
    t.call("bundleSet", json!({ "id": "b1" }));
    for input in [json!([]), json!("internal"), json!(1)] {
        assert_eq!(t.engine.call("bundleReset", &input).unwrap_err().code, "invalid_input");
    }
    assert_eq!(t.call("bundleCurrent", json!({}))["id"], "b1");
}

#[test]
fn configure_applies_nothing_when_the_public_key_is_invalid() {
    let t = TestEngine::new(json!({ "updateUrl": "https://old.example.com" }));
    let error = t
        .engine
        .call(
            "configure",
            &json!({ "updateUrl": "https://new.example.com", "publicKey": "not a key" }),
        )
        .unwrap_err();
    assert_eq!(error.code, "invalid_public_key");
    assert_eq!(t.call("config", json!({}))["updateUrl"], "https://old.example.com");
}

#[test]
fn only_rsa_2048_public_keys_are_accepted() {
    let pem = |bits: usize| {
        let key = rsa::RsaPrivateKey::new(&mut rand::thread_rng(), bits).unwrap();
        key.to_public_key().to_pkcs1_pem(rsa::pkcs1::LineEnding::LF).unwrap()
    };
    let t = TestEngine::new(json!({}));
    t.call("configure", json!({ "publicKey": pem(2048) }));
    for bits in [1024, 3072] {
        let error = t
            .engine
            .call("configure", &json!({ "publicKey": pem(bits) }))
            .unwrap_err();
        assert_eq!(error.code, "invalid_public_key", "{bits} bits");
    }
}

#[test]
fn builtin_and_unknown_records() {
    let t = TestEngine::new(json!({}));
    let builtin = t.call("bundleGet", json!({ "id": "builtin" }));
    assert_eq!(builtin["status"], "success");
    assert_eq!(builtin["version"], "1.0.0");
    assert_eq!(t.call("bundleGet", json!({}))["status"], "error");
    let missing = t.call("bundleGet", json!({ "id": "ABCDEFGHIJ" }));
    assert_eq!(missing["status"], "pending");
    assert!(missing["version"].is_null());
}

#[test]
fn corrupted_record_is_cleared_and_reported_as_error() {
    let t = TestEngine::new(json!({}));
    t.host
        .store
        .lock()
        .unwrap()
        .insert("ABCDEFGHIJ_info".into(), "{not json".into());
    assert_eq!(t.call("bundleGet", json!({ "id": "ABCDEFGHIJ" }))["status"], "error");
    assert!(t.kv("ABCDEFGHIJ_info").is_none());
}

#[test]
fn builtin_records_are_never_saved() {
    let t = TestEngine::new(json!({}));
    let saved = t.call(
        "bundleSave",
        json!({ "id": "builtin", "bundle": { "id": "builtin", "status": "success" } }),
    );
    assert_eq!(saved["saved"], false);
}

#[test]
fn list_raw_only_returns_ten_char_ids() {
    let t = TestEngine::new(json!({}));
    t.install_bundle("AAAAAAAAAA", "1.0.1", "success");
    t.host.store.lock().unwrap().insert("short_info".into(), "{}".into());
    let raw = t.call("bundleList", json!({ "raw": true }));
    assert_eq!(raw.as_array().unwrap().len(), 1);
    let disk = t.call("bundleList", json!({}));
    assert_eq!(disk[0]["id"], "AAAAAAAAAA");
    assert_eq!(
        t.call("bundleGetByName", json!({ "version": "1.0.1" }))["id"],
        "AAAAAAAAAA"
    );
    assert!(t.call("bundleGetByName", json!({ "version": "9" })).is_null());
}

#[test]
fn set_switches_current_bundle_and_marks_pending() {
    let t = TestEngine::new(json!({}));
    let dir = t.install_bundle("AAAAAAAAAA", "1.0.1", "success");
    assert_eq!(t.call("bundleSet", json!({ "id": "AAAAAAAAAA" }))["set"], true);
    assert_eq!(t.kv("serverBasePath").unwrap(), dir.to_string_lossy());
    let current = t.call("bundleCurrent", json!({}));
    assert_eq!(current["id"], "AAAAAAAAAA");
    assert_eq!(current["isBuiltin"], false);
    assert_eq!(current["bundle"]["status"], "pending");
}

#[test]
fn set_missing_bundle_fails_and_marks_error() {
    let t = TestEngine::new(json!({}));
    t.call(
        "bundleSave",
        json!({ "id": "BBBBBBBBBB", "bundle": { "id": "BBBBBBBBBB", "version": "2", "status": "pending" } }),
    );
    assert_eq!(t.call("bundleSet", json!({ "id": "BBBBBBBBBB" }))["set"], false);
    assert_eq!(t.call("bundleGet", json!({ "id": "BBBBBBBBBB" }))["status"], "error");
    assert!(t.engine.call("bundleSet", &json!({ "id": "../../etc" })).unwrap()["set"] == false);
}

#[test]
fn delete_protects_current_next_and_unknown() {
    let t = TestEngine::new(json!({}));
    t.install_bundle("AAAAAAAAAA", "1", "success");
    t.install_bundle("BBBBBBBBBB", "2", "success");
    t.call("bundleSet", json!({ "id": "AAAAAAAAAA" }));
    assert_eq!(
        t.call("bundleDelete", json!({ "id": "AAAAAAAAAA" }))["deleted"],
        false,
        "current"
    );
    t.call("bundleSetNext", json!({ "id": "BBBBBBBBBB" }));
    assert_eq!(
        t.call("bundleDelete", json!({ "id": "BBBBBBBBBB" }))["deleted"],
        false,
        "next"
    );
    assert_eq!(
        t.call("bundleDelete", json!({ "id": "CCCCCCCCCC" }))["deleted"],
        false,
        "unknown"
    );
    assert_eq!(
        t.call("bundleDelete", json!({ "id": "builtin" }))["deleted"],
        false,
        "builtin"
    );
    assert_eq!(
        t.call("bundleDelete", json!({ "id": "../x" }))["deleted"],
        false,
        "invalid id"
    );
}

#[test]
fn delete_removes_folder_then_record() {
    let t = TestEngine::new(json!({}));
    let dir = t.install_bundle("AAAAAAAAAA", "1", "success");
    assert_eq!(
        t.call("bundleDelete", json!({ "id": "AAAAAAAAAA", "removeInfo": false }))["deleted"],
        true
    );
    assert!(!dir.exists());
    assert_eq!(t.call("bundleGet", json!({ "id": "AAAAAAAAAA" }))["status"], "deleted");
    t.install_bundle("BBBBBBBBBB", "2", "success");
    assert_eq!(t.call("bundleDelete", json!({ "id": "BBBBBBBBBB" }))["deleted"], true);
    assert!(t.kv("BBBBBBBBBB_info").is_none());
}

#[test]
fn drain_resumes_deleting_records_and_queue() {
    let t = TestEngine::new(json!({}));
    let a = t.install_bundle("AAAAAAAAAA", "1", "deleting");
    let b = t.install_bundle("BBBBBBBBBB", "2", "success");
    t.host
        .store
        .lock()
        .unwrap()
        .insert("pendingDeleteIds".into(), "BBBBBBBBBB".into());
    t.call("bundleDrainPendingDeletes", json!({}));
    assert!(!a.exists() && !b.exists());
    assert!(t.kv("pendingDeleteIds").is_none());
}

#[test]
fn set_next_requires_existing_bundle_and_emits_event() {
    let t = TestEngine::new(json!({}));
    assert_eq!(t.call("bundleSetNext", json!({ "id": "AAAAAAAAAA" }))["set"], false);
    t.install_bundle("AAAAAAAAAA", "1", "success");
    assert_eq!(t.call("bundleSetNext", json!({ "id": "AAAAAAAAAA" }))["set"], true);
    assert_eq!(t.kv("nextVersion").unwrap(), "AAAAAAAAAA");
    assert_eq!(t.call("bundleNext", json!({}))["status"], "pending");
    assert_eq!(t.host.events_named("setNext").len(), 1);
    t.call("bundleSetNext", json!({ "id": null }));
    assert!(t.call("bundleNext", json!({})).is_null());
}

#[test]
fn reset_points_back_to_builtin() {
    let t = TestEngine::new(json!({}));
    t.install_bundle("AAAAAAAAAA", "1", "success");
    t.call("bundleSet", json!({ "id": "AAAAAAAAAA" }));
    t.call("bundleSetNext", json!({ "id": "AAAAAAAAAA" }));
    t.call("bundleReset", json!({}));
    assert_eq!(t.kv("serverBasePath").unwrap(), "public");
    assert_eq!(t.kv("pastVersion").unwrap(), "builtin");
    assert!(t.kv("nextVersion").is_none());
    assert_eq!(t.call("bundleCurrent", json!({}))["isBuiltin"], true);
}

#[test]
fn reset_state_round_trip() {
    let t = TestEngine::new(json!({}));
    t.install_bundle("AAAAAAAAAA", "1", "success");
    t.call("bundleSet", json!({ "id": "AAAAAAAAAA" }));
    let state = t.call("bundleCaptureResetState", json!({}));
    t.call("bundlePrepareResetTransition", json!({}));
    assert_eq!(t.call("bundleCurrent", json!({}))["isBuiltin"], true);
    t.call("bundleRestoreResetState", state);
    assert_eq!(t.call("bundleCurrent", json!({}))["id"], "AAAAAAAAAA");
}

#[test]
fn auto_reset_on_missing_folder_foreign_path_and_native_change() {
    let t = TestEngine::new(json!({}));
    t.host
        .store
        .lock()
        .unwrap()
        .insert("serverBasePath".into(), "/somewhere/else/ZZZZZZZZZZ".into());
    t.call("bundleAutoReset", json!({ "nativeBuildVersion": "10" }));
    assert_eq!(t.call("bundleCurrent", json!({}))["isBuiltin"], true, "missing folder");

    let dir = t.install_bundle("AAAAAAAAAA", "1", "success");
    t.call("bundleSet", json!({ "id": "AAAAAAAAAA" }));
    t.host
        .store
        .lock()
        .unwrap()
        .insert("LatestNativeBuildVersion".into(), "9".into());
    t.call("bundleAutoReset", json!({ "nativeBuildVersion": "10" }));
    assert_eq!(t.call("bundleCurrent", json!({}))["isBuiltin"], true, "native changed");

    t.call("bundleSet", json!({ "id": "AAAAAAAAAA" }));
    t.call(
        "bundleAutoReset",
        json!({ "nativeBuildVersion": "10", "resetWhenNativeVersionChanged": false }),
    );
    assert_eq!(
        t.call("bundleCurrent", json!({}))["id"],
        "AAAAAAAAAA",
        "opt out of native reset"
    );

    // Folder exists but no record: foreign bundle.
    t.call("bundleSave", json!({ "id": "AAAAAAAAAA", "bundle": null }));
    t.call("bundleAutoReset", json!({ "nativeBuildVersion": "9" }));
    assert_eq!(t.call("bundleCurrent", json!({}))["isBuiltin"], true, "foreign");
    assert!(dir.exists());
}

#[test]
fn set_success_moves_fallback_and_deletes_previous() {
    let t = TestEngine::new(json!({}));
    let old = t.install_bundle("AAAAAAAAAA", "1", "success");
    t.install_bundle("BBBBBBBBBB", "2", "pending");
    t.call(
        "bundleSetSuccess",
        json!({ "id": "AAAAAAAAAA", "autoDeletePrevious": true }),
    );
    assert_eq!(t.kv("pastVersion").unwrap(), "AAAAAAAAAA");
    t.call("bundleSet", json!({ "id": "BBBBBBBBBB" }));
    t.call(
        "bundleSetSuccess",
        json!({ "id": "BBBBBBBBBB", "autoDeletePrevious": true }),
    );
    assert_eq!(t.kv("pastVersion").unwrap(), "BBBBBBBBBB");
    for _ in 0..50 {
        if !old.exists() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(!old.exists(), "previous fallback deleted in background");
}

#[test]
fn cleanup_removes_orphans_and_temp_folders() {
    let t = TestEngine::new(json!({}));
    t.install_bundle("AAAAAAAAAA", "1", "success");
    let orphan = t.root().join("versions/ORPHANXXXX");
    std::fs::create_dir_all(&orphan).unwrap();
    let temp = t.root().join("capgo_unzip_abcdefghij");
    std::fs::create_dir_all(&temp).unwrap();
    t.call("bundleCleanupDownloadDirectories", json!({}));
    t.call("bundleCleanupOrphanedTempFolders", json!({}));
    assert!(!orphan.exists());
    assert!(!temp.exists());
    assert!(t.root().join("versions/AAAAAAAAAA").exists());
}

#[test]
fn ios_layout_uses_empty_builtin_path() {
    let t = TestEngine::new(json!({ "platform": "ios", "builtinServerPath": "" }));
    assert_eq!(t.call("bundleCurrent", json!({}))["isBuiltin"], true);
    t.install_bundle("AAAAAAAAAA", "1", "success");
    t.call("bundleSet", json!({ "id": "AAAAAAAAAA" }));
    t.call("bundleReset", json!({}));
    assert_eq!(t.kv("serverBasePath").unwrap(), "");
}
