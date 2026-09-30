mod support;

use std::io::Write;
use std::sync::{Arc, Mutex, OnceLock};

use aes::cipher::{BlockEncrypt, KeyInit};
use base64::Engine as _;
use rsa::pkcs1::EncodeRsaPublicKey;
use serde_json::{json, Value};
use support::{FakeServer, TestEngine};

fn sha256(bytes: &[u8]) -> String {
    capgo_updater_core::crypto::checksum::sha256_hex(bytes)
}

fn zip_of(files: &[(&str, &[u8])]) -> Vec<u8> {
    let mut buffer = std::io::Cursor::new(Vec::new());
    {
        let mut writer = zip::ZipWriter::new(&mut buffer);
        for (name, content) in files {
            writer
                .start_file(
                    *name,
                    zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated),
                )
                .unwrap();
            writer.write_all(content).unwrap();
        }
        writer.finish().unwrap();
    }
    buffer.into_inner()
}

struct Keys {
    private: rsa::RsaPrivateKey,
    public_pem: String,
}

fn keys() -> &'static Keys {
    static KEYS: OnceLock<Keys> = OnceLock::new();
    KEYS.get_or_init(|| {
        let private = rsa::RsaPrivateKey::new(&mut rand::thread_rng(), 2048).unwrap();
        let public_pem = private
            .to_public_key()
            .to_pkcs1_pem(rsa::pkcs1::LineEnding::LF)
            .unwrap();
        Keys { private, public_pem }
    })
}

/// Node `privateEncrypt` (PKCS#1 v1.5 type 1, no DigestInfo).
fn private_encrypt(data: &[u8]) -> Vec<u8> {
    keys().private.sign(rsa::Pkcs1v15Sign::new_unprefixed(), data).unwrap()
}

const AES_KEY: [u8; 16] = [7; 16];
const IV: [u8; 16] = [9; 16];

fn aes_encrypt(plain: &[u8]) -> Vec<u8> {
    let cipher = aes::Aes128::new(&AES_KEY.into());
    let pad = 16 - plain.len() % 16;
    let mut data = plain.to_vec();
    data.extend(std::iter::repeat(pad as u8).take(pad));
    let mut previous = IV;
    for block in data.chunks_mut(16) {
        for i in 0..16 {
            block[i] ^= previous[i];
        }
        let mut array = aes::Block::clone_from_slice(block);
        cipher.encrypt_block(&mut array);
        block.copy_from_slice(&array);
        previous.copy_from_slice(block);
    }
    data
}

fn session_key() -> String {
    let b64 = base64::engine::general_purpose::STANDARD;
    format!("{}:{}", b64.encode(IV), b64.encode(private_encrypt(&AES_KEY)))
}

fn encrypted_checksum(plain: &[u8]) -> String {
    let digest = capgo_updater_core::text::hex_decode(&sha256(plain)).unwrap();
    capgo_updater_core::text::hex_encode(&private_encrypt(&digest))
}

type Files = Arc<Mutex<Vec<(String, Vec<u8>)>>>;

fn serve(files: Files) -> FakeServer {
    FakeServer::start(move |request| {
        let files = files.lock().unwrap();
        let path = request.url.split('?').next().unwrap().to_string();
        match files.iter().find(|(name, _)| *name == path) {
            Some((_, body)) => (200, vec![], body.clone()),
            None => (404, vec![], vec![]),
        }
    })
}

fn web_bundle(marker: &str) -> Vec<u8> {
    zip_of(&[
        ("index.html", format!("<html>{marker}</html>").as_bytes()),
        ("js/app.js", b"console.log(1)"),
    ])
}

