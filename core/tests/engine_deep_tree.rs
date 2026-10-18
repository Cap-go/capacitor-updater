//! A bundle with a deep folder chain must not crash the app when it is deleted.
//!
//! `std::fs::remove_dir_all` recurses once per directory level (about 2 KiB of stack per
//! level on Apple platforms). iOS runs plugin methods on GCD worker threads (512 KiB stack)
//! and Android on Java threads (about 1 MiB), so deleting a bundle a few hundred levels deep
//! from a host thread overflowed the stack and aborted the process. Kept in its own test
//! binary: a stack overflow aborts every test running in the same process.

mod support;

use std::io::Write;

use serde_json::json;
use support::{core, TestEngine};

/// Smaller than any host thread that calls the engine (iOS GCD workers: 512 KiB).
const HOST_THREAD_STACK: usize = 256 * 1024;

#[test]
fn deleting_a_deeply_nested_bundle_does_not_overflow_a_host_thread_stack() {
    let t = TestEngine::new(json!({}));
    let destination = t.root().join("versions").join("DEEPBUNDLE");
    // As deep as the platform path limit allows (macOS/iOS: 1024 bytes), one-letter folders.
    let room = 1000usize.saturating_sub(destination.as_os_str().len() + 8);
    let depth = (room / 2).min(1000);
    assert!(
        depth >= 200,
        "temp dir path too long for this test: {}",
        destination.display()
    );

    let zip_path = t.root().join("deep.zip");
    let mut writer = zip::ZipWriter::new(std::fs::File::create(&zip_path).unwrap());
    let options = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    writer.start_file("index.html", options).unwrap();
    writer.write_all(b"<html></html>").unwrap();
    writer
        .start_file(format!("{}f.js", "a/".repeat(depth)), options)
        .unwrap();
    writer.write_all(b"x").unwrap();
    writer.finish().unwrap();

    // Refusing such an archive is fine too; if it extracts, deleting it must work.
    let extracted = core()
        .try_test(
            "extractZip",
            json!({ "zip": zip_path.to_string_lossy(), "destination": destination.to_string_lossy() }),
        )
        .is_ok();

    let engine = t.engine.clone();
    let deleted = std::thread::Builder::new()
        .stack_size(HOST_THREAD_STACK)
        .spawn(move || engine.call("bundleDelete", &json!({ "id": "DEEPBUNDLE" })))
        .unwrap()
        .join()
        .expect("bundleDelete panicked");
    if extracted {
        assert_eq!(deleted.unwrap()["deleted"], true);
        assert!(!destination.exists(), "bundle folder left behind");
    }
}
