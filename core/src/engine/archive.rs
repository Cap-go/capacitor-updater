//! Bundle archive extraction: zip-slip safe, CRC checked, symlinks only when
//! they stay inside their own directory, then the single-folder unwrap rule.

use crate::sync::LockRecover;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use crate::error::{CoreError, CoreResult};

/// Why an entry was rejected, mapped to the historical statistic names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExtractError {
    /// Entry name uses `\` (Windows zip): stat `windows_path_fail`.
    WindowsPath(String),
    /// Entry escapes the destination: stat `canonical_path_fail`.
    PathEscape(String),
    /// A directory could not be created: stat `directory_path_fail`.
    Directory(String),
    /// Anything else (corrupt archive, CRC mismatch, I/O): stat `unzip_fail`.
    Failed(String),
    Cancelled,
}

impl ExtractError {
    pub fn stat(&self) -> Option<&'static str> {
        match self {
            ExtractError::WindowsPath(_) => Some("windows_path_fail"),
            ExtractError::PathEscape(_) => Some("canonical_path_fail"),
            ExtractError::Directory(_) => Some("directory_path_fail"),
            ExtractError::Failed(_) | ExtractError::Cancelled => None,
        }
    }

    pub fn message(&self) -> String {
        match self {
            ExtractError::WindowsPath(name) => {
                format!("Unzip failed: Windows path not supported: {name}")
            }
            ExtractError::PathEscape(name) => format!("Unzip failed: entry escapes bundle: {name}"),
            ExtractError::Directory(path) => format!("Failed to ensure directory: {path}"),
            ExtractError::Failed(message) => message.clone(),
            ExtractError::Cancelled => "download_stopped".to_string(),
        }
    }
}

fn resolve_entry(destination: &Path, name: &str) -> Result<PathBuf, ExtractError> {
    crate::paths::resolve_path_inside(&destination.to_string_lossy(), name)
        .map(PathBuf::from)
        .map_err(|error| {
            if error.code == "invalid_separator" && name.contains('\\') {
                ExtractError::WindowsPath(name.to_string())
            } else {
                ExtractError::PathEscape(name.to_string())
            }
        })
}

/// The deepest existing ancestor of `path`, canonicalized, must stay inside
/// `root` (catches directories reached through symlinks from earlier entries).
fn physically_inside(root: &Path, path: &Path) -> bool {
    let Ok(root) = fs::canonicalize(root) else {
        return false;
    };
    let mut probe = path.to_path_buf();
    loop {
        if fs::symlink_metadata(&probe).is_ok() {
            return fs::canonicalize(&probe).is_ok_and(|real| real.starts_with(&root));
        }
        if !probe.pop() {
            return false;
        }
    }
}

fn lexical_normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Read buffer around the archive: large sequential reads for inflate.
const ARCHIVE_READ_BUFFER: usize = 1024 * 1024;
/// Longest symlink target accepted (PATH_MAX on Linux and Android).
const MAX_SYMLINK_TARGET: usize = 4096;
/// Regular files are written by this many threads at most (storage is the limit).
const MAX_EXTRACT_WORKERS: usize = 4;

type Archive = zip::ZipArchive<io::BufReader<File>>;

fn open_archive(zip_path: &Path) -> Result<Archive, ExtractError> {
    let failed = |error: &dyn std::fmt::Display| {
        ExtractError::Failed(format!("Failed to unzip {}: {error}", zip_path.display()))
    };
    let mut file = File::open(zip_path).map_err(|error| failed(&error))?;
    check_declared_entries(&mut file).map_err(|error| failed(&error))?;
    zip::ZipArchive::new(io::BufReader::with_capacity(ARCHIVE_READ_BUFFER, file)).map_err(|error| failed(&error))
}

/// Smallest central directory record (signature + fixed fields, empty name).
const MIN_CENTRAL_RECORD: u64 = 46;

