//! json: the input is JSON text (manifests, server replies, stored records). Parses it and
//! checks that printing and parsing again gives the same value (the core parses floats with
//! serde_json's `float_roundtrip`, correctly rounded like the C core). C: core-c/fuzz/json.c.
#![no_main]

use libfuzzer_sys::fuzz_target;
use serde_json::Value;

fuzz_target!(|data: &[u8]| {
    let Ok(value) = serde_json::from_slice::<Value>(data) else {
        return;
    };
    let printed = value.to_string();
    let again: Value = serde_json::from_str(&printed).expect("printed JSON parses");
    assert_eq!(value, again, "JSON round trip changed the value: {printed}");
    assert_eq!(printed, again.to_string(), "JSON printing is not stable");
});
