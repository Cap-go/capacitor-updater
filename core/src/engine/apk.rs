//! Builtin files inside the Android APK (`assets/...`), indexed from the zip
//! central directory alone.
//!
//! `zip::ZipArchive::new` reads the local header of every entry when it opens
//! an archive: thousands of random reads over a large APK, 0.5-1.6 s on the
//! first manifest download of each process. This index reads the central
//! directory once (one contiguous read) and touches a local header only when
//! that entry is actually used.

use std::collections::HashMap;
use std::fs::File;
use std::io::{self, BufReader, Read};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const EOCD_SIGNATURE: u32 = 0x0605_4b50;
const EOCD_LEN: usize = 22;
const ZIP64_LOCATOR_SIGNATURE: u32 = 0x0706_4b50;
const ZIP64_EOCD_SIGNATURE: u32 = 0x0606_4b50;
const CENTRAL_SIGNATURE: u32 = 0x0201_4b50;
const LOCAL_SIGNATURE: u32 = 0x0403_4b50;
/// Sanity cap: an APK central directory is a few MB at most.
const MAX_CENTRAL_DIRECTORY: u64 = 256 * 1024 * 1024;

#[derive(Debug, Clone, Copy)]
struct Entry {
    header_offset: u64,
    compressed_size: u64,
    method: u16,
}

pub(crate) struct ApkIndex {
    file: File,
    entries: HashMap<String, Entry>,
}

impl ApkIndex {
    /// The index of `path`, parsed once per process and shared by every worker.
    pub(crate) fn shared(path: &Path) -> Option<Arc<ApkIndex>> {
        static CACHE: Mutex<Option<(PathBuf, Arc<ApkIndex>)>> = Mutex::new(None);
        let mut cache = CACHE.lock().unwrap_or_else(|poison| poison.into_inner());
        if let Some((cached_path, index)) = cache.as_ref() {
            if cached_path == path {
                return Some(index.clone());
            }
        }
        let index = Arc::new(Self::open(path, "assets/").ok()?);
        *cache = Some((path.to_path_buf(), index.clone()));
        Some(index)
    }

    /// Indexes the entries whose name starts with `prefix`.
    pub(crate) fn open(path: &Path, prefix: &str) -> io::Result<Self> {
        let file = File::open(path)?;
        let len = file.metadata()?.len();
        let (cd_offset, cd_size) = central_directory(&file, len)?;
        let mut central = vec![0u8; cd_size as usize];
        read_exact_at(&file, &mut central, cd_offset)?;
        let entries = parse_central_directory(&central, prefix)?;
        Ok(Self { file, entries })
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.entries.len()
    }

    /// Runs `f` over the decompressed bytes of `name`; `None` when the entry is
    /// missing, unreadable or uses an unsupported compression method.
    pub(crate) fn with_entry<R>(&self, name: &str, f: impl FnOnce(&mut dyn Read) -> io::Result<R>) -> Option<R> {
        let entry = *self.entries.get(name)?;
        let mut header = [0u8; 30];
        read_exact_at(&self.file, &mut header, entry.header_offset).ok()?;
        if u32_at(&header, 0) != LOCAL_SIGNATURE {
            return None;
        }
        let data_start = entry
            .header_offset
            .checked_add(30 + u16_at(&header, 26) as u64 + u16_at(&header, 28) as u64)?;
        let raw = At {
            file: &self.file,
            position: data_start,
            end: data_start.checked_add(entry.compressed_size)?,
        };
        match entry.method {
            0 => {
                let mut raw = raw;
                f(&mut raw).ok()
            }
            8 => f(&mut flate2::read::DeflateDecoder::new(BufReader::with_capacity(
                64 * 1024,
                raw,
            )))
            .ok(),
            _ => None,
        }
    }
}

/// Positional reader over `[position, end)` of a shared file.
struct At<'a> {
    file: &'a File,
    position: u64,
    end: u64,
}

impl Read for At<'_> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let remaining = self.end.saturating_sub(self.position);
        let want = (out.len() as u64).min(remaining) as usize;
        if want == 0 {
            return Ok(0);
        }
        let read = read_at(self.file, &mut out[..want], self.position)?;
        if read == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        self.position += read as u64;
        Ok(read)
    }
}