/// The zip crate reserves memory for the entry count the end record declares (about 200
/// bytes each) before reading any entry. A forged count (zip64 allows 2^64) made it ask
/// for gigabytes from a small file, and a failed allocation aborts the app. Every entry
/// needs a 46-byte central record, so a count the file cannot hold is rejected first.
fn check_declared_entries(file: &mut File) -> io::Result<()> {
    use io::{Seek, SeekFrom};
    let len = file.seek(SeekFrom::End(0))?;
    // End record (22 bytes) plus the longest comment.
    let tail_len = len.min(22 + u64::from(u16::MAX));
    let mut tail = vec![0u8; tail_len as usize];
    file.seek(SeekFrom::Start(len - tail_len))?;
    file.read_exact(&mut tail)?;
    file.seek(SeekFrom::Start(0))?;
    // No end record: the zip crate reports it.
    let Some(end) = (0..tail.len().saturating_sub(21))
        .rev()
        .find(|&at| tail[at..at + 4] == [0x50, 0x4b, 0x05, 0x06])
    else {
        return Ok(());
    };
    let mut entries = u64::from(u16::from_le_bytes([tail[end + 10], tail[end + 11]]));
    // zip64: the locator just before the end record points at the zip64 end record.
    if entries == u64::from(u16::MAX) && end >= 20 && tail[end - 20..end - 16] == [0x50, 0x4b, 0x06, 0x07] {
        let offset = u64::from_le_bytes(tail[end - 12..end - 4].try_into().unwrap_or_default());
        if offset.saturating_add(40) <= len {
            let mut record = [0u8; 40];
            file.seek(SeekFrom::Start(offset))?;
            file.read_exact(&mut record)?;
            file.seek(SeekFrom::Start(0))?;
            if record[..4] == [0x50, 0x4b, 0x06, 0x06] {
                entries = u64::from_le_bytes(record[32..40].try_into().unwrap_or_default());
            }
        }
    }
    if entries.saturating_mul(MIN_CENTRAL_RECORD) > len {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("archive declares {entries} entries, more than its size can hold"),
        ));
    }
    Ok(())
}

/// A regular file entry to write in the second pass.
struct FileEntry {
    index: usize,
    name: String,
    target: PathBuf,
    declared: u64,
}

fn write_file_entry(
    archive: &mut Archive,
    entry: &FileEntry,
    buffer: &mut [u8],
    zip_path: &Path,
) -> Result<(), ExtractError> {
    let failed = |error: &dyn std::fmt::Display| {
        ExtractError::Failed(format!("Failed to unzip {}: {error}", zip_path.display()))
    };
    // `target` is the physical path: its parent exists and was checked in pass 1b.
    if let Ok(existing) = fs::symlink_metadata(&entry.target) {
        // A directory here is another entry's parent: never replace it.
        if existing.is_dir() {
            return Err(ExtractError::Failed(format!(
                "Entry {} collides with a directory in {}",
                entry.name,
                zip_path.display()
            )));
        }
        super::store::remove_path(&entry.target).map_err(|error| failed(&error))?;
    }
    let mut zip_entry = archive.by_index(entry.index).map_err(|error| failed(&error))?;
    // Inflate hands out small chunks: batch them into large writes.
    let file = File::create(&entry.target).map_err(|error| failed(&error))?;
    let mut output = io::BufWriter::with_capacity(ARCHIVE_READ_BUFFER, file);
    let mut written: u64 = 0;
    loop {
        // zip verifies the CRC-32 when the entry is fully read.
        let read = zip_entry.read(buffer).map_err(|error| failed(&error))?;
        if read == 0 {
            break;
        }
        written += read as u64;
        // Never inflate past the size the central directory declares (zip bombs).
        if written > entry.declared {
            return Err(ExtractError::Failed(format!(
                "Entry {} inflates beyond its declared size",
                entry.name
            )));
        }
        output.write_all(&buffer[..read]).map_err(|error| failed(&error))?;
    }
    if written != entry.declared {
        return Err(ExtractError::Failed(format!(
            "Entry {} size {written} does not match declared {}",
            entry.name, entry.declared
        )));
    }
    output.flush().map_err(|error| failed(&error))?;
    Ok(())
}

