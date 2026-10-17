//! inflate: the input is a raw deflate stream (zip entry data), decoded up to 64 MiB by
//! flate2's DeflateDecoder (zlib-rs), which the zip crate uses. C: core-c/fuzz/inflate.c.
#![no_main]

use capgo_updater_core_fuzz::drain;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let mut decoder = flate2::read::DeflateDecoder::new(data);
    drain(&mut decoder, 64 << 20);
});
