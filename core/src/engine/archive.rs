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

/// Extracts `zip_path` into `destination` (created). `progress(done, total)` is
/// called after each entry. `cancelled()` aborts between entries.
pub fn extract_zip(
    zip_path: &Path,
    destination: &Path,
    progress: &mut dyn FnMut(usize, usize),
    cancelled: &dyn Fn() -> bool,
) -> Result<(), ExtractError> {
    let failed = |error: &dyn std::fmt::Display| {
        ExtractError::Failed(format!("Failed to unzip {}: {error}", zip_path.display()))
    };
    let file = File::open(zip_path).map_err(|error| failed(&error))?;
    let mut archive = zip::ZipArchive::new(io::BufReader::new(file)).map_err(|error| failed(&error))?;
    fs::create_dir_all(destination).map_err(|_| ExtractError::Directory(destination.display().to_string()))?;
    let total = archive.len();
    let mut buffer = vec![0u8; crate::crypto::checksum::IO_BUFFER_BYTES];
    for index in 0..total {
        if cancelled() {
            return Err(ExtractError::Cancelled);
        }
        let mut entry = archive.by_index(index).map_err(|error| failed(&error))?;
        let name = entry.name().to_string();
        let target = resolve_entry(destination, &name)?;
        if entry.is_dir() {
            fs::create_dir_all(&target).map_err(|_| ExtractError::Directory(target.display().to_string()))?;
            progress(index + 1, total);
            continue;
        }
        let parent = target.parent().unwrap_or(destination).to_path_buf();
        fs::create_dir_all(&parent).map_err(|_| ExtractError::Directory(parent.display().to_string()))?;
        if fs::symlink_metadata(&target).is_ok() {
            super::store::remove_path(&target).map_err(|error| failed(&error))?;
        }
        if entry.is_symlink() {
            let mut link = String::new();
            entry.read_to_string(&mut link).map_err(|error| failed(&error))?;
            // The link must stay inside its own directory (lexically).
            let resolved = if Path::new(&link).is_absolute() {
                PathBuf::from(&link)
            } else {
                parent.join(&link)
            };
            let resolved = lexical_normalize(&resolved);
            let parent_normalized = lexical_normalize(&parent);
            if resolved != parent_normalized && !resolved.starts_with(&parent_normalized) {
                return Err(ExtractError::PathEscape(name));
            }
            #[cfg(unix)]
            std::os::unix::fs::symlink(&link, &target).map_err(|error| failed(&error))?;
            #[cfg(not(unix))]
            return Err(failed(&"symlinks are not supported on this platform"));
        } else {
            let declared = entry.size();
            let mut output = File::create(&target).map_err(|error| failed(&error))?;
            let mut written: u64 = 0;
            loop {
                // zip verifies the CRC-32 when the entry is fully read.
                let read = entry.read(&mut buffer).map_err(|error| failed(&error))?;
                if read == 0 {
                    break;
                }
                written += read as u64;
                // Never inflate past the size the central directory declares (zip bombs).
                if written > declared {
                    return Err(ExtractError::Failed(format!(
                        "Entry {name} inflates beyond its declared size"
                    )));
                }
                output.write_all(&buffer[..read]).map_err(|error| failed(&error))?;
            }
            if written != declared {
                return Err(ExtractError::Failed(format!(
                    "Entry {name} size {written} does not match declared {declared}"
                )));
            }
        }
        progress(index + 1, total);
    }
    Ok(())
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
