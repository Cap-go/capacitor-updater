//! Alt-Svc discovery parser, same input and origin as the C target.
#![no_main]
use libfuzzer_sys::fuzz_target;
fuzz_target!(|data: &[u8]| {
    let value = String::from_utf8_lossy(data);
    let _ = capgo_updater_core::altsvc::parse(&value, "example.com");
});
