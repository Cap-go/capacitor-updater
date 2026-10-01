//! Minimal RSA public-key support: PEM/DER parsing and the raw public
//! operation used to recover data signed with Node's `privateEncrypt`
//! (PKCS#1 v1.5 block type 1). Only public data is handled here, so the
//! operation does not need to be constant time.

use num_bigint::BigUint;

use crate::error::{CoreError, CoreResult};
use crate::text::base64_decode;

const TAG_INTEGER: u8 = 0x02;
const TAG_BIT_STRING: u8 = 0x03;
const TAG_SEQUENCE: u8 = 0x30;
const RSA_ENCRYPTION_OID: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01];
const MIN_MODULUS_BITS: u64 = 1024;
const MAX_MODULUS_BITS: u64 = 8192;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RsaPublicKey {
    modulus: BigUint,
    exponent: BigUint,
    size_bytes: usize,
}

fn invalid_key(message: &str) -> CoreError {
    CoreError::new("invalid_public_key", message.to_string())
}

/// Reads one DER TLV at `input[0..]`, returns (tag, content, rest).
fn read_tlv(input: &[u8]) -> CoreResult<(u8, &[u8], &[u8])> {
    let (&tag, rest) = input.split_first().ok_or_else(|| invalid_key("Truncated DER"))?;
    let (&first_len, mut rest) = rest.split_first().ok_or_else(|| invalid_key("Truncated DER length"))?;
    let len = if first_len & 0x80 == 0 {
        first_len as usize
    } else {
        let count = (first_len & 0x7f) as usize;
        if count == 0 || count > 4 || rest.len() < count {
            return Err(invalid_key("Unsupported DER length"));
        }
        let len = rest[..count]
            .iter()
            .fold(0usize, |acc, byte| (acc << 8) | *byte as usize);
        rest = &rest[count..];
        len
    };
    if rest.len() < len {
        return Err(invalid_key("Truncated DER content"));
    }
    Ok((tag, &rest[..len], &rest[len..]))
}

fn expect_tlv(input: &[u8], tag: u8) -> CoreResult<(&[u8], &[u8])> {
    let (found, content, rest) = read_tlv(input)?;
    if found != tag {
        return Err(invalid_key("Unexpected DER tag"));
    }
    Ok((content, rest))
}

impl RsaPublicKey {
    /// Parses a PKCS#1 `RSA PUBLIC KEY` or SPKI `PUBLIC KEY` PEM (headers optional).
    pub fn from_pem(pem: &str) -> CoreResult<Self> {
        let body = pem
            .replace("-----BEGIN RSA PUBLIC KEY-----", "")
            .replace("-----END RSA PUBLIC KEY-----", "")
            .replace("-----BEGIN PUBLIC KEY-----", "")
            .replace("-----END PUBLIC KEY-----", "")
            // Keys pasted into JSON config sometimes keep literal "\n" sequences.
            .replace("\\n", "");
        let der = base64_decode(&body).ok_or_else(|| invalid_key("Public key is not valid base64"))?;
        Self::from_der(&der)
    }

    pub fn from_der(der: &[u8]) -> CoreResult<Self> {
        let (sequence, trailing) = expect_tlv(der, TAG_SEQUENCE)?;
        if !trailing.is_empty() {
            return Err(invalid_key("Trailing data after public key"));
        }
        let (first_tag, _, _) = read_tlv(sequence)?;
        if first_tag == TAG_SEQUENCE {
            // SubjectPublicKeyInfo { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }
            let (algorithm, rest) = expect_tlv(sequence, TAG_SEQUENCE)?;
            let (oid_tag, oid, _) = read_tlv(algorithm)?;
            if oid_tag != 0x06 || oid != RSA_ENCRYPTION_OID {
                return Err(invalid_key("Public key is not an RSA key"));
            }
            let (bits, _) = expect_tlv(rest, TAG_BIT_STRING)?;
            let (&unused_bits, pkcs1) = bits.split_first().ok_or_else(|| invalid_key("Empty key bit string"))?;
            if unused_bits != 0 {
                return Err(invalid_key("Unexpected key bit string padding"));
            }
            return Self::from_der(pkcs1);
        }

        // RSAPublicKey { modulus INTEGER, publicExponent INTEGER }
        let (modulus, rest) = expect_tlv(sequence, TAG_INTEGER)?;
        let (exponent, _) = expect_tlv(rest, TAG_INTEGER)?;
        let modulus = BigUint::from_bytes_be(modulus);
        let exponent = BigUint::from_bytes_be(exponent);
        let bits = modulus.bits();
        if !(MIN_MODULUS_BITS..=MAX_MODULUS_BITS).contains(&bits) {
            return Err(invalid_key("Unsupported RSA modulus size"));
        }
        if exponent <= BigUint::from(1u8) || !exponent.bit(0) {
            return Err(invalid_key("Invalid RSA public exponent"));
        }
        Ok(Self {
            size_bytes: bits.div_ceil(8) as usize,
            modulus,
            exponent,
        })
    }

