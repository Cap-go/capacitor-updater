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

fn der(tag: u8, content: &[u8]) -> Vec<u8> {
    let mut out = vec![tag];
    if content.len() < 0x80 {
        out.push(content.len() as u8);
    } else {
        let len: Vec<u8> = content
            .len()
            .to_be_bytes()
            .into_iter()
            .skip_while(|byte| *byte == 0)
            .collect();
        out.push(0x80 | len.len() as u8);
        out.extend(len);
    }
    out.extend_from_slice(content);
    out
}

/// PKCS#1 `RSAPublicKey` DER for any (n, e), including exponents `rsa` itself refuses.
fn pkcs1_der(modulus: &[u8], exponent: &[u8]) -> Vec<u8> {
    let integer = |bytes: &[u8]| {
        let mut content = vec![0u8];
        content.extend_from_slice(bytes);
        der(0x02, &content)
    };
    let mut body = integer(modulus);
    body.extend(integer(exponent));
    der(0x30, &body)
}

fn reference_public_op(input: &[u8], modulus: &[u8], exponent: &[u8], size: usize) -> Vec<u8> {
    let value = rsa::BigUint::from_bytes_be(input).modpow(
        &rsa::BigUint::from_bytes_be(exponent),
        &rsa::BigUint::from_bytes_be(modulus),
    );
    let bytes = value.to_bytes_be();
    let mut out = vec![0u8; size - bytes.len()];
    out.extend(bytes);
    out
}

/// The hand-written modular exponentiation matches a general big-integer
/// implementation on random odd moduli, exponents and inputs.
#[test]
fn public_op_matches_big_integer_reference_on_random_values() {
    use rand::{Rng, RngCore};
    let mut rng = rand::thread_rng();
    for bits in [1024usize, 1032, 2048, 3072, 4096] {
        let size = bits / 8;
        for round in 0..6 {
            let mut modulus = vec![0u8; size];
            rng.fill_bytes(&mut modulus);
            modulus[0] |= 0x80;
            modulus[size - 1] |= 1;
            let exponent: Vec<u8> = match round {
                0 => vec![0x01, 0x00, 0x01],
                1 => vec![3],
                _ => {
                    let max_len = if bits == 1024 { size } else { 64 };
                    let mut exponent = vec![0u8; rng.gen_range(1..=max_len)];
                    rng.fill_bytes(&mut exponent);
                    exponent[0] |= 1;
                    let last = exponent.len() - 1;
                    exponent[last] |= 1;
                    if exponent == [1] {
                        exponent[0] = 5;
                    }
                    exponent
                }
            };
            let key = RsaPublicKey::from_der(&pkcs1_der(&modulus, &exponent)).unwrap();
            for case in 0..4 {
                let mut input = vec![0u8; size];
                match case {
                    0 => input[size - 1] = 1,
                    1 => {
                        input.copy_from_slice(&modulus);
                        input[size - 1] -= 1;
                    }
                    _ => {
                        rng.fill_bytes(&mut input);
                        input[0] &= modulus[0] >> 1;
                    }
                }
                assert_eq!(
                    key.public_op(&input).unwrap(),
                    reference_public_op(&input, &modulus, &exponent, size),
                    "{bits} bits, round {round}, case {case}"
                );
            }
            assert!(key.public_op(&modulus).is_err(), "input equal to the modulus");
        }
    }
}

/// Node `privateEncrypt` (PKCS#1 v1.5 type 1) output from real random keys round-trips.
#[test]
fn public_decrypt_recovers_private_encrypt_output_from_random_keys() {
    use rand::{Rng, RngCore};
    use rsa::traits::PublicKeyParts;
    let mut rng = rand::thread_rng();
    for bits in [1024usize, 2048, 4096] {
        let private = rsa::RsaPrivateKey::new(&mut rng, bits).unwrap();
        let public = private.to_public_key();
        let pem = public.to_pkcs1_pem(rsa::pkcs1::LineEnding::LF).unwrap();
        let key = RsaPublicKey::from_pem(&pem).unwrap();
        let modulus = public.n().to_bytes_be();
        let exponent = public.e().to_bytes_be();
        for _ in 0..4 {
            let mut payload = vec![0u8; rng.gen_range(1..=bits / 8 - 11)];
            rng.fill_bytes(&mut payload);
            let signature = private.sign(rsa::Pkcs1v15Sign::new_unprefixed(), &payload).unwrap();
            assert_eq!(key.public_decrypt(&signature).unwrap(), payload, "{bits} bits");
            assert_eq!(
                key.public_op(&signature).unwrap(),
                reference_public_op(&signature, &modulus, &exponent, bits / 8)
            );
        }
    }
}

#[test]
fn even_modulus_and_invalid_exponents_are_rejected() {
    let mut modulus = vec![0xc3u8; 128];
    assert!(RsaPublicKey::from_der(&pkcs1_der(&modulus, &[1, 0, 1])).is_ok());
    for exponent in [&[][..], &[1], &[0, 1], &[2], &[1, 0]] {
        assert!(
            RsaPublicKey::from_der(&pkcs1_der(&modulus, exponent)).is_err(),
            "{exponent:?}"
        );
    }
    modulus[127] = 0xc2;
    assert!(RsaPublicKey::from_der(&pkcs1_der(&modulus, &[1, 0, 1])).is_err());
    // 1016-bit modulus: below the minimum size.
    assert!(RsaPublicKey::from_der(&pkcs1_der(&[0xc3; 127], &[1, 0, 1])).is_err());
}