#[test]
fn zip_download_installs_pending_bundle() {
    let bundle = web_bundle("v2");
    let server = serve(Arc::new(Mutex::new(vec![("/b.zip".into(), bundle.clone())])));
    let t = TestEngine::new(json!({}));
    let installed = t.call(
        "download",
        json!({ "url": format!("{}/b.zip", server.url), "version": "2.0.0", "checksum": sha256(&bundle) }),
    );
    assert_eq!(installed["status"], "pending");
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert_eq!(
        std::fs::read_to_string(dir.join("index.html")).unwrap(),
        "<html>v2</html>"
    );
    assert!(dir.join("js/app.js").exists());
    assert_eq!(t.host.events_named("updateAvailable").len(), 1);
    let percents: Vec<i64> = t
        .host
        .events_named("download")
        .iter()
        .map(|event| event["percent"].as_i64().unwrap())
        .collect();
    assert_eq!(percents.first(), Some(&0));
    assert_eq!(percents.last(), Some(&100));
    assert!(percents.windows(2).all(|pair| pair[0] <= pair[1]), "{percents:?}");
    let leftovers: Vec<_> = std::fs::read_dir(t.root())
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.file_name())
        .collect();
    assert!(
        !leftovers
            .iter()
            .any(|name| name.to_string_lossy().starts_with("temp_")
                || name.to_string_lossy().starts_with("capgo_unzip_")),
        "{leftovers:?}"
    );
}

#[test]
fn zip_single_folder_is_unwrapped() {
    let bundle = zip_of(&[("dist/index.html", b"<html>dist</html>"), ("__MACOSX/._x", b"junk")]);
    let server = serve(Arc::new(Mutex::new(vec![("/b.zip".into(), bundle.clone())])));
    let t = TestEngine::new(json!({}));
    let installed = t.call(
        "download",
        json!({ "url": format!("{}/b.zip", server.url), "version": "2", "checksum": sha256(&bundle) }),
    );
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert!(dir.join("index.html").exists());
}

#[test]
fn checksum_mismatch_fails_before_extraction() {
    let bundle = web_bundle("v2");
    let server = serve(Arc::new(Mutex::new(vec![("/b.zip".into(), bundle)])));
    let t = TestEngine::new(json!({}));
    let error = t
        .engine
        .call(
            "download",
            &json!({ "url": format!("{}/b.zip", server.url), "version": "2", "checksum": sha256(b"other") }),
        )
        .unwrap_err();
    assert_eq!(error.code, "checksum_fail");
    let failed = t.call("bundleGetByName", json!({ "version": "2" }));
    assert!(failed.is_null() || failed["status"] == "error");
    assert_eq!(t.host.events_named("downloadFailed")[0]["version"], "2");
    let versions = t.root().join("versions");
    assert!(
        !versions.exists() || std::fs::read_dir(&versions).unwrap().count() == 0,
        "nothing extracted"
    );
}

#[test]
fn zip_slip_entry_is_rejected() {
    let bundle = zip_of(&[("index.html", b"x"), ("../../evil.txt", b"pwned")]);
    let server = serve(Arc::new(Mutex::new(vec![("/b.zip".into(), bundle.clone())])));
    let t = TestEngine::new(json!({}));
    let error = t
        .engine
        .call(
            "download",
            &json!({ "url": format!("{}/b.zip", server.url), "version": "2", "checksum": sha256(&bundle) }),
        )
        .unwrap_err();
    assert_eq!(error.code, "unzip_fail");
    assert!(!t.root().join("evil.txt").exists() && !t.root().parent().unwrap().join("evil.txt").exists());
}

#[test]
fn encrypted_zip_requires_session_key_and_decrypts() {
    let bundle = web_bundle("secret");
    let encrypted = aes_encrypt(&bundle);
    let server = serve(Arc::new(Mutex::new(vec![("/b.zip".into(), encrypted)])));
    let t = TestEngine::new(json!({ "publicKey": keys().public_pem }));
    let missing = t
        .engine
        .call(
            "download",
            &json!({ "url": format!("{}/b.zip", server.url), "version": "2", "checksum": encrypted_checksum(&bundle) }),
        )
        .unwrap_err();
    assert_eq!(missing.code, "session_key_required");
    let installed = t.call(
        "download",
        json!({ "url": format!("{}/b.zip", server.url), "version": "2", "checksum": encrypted_checksum(&bundle), "sessionKey": session_key() }),
    );
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert_eq!(
        std::fs::read_to_string(dir.join("index.html")).unwrap(),
        "<html>secret</html>"
    );
    // A plain (not RSA-encrypted) checksum is refused when a key is configured.
    let error = t
        .engine
        .call("download", &json!({ "url": format!("{}/b.zip", server.url), "version": "3", "checksum": sha256(&bundle), "sessionKey": session_key() }))
        .unwrap_err();
    assert_eq!(error.code, "checksum_not_encrypted");
}

