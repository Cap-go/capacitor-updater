//! Streaming AES-128-CBC decryption with PKCS#7 padding.

use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use aes::cipher::generic_array::GenericArray;
use aes::cipher::{BlockDecrypt, KeyInit};
use aes::Aes128;

use crate::crypto::checksum::IO_BUFFER_BYTES;
use crate::error::{CoreError, CoreResult};

const BLOCK: usize = 16;

pub struct CbcDecryptor {
    cipher: Aes128,
    previous: [u8; BLOCK],
    /// Last decrypted block, withheld until we know whether it carries padding.
    pending: Option<[u8; BLOCK]>,
    /// Buffered ciphertext bytes that do not complete a block yet.
    partial: Vec<u8>,
}

impl CbcDecryptor {
    pub fn new(key: &[u8; 16], iv: &[u8; 16]) -> Self {
        Self {
            cipher: Aes128::new(GenericArray::from_slice(key)),
            previous: *iv,
            pending: None,
            partial: Vec::with_capacity(BLOCK),
        }
    }

    /// Decrypts `input`, appending plaintext that is known not to be padding to `out`.
    pub fn update(&mut self, mut input: &[u8], out: &mut Vec<u8>) {
        if !self.partial.is_empty() {
            let take = (BLOCK - self.partial.len()).min(input.len());
            self.partial.extend_from_slice(&input[..take]);
            input = &input[take..];
            if self.partial.len() < BLOCK {
                return;
            }
            let block: [u8; BLOCK] = self.partial[..].try_into().expect("full block");
            self.partial.clear();
            self.decrypt_blocks(&block, out);
        }
        let whole = input.len() - input.len() % BLOCK;
        self.decrypt_blocks(&input[..whole], out);
        self.partial.extend_from_slice(&input[whole..]);
    }

    fn decrypt_blocks(&mut self, ciphertext: &[u8], out: &mut Vec<u8>) {
        if ciphertext.is_empty() {
            return;
        }
        let mut blocks: Vec<aes::Block> = ciphertext
            .chunks_exact(BLOCK)
            .map(aes::Block::clone_from_slice)
            .collect();
        self.cipher.decrypt_blocks(&mut blocks);
        for (plain, cipher_chunk) in blocks.iter().zip(ciphertext.chunks_exact(BLOCK)) {
            let mut block = [0u8; BLOCK];
            for i in 0..BLOCK {
                block[i] = plain[i] ^ self.previous[i];
            }
            self.previous.copy_from_slice(cipher_chunk);
            if let Some(ready) = self.pending.replace(block) {
                out.extend_from_slice(&ready);
            }
        }
    }

    /// Validates and strips PKCS#7 padding from the final block.
    pub fn finish(self, out: &mut Vec<u8>) -> CoreResult<()> {
        let failed = |message: &str| CoreError::new("decrypt_failed", message.to_string());
        if !self.partial.is_empty() {
            return Err(failed("Ciphertext is not a multiple of the AES block size"));
        }
        let last = self.pending.ok_or_else(|| failed("Ciphertext is empty"))?;
        let pad = last[BLOCK - 1] as usize;
        if pad == 0 || pad > BLOCK || last[BLOCK - pad..].iter().any(|byte| *byte as usize != pad) {
            return Err(failed("Invalid PKCS#7 padding"));
        }
        out.extend_from_slice(&last[..BLOCK - pad]);
        Ok(())
    }
}

/// Decrypts whole buffers (used by tests and small payloads).
pub fn decrypt(ciphertext: &[u8], key: &[u8; 16], iv: &[u8; 16]) -> CoreResult<Vec<u8>> {
    let mut decryptor = CbcDecryptor::new(key, iv);
    let mut out = Vec::with_capacity(ciphertext.len());
    decryptor.update(ciphertext, &mut out);
    decryptor.finish(&mut out)?;
    Ok(out)
}

fn temp_path_for(path: &Path) -> CoreResult<PathBuf> {
    let parent = path
        .parent()
        .ok_or_else(|| CoreError::new("io_error", format!("No parent directory for {}", path.display())))?;
    // Files are decrypted in parallel in one directory: the name must be unique per call.
    Ok(crate::engine::fsutil::unique_temp(parent, "capgo-aes-", ".tmp"))
}

