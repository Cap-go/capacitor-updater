//! Throughput smoke test for the bundle hot paths. Run with
//! `cargo test --release --test perf -- --ignored --nocapture`.

mod support;

use std::io::Write;
use std::time::Instant;

use serde_json::json;
use support::core;

fn noise(len: usize) -> Vec<u8> {
    let mut state: u32 = 7;
    (0..len)
        .map(|_| {
            state = state.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            (state >> 16) as u8
        })
        .collect()
}

#[test]
#[ignore]
fn hot_path_throughput() {
    let dir = tempfile::tempdir().unwrap();
    let size = 100 * 1024 * 1024;
    let data = noise(size);
    let path = dir.path().join("blob.bin");
    std::fs::write(&path, &data).unwrap();
    let mb = size as f64 / 1_048_576.0;

    let start = Instant::now();
    core().test("sha256File", json!({ "path": path.to_string_lossy() }));
    println!("sha256: {:.0} MB/s", mb / start.elapsed().as_secs_f64());

    // AES-CBC decrypt (the ciphertext does not need to be valid for throughput: the
    // padding error at the end is ignored).
    let start = Instant::now();
    let _ = core().try_test(
        "decryptFileTo",
        json!({
            "source": path.to_string_lossy(),
            "destination": dir.path().join("plain.bin").to_string_lossy(),
            "keyHex": "01".repeat(16),
            "ivHex": "02".repeat(16),
        }),
    );
    println!("aes-cbc: {:.0} MB/s", mb / start.elapsed().as_secs_f64());

    let zip_path = dir.path().join("bundle.zip");
    {
        let file = std::fs::File::create(&zip_path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        let text = "console.log('capgo');\n".repeat(size / 22);
        writer.start_file("index.js", options).unwrap();
        writer.write_all(text.as_bytes()).unwrap();
        writer.finish().unwrap();
    }
    let start = Instant::now();
    core().test(
        "extractZip",
        json!({ "zip": zip_path.to_string_lossy(), "destination": dir.path().join("out").to_string_lossy() }),
    );
    println!(
        "unzip (inflate + CRC + write): {:.0} MB/s",
        mb / start.elapsed().as_secs_f64()
    );
}