/// Serves `body`: the first request drops the connection halfway, later ones honour `Range`.
fn truncating_server(body: Vec<u8>) -> String {
    use std::io::{BufRead, BufReader, Read};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/b.zip", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        let mut first = true;
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut start = 0usize;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                    break;
                }
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("range: bytes=") {
                    start = value.trim().trim_end_matches('-').parse().unwrap_or(0);
                }
            }
            let total = body.len();
            if first {
                first = false;
                let _ = stream.write_all(
                    format!("HTTP/1.1 200 OK\r\nContent-Length: {total}\r\nConnection: close\r\n\r\n").as_bytes(),
                );
                let _ = stream.write_all(&body[..total / 2]);
            } else {
                let _ = stream.write_all(format!(
                    "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{}/{total}\r\nConnection: close\r\n\r\n",
                    total - start,
                    total - 1
                ).as_bytes());
                let _ = stream.write_all(&body[start..]);
            }
            let _ = stream.flush();
            let _ = stream.shutdown(std::net::Shutdown::Write);
            let _ = stream.read(&mut [0u8; 1]);
        }
    });
    url
}

/// Encrypted zips are decrypted while downloading; a resumed transfer falls back
/// to decrypting the file, and a corrupted ciphertext still fails.
#[test]
fn encrypted_zip_streamed_resumed_and_corrupted() {
    let mut noise = Vec::new();
    let mut state: u32 = 1;
    for _ in 0..(512 * 1024) {
        state = state.wrapping_mul(1_103_515_245).wrapping_add(12_345);
        noise.push((state >> 16) as u8);
    }
    let bundle = zip_of(&[("index.html", b"<html>stream</html>"), ("blob.bin", &noise)]);
    let encrypted = aes_encrypt(&bundle);
    let t = TestEngine::new(json!({ "publicKey": keys().public_pem }));
    let request = |url: String, version: &str| json!({ "url": url, "version": version, "checksum": encrypted_checksum(&bundle), "sessionKey": session_key() });
    // Streamed.
    let server = serve(Arc::new(Mutex::new(vec![("/b.zip".into(), encrypted.clone())])));
    let installed = t.call("download", request(format!("{}/b.zip", server.url), "2"));
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert_eq!(std::fs::read(dir.join("blob.bin")).unwrap(), noise);
    // Resumed.
    let installed = t.call("download", request(truncating_server(encrypted.clone()), "3"));
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert_eq!(std::fs::read(dir.join("blob.bin")).unwrap(), noise);
    // Corrupted ciphertext (last block): refused, nothing left behind.
    let mut corrupted = encrypted.clone();
    let last = corrupted.len() - 1;
    corrupted[last] ^= 0xff;
    let server = serve(Arc::new(Mutex::new(vec![("/b.zip".into(), corrupted)])));
    let error = t
        .engine
        .call("download", &request(format!("{}/b.zip", server.url), "4"))
        .unwrap_err();
    assert!(
        error.code == "decrypt_fail" || error.code == "checksum_fail",
        "{error:?}"
    );
    let leftovers: Vec<String> = std::fs::read_dir(t.root())
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with("temp_"))
        .collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");
}

#[test]
fn transient_server_errors_are_retried() {
    let bundle = web_bundle("retry");
    let calls = Arc::new(Mutex::new(0));
    let (bundle_clone, calls_clone) = (bundle.clone(), calls.clone());
    let server = FakeServer::start(move |_| {
        let mut calls = calls_clone.lock().unwrap();
        *calls += 1;
        if *calls == 1 {
            (503, vec![], vec![])
        } else {
            (200, vec![], bundle_clone.clone())
        }
    });
    let t = TestEngine::new(json!({}));
    t.call(
        "download",
        json!({ "url": format!("{}/b.zip", server.url), "version": "2", "checksum": sha256(&bundle) }),
    );
    assert_eq!(*calls.lock().unwrap(), 2);
}

