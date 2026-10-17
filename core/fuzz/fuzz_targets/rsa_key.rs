//! rsa_key: the input is a configured public key (PEM text, or DER bytes). Parses it both
//! ways (`RsaPublicKey::from_pem` / `from_der`), computes its key id, and runs one public
//! operation with each key that parses. C: core-c/fuzz/rsa_key.c.
#![no_main]

use capgo_updater_core::crypto::{self, RsaPublicKey};
use libfuzzer_sys::fuzz_target;

fn exercise(key: Option<RsaPublicKey>) {
    let Some(key) = key else {
        return;
    };
    // One RSA-2048 block (other key sizes refuse it), as in the C target.
    let mut value = [0u8; 256];
    value[255] = 2;
    let _ = key.public_op(&value);
    let _ = key.public_decrypt(&value);
}

fuzz_target!(|data: &[u8]| {
    let text = String::from_utf8_lossy(data);
    let text = text.split('\0').next().unwrap_or_default();
    exercise(RsaPublicKey::from_pem(text).ok());
    exercise(RsaPublicKey::from_der(data).ok());
    let _ = crypto::key_id(text);
});
