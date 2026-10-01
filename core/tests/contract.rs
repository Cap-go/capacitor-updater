//! Runs the shared contract fixtures (`native-contract-tests/*.json`) against
//! the Rust core. Each fixture group maps to the Rust function the engine runs;
//! the platform tests only smoke-test their JNI / C binding.

use std::fs;
use std::path::{Path, PathBuf};

use capgo_updater_core::crypto::{self, RsaPublicKey};
use capgo_updater_core::text::{hex_decode, hex_encode};
use capgo_updater_core::{bundle, http, paths, policy, CoreError};
use serde_json::{json, Value};

const CONTRACT_FILES: &[&str] = &["core.json", "policy.json", "security.json", "crypto.json"];

fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../native-contract-tests")
}

fn load(name: &str) -> Value {
    let path = fixtures_dir().join(name);
    let text = fs::read_to_string(&path).unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|error| panic!("parse {}: {error}", path.display()))
}

/// Expected failure code: case-level `"error"`.
fn expected_error(case: &Value) -> Option<&str> {
    case.get("error").and_then(Value::as_str).or_else(|| {
        let expect = case.get("expect")?.as_object()?;
        (expect.len() == 1).then(|| expect.get("error")?.as_str()).flatten()
    })
}

fn with_fixture_key(input: &Value, public_key_pem: Option<&str>) -> Value {
    let mut input = input.clone();
    if let (Some(object), Some(pem)) = (input.as_object_mut(), public_key_pem) {
        if object.get("publicKey").is_some_and(Value::is_null) {
            object.insert("publicKey".into(), Value::String(pem.to_string()));
        }
    }
    input
}

fn write_temp(dir: &Path, name: &str, bytes: &[u8]) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, bytes).unwrap();
    path
}

// ---- fixture input accessors (a malformed fixture panics: it is a test bug)

fn opt_str<'a>(input: &'a Value, key: &str) -> Option<&'a str> {
    match input.get(key) {
        None | Some(Value::Null) => None,
        Some(Value::String(value)) => Some(value),
        Some(other) => panic!("`{key}` must be a string, got {other}"),
    }
}

fn str_or_empty<'a>(input: &'a Value, key: &str) -> &'a str {
    opt_str(input, key).unwrap_or_default()
}

fn req_str<'a>(input: &'a Value, key: &str) -> &'a str {
    opt_str(input, key).unwrap_or_else(|| panic!("`{key}` is required"))
}

fn req_bool(input: &Value, key: &str) -> bool {
    input[key]
        .as_bool()
        .unwrap_or_else(|| panic!("`{key}` must be a boolean"))
}

fn opt_i64(input: &Value, key: &str) -> Option<i64> {
    match input.get(key) {
        None | Some(Value::Null) => None,
        Some(value) => Some(
            value
                .as_i64()
                .or_else(|| value.as_f64().filter(|v| v.fract() == 0.0).map(|v| v as i64))
                .unwrap_or_else(|| panic!("`{key}` must be an integer")),
        ),
    }
}

fn req_i64(input: &Value, key: &str) -> i64 {
    opt_i64(input, key).unwrap_or_else(|| panic!("`{key}` is required"))
}

