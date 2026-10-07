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

/// Hard-links `source` to `destination` (atomically replacing it); copies when
/// linking is not possible (other volume, unsupported file system). Only for
/// files the updater owns and never rewrites in place (bundle and cache files).
pub fn link_or_copy(source: &Path, destination: &Path) -> io::Result<()> {
    let parent = destination
        .parent()
        .ok_or_else(|| io::Error::other("destination has no parent"))?;
    fs::create_dir_all(parent)?;
    let temp = unique_temp(parent, "capgo-", ".tmp");
    if fs::hard_link(source, &temp).is_ok() {
        if fs::rename(&temp, destination).is_ok() {
            return Ok(());
        }
        let _ = fs::remove_file(&temp);
    }
    copy_atomically(source, destination)
}

/// Writes `data` to `destination` through a sibling temp file + rename.
pub fn write_atomically(destination: &Path, data: &[u8]) -> io::Result<()> {
    let parent = destination
        .parent()
        .ok_or_else(|| io::Error::other("destination has no parent"))?;
    fs::create_dir_all(parent)?;
    let temp = unique_temp(parent, "capgo-", ".tmp");
    let result = fs::write(&temp, data).and_then(|_| fs::rename(&temp, destination));
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

/// What the side thread of a [`BlockWriter`] does with the bytes.
#[derive(Clone)]
pub enum StreamSink {
    None,
    /// SHA-256 of the bytes.
    Hash,
    /// AES-128-CBC decrypt into `plain` and SHA-256 of the plaintext.
    Decrypt {
        key: [u8; 16],
        iv: [u8; 16],
        plain: PathBuf,
    },
}

type SinkThread = (
    std::sync::mpsc::SyncSender<Vec<u8>>,
    std::thread::JoinHandle<Option<String>>,
);

/// Writes a stream to a file in 1 MiB blocks; a side thread hashes (or
/// decrypts and hashes) the same blocks, overlapping with network and disk I/O.
pub struct BlockWriter {
    file: File,
    block: Vec<u8>,
    sink: Option<SinkThread>,
}

const BLOCK_BYTES: usize = 1024 * 1024;

fn decrypt_sink(
    receiver: std::sync::mpsc::Receiver<Vec<u8>>,
    key: [u8; 16],
    iv: [u8; 16],
    plain: &Path,
) -> Option<String> {
    let file = File::create(plain).ok()?;
    let mut output = io::BufWriter::with_capacity(BLOCK_BYTES, file);
    let mut decryptor = crate::crypto::aes_cbc::CbcDecryptor::new(&key, &iv);
    let mut context = Context::new(&SHA256);
    let mut out = Vec::with_capacity(BLOCK_BYTES + 16);
    let mut produced = 0usize;
    for block in receiver {
        out.clear();
        decryptor.update(&block, &mut out);
        context.update(&out);
        output.write_all(&out).ok()?;
        produced += out.len();
    }
    out.clear();
    decryptor.finish(&mut out).ok()?;
    context.update(&out);
    output.write_all(&out).ok()?;
    output.flush().ok()?;
    produced += out.len();
    (produced > 0).then(|| hex_encode(context.finish().as_ref()))
}

impl BlockWriter {
    pub fn new(file: File, sink: StreamSink) -> Self {
        let sink = match sink {
            StreamSink::None => None,
            StreamSink::Hash => {
                let (sender, receiver) = std::sync::mpsc::sync_channel::<Vec<u8>>(4);
                let handle = std::thread::spawn(move || {
                    let mut context = Context::new(&SHA256);
                    for block in receiver {
                        context.update(&block);
                    }
                    Some(hex_encode(context.finish().as_ref()))
                });
                Some((sender, handle))
            }
            StreamSink::Decrypt { key, iv, plain } => {
                let (sender, receiver) = std::sync::mpsc::sync_channel::<Vec<u8>>(4);
                let handle = std::thread::spawn(move || {
                    let result = decrypt_sink(receiver, key, iv, &plain);
                    if result.is_none() {
                        let _ = fs::remove_file(&plain);
                    }
                    result
                });
                Some((sender, handle))
            }
        };
        Self {
            file,
            block: Vec::with_capacity(BLOCK_BYTES),
            sink,
        }
    }

    pub fn write(&mut self, mut data: &[u8]) -> io::Result<()> {
        while !data.is_empty() {
            let take = (BLOCK_BYTES - self.block.len()).min(data.len());
            self.block.extend_from_slice(&data[..take]);
            data = &data[take..];
            if self.block.len() == BLOCK_BYTES {
                self.flush_block()?;
            }
        }
        Ok(())
    }

    fn flush_block(&mut self) -> io::Result<()> {
        if self.block.is_empty() {
            return Ok(());
        }
        self.file.write_all(&self.block)?;
        let block = std::mem::replace(&mut self.block, Vec::with_capacity(BLOCK_BYTES));
        if let Some((sender, _)) = &self.sink {
            // A failed side thread only loses its result; the caller falls back to a file pass.
            if sender.send(block).is_err() {
                self.sink = None;
            }
        }
        Ok(())
    }

    /// Writes what is buffered and returns the side thread's result: the SHA-256
    /// of the bytes (`Hash`) or of the plaintext (`Decrypt`), `None` when unavailable.
    pub fn finish(mut self) -> io::Result<Option<String>> {
        self.flush_block()?;
        self.file.flush()?;
        Ok(self.sink.take().and_then(|(sender, handle)| {
            drop(sender);
            handle.join().ok().flatten()
        }))
    }
}
