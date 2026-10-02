//! String helpers that reproduce the exact semantics the Android and iOS
//! plugins shipped with, so every host gets byte-identical results.

/// `java.lang.String#trim`: strips leading/trailing code points <= U+0020.
pub fn java_trim(value: &str) -> &str {
    value.trim_matches(|c: char| c <= '\u{20}')
}

/// Lowercase hex encoding.
pub fn hex_encode(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(DIGITS[(byte >> 4) as usize] as char);
        out.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    out
}

/// Strict hex decoding (even length, `[0-9a-fA-F]` only).
pub fn hex_decode(value: &str) -> Option<Vec<u8>> {
    if value.len() % 2 != 0 {
        return None;
    }
    let digit = |c: u8| -> Option<u8> {
        match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            b'A'..=b'F' => Some(c - b'A' + 10),
            _ => None,
        }
    };
    value
        .as_bytes()
        .chunks(2)
        .map(|pair| Some((digit(pair[0])? << 4) | digit(pair[1])?))
        .collect()
}

pub fn is_hex(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|c| c.is_ascii_hexdigit())
}

/// Lenient standard base64: ignores whitespace, accepts missing padding and
/// non-canonical trailing bits.
/// Matches what Capgo keys/session keys look like on both platforms.
pub fn base64_decode(value: &str) -> Option<Vec<u8>> {
    use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig};
    use base64::engine::DecodePaddingMode;
    use base64::Engine;

    const ENGINE: GeneralPurpose = GeneralPurpose::new(
        &base64::alphabet::STANDARD,
        GeneralPurposeConfig::new()
            .with_decode_padding_mode(DecodePaddingMode::Indifferent)
            // Android's Base64 and iOS's Data(base64Encoded:) both ignore non-zero trailing bits.
            .with_decode_allow_trailing_bits(true),
    );
    let compact: String = value.chars().filter(|c| !c.is_whitespace()).collect();
    ENGINE.decode(compact.as_bytes()).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_accepts_non_canonical_trailing_bits() {
        // "QQ==" is canonical for "A"; "QR==" sets unused bits, accepted by the old native decoders.
        assert_eq!(base64_decode("QR=="), Some(b"A".to_vec()));
        assert_eq!(base64_decode("Q Q"), Some(b"A".to_vec()));
        assert_eq!(base64_decode("Q!=="), None);
    }

    #[test]
    fn hex_round_trip() {
        assert_eq!(hex_encode(&[0, 1, 0xab, 0xff]), "0001abff");
        assert_eq!(hex_decode("0001ABff"), Some(vec![0, 1, 0xab, 0xff]));
        assert_eq!(hex_decode("abc"), None);
        assert_eq!(hex_decode("zz"), None);
    }

    #[test]
    fn base64_is_lenient() {
        assert_eq!(base64_decode("aGk=").unwrap(), b"hi");
        assert_eq!(base64_decode("aGk").unwrap(), b"hi");
        assert_eq!(base64_decode("a G\nk=").unwrap(), b"hi");
        assert!(base64_decode("!!!").is_none());
    }

    #[test]
    fn java_trim_only_strips_control_and_space() {
        assert_eq!(java_trim(" \t a b \n"), "a b");
        assert_eq!(java_trim("\u{a0}a\u{a0}"), "\u{a0}a\u{a0}");
    }
}