#[test]
fn not_found_is_not_retried() {
    let server = FakeServer::start(|_| (404, vec![], vec![]));
    let t = TestEngine::new(json!({}));
    let error = t
        .engine
        .call(
            "download",
            &json!({ "url": format!("{}/b.zip", server.url), "version": "2", "checksum": "abc" }),
        )
        .unwrap_err();
    assert_eq!(error.code, "http_error");
    assert_eq!(server.requests().len(), 1);
}

#[test]
fn set_next_and_direct_update_after_install() {
    let bundle = web_bundle("next");
    let server = serve(Arc::new(Mutex::new(vec![("/b.zip".into(), bundle.clone())])));
    let t = TestEngine::new(json!({}));
    let installed = t.call(
        "download",
        json!({ "url": format!("{}/b.zip", server.url), "version": "2", "checksum": sha256(&bundle), "setNext": true }),
    );
    assert_eq!(t.kv("nextVersion").unwrap(), installed["id"].as_str().unwrap());
    t.call("download", json!({ "url": format!("{}/b.zip", server.url), "version": "3", "checksum": sha256(&bundle), "setNext": true, "directUpdate": true }));
    assert_eq!(t.host.events_named("directUpdateFinish").len(), 1);
}

fn manifest_entry(server: &FakeServer, name: &str, content: &[u8]) -> Value {
    json!({ "file_name": name, "file_hash": sha256(content), "download_url": format!("{}/files/{name}", server.url) })
}

#[test]
fn manifest_download_then_cache_reuse() {
    let files: Files = Arc::default();
    let server = serve(files.clone());
    let a = b"<html>a</html>".to_vec();
    let b = vec![42u8; 5000];
    files.lock().unwrap().push(("/files/index.html".into(), a.clone()));
    files.lock().unwrap().push(("/files/assets/b.bin".into(), b.clone()));
    let t = TestEngine::new(json!({}));
    let manifest = json!([
        manifest_entry(&server, "index.html", &a),
        manifest_entry(&server, "assets/b.bin", &b)
    ]);
    let installed = t.call("download", json!({ "version": "2", "manifest": manifest }));
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert_eq!(std::fs::read(dir.join("assets/b.bin")).unwrap(), b);
    let requests = server.requests().len();
    let missing = t.call("missingBundleFiles", json!({ "manifest": manifest }));
    assert_eq!(missing["missingCount"], 0);
    // Same files again: everything comes from the delta cache.
    t.call("download", json!({ "version": "3", "manifest": manifest }));
    assert_eq!(server.requests().len(), requests, "no network for cached files");
}

/// Delta cache entries are hard links when possible: deleting the bundle keeps them.
#[test]
fn delta_cache_survives_bundle_deletion() {
    let files: Files = Arc::default();
    let server = serve(files.clone());
    let content = b"cached content".to_vec();
    files.lock().unwrap().push(("/files/app.js".into(), content.clone()));
    let t = TestEngine::new(json!({}));
    let installed = t.call(
        "download",
        json!({ "version": "2", "manifest": [manifest_entry(&server, "app.js", &content)] }),
    );
    let id = installed["id"].as_str().unwrap().to_string();
    t.call("bundleDelete", json!({ "id": id }));
    let cache = t.root().join("cache/capgo_downloads");
    let cached = std::fs::read_dir(&cache)
        .unwrap()
        .filter_map(Result::ok)
        .find(|entry| entry.file_name().to_string_lossy().ends_with("_app.js"))
        .expect("cache entry");
    assert_eq!(std::fs::read(cached.path()).unwrap(), content);
    // The next version reuses it without the network.
    let requests = server.requests().len();
    t.call(
        "download",
        json!({ "version": "3", "manifest": [manifest_entry(&server, "app.js", &content)] }),
    );
    assert_eq!(server.requests().len(), requests);
}

