//! Bundle archive extraction: zip-slip safe, CRC checked, symlinks only when
//! they stay inside their own directory, then the single-folder unwrap rule.

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
/// Regular files are written by this many threads at most (storage is the limit).
const MAX_EXTRACT_WORKERS: usize = 4;

type Archive = zip::ZipArchive<io::BufReader<File>>;

fn open_archive(zip_path: &Path) -> Result<Archive, ExtractError> {
    let failed = |error: &dyn std::fmt::Display| {
        ExtractError::Failed(format!("Failed to unzip {}: {error}", zip_path.display()))
    };
    let file = File::open(zip_path).map_err(|error| failed(&error))?;
    zip::ZipArchive::new(io::BufReader::with_capacity(ARCHIVE_READ_BUFFER, file)).map_err(|error| failed(&error))
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
    destination: &Path,
    buffer: &mut [u8],
    zip_path: &Path,
) -> Result<(), ExtractError> {
    let failed = |error: &dyn std::fmt::Display| {
        ExtractError::Failed(format!("Failed to unzip {}: {error}", zip_path.display()))
    };
    let parent = entry.target.parent().unwrap_or(destination).to_path_buf();
    fs::create_dir_all(&parent).map_err(|_| ExtractError::Directory(parent.display().to_string()))?;
    // Symlinks created in the first pass must not redirect this file outside the bundle.
    if !physically_inside(destination, &parent) {
        return Err(ExtractError::PathEscape(entry.name.clone()));
    }
    if fs::symlink_metadata(&entry.target).is_ok() {
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
        let mut entry = archive.by_index(index).map_err(|error| failed(&error))?;
        let name = entry.name().to_string();
        let target = resolve_entry(destination, &name)?;
        if !physically_inside(destination, target.parent().unwrap_or(destination)) {
            return Err(ExtractError::PathEscape(name));
        }
        if entry.is_dir() {
            fs::create_dir_all(&target).map_err(|_| ExtractError::Directory(target.display().to_string()))?;
            done += 1;
            progress(done, total);
            continue;
        }
        if !entry.is_symlink() {
            files.push(FileEntry {
                index,
                name,
                target,
                declared: entry.size(),
            });
            continue;
        }
        let parent = target.parent().unwrap_or(destination).to_path_buf();
        fs::create_dir_all(&parent).map_err(|_| ExtractError::Directory(parent.display().to_string()))?;
        if fs::symlink_metadata(&target).is_ok() {
            super::store::remove_path(&target).map_err(|error| failed(&error))?;
        }
        let mut link = String::new();
        entry.read_to_string(&mut link).map_err(|error| failed(&error))?;
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
    // writers must never share a file, and a file must not replace a directory.
    for file in &mut files {
        let parent = file.target.parent().unwrap_or(destination).to_path_buf();
        fs::create_dir_all(&parent).map_err(|_| ExtractError::Directory(parent.display().to_string()))?;
        if !physically_inside(destination, &parent) {
            return Err(ExtractError::PathEscape(file.name.clone()));
        }
        let real_parent = fs::canonicalize(&parent).map_err(|error| failed(&error))?;
        let Some(file_name) = file.target.file_name() else {
            return Err(ExtractError::PathEscape(file.name.clone()));
        };
        let physical = real_parent.join(file_name);
        if fs::metadata(&physical).is_ok_and(|metadata| metadata.is_dir()) {
            return Err(ExtractError::Failed(format!(
                "Entry {} collides with a directory in {}",
                file.name,
                zip_path.display()
            )));
        }
        file.target = physical;
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
                        first_error.lock().unwrap().get_or_insert(error);
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
                    if let Err(error) = write_file_entry(&mut archive, entry, destination, &mut buffer, zip_path) {
                        first_error.lock().unwrap().get_or_insert(error);
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
                first_error.lock().unwrap().get_or_insert(ExtractError::Cancelled);
            }
        }
        for handle in handles {
            let _ = handle.join();
        }
    });
    match first_error.into_inner().unwrap() {
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
    let unwrap = entries.len() == 1 && entries[0].is_dir() && !source.join("index.html").exists();
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