/// Extracts `zip_path` into `destination` (created). `progress(done, total)` is
/// called after each entry. `cancelled()` aborts between entries.
///
/// Directories and symlinks are created first, in archive order; regular files
/// are then written by a few threads, each with its own archive handle.
pub fn extract_zip(
    zip_path: &Path,
    destination: &Path,
    progress: &mut dyn FnMut(usize, usize),
    cancelled: &dyn Fn() -> bool,
) -> Result<(), ExtractError> {
    let failed = |error: &dyn std::fmt::Display| {
        ExtractError::Failed(format!("Failed to unzip {}: {error}", zip_path.display()))
    };
    let mut archive = open_archive(zip_path)?;
    fs::create_dir_all(destination).map_err(|_| ExtractError::Directory(destination.display().to_string()))?;
    let total = archive.len();
    let mut done = 0;
    let mut files: Vec<FileEntry> = Vec::new();

    // Pass 1: validate every name, create directories and symlinks.
    for index in 0..total {
        if cancelled() {
            return Err(ExtractError::Cancelled);
        }
        let entry = archive.by_index(index).map_err(|error| failed(&error))?;
        let name = entry.name().to_string();
        let target = resolve_entry(destination, &name)?;
        if !entry.is_dir() && !entry.is_symlink() {
            // Checked in pass 1b, once every symlink exists.
            files.push(FileEntry {
                index,
                name,
                target,
                declared: entry.size(),
            });
            continue;
        }
        if !physically_inside(destination, target.parent().unwrap_or(destination)) {
            return Err(ExtractError::PathEscape(name));
        }
        if entry.is_dir() {
            fs::create_dir_all(&target).map_err(|_| ExtractError::Directory(target.display().to_string()))?;
            done += 1;
            progress(done, total);
            continue;
        }
        let parent = target.parent().unwrap_or(destination).to_path_buf();
        fs::create_dir_all(&parent).map_err(|_| ExtractError::Directory(parent.display().to_string()))?;
        if fs::symlink_metadata(&target).is_ok() {
            super::store::remove_path(&target).map_err(|error| failed(&error))?;
        }
        // Bounded read: a tiny compressed entry could inflate to a huge "target".
        let mut link = String::new();
        entry
            .take(MAX_SYMLINK_TARGET as u64 + 1)
            .read_to_string(&mut link)
            .map_err(|error| failed(&error))?;
        if link.len() > MAX_SYMLINK_TARGET {
            return Err(ExtractError::Failed(format!("Symlink target of {name} is too long")));
        }
        // Relative targets without `..` only: the link stays inside its own directory
        // whatever the other entries are (no chains through `..`).
        let link_path = Path::new(&link);
        if link_path.is_absolute()
            || link_path
                .components()
                .any(|component| matches!(component, std::path::Component::ParentDir))
        {
            return Err(ExtractError::PathEscape(name));
        }
        let resolved = lexical_normalize(&parent.join(&link));
        let parent_normalized = lexical_normalize(&parent);
        if resolved != parent_normalized && !resolved.starts_with(&parent_normalized) {
            return Err(ExtractError::PathEscape(name));
        }
        #[cfg(unix)]
        std::os::unix::fs::symlink(&link, &target).map_err(|error| failed(&error))?;
        #[cfg(not(unix))]
        return Err(failed(&"symlinks are not supported on this platform"));
        done += 1;
        progress(done, total);
    }

    // Pass 1b (sequential): every file gets its physical path. Two names can reach one
    // file through an in-bundle directory symlink (`b -> a`: `a/x` and `b/x`); parallel
    // writers must never share a file. No symlink is created after pass 1, so each
    // directory is created, checked and canonicalized once.
    let root = fs::canonicalize(destination).map_err(|_| ExtractError::Directory(destination.display().to_string()))?;
    let mut real_dirs: std::collections::HashMap<PathBuf, PathBuf> = std::collections::HashMap::new();
    for file in &mut files {
        let parent = file.target.parent().unwrap_or(destination).to_path_buf();
        let real_parent = match real_dirs.get(&parent) {
            Some(real) => real.clone(),
            None => {
                if !physically_inside(destination, &parent) {
                    return Err(ExtractError::PathEscape(file.name.clone()));
                }
                fs::create_dir_all(&parent).map_err(|_| ExtractError::Directory(parent.display().to_string()))?;
                let real = fs::canonicalize(&parent).map_err(|_| ExtractError::PathEscape(file.name.clone()))?;
                if !real.starts_with(&root) {
                    return Err(ExtractError::PathEscape(file.name.clone()));
                }
                real_dirs.insert(parent, real.clone());
                real
            }
        };
        let Some(file_name) = file.target.file_name() else {
            return Err(ExtractError::PathEscape(file.name.clone()));
        };
        file.target = real_parent.join(file_name);
    }

    // The same physical file twice: the last entry wins (as a sequential extraction would).
    let mut last_by_target = std::collections::HashMap::new();
    for (position, file) in files.iter().enumerate() {
        last_by_target.insert(file.target.clone(), position);
    }
    let skipped = files.len() - last_by_target.len();
    let files: Vec<FileEntry> = files
        .into_iter()
        .enumerate()
        .filter(|(position, file)| last_by_target.get(&file.target) == Some(position))
        .map(|(_, file)| file)
        .collect();
    done += skipped;

    // Pass 2: regular files in parallel.
    let workers = std::thread::available_parallelism()
        .map(|cores| cores.get())
        .unwrap_or(2)
        .clamp(1, MAX_EXTRACT_WORKERS)
        .min(files.len().max(1));
    let next = std::sync::atomic::AtomicUsize::new(0);
    let stop = std::sync::atomic::AtomicBool::new(false);
    let first_error: std::sync::Mutex<Option<ExtractError>> = std::sync::Mutex::new(None);
    let (sender, receiver) = std::sync::mpsc::channel::<()>();
    std::thread::scope(|scope| {
        let mut handles = Vec::new();
        for _ in 0..workers {
            let sender = sender.clone();
            let (files, next, stop, first_error) = (&files, &next, &stop, &first_error);
            handles.push(scope.spawn(move || {
                let mut archive = match open_archive(zip_path) {
                    Ok(archive) => archive,
                    Err(error) => {
                        first_error.lock_or_recover().get_or_insert(error);
                        stop.store(true, std::sync::atomic::Ordering::SeqCst);
                        return;
                    }
                };
                let mut buffer = vec![0u8; crate::crypto::checksum::IO_BUFFER_BYTES];
                loop {
                    if stop.load(std::sync::atomic::Ordering::SeqCst) {
                        return;
                    }
                    let position = next.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    let Some(entry) = files.get(position) else {
                        return;
                    };
                    if let Err(error) = write_file_entry(&mut archive, entry, &mut buffer, zip_path) {
                        first_error.lock_or_recover().get_or_insert(error);
                        stop.store(true, std::sync::atomic::Ordering::SeqCst);
                        return;
                    }
                    let _ = sender.send(());
                }
            }));
        }
        drop(sender);
        // Progress and cancellation stay on the caller's thread.
        for () in receiver.iter() {
            done += 1;
            progress(done, total);
            if cancelled() {
                stop.store(true, std::sync::atomic::Ordering::SeqCst);
                first_error.lock_or_recover().get_or_insert(ExtractError::Cancelled);
            }
        }
        for handle in handles {
            let _ = handle.join();
        }
    });
    match first_error
        .into_inner()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
    {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

fn visible_entries(dir: &Path) -> io::Result<Vec<PathBuf>> {
    let mut entries: Vec<PathBuf> = fs::read_dir(dir)?
        .filter_map(Result::ok)
        .filter(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            !name.starts_with("__MACOSX") && !name.starts_with('.')
        })
        .map(|entry| entry.path())
        .collect();
    entries.sort();
    Ok(entries)
}

/// Moves an extracted bundle into `destination`. A single top-level folder
/// (ignoring `__MACOSX` and dot files) without `index.html` next to it is
/// unwrapped (`dist/index.html` zips).
pub fn install_extracted(source: &Path, destination: &Path) -> CoreResult<()> {
    let io_error = |context: &str, error: io::Error| CoreError::io(context, error);
    let entries = visible_entries(source).map_err(|error| io_error("Cannot list extracted bundle", error))?;
    if entries.is_empty() {
        return Err(CoreError::new(
            "unzip_fail",
            format!("Source file was not a directory or was empty: {}", source.display()),
        ));
    }
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(|error| io_error("Cannot create bundle root", error))?;
    }
    if destination.exists() {
        super::store::remove_path(destination).map_err(|error| io_error("Cannot replace bundle folder", error))?;
    }
    // A real directory only: a symlink to a hidden folder would be moved alone, then
    // its target deleted with `source`.
    let unwrap = entries.len() == 1
        && fs::symlink_metadata(&entries[0]).is_ok_and(|metadata| metadata.is_dir())
        && !source.join("index.html").exists();
    let from = if unwrap {
        entries[0].clone()
    } else {
        source.to_path_buf()
    };
    fs::rename(&from, destination).map_err(|error| {
        CoreError::new(
            "unzip_fail",
            format!(
                "Failed to move bundle contents: {} -> {}: {error}",
                from.display(),
                destination.display()
            ),
        )
    })?;
    if unwrap {
        let _ = super::store::remove_path(source);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 1 MiB of zeros, then zip64 end records declaring `entries` files.
    fn forged_zip64(entries: u64) -> Vec<u8> {
        let mut bytes = vec![0u8; 1 << 20];
        let zip64_end = bytes.len() as u64;
        bytes.extend(0x0606_4b50u32.to_le_bytes());
        bytes.extend(44u64.to_le_bytes());
        bytes.extend([45, 0, 45, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        bytes.extend(entries.to_le_bytes());
        bytes.extend(entries.to_le_bytes());
        bytes.extend((46 * entries).to_le_bytes());
        bytes.extend(1024u64.to_le_bytes());
        bytes.extend(0x0706_4b50u32.to_le_bytes());
        bytes.extend(0u32.to_le_bytes());
        bytes.extend(zip64_end.to_le_bytes());
        bytes.extend(1u32.to_le_bytes());
        bytes.extend(0x0605_4b50u32.to_le_bytes());
        bytes.extend([0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff]);
        bytes.extend([0xff; 8]);
        bytes.extend([0, 0]);
        bytes
    }

    #[test]
    fn an_entry_count_the_file_cannot_hold_is_rejected_before_allocating() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("forged.zip");
        // The zip crate would reserve about 200 bytes per declared entry: 200 MB here.
        std::fs::write(&path, forged_zip64(1 << 20)).unwrap();
        let Err(ExtractError::Failed(message)) = open_archive(&path) else {
            panic!("a forged entry count must be rejected");
        };
        assert!(message.contains("more than its size can hold"), "{message}");
    }

    #[test]
    fn real_archives_still_open() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ok.zip");
        let mut writer = zip::ZipWriter::new(File::create(&path).unwrap());
        for index in 0..3 {
            writer
                .start_file(format!("f{index}.txt"), zip::write::SimpleFileOptions::default())
                .unwrap();
            writer.write_all(b"x").unwrap();
        }
        writer.finish().unwrap();
        assert_eq!(open_archive(&path).ok().map(|archive| archive.len()), Some(3));
        std::fs::write(&path, []).unwrap();
        assert!(open_archive(&path).is_err());
    }
}