    pub fn modulus_bits(&self) -> u64 {
        self.modulus.bits()
    }

    /// DER `SubjectPublicKeyInfo` (X.509) encoding, as expected by JCA `X509EncodedKeySpec`.
    pub fn to_spki_der(&self) -> Vec<u8> {
        let mut rsa_key = der_unsigned_integer(&self.modulus.to_bytes_be());
        rsa_key.extend(der_unsigned_integer(&self.exponent.to_bytes_be()));
        let pkcs1 = der(TAG_SEQUENCE, &rsa_key);

        let mut algorithm = der(0x06, RSA_ENCRYPTION_OID);
        algorithm.extend([0x05, 0x00]);
        let mut bit_string = vec![0u8];
        bit_string.extend(pkcs1);

        let mut spki = der(TAG_SEQUENCE, &algorithm);
        spki.extend(der(TAG_BIT_STRING, &bit_string));
        der(TAG_SEQUENCE, &spki)
    }

    /// Recovers the payload of a PKCS#1 v1.5 type-1 block (`privateEncrypt`).
    pub fn public_decrypt(&self, ciphertext: &[u8]) -> CoreResult<Vec<u8>> {
        let failed = |message: &str| CoreError::new("decrypt_failed", message.to_string());
        if ciphertext.len() != self.size_bytes {
            return Err(failed("Ciphertext length does not match the RSA key size"));
        }
        let value = BigUint::from_bytes_be(ciphertext);
        if value >= self.modulus {
            return Err(failed("Ciphertext is out of range for the RSA key"));
        }
        let recovered = value.modpow(&self.exponent, &self.modulus).to_bytes_be();
        let mut block = vec![0u8; self.size_bytes - recovered.len()];
        block.extend_from_slice(&recovered);
        unpad_type1(&block).ok_or_else(|| failed("Invalid PKCS#1 signature padding"))
    }
}

fn der(tag: u8, content: &[u8]) -> Vec<u8> {
    let mut out = vec![tag];
    let len = content.len();
    if len < 0x80 {
        out.push(len as u8);
    } else {
        let bytes: Vec<u8> = len.to_be_bytes().into_iter().skip_while(|byte| *byte == 0).collect();
        out.push(0x80 | bytes.len() as u8);
        out.extend(bytes);
    }
    out.extend_from_slice(content);
    out
}

fn der_unsigned_integer(big_endian: &[u8]) -> Vec<u8> {
    let trimmed: Vec<u8> = big_endian.iter().copied().skip_while(|byte| *byte == 0).collect();
    let mut content = Vec::with_capacity(trimmed.len() + 1);
    if trimmed.first().map_or(true, |byte| byte & 0x80 != 0) {
        content.push(0);
    }
    content.extend(trimmed);
    der(TAG_INTEGER, &content)
}

/// RFC 8017: `00 01`, at least eight `FF`, `00`, then a non-empty payload.
pub fn unpad_type1(block: &[u8]) -> Option<Vec<u8>> {
    if block.len() < 11 || block[0] != 0 || block[1] != 1 {
        return None;
    }
    let separator = 2 + block[2..].iter().take_while(|byte| **byte == 0xff).count();
    if separator < 10 || separator >= block.len() - 1 || block[separator] != 0 {
        return None;
    }
    Some(block[separator + 1..].to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unpad_rejects_short_padding() {
        let mut block = vec![0u8, 1];
        block.extend([0xff; 7]);
        block.push(0);
        block.push(42);
        assert!(unpad_type1(&block).is_none());
        let mut block = vec![0u8, 1];
        block.extend([0xff; 8]);
        block.push(0);
        block.push(42);
        assert_eq!(unpad_type1(&block), Some(vec![42]));
    }

    #[test]
    fn spki_round_trips() {
        let modulus = BigUint::from_bytes_be(&[0xc3; 128]);
        let key = RsaPublicKey {
            size_bytes: 128,
            modulus,
            exponent: BigUint::from(65537u32),
        };
        let parsed = RsaPublicKey::from_der(&key.to_spki_der()).unwrap();
        assert_eq!(parsed, key);
    }

    #[test]
    fn rejects_garbage_keys() {
        assert_eq!(
            RsaPublicKey::from_pem("not-a-key").unwrap_err().code,
            "invalid_public_key"
        );
        assert_eq!(
            RsaPublicKey::from_der(&[0x30, 0x00]).unwrap_err().code,
            "invalid_public_key"
        );
    }
}
