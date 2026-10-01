//! RSA signature edge cases (moved from the iOS RsaContractTests): the public
//! operation, PKCS#1 type-1 padding and the cached key behind `decrypt_checksum`.

use std::path::Path;

use capgo_updater_core::crypto::{self, rsa::unpad_type1, RsaPublicKey};
use capgo_updater_core::text::{hex_decode, hex_encode};
use rsa::pkcs1::EncodeRsaPublicKey;
use serde_json::Value;

struct SignedVector {
    key: String,
    ciphertext: Vec<u8>,
    plaintext: Vec<u8>,
}

/// First `rsaPublicDecrypt` case of native-contract-tests/crypto-rsa.json.
fn signed_vector() -> SignedVector {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../native-contract-tests/crypto-rsa.json");
    let fixture: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let case = &fixture["rsaPublicDecrypt"][0];
    SignedVector {
        key: fixture["publicKeyPem"].as_str().unwrap().to_string(),
        ciphertext: hex_decode(case["input"]["ciphertextHex"].as_str().unwrap()).unwrap(),
        plaintext: hex_decode(case["expect"]["plaintextHex"].as_str().unwrap()).unwrap(),
    }
}

#[test]
fn public_decrypt_rejects_modified_and_wrong_length_signatures() {
    let vector = signed_vector();
    let key = RsaPublicKey::from_pem(&vector.key).unwrap();
    assert_eq!(key.public_decrypt(&vector.ciphertext).unwrap(), vector.plaintext);
    assert!(key.public_decrypt(&[]).is_err());
    assert!(key
        .public_decrypt(&vector.ciphertext[..vector.ciphertext.len() - 1])
        .is_err());
    let mut longer = vector.ciphertext.clone();
    longer.push(0);
    assert!(key.public_decrypt(&longer).is_err());
    for index in 0..vector.ciphertext.len() {
        let mut changed = vector.ciphertext.clone();
        changed[index] ^= 1;
        assert!(key.public_decrypt(&changed).is_err(), "modified signature byte {index}");
    }
}

#[test]
fn type_one_padding_requires_complete_valid_block() {
    let block = |parts: &[&[u8]]| parts.concat();
    let payload = [0xab; 32];
    let valid = block(&[&[0, 1], &[0xff; 221], &[0], &payload]);
    assert_eq!(unpad_type1(&valid), Some(payload.to_vec()));

    // RFC 8017 permits a minimum of eight padding bytes.
    let longest_payload = [0xab; 245];
    let minimum_padding = block(&[&[0, 1], &[0xff; 8], &[0], &longest_payload]);
    assert_eq!(unpad_type1(&minimum_padding), Some(longest_payload.to_vec()));
    let short_padding = block(&[&[0, 1], &[0xff; 7], &[0], &[0xab; 246]]);
    assert_eq!(unpad_type1(&short_padding), None);

    for (index, replacement) in [(0, 1u8), (1, 2), (2, 0x7f)] {
        let mut malformed = valid.clone();
        malformed[index] = replacement;
        assert_eq!(unpad_type1(&malformed), None, "byte {index}");
    }
    // No separator, and a separator with an empty payload.
    assert_eq!(unpad_type1(&block(&[&[0, 1], &[0xff; 254]])), None);
    assert_eq!(unpad_type1(&block(&[&[0, 1], &[0xff; 253], &[0]])), None);
}

#[test]
fn checksum_key_cache_handles_invalid_keys_rotation_and_concurrent_callers() {
    let vector = signed_vector();
    let checksum = hex_encode(&vector.ciphertext);
    let expected = hex_encode(&vector.plaintext);
    assert_eq!(crypto::decrypt_checksum(&checksum, &vector.key).unwrap(), expected);
    for invalid in ["not-a-public-key", "YWJj"] {
        assert!(RsaPublicKey::from_pem(invalid).is_err(), "{invalid}");
        assert_eq!(
            crypto::decrypt_checksum(&checksum, invalid).unwrap_err().code,
            "invalid_public_key"
        );
    }

    let other = rsa::RsaPrivateKey::new(&mut rand::thread_rng(), 2048).unwrap();
    let other_pem = other.to_public_key().to_pkcs1_pem(rsa::pkcs1::LineEnding::LF).unwrap();
    assert!(crypto::decrypt_checksum(&checksum, &other_pem).is_err());
    assert_eq!(
        crypto::decrypt_checksum(&checksum, &vector.key).unwrap(),
        expected,
        "switching keys must not keep the previous key"
    );

    std::thread::scope(|scope| {
        for index in 0..32 {
            let (checksum, expected, key, other_pem) = (&checksum, &expected, &vector.key, &other_pem);
            scope.spawn(move || {
                for round in 0..4 {
                    if (index + round) % 2 == 0 {
                        assert_eq!(&crypto::decrypt_checksum(checksum, key).unwrap(), expected);
                    } else {
                        assert!(crypto::decrypt_checksum(checksum, other_pem).is_err());
                    }
                }
            });
        }
    });

    // Keys pasted into JSON config sometimes keep literal "\n" sequences.
    let escaped = vector.key.replace('\n', "\\n");
    assert_eq!(crypto::decrypt_checksum(&checksum, &escaped).unwrap(), expected);
}