#[cfg(unix)]
fn read_at(file: &File, buf: &mut [u8], offset: u64) -> io::Result<usize> {
    std::os::unix::fs::FileExt::read_at(file, buf, offset)
}

#[cfg(windows)]
fn read_at(file: &File, buf: &mut [u8], offset: u64) -> io::Result<usize> {
    std::os::windows::fs::FileExt::seek_read(file, buf, offset)
}

fn read_exact_at(file: &File, mut buf: &mut [u8], mut offset: u64) -> io::Result<()> {
    while !buf.is_empty() {
        match read_at(file, buf, offset)? {
            0 => return Err(io::ErrorKind::UnexpectedEof.into()),
            read => {
                buf = &mut buf[read..];
                offset += read as u64;
            }
        }
    }
    Ok(())
}

fn u16_at(bytes: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([bytes[at], bytes[at + 1]])
}

fn u32_at(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
}

fn u64_at(bytes: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(bytes[at..at + 8].try_into().unwrap())
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

/// (offset, size) of the central directory, from the (zip64) end record.
fn central_directory(file: &File, len: u64) -> io::Result<(u64, u64)> {
    let tail_len = len.min((EOCD_LEN + u16::MAX as usize) as u64) as usize;
    if tail_len < EOCD_LEN {
        return Err(invalid("not a zip"));
    }
    let tail_start = len - tail_len as u64;
    let mut tail = vec![0u8; tail_len];
    read_exact_at(file, &mut tail, tail_start)?;
    // The last end record whose comment length reaches exactly the end of the file.
    let eocd = (0..=tail_len - EOCD_LEN)
        .rev()
        .find(|&at| u32_at(&tail, at) == EOCD_SIGNATURE && at + EOCD_LEN + u16_at(&tail, at + 20) as usize == tail_len)
        .ok_or_else(|| invalid("end of central directory not found"))?;
    let mut size = u32_at(&tail, eocd + 12) as u64;
    let mut offset = u32_at(&tail, eocd + 16) as u64;
    let zip64 = u16_at(&tail, eocd + 10) == u16::MAX || size == u32::MAX as u64 || offset == u32::MAX as u64;
    if zip64 {
        let locator_at = tail_start + eocd as u64;
        let locator_at = locator_at
            .checked_sub(20)
            .ok_or_else(|| invalid("zip64 locator missing"))?;
        let mut locator = [0u8; 20];
        read_exact_at(file, &mut locator, locator_at)?;
        if u32_at(&locator, 0) != ZIP64_LOCATOR_SIGNATURE {
            return Err(invalid("zip64 locator missing"));
        }
        let mut record = [0u8; 56];
        read_exact_at(file, &mut record, u64_at(&locator, 8))?;
        if u32_at(&record, 0) != ZIP64_EOCD_SIGNATURE {
            return Err(invalid("zip64 end record missing"));
        }
        size = u64_at(&record, 40);
        offset = u64_at(&record, 48);
    }
    if size > MAX_CENTRAL_DIRECTORY || offset.checked_add(size).map_or(true, |end| end > len) {
        return Err(invalid("central directory out of bounds"));
    }
    Ok((offset, size))
}

fn parse_central_directory(central: &[u8], prefix: &str) -> io::Result<HashMap<String, Entry>> {
    let mut entries = HashMap::new();
    let mut at = 0usize;
    while at + 46 <= central.len() {
        if u32_at(central, at) != CENTRAL_SIGNATURE {
            break;
        }
        let flags = u16_at(central, at + 8);
        let method = u16_at(central, at + 10);
        let mut compressed_size = u32_at(central, at + 20) as u64;
        let uncompressed_size = u32_at(central, at + 24);
        let name_len = u16_at(central, at + 28) as usize;
        let extra_len = u16_at(central, at + 30) as usize;
        let comment_len = u16_at(central, at + 32) as usize;
        let mut header_offset = u32_at(central, at + 42) as u64;
        let name_start = at + 46;
        let extra_start = name_start + name_len;
        let next = extra_start + extra_len + comment_len;
        if next > central.len() {
            return Err(invalid("truncated central directory"));
        }
        let name = &central[name_start..extra_start];
        if flags & 1 == 0 && name.starts_with(prefix.as_bytes()) {
            // Zip64 extra field: the 64-bit values replace the saturated ones, in order.
            let mut extra = &central[extra_start..extra_start + extra_len];
            while extra.len() >= 4 {
                let id = u16_at(extra, 0);
                let size = (u16_at(extra, 2) as usize).min(extra.len() - 4);
                if id == 1 {
                    let mut fields = extra[4..4 + size].chunks_exact(8).map(|chunk| u64_at(chunk, 0));
                    if uncompressed_size == u32::MAX {
                        fields.next();
                    }
                    if compressed_size == u32::MAX as u64 {
                        compressed_size = fields.next().unwrap_or(compressed_size);
                    }
                    if header_offset == u32::MAX as u64 {
                        header_offset = fields.next().unwrap_or(header_offset);
                    }
                }
                extra = &extra[4 + size..];
            }
            if let Ok(name) = std::str::from_utf8(name) {
                entries.insert(
                    name.to_string(),
                    Entry {
                        header_offset,
                        compressed_size,
                        method,
                    },
                );
            }
        }
        at = next;
    }
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_zip(path: &Path, entries: &[(&str, &[u8], zip::CompressionMethod, bool)]) {
        let mut writer = zip::ZipWriter::new(File::create(path).unwrap());
        for (name, content, method, large) in entries {
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(*method)
                .large_file(*large);
            writer.start_file(*name, options).unwrap();
            writer.write_all(content).unwrap();
        }
        writer.set_comment("apk comment");
        writer.finish().unwrap();
    }

    fn read(index: &ApkIndex, name: &str) -> Option<Vec<u8>> {
        index.with_entry(name, |reader| {
            let mut out = Vec::new();
            reader.read_to_end(&mut out)?;
            Ok(out)
        })
    }

    #[test]
    fn reads_stored_deflated_and_zip64_entries() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("app.apk");
        let big: Vec<u8> = (0..200_000u32).flat_map(|value| value.to_le_bytes()).collect();
        write_zip(
            &path,
            &[
                ("classes.dex", b"dex", zip::CompressionMethod::Stored, false),
                (
                    "assets/public/index.html",
                    b"<html>",
                    zip::CompressionMethod::Stored,
                    false,
                ),
                ("assets/public/app.js", &big, zip::CompressionMethod::Deflated, false),
                (
                    "assets/public/zip64.js",
                    b"large",
                    zip::CompressionMethod::Deflated,
                    true,
                ),
            ],
        );
        let index = ApkIndex::open(&path, "assets/").unwrap();
        assert_eq!(index.len(), 3, "only assets/ are indexed");
        assert_eq!(read(&index, "assets/public/index.html").unwrap(), b"<html>");
        assert_eq!(read(&index, "assets/public/app.js").unwrap(), big);
        assert_eq!(read(&index, "assets/public/zip64.js").unwrap(), b"large");
        assert!(read(&index, "classes.dex").is_none());
        assert!(read(&index, "assets/public/missing.js").is_none());
    }

    /// Opening only reads the central directory: a broken local header affects
    /// that entry alone.
    #[test]
    fn local_headers_are_read_on_use_only() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("app.apk");
        write_zip(
            &path,
            &[
                ("assets/a.js", b"first", zip::CompressionMethod::Stored, false),
                ("assets/b.js", b"second", zip::CompressionMethod::Stored, false),
            ],
        );
        let mut bytes = std::fs::read(&path).unwrap();
        bytes[0] = 0; // local header signature of assets/a.js
        std::fs::write(&path, bytes).unwrap();
        let index = ApkIndex::open(&path, "assets/").unwrap();
        assert!(read(&index, "assets/a.js").is_none());
        assert_eq!(read(&index, "assets/b.js").unwrap(), b"second");
    }

    #[test]
    fn rejects_non_zip_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("app.apk");
        std::fs::write(&path, vec![7u8; 4096]).unwrap();
        assert!(ApkIndex::open(&path, "assets/").is_err());
        std::fs::write(&path, b"PK").unwrap();
        assert!(ApkIndex::open(&path, "assets/").is_err());
    }
}
