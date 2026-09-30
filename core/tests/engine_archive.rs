//! Archive extraction, delta cache population and zip resume (ported from the
//! iOS/Android helper tests that exercised the native implementations).

mod support;

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::Path;
use std::sync::{Arc, Mutex};

use capgo_updater_core::engine::archive::{extract_zip, install_extracted, ExtractError};
use serde_json::json;
use support::TestEngine;

enum Entry<'a> {
    File(&'a str, &'a [u8]),
    Dir(&'a str),
    Symlink(&'a str, &'a str),
}

fn zip_of(entries: &[Entry<'_>]) -> Vec<u8> {
    let mut buffer = std::io::Cursor::new(Vec::new());
    {
        let mut writer = zip::ZipWriter::new(&mut buffer);
        let options = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        for entry in entries {
            match entry {
                Entry::File(name, content) => {
                    writer.start_file(*name, options).unwrap();
                    writer.write_all(content).unwrap();
                }
                Entry::Dir(name) => writer.add_directory(*name, options).unwrap(),
                Entry::Symlink(name, target) => writer.add_symlink(*name, *target, options).unwrap(),
            }
        }
        writer.finish().unwrap();
    }
    buffer.into_inner()
}

fn extract(bytes: &[u8], root: &Path) -> Result<std::path::PathBuf, ExtractError> {
    let zip = root.join("bundle.zip");
    std::fs::write(&zip, bytes).unwrap();
    let out = root.join("out");
    extract_zip(&zip, &out, &mut |_, _| {}, &|| false)?;
    Ok(out)
}

#[test]
fn extracts_nested_files_directories_and_symlinks() {
    let dir = tempfile::tempdir().unwrap();
    let bytes = zip_of(&[
        Entry::File("index.html", b"<html></html>"),
        Entry::Dir("assets/empty/"),
        Entry::File("assets/js/app.js", b"console.log(1)"),
        Entry::Symlink("assets/js/alias.js", "app.js"),
    ]);
    let out = extract(&bytes, dir.path()).unwrap();
    assert_eq!(std::fs::read(out.join("assets/js/app.js")).unwrap(), b"console.log(1)");
    assert!(out.join("assets/empty").is_dir());
    let link = out.join("assets/js/alias.js");
    assert!(std::fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
    assert_eq!(std::fs::read(&link).unwrap(), b"console.log(1)");
}

#[test]
fn rejects_symlinks_escaping_their_directory() {
    for target in ["../../outside.txt", "/etc/passwd", "../sibling.js"] {
        let dir = tempfile::tempdir().unwrap();
        let bytes = zip_of(&[
            Entry::File("index.html", b"x"),
            Entry::Symlink("assets/link.js", target),
        ]);
        let error = extract(&bytes, dir.path()).unwrap_err();
        assert_eq!(error, ExtractError::PathEscape("assets/link.js".into()), "{target}");
        assert!(!dir.path().join("out/assets/link.js").exists());
    }
}

#[test]
fn rejects_symlink_chains_escaping_the_root() {
    let dir = tempfile::tempdir().unwrap();
    let bytes = zip_of(&[
        Entry::Symlink("m", "."),
        Entry::Symlink("l", "m/.."),
        Entry::File("l/x", b"pwned"),
    ]);
    let error = extract(&bytes, dir.path()).unwrap_err();
    assert!(matches!(error, ExtractError::PathEscape(_)), "{error:?}");
    assert!(!dir.path().join("x").exists());
    // A directory entry reached through a symlink to the outside is refused too.
    let dir = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("out")).unwrap();
    std::os::unix::fs::symlink(outside.path(), dir.path().join("out/escape")).unwrap();
    let zip = dir.path().join("bundle.zip");
    std::fs::write(
        &zip,
        zip_of(&[Entry::Dir("escape/sub/"), Entry::File("escape/y", b"pwned")]),
    )
    .unwrap();
    assert!(extract_zip(&zip, &dir.path().join("out"), &mut |_, _| {}, &|| false).is_err());
    assert!(!outside.path().join("y").exists());
    assert!(!outside.path().join("sub").exists());
}

#[test]
fn rejects_traversal_and_windows_entries() {
    let dir = tempfile::tempdir().unwrap();
    let error = extract(&zip_of(&[Entry::File("../evil.txt", b"x")]), dir.path()).unwrap_err();
    assert_eq!(error.stat(), Some("canonical_path_fail"));
    assert!(!dir.path().join("evil.txt").exists());
    let error = extract(&zip_of(&[Entry::File("assets\\app.js", b"x")]), dir.path()).unwrap_err();
    assert_eq!(error.stat(), Some("windows_path_fail"));
}

#[test]
fn rejects_corrupt_archives_and_crc_mismatch() {
    let dir = tempfile::tempdir().unwrap();
    let error = extract(b"PK\x03\x04 definitely not a zip", dir.path()).unwrap_err();
    assert!(matches!(error, ExtractError::Failed(_)), "{error:?}");

    // Flip one byte of stored (uncompressed) data: the CRC check must fail.
    let mut buffer = std::io::Cursor::new(Vec::new());
    {
        let mut writer = zip::ZipWriter::new(&mut buffer);
        let options = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        writer.start_file("index.html", options).unwrap();
        writer.write_all(b"<html>original</html>").unwrap();
        writer.finish().unwrap();
    }
    let mut bytes = buffer.into_inner();
    let at = bytes.windows(8).position(|window| window == b"original").unwrap();
    bytes[at] = b'X';
    let dir = tempfile::tempdir().unwrap();
    assert!(matches!(
        extract(&bytes, dir.path()).unwrap_err(),
        ExtractError::Failed(_)
    ));
}

#[test]
fn cancellation_stops_between_entries() {
    let dir = tempfile::tempdir().unwrap();
    let zip = dir.path().join("bundle.zip");
    std::fs::write(&zip, zip_of(&[Entry::File("a", b"1"), Entry::File("b", b"2")])).unwrap();
    let error = extract_zip(&zip, &dir.path().join("out"), &mut |_, _| {}, &|| true).unwrap_err();
    assert_eq!(error, ExtractError::Cancelled);
}

#[test]
fn install_unwraps_single_top_level_folder_only_without_root_index() {
    let dir = tempfile::tempdir().unwrap();
    let out = extract(
        &zip_of(&[
            Entry::File("dist/index.html", b"dist"),
            Entry::File("__MACOSX/._junk", b""),
        ]),
        dir.path(),
    )
    .unwrap();
    let target = dir.path().join("bundle");
    install_extracted(&out, &target).unwrap();
    assert_eq!(std::fs::read(target.join("index.html")).unwrap(), b"dist");

    let dir = tempfile::tempdir().unwrap();
    let out = extract(&zip_of(&[Entry::File("assets/app.js", b"js")]), dir.path()).unwrap();
    std::fs::write(out.join("index.html"), b"root").unwrap();
    let target = dir.path().join("bundle");
    install_extracted(&out, &target).unwrap();
    assert!(
        target.join("assets/app.js").exists(),
        "root index.html keeps the layout"
    );

    let dir = tempfile::tempdir().unwrap();
    let empty = dir.path().join("empty");
    std::fs::create_dir_all(&empty).unwrap();
    assert_eq!(
        install_extracted(&empty, &dir.path().join("bundle")).unwrap_err().code,
        "unzip_fail"
    );
}

// ---- delta cache ------------------------------------------------------------------------------

fn sha256(bytes: &[u8]) -> String {
    capgo_updater_core::crypto::checksum::sha256_hex(bytes)
}

fn delta_engine() -> (TestEngine, std::path::PathBuf) {
    let base = TestEngine::new(json!({}));
    let builtin = base.root().join("public");
    std::fs::create_dir_all(&builtin).unwrap();
    let t = TestEngine::new(json!({
        "builtinDir": builtin.to_string_lossy(),
        "bundleRoot": base.root().join("versions").to_string_lossy(),
        "cacheDir": base.root().join("cache").to_string_lossy(),
    }));
    // Keep the directory alive for the engine's lifetime.
    std::mem::forget(base);
    (t, builtin)
}

#[test]
fn populate_delta_cache_caches_bundle_files_by_hash() {
    let (t, builtin) = delta_engine();
    let bundle = builtin.parent().unwrap().join("versions/b1");
    std::fs::create_dir_all(bundle.join("assets")).unwrap();
    std::fs::write(bundle.join("assets/new.js"), b"only in bundle").unwrap();
    std::fs::write(bundle.join("index.html"), b"<html>v2</html>").unwrap();
    t.call("populateDeltaCache", json!({ "id": "b1" }));
    let cache = builtin.parent().unwrap().join("cache");
    assert_eq!(
        std::fs::read(cache.join(format!("{}_new.js", sha256(b"only in bundle")))).unwrap(),
        b"only in bundle"
    );
    assert!(cache
        .join(format!("{}_index.html", sha256(b"<html>v2</html>")))
        .exists());
}

#[test]
fn populate_delta_cache_skips_files_identical_to_builtin() {
    let (t, builtin) = delta_engine();
    std::fs::create_dir_all(builtin.join("assets")).unwrap();
    std::fs::write(builtin.join("assets/app.js"), b"shared").unwrap();
    std::fs::write(builtin.join("changed.js"), b"old").unwrap();
    let bundle = builtin.parent().unwrap().join("versions/b1");
    std::fs::create_dir_all(bundle.join("assets")).unwrap();
    std::fs::write(bundle.join("assets/app.js"), b"shared").unwrap();
    std::fs::write(bundle.join("changed.js"), b"new").unwrap();
    t.call("populateDeltaCache", json!({ "id": "b1" }));
    let cache = builtin.parent().unwrap().join("cache");
    assert!(!cache.join(format!("{}_app.js", sha256(b"shared"))).exists());
    assert!(cache.join(format!("{}_changed.js", sha256(b"new"))).exists());
}

#[test]
fn populate_delta_cache_rejects_traversal_ids() {
    let (t, builtin) = delta_engine();
    std::fs::write(builtin.join("secret.txt"), b"secret").unwrap();
    let _ = t.engine.call("populateDeltaCache", &json!({ "id": "../public" }));
    let cache = builtin.parent().unwrap().join("cache");
    assert!(!cache.join(format!("{}_secret.txt", sha256(b"secret"))).exists());
}

// ---- zip resume -------------------------------------------------------------------------------

/// Serves `body`: the first request advertises the full length but drops the
/// connection halfway; later requests honour `Range` with a 206.
fn truncating_server(body: Vec<u8>) -> (String, Arc<Mutex<Vec<Option<String>>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/b.zip", listener.local_addr().unwrap());
    let ranges: Arc<Mutex<Vec<Option<String>>>> = Arc::default();
    let seen = ranges.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut range = None;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                    break;
                }
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("range: bytes=") {
                    range = Some(value.trim().trim_end_matches('-').to_string());
                }
            }
            let first = seen.lock().unwrap().is_empty();
            seen.lock().unwrap().push(range.clone());
            let total = body.len();
            if first {
                let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {total}\r\nConnection: close\r\n\r\n");
                let _ = stream.write_all(head.as_bytes());
                let _ = stream.write_all(&body[..total / 2]);
            } else {
                let start: usize = range.as_deref().and_then(|value| value.parse().ok()).unwrap_or(0);
                let head = format!(
                    "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{}/{total}\r\nConnection: close\r\n\r\n",
                    total - start,
                    total - 1
                );
                let _ = stream.write_all(head.as_bytes());
                let _ = stream.write_all(&body[start..]);
            }
            let _ = stream.flush();
            drop(reader);
            let _ = stream.shutdown(std::net::Shutdown::Both);
            let _ = stream.read(&mut [0u8; 1]);
        }
    });
    (url, ranges)
}

#[test]
fn interrupted_zip_download_resumes_with_range() {
    // Incompressible payload so the zip is large enough to split meaningfully.
    let mut noise = Vec::with_capacity(256 * 1024);
    let mut state: u32 = 12345;
    for _ in 0..256 * 1024 {
        state = state.wrapping_mul(1_103_515_245).wrapping_add(12345);
        noise.push((state >> 16) as u8);
    }
    let bundle = zip_of(&[
        Entry::File("index.html", b"<html>resume</html>"),
        Entry::File("blob.bin", &noise),
    ]);
    let (url, ranges) = truncating_server(bundle.clone());
    let t = TestEngine::new(json!({}));
    let installed = t.call(
        "download",
        json!({ "url": url, "version": "2", "checksum": sha256(&bundle) }),
    );
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    assert_eq!(std::fs::read(dir.join("blob.bin")).unwrap(), noise);
    let ranges = ranges.lock().unwrap().clone();
    assert!(ranges.len() >= 2, "{ranges:?}");
    assert_eq!(ranges[0], None);
    let resumed_at: usize = ranges[1].as_deref().unwrap().parse().unwrap();
    assert!(resumed_at > 0 && resumed_at < bundle.len(), "{ranges:?}");
}