/// Decrypts `source` into `destination` (created, must not exist) in one pass and
/// returns the SHA-256 (lowercase hex) of the plaintext.
pub fn decrypt_file_to(source: &Path, destination: &Path, key: &[u8; 16], iv: &[u8; 16]) -> CoreResult<String> {
    let size = fs::metadata(source)
        .map_err(|error| CoreError::io("Cannot stat encrypted file", error))?
        .len();
    if size == 0 {
        return Err(CoreError::new("empty_input", "Empty encrypted data"));
    }
    let input = File::open(source).map_err(|error| CoreError::io("Cannot open encrypted file", error))?;
    let mut output = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(destination)
        .map_err(|error| CoreError::io("Cannot create temp file", error))?;
    let mut reader = CbcDecryptReader::new(input, key, iv);
    let mut hasher = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buffer = vec![0u8; IO_BUFFER_BYTES];
    loop {
        let read = reader.read(&mut buffer).map_err(|error| match error.kind() {
            std::io::ErrorKind::InvalidData => CoreError::new("decrypt_failed", error.to_string()),
            _ => CoreError::io("Cannot read encrypted file", error),
        })?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        output
            .write_all(&buffer[..read])
            .map_err(|error| CoreError::io("Cannot write decrypted file", error))?;
    }
    output
        .flush()
        .map_err(|error| CoreError::io("Cannot flush decrypted file", error))?;
    Ok(crate::text::hex_encode(hasher.finish().as_ref()))
}

/// Decrypts `path` in place (sibling temp file + atomic rename) and returns the
/// SHA-256 of the plaintext.
pub fn decrypt_file_in_place_hashed(path: &Path, key: &[u8; 16], iv: &[u8; 16]) -> CoreResult<String> {
    let temp = temp_path_for(path)?;
    let result = decrypt_file_to(path, &temp, key, iv).and_then(|hash| {
        fs::rename(&temp, path).map_err(|error| CoreError::io("Cannot replace encrypted file", error))?;
        Ok(hash)
    });
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

/// Decrypts `path` in place: streams into a sibling temp file, then atomically replaces it.
pub fn decrypt_file_in_place(path: &Path, key: &[u8; 16], iv: &[u8; 16]) -> CoreResult<()> {
    decrypt_file_in_place_hashed(path, key, iv).map(|_| ())
}

/// Plaintext reader over an AES-128-CBC ciphertext stream (PKCS#7 checked at the end).
pub struct CbcDecryptReader<R: Read> {
    inner: R,
    decryptor: Option<CbcDecryptor>,
    input: Vec<u8>,
    plain: Vec<u8>,
    position: usize,
    produced: u64,
}

impl<R: Read> CbcDecryptReader<R> {
    pub fn new(inner: R, key: &[u8; 16], iv: &[u8; 16]) -> Self {
        Self {
            inner,
            decryptor: Some(CbcDecryptor::new(key, iv)),
            input: vec![0u8; IO_BUFFER_BYTES],
            plain: Vec::with_capacity(IO_BUFFER_BYTES + BLOCK),
            position: 0,
            produced: 0,
        }
    }
}

impl<R: Read> Read for CbcDecryptReader<R> {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        let invalid = |message: String| std::io::Error::new(std::io::ErrorKind::InvalidData, message);
        loop {
            if self.position < self.plain.len() {
                let count = out.len().min(self.plain.len() - self.position);
                out[..count].copy_from_slice(&self.plain[self.position..self.position + count]);
                self.position += count;
                self.produced += count as u64;
                return Ok(count);
            }
            let Some(decryptor) = self.decryptor.as_mut() else {
                return Ok(0);
            };
            self.plain.clear();
            self.position = 0;
            let read = self.inner.read(&mut self.input)?;
            if read == 0 {
                let decryptor = self.decryptor.take().expect("decryptor present");
                decryptor
                    .finish(&mut self.plain)
                    .map_err(|error| invalid(error.message))?;
                if self.produced == 0 && self.plain.is_empty() {
                    return Err(invalid("Empty decrypted data".into()));
                }
            } else {
                decryptor.update(&self.input[..read], &mut self.plain);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // NIST SP 800-38A F.2.2 CBC-AES128.Decrypt (first two blocks), plus a padding block.
    #[test]
    fn nist_vector_streamed_in_odd_chunks() {
        let key: [u8; 16] = crate::text::hex_decode("2b7e151628aed2a6abf7158809cf4f3c")
            .unwrap()
            .try_into()
            .unwrap();
        let iv: [u8; 16] = crate::text::hex_decode("000102030405060708090a0b0c0d0e0f")
            .unwrap()
            .try_into()
            .unwrap();
        let ciphertext =
            crate::text::hex_decode("7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2").unwrap();
        let mut decryptor = CbcDecryptor::new(&key, &iv);
        let mut out = Vec::new();
        for chunk in ciphertext.chunks(7) {
            decryptor.update(chunk, &mut out);
        }
        // The final block is withheld until finish(); these blocks carry no padding.
        assert_eq!(crate::text::hex_encode(&out), "6bc1bee22e409f96e93d7e117393172a");
        assert!(decryptor.finish(&mut out).is_err());
    }
}
