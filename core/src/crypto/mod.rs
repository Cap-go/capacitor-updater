//! Bundle cryptography: RSA public-key recovery of session keys and
//! checksums (PKCS#1 v1.5 type 1, as produced by the Capgo CLI with
//! `privateEncrypt`), AES-128-CBC bundle decryption and SHA-256 checksums.

pub mod aes_cbc;
pub mod checksum;
pub mod rsa;

use crate::error::{CoreError, CoreResult};
use crate::text::{base64_decode, hex_decode, hex_encode, is_hex};

pub use self::rsa::RsaPublicKey;

/// `<iv base64>:<RSA-encrypted AES key base64>`, both parts non-empty.
pub fn is_valid_session_key(session_key: Option<&str>) -> bool {
    let Some(session_key) = session_key else {
        return false;
    };
    let mut parts = session_key.split(':');
    matches!(
        (parts.next(), parts.next(), parts.next()),
        (Some(iv), Some(key), None) if !iv.is_empty() && !key.is_empty()
    )
}

/// First 20 characters of the base64 key body; identifies the key in stats.
pub fn key_id(public_key: &str) -> String {
    let compact: String = public_key.chars().filter(|c| !c.is_whitespace()).collect();
    let cleaned = compact
        .replace("-----BEGINRSAPUBLICKEY-----", "")
        .replace("-----ENDRSAPUBLICKEY-----", "");
    cleaned.chars().take(20).collect()
}

pub fn detect_checksum_algorithm(checksum: &str) -> String {
    match checksum.chars().count() {
        0 => "empty".to_string(),
        64 => "SHA-256".to_string(),
        8 => "CRC32 (deprecated)".to_string(),
        other => format!("unknown ({other} hex chars)"),
    }
}

/// Decrypts a bundle checksum signed with the private key.
///
/// With no public key configured the checksum is returned unchanged. The
/// encrypted checksum is hex (current CLI) or base64 (legacy CLI) and must be
/// one RSA-2048 block. Returns lowercase hex (SHA-256, or legacy CRC32).
pub fn decrypt_checksum(checksum: &str, public_key: &str) -> CoreResult<String> {
    if public_key.is_empty() {
        return Ok(checksum.to_string());
    }
    let encrypted = if is_hex(checksum) {
        hex_decode(checksum)
    } else {
        base64_decode(checksum)
    }
    .filter(|bytes| !bytes.is_empty())
    .ok_or_else(|| {
        CoreError::new(
            "invalid_checksum",
            "Cannot decode checksum as hex or base64",
        )
    })?;

    if encrypted.len() != 256 {
        return Err(CoreError::new(
            "checksum_not_encrypted",
            format!(
                "Checksum is not RSA encrypted (size: {} bytes, expected 256 for RSA-2048). Upload the bundle with encryption when a public key is configured.",
                encrypted.len()
            ),
        ));
    }
    let key = RsaPublicKey::from_pem(public_key)?;
    let decrypted = key.public_decrypt(&encrypted)?;
    Ok(hex_encode(&decrypted))
}

/// Parsed `<iv>:<encrypted key>` session key.
struct SessionKey {
    iv: [u8; 16],
    key: [u8; 16],
}

fn decrypt_session_key(public_key: &str, session_key: &str) -> CoreResult<SessionKey> {
    let (iv_b64, key_b64) = session_key
        .split_once(':')
        .ok_or_else(|| CoreError::new("invalid_session_key", "Session key must be <iv>:<key>"))?;
    let iv: [u8; 16] = base64_decode(iv_b64)
        .and_then(|iv| iv.try_into().ok())
        .ok_or_else(|| CoreError::new("invalid_iv", "IV must be 16 bytes of base64"))?;
    let encrypted_key = base64_decode(key_b64)
        .ok_or_else(|| CoreError::new("invalid_session_key", "Session key is not base64"))?;
    let rsa_key = RsaPublicKey::from_pem(public_key)?;
    let key = rsa_key.public_decrypt(&encrypted_key).map_err(|error| {
        CoreError::new(
            "session_key_decrypt_failed",
            format!("Failed to decrypt session key: {}", error.message),
        )
    })?;
    let key: [u8; 16] = key.try_into().map_err(|key: Vec<u8>| {
        CoreError::new(
            "invalid_session_key",
            format!("Decrypted session key must be 16 bytes, got {}", key.len()),
        )
    })?;
    Ok(SessionKey { iv, key })
}

/// Outcome of [`decrypt_bundle_file`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecryptOutcome {
    Decrypted,
    /// No public key or no session key: the bundle is not encrypted.
    NotEncrypted,
}

/// Decrypts an encrypted bundle file in place (AES-128-CBC, PKCS#7), streaming.
///
/// Fails closed: an unusable public key is an error, never a silent skip.
/// Hosts must separately refuse unencrypted downloads when a public key is
/// configured (see `requireSessionKey` in the plugins); this function only
/// performs the decryption step.
pub fn decrypt_bundle_file(
    path: &std::path::Path,
    public_key: &str,
    session_key: Option<&str>,
) -> CoreResult<DecryptOutcome> {
    if public_key.is_empty() || !is_valid_session_key(session_key) {
        return Ok(DecryptOutcome::NotEncrypted);
    }
    let session = decrypt_session_key(public_key, session_key.unwrap_or_default())?;
    aes_cbc::decrypt_file_in_place(path, &session.key, &session.iv)?;
    Ok(DecryptOutcome::Decrypted)
}