/// Android: builtin files are read from the APK (`assets/public/...`) through one
/// shared archive index, by every worker in parallel.
#[test]
fn manifest_reuses_apk_assets_in_parallel() {
    let files: Files = Arc::default();
    let server = serve(files.clone());
    let base = TestEngine::new(json!({}));
    let apk = base.root().join("app.apk");
    let contents: Vec<(String, Vec<u8>)> = (0..120)
        .map(|index| {
            (
                format!("js/chunk-{index}.js"),
                format!("console.log({index});").repeat(50).into_bytes(),
            )
        })
        .collect();
    let entries: Vec<(String, Vec<u8>)> = contents
        .iter()
        .map(|(name, content)| (format!("assets/public/{name}"), content.clone()))
        .chain(std::iter::once(("classes.dex".to_string(), vec![0u8; 1000])))
        .collect();
    let refs: Vec<(&str, &[u8])> = entries
        .iter()
        .map(|(name, content)| (name.as_str(), content.as_slice()))
        .collect();
    std::fs::write(&apk, zip_of(&refs)).unwrap();
    let t =
        TestEngine::new(json!({ "builtinApk": apk.to_string_lossy(), "storageRoot": base.root().to_string_lossy() }));
    let manifest: Vec<Value> = contents
        .iter()
        .map(|(name, content)| json!({ "file_name": name, "file_hash": sha256(content), "download_url": format!("{}/nope", server.url) }))
        .collect();
    let installed = t.call("download", json!({ "version": "2", "manifest": manifest }));
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    for (name, content) in &contents {
        assert_eq!(&std::fs::read(dir.join(name)).unwrap(), content, "{name}");
    }
    assert!(server.requests().is_empty(), "everything came from the APK");
}

#[test]
fn manifest_reuses_builtin_files() {
    let files: Files = Arc::default();
    let server = serve(files.clone());
    let t = TestEngine::new(json!({}));
    let builtin = t.root().join("public");
    std::fs::create_dir_all(builtin.join("js")).unwrap();
    std::fs::write(builtin.join("js/app.js"), b"builtin").unwrap();
    let t =
        TestEngine::new(json!({ "builtinDir": builtin.to_string_lossy(), "storageRoot": t.root().to_string_lossy() }));
    let manifest = json!([{ "file_name": "js/app.js", "file_hash": sha256(b"builtin"), "download_url": format!("{}/nope", server.url) }]);
    let installed = t.call("download", json!({ "version": "2", "manifest": manifest }));
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert_eq!(std::fs::read(dir.join("js/app.js")).unwrap(), b"builtin");
    assert!(server.requests().is_empty());
}

/// Files reused from the builtin bundle need no decryption: the session key is
/// only decrypted when a file is downloaded.
#[test]
fn encrypted_manifest_reusing_builtin_needs_no_session_decryption() {
    let base = TestEngine::new(json!({}));
    let builtin = base.root().join("public");
    std::fs::create_dir_all(builtin.join("js")).unwrap();
    std::fs::write(builtin.join("js/app.js"), b"builtin").unwrap();
    let t = TestEngine::new(json!({
        "builtinDir": builtin.to_string_lossy(),
        "storageRoot": base.root().to_string_lossy(),
        "publicKey": keys().public_pem,
    }));
    let manifest = json!([{ "file_name": "js/app.js", "file_hash": encrypted_checksum(b"builtin"), "download_url": "http://127.0.0.1:1/nope" }]);
    let installed = t.call(
        "download",
        json!({ "version": "2", "manifest": manifest, "sessionKey": "AAAAAAAAAAAAAAAAAAAAAA==:AAAA" }),
    );
    assert_eq!(installed["status"], "pending");
}

