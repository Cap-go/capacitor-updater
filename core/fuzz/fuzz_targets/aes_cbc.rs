//! aes_cbc: the input is `<key 16> <iv 16> <ciphertext>`. Decrypts it in one call and in
//! uneven chunks (`CbcDecryptor`, PKCS#7 padding check): both must agree. The whole input is
//! also read as a session key `<iv>:<key>` and opened with the configured public key
//! (`crypto::bundle_session_key`). C: core-c/fuzz/aes_cbc.c.
#![no_main]

use capgo_updater_core::crypto::{self, aes_cbc::CbcDecryptor};
use capgo_updater_core_fuzz::PUBLIC_KEY;
use libfuzzer_sys::fuzz_target;

fn decrypt(key: &[u8; 16], iv: &[u8; 16], data: &[u8], chunked: bool) -> Option<Vec<u8>> {
    let mut decryptor = CbcDecryptor::new(key, iv);
    let mut out = Vec::new();
    let mut offset = 0;
    let mut step = 0usize;
    while offset < data.len() {
        let mut len = if chunked {
            1 + (step * 7 + data[offset] as usize) % 37
        } else {
            data.len()
        };
        len = len.min(data.len() - offset);
        decryptor.update(&data[offset..offset + len], &mut out);
        offset += len;
        step += 1;
    }
    decryptor.finish(&mut out).ok().map(|_| out)
}

fuzz_target!(|data: &[u8]| {
    if data.len() >= 32 {
        let key: [u8; 16] = data[..16].try_into().unwrap();
        let iv: [u8; 16] = data[16..32].try_into().unwrap();
        let ciphertext = &data[32..];
        let whole = decrypt(&key, &iv, ciphertext, false);
        let chunks = decrypt(&key, &iv, ciphertext, true);
        assert_eq!(whole, chunks, "chunked decryption disagrees");
        if let Some(plain) = whole {
            assert!(
                !ciphertext.is_empty()
                    && ciphertext.len().is_multiple_of(16)
                    && plain.len() < ciphertext.len()
                    && plain.len() + 16 >= ciphertext.len(),
                "{} plaintext bytes from {} ciphertext bytes",
                plain.len(),
                ciphertext.len()
            );
        }
    }
    let text = String::from_utf8_lossy(data);
    let text = text.split('\0').next().unwrap_or_default();
    let _ = crypto::bundle_session_key(PUBLIC_KEY, text);
});
