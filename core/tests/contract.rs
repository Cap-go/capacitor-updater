//! Runs the shared contract fixtures (`native-contract-tests/*.json`) against
//! the Rust core. Each fixture group maps to the Rust function the engine runs;
//! the platform tests only smoke-test their JNI / C binding.

mod support;

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};
use support::core;

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

/// Runs one fixture group through the C ABI (`test.<group>`). Errors are core error codes.
fn run(group: &str, input: &Value, temp: &Path) -> Result<Value, String> {
    let mut input = input.clone();
    if let Some(object) = input.as_object_mut() {
        object.insert("tempDir".into(), Value::String(temp.to_string_lossy().into_owned()));
    }
    core().try_test(group, input).map_err(|error| {
        assert_ne!(error.code, "unknown_operation", "fixture group `{group}`: {error}");
        assert_ne!(error.code, "invalid_input", "fixture group `{group}`: {error}");
        error.code
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
fn core_matches_shared_contract() {
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
    let call = |operation: &str, input: Option<&str>| core().call_raw(operation, input);

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