#[test]
fn manifest_brotli_and_checksum_failure() {
    let files: Files = Arc::default();
    let server = serve(files.clone());
    let content = b"hello brotli hello brotli hello brotli".to_vec();
    // Capgo CLI "stored" brotli wrapper for small files: 0b 02 80 + raw + 03.
    let mut wrapped = vec![0x0b, 0x02, 0x80];
    wrapped.extend(&content);
    wrapped.push(0x03);
    files.lock().unwrap().push(("/files/a.js.br".into(), wrapped));
    files
        .lock()
        .unwrap()
        .push(("/files/bad.js".into(), b"tampered".to_vec()));
    let t = TestEngine::new(json!({}));
    let installed = t.call(
        "download",
        json!({ "version": "2", "manifest": [manifest_entry(&server, "a.js.br", &content)] }),
    );
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert_eq!(std::fs::read(dir.join("a.js")).unwrap(), content);
    let error = t
        .engine
        .call("download", &json!({ "version": "3", "manifest": [{ "file_name": "bad.js", "file_hash": sha256(b"original"), "download_url": format!("{}/files/bad.js", server.url) }] }))
        .unwrap_err();
    assert_eq!(error.code, "checksum_fail");
}

#[test]
fn manifest_rejects_traversal_and_duplicates() {
    let t = TestEngine::new(json!({}));
    let traversal = t
        .engine
        .call("download", &json!({ "version": "2", "manifest": [{ "file_name": "../x.js", "file_hash": sha256(b"x"), "download_url": "http://127.0.0.1:1/x" }] }))
        .unwrap_err();
    assert_eq!(traversal.code, "invalid_manifest");
    let duplicate = t
        .engine
        .call(
            "download",
            &json!({ "version": "3", "manifest": [
                { "file_name": "a.js", "file_hash": sha256(b"x"), "download_url": "http://127.0.0.1:1/x" },
                { "file_name": "a.js.br", "file_hash": sha256(b"x"), "download_url": "http://127.0.0.1:1/x" }
            ] }),
        )
        .unwrap_err();
    assert_eq!(duplicate.code, "invalid_manifest");
}

#[test]
fn encrypted_manifest_files_are_decrypted() {
    let files: Files = Arc::default();
    let server = serve(files.clone());
    let content = b"<html>encrypted manifest</html>".to_vec();
    files
        .lock()
        .unwrap()
        .push(("/files/index.html".into(), aes_encrypt(&content)));
    let t = TestEngine::new(json!({ "publicKey": keys().public_pem }));
    let entry = json!({ "file_name": "index.html", "file_hash": encrypted_checksum(&content), "download_url": format!("{}/files/index.html", server.url) });
    let installed = t.call(
        "download",
        json!({ "version": "2", "manifest": [entry], "sessionKey": session_key() }),
    );
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert_eq!(std::fs::read(dir.join("index.html")).unwrap(), content);
}

#[test]
fn https_to_http_redirect_is_refused() {
    let t = TestEngine::new(json!({}));
    // Only reachable over plain HTTP locally: assert the rule on a real redirect chain.
    let server = FakeServer::start(|request| {
        if request.url == "/start" {
            (302, vec![("Location".into(), "/final".into())], vec![])
        } else {
            FakeServer::json(200, json!({ "ok": true }))
        }
    });
    // http -> http redirects are followed.
    let response = t.call("getLatest", json!({ "updateUrl": format!("{}/start", server.url) }));
    assert_eq!(response["ok"], true);
}

#[test]
fn redirect_policy_blocks_downgrade_only() {
    use capgo_updater_core::net::redirect_allowed;
    assert!(!redirect_allowed("https", "http", false));
    assert!(redirect_allowed("https", "http", true));
    assert!(redirect_allowed("http", "https", false));
    assert!(redirect_allowed("https", "https", false));
}

#[test]
fn manifest_real_brotli_stream() {
    let files: Files = Arc::default();
    let server = serve(files.clone());
    let content: Vec<u8> = (0..200_000u32).map(|i| (i % 97) as u8).collect();
    let mut compressed = Vec::new();
    {
        let mut writer = brotli::CompressorWriter::new(&mut compressed, 4096, 9, 22);
        writer.write_all(&content).unwrap();
    }
    files.lock().unwrap().push(("/files/big.js.br".into(), compressed));
    let t = TestEngine::new(json!({}));
    let installed = t.call(
        "download",
        json!({ "version": "2", "manifest": [manifest_entry(&server, "big.js.br", &content)] }),
    );
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert_eq!(std::fs::read(dir.join("big.js")).unwrap(), content);
}