/// Runs one fixture group against the Rust functions behind it. Errors are core error codes.
fn run(group: &str, input: &Value, temp: &Path) -> Result<Value, String> {
    let code = |error: CoreError| error.code.to_string();
    Ok(match group {
        "periodCheckDelay" => json!({
            "normalizedSeconds": policy::normalized_period_check_delay_seconds(req_i64(input, "seconds"))
        }),
        "autoUpdateMode" => {
            let mode = policy::normalized_auto_update_mode(opt_str(input, "mode"));
            json!({
                "mode": mode,
                "enabled": policy::is_auto_update_mode_enabled(mode),
                "directUpdateMode": policy::direct_update_mode_for_auto_update_mode(mode),
                "setNextBundle": policy::should_auto_update_mode_set_next_bundle(mode),
            })
        }
        "legacyDirectUpdateAutoMode" => json!({
            "mode": policy::auto_update_mode_for_legacy_direct_update_mode(req_str(input, "directUpdateMode"))
        }),
        "isDirectUpdateMode" => json!({
            "direct": policy::is_direct_update_mode(req_str(input, "directUpdateMode"))
        }),
        "onLaunchDirectUpdateConsumption" => json!({
            "consume": policy::should_consume_on_launch_direct_update(
                req_str(input, "mode"),
                req_bool(input, "plannedDirectUpdate"),
            )
        }),
        "updateResponseKind" => json!({
            "kind": policy::normalized_update_response_kind(opt_str(input, "kind"))
        }),
        "shakeMenuGesture" => {
            let value = opt_str(input, "value");
            json!({
                "gesture": policy::normalized_shake_menu_gesture(value),
                "supported": policy::is_supported_shake_menu_gesture(value),
            })
        }
        "webViewErrorStatsAction" => json!({
            "action": policy::stats_action_for_webview_error_type(str_or_empty(input, "type"))
        }),
        "launchDownloadReady" => {
            let success = req_bool(input, "success");
            json!({
                "notify": policy::should_notify_launch_download_ready(
                    req_bool(input, "awaitedByCaller"),
                    success,
                    req_bool(input, "directInstall"),
                    req_bool(input, "previewSession"),
                ),
                "status": policy::launch_download_ready_status(success, req_bool(input, "setNext")),
            })
        }
        "foreignBundleReset" => json!({
            "reset": policy::should_reset_for_foreign_bundle(
                opt_str(input, "bundlePath"),
                req_bool(input, "isBuiltin"),
                req_bool(input, "hasStoredBundleInfo"),
            )
        }),
        "clearPersistedDefaultChannel" => json!({
            "clear": policy::should_clear_persisted_default_channel(
                req_bool(input, "persistDefaultChannelOnReinstall"),
                req_bool(input, "resetWhenUpdate"),
                req_bool(input, "nativeBuildVersionChanged"),
                req_bool(input, "restoredReinstall"),
            )
        }),
        "manifestConcurrency" => json!({
            "maxConcurrentFiles": policy::manifest_max_concurrent_files(req_i64(input, "processorCount"))
        }),
        "bundleStatus" => json!({ "status": bundle::parse_bundle_status(opt_str(input, "value")) }),

        "userAgent" => json!({
            "userAgent": http::user_agent(
                str_or_empty(input, "appId"),
                str_or_empty(input, "pluginVersion"),
                str_or_empty(input, "versionOs"),
                req_str(input, "platform"),
            )
        }),
        "retryableHttpStatus" => json!({
            "retryable": http::is_retryable_http_status(req_i64(input, "status"))
        }),
        "contentRange" => json!({
            "range": http::parse_content_range(opt_str(input, "header"))
                .map(|range| json!({ "start": range.start, "end": range.end, "total": range.total }))
        }),
        "zipResumePlan" => {
            let plan = http::plan_zip_resume_write(
                req_i64(input, "responseCode"),
                req_i64(input, "downloadedBytes"),
                opt_str(input, "contentRange"),
            )?;
            json!({ "responseCode": plan.response_code, "writeOffset": plan.write_offset })
        }
        "appendHttpBody" => json!({
            "append": http::should_append_http_body(req_i64(input, "statusCode"), req_i64(input, "existingBytes"))
        }),
        "rateLimitDeadline" => json!({
            "blockedUntilMs": http::rate_limit_blocked_until_ms(
                opt_str(input, "retryAfter"),
                opt_str(input, "body"),
                req_i64(input, "nowMs"),
            )
        }),
        "remoteError" => {
            let (error, message) = http::parse_remote_error(opt_str(input, "body"));
            json!({ "error": error, "message": message })
        }

        "pathTraversalSegment" => json!({
            "traversal": paths::contains_path_traversal_segment(req_str(input, "path"))
        }),
        "resolvePathInside" => json!({
            "path": paths::resolve_path_inside(req_str(input, "base"), req_str(input, "path")).map_err(code)?
        }),
        "manifestTargetPath" => json!({
            "path": paths::resolve_manifest_target_path(req_str(input, "base"), req_str(input, "fileName"))
                .map_err(code)?
        }),
        "builtinAssetPath" => json!({
            "assetPath": paths::builtin_asset_path(req_str(input, "fileName")).map_err(code)?
        }),
        "safeCacheHash" => json!({ "safe": paths::is_safe_cache_hash(opt_str(input, "hash")) }),
        "reusableCacheFile" => json!({
            "reusable": paths::is_reusable_cache_file(opt_str(input, "hash"), opt_i64(input, "size"))
        }),
        "manifestPartialName" => json!({
            "name": paths::manifest_partial_name(opt_str(input, "hash"), str_or_empty(input, "fileName"))
        }),
        "shortPathKey" => json!({
            "key": crypto::checksum::short_path_key(str_or_empty(input, "value"))
        }),

        "sessionKeyValid" => json!({ "valid": crypto::is_valid_session_key(opt_str(input, "sessionKey")) }),
        "keyId" => json!({ "keyId": crypto::key_id(str_or_empty(input, "publicKey")) }),
        "publicKeyValid" => json!({
            "valid": RsaPublicKey::from_pem(str_or_empty(input, "publicKey")).is_ok()
        }),
        "checksumAlgorithm" => json!({
            "algorithm": crypto::detect_checksum_algorithm(str_or_empty(input, "checksum"))
        }),
        "checksumFile" => {
            let content = hex_decode(req_str(input, "contentHex")).unwrap();
            let repeat = opt_i64(input, "repeat").unwrap_or(1) as usize;
            let path = write_temp(temp, "checksum.bin", &content.repeat(repeat));
            json!({ "checksum": crypto::checksum::sha256_file(&path).map_err(code)? })
        }
        "decryptChecksum" => json!({
            "checksum": crypto::decrypt_checksum(str_or_empty(input, "checksum"), str_or_empty(input, "publicKey"))
                .map_err(code)?
        }),
        // What download.rs runs on a zip: session key, then in-place AES-CBC decryption.
        "decryptFile" => {
            let path = write_temp(
                temp,
                "bundle.zip",
                &hex_decode(req_str(input, "ciphertextHex")).unwrap(),
            );
            let session =
                crypto::bundle_session_key(str_or_empty(input, "publicKey"), str_or_empty(input, "sessionKey"))
                    .map_err(code)?;
            if let Some(session) = session {
                crypto::aes_cbc::decrypt_file_in_place_hashed(&path, &session.key, &session.iv).map_err(code)?;
            }
            json!({ "plaintextHex": hex_encode(&fs::read(&path).unwrap()) })
        }
        "rsaPublicDecrypt" => {
            let key = RsaPublicKey::from_pem(req_str(input, "publicKey")).map_err(code)?;
            let ciphertext = hex_decode(req_str(input, "ciphertextHex")).unwrap();
            json!({ "plaintextHex": hex_encode(&key.public_decrypt(&ciphertext).map_err(code)?) })
        }
        other => panic!("fixture group `{other}` has no Rust mapping"),
    })
}

