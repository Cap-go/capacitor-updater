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
    .ok_or_else(|| CoreError::new("invalid_checksum", "Cannot decode checksum as hex or base64"))?;

    if encrypted.len() != 256 {
        return Err(CoreError::new(
            "checksum_not_encrypted",
            format!(
                "Checksum is not RSA encrypted (size: {} bytes, expected 256 for RSA-2048). Upload the bundle with encryption when a public key is configured.",
                encrypted.len()
            ),
        ));
    }
    let key = cached_public_key(public_key)?;
    let decrypted = key.public_decrypt(&encrypted)?;
    Ok(hex_encode(&decrypted))
}

/// The configured public key parsed once (manifests decrypt one checksum per file).
fn cached_public_key(pem: &str) -> CoreResult<std::sync::Arc<RsaPublicKey>> {
    static CACHE: std::sync::Mutex<Option<(String, std::sync::Arc<RsaPublicKey>)>> = std::sync::Mutex::new(None);
    let mut cache = CACHE.lock().unwrap_or_else(|poison| poison.into_inner());
    if let Some((cached_pem, key)) = cache.as_ref() {
        if cached_pem == pem {
            return Ok(key.clone());
        }
    }
    let key = std::sync::Arc::new(RsaPublicKey::from_pem(pem)?);
    *cache = Some((pem.to_string(), key.clone()));
    Ok(key)
}

/// Parsed `<iv>:<encrypted key>` session key.
pub struct SessionKey {
    pub iv: [u8; 16],
    pub key: [u8; 16],
}

/// The AES key of an encrypted bundle, `None` when the bundle is not encrypted.
pub fn bundle_session_key(public_key: &str, session_key: &str) -> CoreResult<Option<SessionKey>> {
    if public_key.is_empty() || !is_valid_session_key(Some(session_key)) {
        return Ok(None);
    }
    decrypt_session_key(public_key, session_key).map(Some)
}

fn decrypt_session_key(public_key: &str, session_key: &str) -> CoreResult<SessionKey> {
    let (iv_b64, key_b64) = session_key
        .split_once(':')
        .ok_or_else(|| CoreError::new("invalid_session_key", "Session key must be <iv>:<key>"))?;
    let iv: [u8; 16] = base64_decode(iv_b64)
        .and_then(|iv| iv.try_into().ok())
        .ok_or_else(|| CoreError::new("invalid_iv", "IV must be 16 bytes of base64"))?;
    let encrypted_key =
        base64_decode(key_b64).ok_or_else(|| CoreError::new("invalid_session_key", "Session key is not base64"))?;
    let rsa_key = cached_public_key(public_key)?;
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
