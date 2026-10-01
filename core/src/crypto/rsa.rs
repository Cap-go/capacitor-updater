//! Minimal RSA public-key support: PEM/DER parsing and the raw public
//! operation used to recover data signed with Node's `privateEncrypt`
//! (PKCS#1 v1.5 block type 1). Only public data is handled here, so the
//! operation does not need to be constant time: a small Montgomery modular
//! exponentiation over 64-bit limbs replaces a general big-integer crate.

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
    modulus: Montgomery,
    /// Big-endian, without leading zero bytes.
    exponent: Vec<u8>,
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
        let modulus = limbs_from_be(modulus);
        let exponent = strip_leading_zeros(exponent);
        let bits = bit_length(&modulus);
        if !(MIN_MODULUS_BITS..=MAX_MODULUS_BITS).contains(&bits) {
            return Err(invalid_key("Unsupported RSA modulus size"));
        }
        // An RSA modulus is a product of two odd primes.
        if modulus[0] & 1 == 0 {
            return Err(invalid_key("Invalid RSA modulus"));
        }
        if exponent.is_empty() || exponent == [1] || exponent[exponent.len() - 1] & 1 == 0 {
            return Err(invalid_key("Invalid RSA public exponent"));
        }
        Ok(Self {
            size_bytes: bits.div_ceil(8) as usize,
            modulus: Montgomery::new(modulus),
            exponent: exponent.to_vec(),
        })
    }

    /// Modulus size in bytes (the length of every ciphertext).
    pub fn size_bytes(&self) -> usize {
        self.size_bytes
    }

    /// Raw public operation `value^e mod n`, big-endian and left-padded to the key size.
    pub fn public_op(&self, value: &[u8]) -> CoreResult<Vec<u8>> {
        let failed = |message: &str| CoreError::new("decrypt_failed", message.to_string());
        if value.len() != self.size_bytes {
            return Err(failed("Ciphertext length does not match the RSA key size"));
        }
        let mut limbs = limbs_from_be(value);
        if limbs.len() > self.modulus.n.len() || compare(&limbs, &self.modulus.n) != std::cmp::Ordering::Less {
            return Err(failed("Ciphertext is out of range for the RSA key"));
        }
        limbs.resize(self.modulus.n.len(), 0);
        let recovered = self.modulus.pow(&limbs, &self.exponent);
        Ok(limbs_to_be(&recovered, self.size_bytes))
    }

    /// Recovers the payload of a PKCS#1 v1.5 type-1 block (`privateEncrypt`).
    pub fn public_decrypt(&self, ciphertext: &[u8]) -> CoreResult<Vec<u8>> {
        let block = self.public_op(ciphertext)?;
        unpad_type1(&block).ok_or_else(|| CoreError::new("decrypt_failed", "Invalid PKCS#1 signature padding"))
    }
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

fn strip_leading_zeros(bytes: &[u8]) -> &[u8] {
    let zeros = bytes.iter().take_while(|byte| **byte == 0).count();
    &bytes[zeros..]
}

/// Little-endian 64-bit limbs of a big-endian unsigned integer, without high zero limbs.
fn limbs_from_be(bytes: &[u8]) -> Vec<u64> {
    let bytes = strip_leading_zeros(bytes);
    let mut limbs = vec![0u64; bytes.len().div_ceil(8)];
    for (index, byte) in bytes.iter().rev().enumerate() {
        limbs[index / 8] |= u64::from(*byte) << (8 * (index % 8));
    }
    limbs
}

/// Big-endian bytes of `limbs`, left-padded (or truncated from the top) to `len`.
fn limbs_to_be(limbs: &[u64], len: usize) -> Vec<u8> {
    let mut out = vec![0u8; len];
    for (index, slot) in out.iter_mut().rev().enumerate() {
        if let Some(limb) = limbs.get(index / 8) {
            *slot = (limb >> (8 * (index % 8))) as u8;
        }
    }
    out
}

fn bit_length(limbs: &[u64]) -> u64 {
    match limbs.iter().rposition(|limb| *limb != 0) {
        Some(top) => top as u64 * 64 + u64::from(64 - limbs[top].leading_zeros()),
        None => 0,
    }
}

/// Compares two limb slices of any length.
fn compare(a: &[u64], b: &[u64]) -> std::cmp::Ordering {
    let len = a.len().max(b.len());
    for index in (0..len).rev() {
        let (x, y) = (a.get(index).copied().unwrap_or(0), b.get(index).copied().unwrap_or(0));
        if x != y {
            return x.cmp(&y);
        }
    }
    std::cmp::Ordering::Equal
}

