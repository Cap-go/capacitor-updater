//! Decrypts bundles encrypted by the real Capgo CLI (`native-contract-tests/cli`,
//! written by `scripts/generate-cli-crypto-fixtures.mjs` through `@capgo/cli/sdk`).
//! The CLI is the source of truth for the format: these tests must pass for every
//! bundle it produces, through the crypto functions and the engine `download` path.

mod support;

use std::path::{Path, PathBuf};

use capgo_updater_core::crypto::{self, aes_cbc, checksum};
use serde_json::{json, Value};
use support::{FakeServer, TestEngine};

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
        let session = crypto::bundle_session_key(&fixture.public_key, &bundle.iv_session_key)
            .unwrap_or_else(|error| panic!("{id}: session key: {error}"))
            .unwrap_or_else(|| panic!("{id}: bundle must be treated as encrypted"));

        // File path used for downloaded zips.
        let file = dir.path().join(format!("{id}.zip"));
        std::fs::write(&file, &bundle.encrypted).unwrap();
        let hash = aes_cbc::decrypt_file_in_place_hashed(&file, &session.key, &session.iv)
            .unwrap_or_else(|error| panic!("{id}: decrypt file: {error}"));
        assert!(
            std::fs::read(&file).unwrap() == bundle.zip,
            "{id}: decrypted bytes differ from the CLI zip"
        );
        assert_eq!(hash, bundle.sha256, "{id}: plaintext hash");
        assert_eq!(
            checksum::sha256_file(&file).unwrap(),
            bundle.sha256,
            "{id}: file checksum"
        );

        // Streaming decryptor, fed in uneven chunks.
        let mut decryptor = aes_cbc::CbcDecryptor::new(&session.key, &session.iv);
        let mut plain = Vec::new();
        for chunk in bundle.encrypted.chunks(4099) {
            decryptor.update(chunk, &mut plain);
        }
        decryptor
            .finish(&mut plain)
            .unwrap_or_else(|error| panic!("{id}: finish: {error}"));
        assert!(plain == bundle.zip, "{id}: streamed plaintext differs from the CLI zip");

        let expected = crypto::decrypt_checksum(&bundle.checksum, &fixture.public_key)
            .unwrap_or_else(|error| panic!("{id}: decrypt checksum: {error}"));
        assert_eq!(expected, bundle.sha256, "{id}: decrypted checksum");
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
            assert_eq!(&checksum::sha256_hex(&content), sha256, "{id}: {path}");
        }
    }
}
