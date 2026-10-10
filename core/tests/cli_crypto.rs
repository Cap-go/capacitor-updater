//! Decrypts bundles encrypted by the real Capgo CLI (`native-contract-tests/cli`,
//! written by `scripts/generate-cli-crypto-fixtures.mjs` through `@capgo/cli/sdk`).
//! The CLI is the source of truth for the format: these tests must pass for every
//! bundle it produces, through the crypto functions and the engine `download` path.

mod support;

use std::path::{Path, PathBuf};

use capgo_updater_core::crypto::checksum::sha256_hex;
use capgo_updater_core::text::{hex_decode, hex_encode};
use serde_json::{json, Value};
use support::{core, FakeServer, TestEngine};

struct CliBundle {
    id: String,
    zip: Vec<u8>,
    encrypted: Vec<u8>,
    sha256: String,
    checksum: String,
    iv_session_key: String,
    /// (path inside the bundle, SHA-256 of its content)
    files: Vec<(String, String)>,
}

struct CliFixture {
    public_key: String,
    bundles: Vec<CliBundle>,
}

fn fixture_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../native-contract-tests/cli")
}

fn text(value: &Value, key: &str) -> String {
    value[key]
        .as_str()
        .unwrap_or_else(|| panic!("fixture field `{key}` must be a string"))
        .to_string()
}

fn load() -> CliFixture {
    let dir = fixture_dir();
    let read = |name: &str| std::fs::read(dir.join(name)).unwrap_or_else(|error| panic!("read {name}: {error}"));
    let fixture: Value = serde_json::from_slice(&read("cli-crypto.json")).unwrap();
    let bundles: Vec<CliBundle> = fixture["bundles"]
        .as_array()
        .expect("bundles")
        .iter()
        .map(|bundle| CliBundle {
            id: text(bundle, "id"),
            zip: read(&text(bundle, "zip")),
            encrypted: read(&text(bundle, "encrypted")),
            sha256: text(bundle, "sha256"),
            checksum: text(bundle, "checksum"),
            iv_session_key: text(bundle, "ivSessionKey"),
            files: bundle["files"]
                .as_array()
                .expect("files")
                .iter()
                .map(|file| (text(file, "path"), text(file, "sha256")))
                .collect(),
        })
        .collect();
    assert!(!bundles.is_empty(), "fixture has bundles");
    CliFixture {
        public_key: text(&fixture, "publicKey"),
        bundles,
    }
}

#[test]
fn every_cli_bundle_decrypts_to_its_zip() {
    let fixture = load();
    let dir = tempfile::tempdir().unwrap();
    for bundle in &fixture.bundles {
        let id = &bundle.id;
        let session = core()
            .try_test(
                "sessionKey",
                json!({ "publicKey": fixture.public_key, "sessionKey": bundle.iv_session_key }),
            )
            .unwrap_or_else(|error| panic!("{id}: session key: {error}"))["session"]
            .clone();
        assert!(!session.is_null(), "{id}: bundle must be treated as encrypted");
        let (key, iv) = (&session["keyHex"], &session["ivHex"]);

        // File path used for downloaded zips.
        let file = dir.path().join(format!("{id}.zip"));
        std::fs::write(&file, &bundle.encrypted).unwrap();
        let hash = core()
            .try_test(
                "decryptFileInPlace",
                json!({ "path": file.to_string_lossy(), "keyHex": key, "ivHex": iv }),
            )
            .unwrap_or_else(|error| panic!("{id}: decrypt file: {error}"))["hash"]
            .clone();
        assert!(
            std::fs::read(&file).unwrap() == bundle.zip,
            "{id}: decrypted bytes differ from the CLI zip"
        );
        assert_eq!(hash, bundle.sha256.as_str(), "{id}: plaintext hash");
        assert_eq!(
            core().test("sha256File", json!({ "path": file.to_string_lossy() }))["checksum"],
            bundle.sha256.as_str(),
            "{id}: file checksum"
        );

        // Streaming decryptor, fed in uneven chunks.
        let plain = core()
            .try_test(
                "aesCbcDecrypt",
                json!({ "ciphertextHex": hex_encode(&bundle.encrypted), "keyHex": key, "ivHex": iv, "chunkSize": 4099 }),
            )
            .unwrap_or_else(|error| panic!("{id}: finish: {error}"));
        let plain = hex_decode(plain["plaintextHex"].as_str().unwrap()).unwrap();
        assert!(plain == bundle.zip, "{id}: streamed plaintext differs from the CLI zip");

        let expected = core()
            .try_test(
                "decryptChecksum",
                json!({ "checksum": bundle.checksum, "publicKey": fixture.public_key }),
            )
            .unwrap_or_else(|error| panic!("{id}: decrypt checksum: {error}"));
        assert_eq!(expected["checksum"], bundle.sha256.as_str(), "{id}: decrypted checksum");
    }
}

#[test]
fn engine_download_installs_every_cli_bundle() {
    let fixture = load();
    let served: Vec<(String, Vec<u8>)> = fixture
        .bundles
        .iter()
        .map(|bundle| (format!("/{}.zip", bundle.id), bundle.encrypted.clone()))
        .collect();
    let server = FakeServer::start(move |request| {
        let path = request.url.split('?').next().unwrap_or_default();
        match served.iter().find(|(name, _)| name == path) {
            Some((_, body)) => (200, vec![], body.clone()),
            None => (404, vec![], vec![]),
        }
    });
    let t = TestEngine::new(json!({ "publicKey": fixture.public_key }));

    for bundle in &fixture.bundles {
        let id = &bundle.id;
        // The update response fields, exactly as the CLI uploads them.
        let installed = t
            .engine
            .call(
                "download",
                &json!({
                    "url": format!("{}/{id}.zip", server.url),
                    "version": format!("1.0.0-{id}"),
                    "checksum": bundle.checksum,
                    "sessionKey": bundle.iv_session_key,
                }),
            )
            .unwrap_or_else(|error| panic!("{id}: download failed: {error}"));
        assert_eq!(installed["status"], "pending", "{id}");
        let bundle_dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
        assert!(!bundle.files.is_empty(), "{id}: bundle has files");
        for (path, sha256) in &bundle.files {
            let content = std::fs::read(bundle_dir.join(path)).unwrap_or_else(|error| panic!("{id}: {path}: {error}"));
            assert_eq!(&sha256_hex(&content), sha256, "{id}: {path}");
        }
    }
}
