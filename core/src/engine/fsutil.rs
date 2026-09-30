//! Small file-system helpers shared by the download pipeline.

use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use ring::digest::{Context, SHA256};

use crate::crypto::checksum::IO_BUFFER_BYTES;
use crate::text::hex_encode;

/// Free bytes available to the app on the volume holding `path`.
pub fn available_space(path: &Path) -> Option<u64> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let mut probe = path.to_path_buf();
        while !probe.exists() {
            probe = probe.parent()?.to_path_buf();
        }
        let c_path = std::ffi::CString::new(probe.as_os_str().as_bytes()).ok()?;
        let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) } != 0 {
            return None;
        }
        #[allow(clippy::unnecessary_cast)]
        Some(stat.f_bavail as u64 * stat.f_frsize as u64)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

pub fn unique_temp(dir: &Path, prefix: &str, suffix: &str) -> PathBuf {
    dir.join(format!("{prefix}{}{suffix}", super::store::random_id()))
}

/// Copies `source` to `destination` through a sibling temp file + rename.
pub fn copy_atomically(source: &Path, destination: &Path) -> io::Result<()> {
    let parent = destination
        .parent()
        .ok_or_else(|| io::Error::other("destination has no parent"))?;
    fs::create_dir_all(parent)?;
    let temp = unique_temp(parent, "capgo-", ".tmp");
    let result = fs::copy(source, &temp).and_then(|_| fs::rename(&temp, destination));
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

/// Streams `reader` into `destination` (temp + rename) and returns its SHA-256.
/// With `expected`, the file is only put in place when the hash matches
/// (case-insensitive); otherwise `Ok(None)` is returned and nothing is written.
pub fn write_verified(reader: &mut dyn Read, destination: &Path, expected: Option<&str>) -> io::Result<Option<String>> {
    let parent = destination
        .parent()
        .ok_or_else(|| io::Error::other("destination has no parent"))?;
    fs::create_dir_all(parent)?;
    let temp = unique_temp(parent, "capgo-", ".tmp");
    let result = (|| {
        let mut output = File::create(&temp)?;
        let mut hasher = Context::new(&SHA256);
        let mut buffer = vec![0u8; IO_BUFFER_BYTES];
        loop {
            let read = reader.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
            output.write_all(&buffer[..read])?;
        }
        output.flush()?;
        drop(output);
        let actual = hex_encode(hasher.finish().as_ref());
        if let Some(expected) = expected {
            if !expected.eq_ignore_ascii_case(&actual) {
                return Ok(None);
            }
        }
        fs::rename(&temp, destination)?;
        Ok(Some(actual))
    })();
    let _ = fs::remove_file(&temp);
    result
}

/// SHA-256 of a readable stream.
pub fn sha256_reader(reader: &mut dyn Read) -> io::Result<String> {
    let mut hasher = Context::new(&SHA256);
    let mut buffer = vec![0u8; IO_BUFFER_BYTES];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex_encode(hasher.finish().as_ref()))
}

pub fn file_matches_hash(path: &Path, expected: &str) -> bool {
    if expected.is_empty() || !path.is_file() {
        return false;
    }
    crate::crypto::checksum::sha256_file(path).is_ok_and(|actual| actual.eq_ignore_ascii_case(expected))
}

pub fn modified_before(path: &Path, age: std::time::Duration) -> bool {
    fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|elapsed| elapsed > age)
}
