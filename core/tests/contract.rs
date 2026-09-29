//! Runs the shared native contract fixtures (`native-contract-tests/*.json`)
//! against the Rust core. The Android and iOS runners execute the same files
//! through their JNI / C bindings, so every host is held to one behavior.

use std::fs;
use std::path::{Path, PathBuf};

use capgo_updater_core::api;
use capgo_updater_core::text::{hex_decode, hex_encode};
use serde_json::{json, Map, Value};

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

/// Adapts file-backed fixture groups (content in the fixture, path at runtime).
fn run(group: &str, input: &Value, temp: &Path) -> Result<Value, String> {
    let to_result =
        |result: Result<Value, capgo_updater_core::CoreError>| result.map_err(|error| error.code.to_string());
    match group {
        "checksumFile" => {
            let content = hex_decode(input["contentHex"].as_str().unwrap()).unwrap();
            let repeat = input["repeat"].as_u64().unwrap_or(1) as usize;
            let path = write_temp(temp, "checksum.bin", &content.repeat(repeat));
            to_result(api::call(group, &json!({ "path": path })))
        }
        "decryptFile" => {
            let content = hex_decode(input["ciphertextHex"].as_str().unwrap()).unwrap();
            let path = write_temp(temp, "bundle.zip", &content);
            let mut call_input = input.as_object().cloned().unwrap_or_default();
            call_input.remove("ciphertextHex");
            call_input.insert("path".into(), json!(path));
            to_result(api::call(group, &Value::Object(call_input)))?;
            Ok(json!({ "plaintextHex": hex_encode(&fs::read(&path).unwrap()) }))
        }
        _ => to_result(api::call(group, input)),
    }
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
            assert!(
                api::OPERATIONS.contains(&group.as_str()),
                "{file}: group `{group}` is not a core operation"
            );
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
    for case in cases("rsaPublicDecrypt") {
        let actual = api::call(
            "rsaPublicDecrypt",
            &json!({ "publicKey": pem, "ciphertextHex": case["input"]["ciphertextHex"] }),
        )
        .map_err(|error| error.code.to_string());
        report.check(case["id"].as_str().unwrap(), actual, Some(&case["expect"]), None);
    }
    for case in cases("decryptChecksum") {
        let actual = api::call(
            "decryptChecksum",
            &json!({ "publicKey": pem, "checksum": case["input"]["checksumHex"] }),
        )
        .map(|value| json!({ "decryptedHex": value["checksum"] }))
        .map_err(|error| error.code.to_string());
        report.check(case["id"].as_str().unwrap(), actual, Some(&case["expect"]), None);
    }
    for case in cases("calcKeyId") {
        let actual = api::call("keyId", &json!({ "publicKey": case["input"]["publicKeyPem"] }))
            .map_err(|error| error.code.to_string());
        report.check(case["id"].as_str().unwrap(), actual, Some(&case["expect"]), None);
    }
    for case in cases("rsaPublicKeyLoad") {
        let actual = api::call("publicKeyValid", &json!({ "publicKey": case["input"]["publicKeyPem"] }))
            .map(|value| json!({ "loads": value["valid"] }))
            .map_err(|error| error.code.to_string());
        report.check(case["id"].as_str().unwrap(), actual, Some(&case["expect"]), None);
    }
    for case in cases("decryptChecksumInvalid") {
        let actual = api::call(
            "decryptChecksum",
            &json!({ "publicKey": pem, "checksum": case["input"]["checksumHex"] }),
        )
        .map_err(|error| error.code.to_string())
        .map(|value| Value::Object(Map::from_iter([("unexpected".to_string(), value)])));
        let threw = actual.is_err();
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

    let operation = CString::new("manifestConcurrency").unwrap();
    let input = CString::new(r#"{"processorCount":4}"#).unwrap();
    unsafe {
        let output = capgo_updater_core::ffi::capgo_core_call(operation.as_ptr(), input.as_ptr());
        let text = CStr::from_ptr(output).to_str().unwrap().to_string();
        capgo_updater_core::ffi::capgo_core_free(output);
        assert_eq!(text, r#"{"ok":true,"value":{"maxConcurrentFiles":8}}"#);
    }

    let unknown = CString::new("nope").unwrap();
    unsafe {
        let output = capgo_updater_core::ffi::capgo_core_call(unknown.as_ptr(), std::ptr::null());
        let text = CStr::from_ptr(output).to_str().unwrap().to_string();
        capgo_updater_core::ffi::capgo_core_free(output);
        assert!(text.contains(r#""code":"unknown_operation""#), "{text}");
    }
}
