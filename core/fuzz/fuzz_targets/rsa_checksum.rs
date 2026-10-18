//! rsa_checksum: the input is a signed bundle checksum (hex or base64 text) checked with the
//! configured key (`crypto::decrypt_checksum`), then the raw block through the public
//! decrypt and the PKCS#1 type-1 unpadding. C: core-c/fuzz/rsa_checksum.c.
#![no_main]

use std::sync::OnceLock;

use capgo_updater_core::crypto::{self, rsa, RsaPublicKey};
use capgo_updater_core_fuzz::PUBLIC_KEY;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    static KEY: OnceLock<RsaPublicKey> = OnceLock::new();
    let key = KEY.get_or_init(|| RsaPublicKey::from_pem(PUBLIC_KEY).expect("fuzz public key"));
    let text = String::from_utf8_lossy(data);
    let text = text.split('\0').next().unwrap_or_default();
    if let Ok(checksum) = crypto::decrypt_checksum(text, PUBLIC_KEY) {
        assert!(checksum.len().is_multiple_of(2), "checksum {checksum:?} is not hex");
    }
    if let Some(payload) = rsa::unpad_type1(data) {
        assert!(!payload.is_empty() && payload.len() + 11 <= data.len());
    }
    let _ = key.public_decrypt(data);
});