struct Report {
    passed: usize,
    failures: Vec<String>,
}

impl Report {
    fn check(&mut self, id: &str, actual: Result<Value, String>, expect: Option<&Value>, error: Option<&str>) {
        let ok = match (&actual, error, expect) {
            (Err(code), Some(expected), _) => code == expected,
            (Ok(value), None, Some(expected)) => value == expected,
            _ => false,
        };
        if ok {
            self.passed += 1;
        } else {
            self.failures.push(format!(
                "{id}: expected {} got {:?}",
                error
                    .map(|code| format!("error {code}"))
                    .unwrap_or_else(|| expect.map(Value::to_string).unwrap_or_default()),
                actual
            ));
        }
    }
}

#[test]
fn rust_core_matches_shared_contract() {
    let temp = tempfile::tempdir().unwrap();
    let mut report = Report {
        passed: 0,
        failures: Vec::new(),
    };

    for file in CONTRACT_FILES {
        let fixture = load(file);
        let public_key_pem = fixture.get("publicKeyPem").and_then(Value::as_str);
        for (group, cases) in fixture.as_object().unwrap() {
            let Some(cases) = cases.as_array() else {
                continue;
            };
            for case in cases {
                let id = case["id"].as_str().unwrap();
                let input = with_fixture_key(&case["input"], public_key_pem);
                let actual = run(group, &input, temp.path());
                report.check(id, actual, case.get("expect"), expected_error(case));
            }
        }
    }

    // crypto-rsa.json predates the operation-named format; map its groups explicitly.
    let rsa = load("crypto-rsa.json");
    let pem = rsa["publicKeyPem"].as_str().unwrap();
    let cases = |group: &str| rsa[group].as_array().cloned().unwrap_or_default();
    let temp = temp.path();
    for case in cases("rsaPublicDecrypt") {
        let actual = run(
            "rsaPublicDecrypt",
            &json!({ "publicKey": pem, "ciphertextHex": case["input"]["ciphertextHex"] }),
            temp,
        );
        report.check(case["id"].as_str().unwrap(), actual, Some(&case["expect"]), None);
    }
    for case in cases("decryptChecksum") {
        let actual = run(
            "decryptChecksum",
            &json!({ "publicKey": pem, "checksum": case["input"]["checksumHex"] }),
            temp,
        )
        .map(|value| json!({ "decryptedHex": value["checksum"] }));
        report.check(case["id"].as_str().unwrap(), actual, Some(&case["expect"]), None);
    }
    for case in cases("calcKeyId") {
        let actual = run("keyId", &json!({ "publicKey": case["input"]["publicKeyPem"] }), temp);
        report.check(case["id"].as_str().unwrap(), actual, Some(&case["expect"]), None);
    }
    for case in cases("rsaPublicKeyLoad") {
        let actual = run(
            "publicKeyValid",
            &json!({ "publicKey": case["input"]["publicKeyPem"] }),
            temp,
        )
        .map(|value| json!({ "loads": value["valid"] }));
        report.check(case["id"].as_str().unwrap(), actual, Some(&case["expect"]), None);
    }
    for case in cases("decryptChecksumInvalid") {
        let threw = run(
            "decryptChecksum",
            &json!({ "publicKey": pem, "checksum": case["input"]["checksumHex"] }),
            temp,
        )
        .is_err();
        report.check(
            case["id"].as_str().unwrap(),
            Ok(json!({ "throws": threw })),
            Some(&case["expect"]),
            None,
        );
    }

    println!("contract cases passed: {}", report.passed);
    assert!(
        report.failures.is_empty(),
        "{} contract case(s) failed:\n{}",
        report.failures.len(),
        report.failures.join("\n")
    );
}

#[test]
fn c_abi_round_trip() {
    use std::ffi::{CStr, CString};

    let call = |operation: &str, input: Option<&str>| unsafe {
        let operation = CString::new(operation).unwrap();
        let input = input.map(|input| CString::new(input).unwrap());
        let output = capgo_updater_core::ffi::capgo_core_call(
            operation.as_ptr(),
            input.as_ref().map_or(std::ptr::null(), |input| input.as_ptr()),
        );
        let text = CStr::from_ptr(output).to_str().unwrap().to_string();
        capgo_updater_core::ffi::capgo_core_free(output);
        text
    };

    assert_eq!(
        call("resolvePathInside", Some(r#"{"base":"/data/versions","path":"abc"}"#)),
        r#"{"ok":true,"value":{"path":"/data/versions/abc"}}"#
    );
    let escape = call(
        "resolvePathInside",
        Some(r#"{"base":"/data/versions","path":"../abc"}"#),
    );
    assert!(escape.contains(r#""code":"path_traversal""#), "{escape}");
    let unknown = call("nope", None);
    assert!(unknown.contains(r#""code":"unknown_operation""#), "{unknown}");
}
