use std::fs::File;
use std::io::Read;
use std::path::Path;

use sha2::{Digest, Sha256};

use crate::error::{CoreError, CoreResult};
use crate::text::hex_encode;

/// 256 KiB: one buffer size for checksum, copy and decode on every host.
pub const IO_BUFFER_BYTES: usize = 256 * 1024;

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex_encode(&Sha256::digest(bytes))
}

/// Lowercase hex SHA-256 of a file, streamed.
pub fn sha256_file(path: &Path) -> CoreResult<String> {
    let mut file =
        File::open(path).map_err(|error| CoreError::io("Cannot open file for checksum", error))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; IO_BUFFER_BYTES];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| CoreError::io("Cannot read file for checksum", error))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex_encode(&hasher.finalize()))
}

/// First 16 hex chars of the SHA-256 of a UTF-8 string: a short, file-system-safe token.
pub fn short_path_key(value: &str) -> String {
    let mut key = sha256_hex(value.as_bytes());
    key.truncate(16);
    key
}
