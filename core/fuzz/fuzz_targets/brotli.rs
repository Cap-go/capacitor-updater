//! brotli: the input is a manifest `.br` file, decoded up to 64 MiB by
//! brotli_decompressor::Decompressor (manifest.rs decode_brotli). C: core-c/fuzz/brotli.c.
#![no_main]

use capgo_updater_core_fuzz::drain;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let mut decoder = brotli_decompressor::Decompressor::new(data, 64 * 1024);
    drain(&mut decoder, 64 << 20);
});