/// `a -= b` over equal-length slices; returns the final borrow.
fn sub_assign(a: &mut [u64], b: &[u64]) -> bool {
    let mut borrow = false;
    for (x, y) in a.iter_mut().zip(b) {
        let (value, under1) = x.overflowing_sub(*y);
        let (value, under2) = value.overflowing_sub(u64::from(borrow));
        *x = value;
        borrow = under1 || under2;
    }
    borrow
}

/// Montgomery arithmetic modulo an odd `n` (R = 2^(64 * limbs)).
#[derive(Debug, Clone, PartialEq, Eq)]
struct Montgomery {
    n: Vec<u64>,
    /// `-n^-1 mod 2^64`.
    n_prime: u64,
    /// `R^2 mod n`, to enter the Montgomery domain.
    r_squared: Vec<u64>,
}

impl Montgomery {
    fn new(n: Vec<u64>) -> Self {
        // Newton iteration for n[0]^-1 mod 2^64: n0 * n0 == 1 mod 8, then 3 -> 6 -> ... -> 96 bits.
        let mut inverse = n[0];
        for _ in 0..5 {
            inverse = inverse.wrapping_mul(2u64.wrapping_sub(n[0].wrapping_mul(inverse)));
        }
        // R^2 mod n by doubling 1, reducing after each step (2x < 2n needs one subtraction).
        let mut r_squared = vec![0u64; n.len()];
        r_squared[0] = 1;
        for _ in 0..2 * 64 * n.len() {
            let mut carry = 0u64;
            for limb in r_squared.iter_mut() {
                let next = *limb >> 63;
                *limb = (*limb << 1) | carry;
                carry = next;
            }
            if carry != 0 || compare(&r_squared, &n) != std::cmp::Ordering::Less {
                sub_assign(&mut r_squared, &n);
            }
        }
        Self {
            n,
            n_prime: inverse.wrapping_neg(),
            r_squared,
        }
    }

    /// `a * b * R^-1 mod n` for `a, b < n` (CIOS).
    fn mul(&self, a: &[u64], b: &[u64]) -> Vec<u64> {
        let n = &self.n;
        let k = n.len();
        let mut t = vec![0u64; k + 2];
        for &a_i in a {
            let mut carry = 0u128;
            for j in 0..k {
                let sum = u128::from(t[j]) + u128::from(a_i) * u128::from(b[j]) + carry;
                t[j] = sum as u64;
                carry = sum >> 64;
            }
            let sum = u128::from(t[k]) + carry;
            t[k] = sum as u64;
            t[k + 1] = (sum >> 64) as u64;

            let m = u128::from(t[0].wrapping_mul(self.n_prime));
            let mut carry = (u128::from(t[0]) + m * u128::from(n[0])) >> 64;
            for j in 1..k {
                let sum = u128::from(t[j]) + m * u128::from(n[j]) + carry;
                t[j - 1] = sum as u64;
                carry = sum >> 64;
            }
            let sum = u128::from(t[k]) + carry;
            t[k - 1] = sum as u64;
            t[k] = t[k + 1] + (sum >> 64) as u64;
            t[k + 1] = 0;
        }
        // t < 2n: one conditional subtraction.
        let overflow = t[k] != 0;
        t.truncate(k);
        if overflow || compare(&t, n) != std::cmp::Ordering::Less {
            sub_assign(&mut t, n);
        }
        t
    }

    /// `base^exponent mod n`; `base < n` with `n.len()` limbs, exponent big-endian and non-zero.
    fn pow(&self, base: &[u64], exponent: &[u8]) -> Vec<u64> {
        let base = self.mul(base, &self.r_squared);
        let mut acc: Option<Vec<u64>> = None;
        for byte in exponent {
            for shift in (0..8).rev() {
                if let Some(value) = acc.as_mut() {
                    *value = self.mul(value, value);
                }
                if (byte >> shift) & 1 == 1 {
                    acc = Some(match acc {
                        Some(value) => self.mul(&value, &base),
                        None => base.clone(),
                    });
                }
            }
        }
        let mut one = vec![0u64; self.n.len()];
        one[0] = 1;
        match acc {
            Some(value) => self.mul(&value, &one),
            // x^0 = 1 (never reached: exponents are validated as > 1).
            None => one,
        }
    }
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
