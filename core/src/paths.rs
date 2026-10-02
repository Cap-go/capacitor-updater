//! Path and cache-name guards. These are security boundaries: manifest
//! `file_name` values, zip entry names and bundle ids come from the network
//! and must never escape the directory they are resolved against.

use crate::crypto::checksum::short_path_key;
use crate::error::{CoreError, CoreResult};

/// SHA-256 of zero bytes.
pub const EMPTY_SHA256: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/// Virtual root used to resolve builtin (APK / app bundle) asset paths.
const BUILTIN_ASSETS_ROOT: &str = "/capgo-builtin-assets";

/// True when any `/`-separated segment is exactly `..`.
pub fn contains_path_traversal_segment(relative_path: &str) -> bool {
    relative_path.split('/').any(|segment| segment == "..")
}

fn is_absolute(relative_path: &str) -> bool {
    // `~` is expanded by Foundation path APIs, so treat it like an absolute path.
    relative_path.starts_with('/') || relative_path.starts_with('~')
}

/// Validates `relative_path` and returns its normalized components.
fn relative_components(relative_path: &str) -> CoreResult<Vec<&str>> {
    if relative_path.is_empty() {
        return Err(CoreError::new("empty_path", "Invalid empty path"));
    }
    if relative_path.contains('\\') || relative_path.contains('\0') {
        return Err(CoreError::new("invalid_separator", "Invalid path separator"));
    }
    if contains_path_traversal_segment(relative_path) {
        return Err(CoreError::new(
            "path_traversal",
            "Path traversal segments are not allowed",
        ));
    }
    if is_absolute(relative_path) {
        return Err(CoreError::new("absolute_path", "Absolute paths are not allowed"));
    }
    let components: Vec<&str> = relative_path
        .split('/')
        .filter(|segment| !segment.is_empty() && *segment != ".")
        .collect();
    // Require a strict child of the base: "." (or "./") would target the base itself.
    if components.is_empty() {
        return Err(CoreError::new(
            "escapes_base",
            format!("Path escapes base directory: {relative_path}"),
        ));
    }
    Ok(components)
}

fn normalized_base(base: &str) -> &str {
    let trimmed = base.trim_end_matches('/');
    if trimmed.is_empty() {
        "/"
    } else {
        trimmed
    }
}

/// Resolves an untrusted relative path strictly inside `base` (lexically).
///
/// Hosts may additionally canonicalize the result against the real file
/// system (symlinks) as defense in depth.
pub fn resolve_path_inside(base: &str, relative_path: &str) -> CoreResult<String> {
    let components = relative_components(relative_path)?;
    let base = normalized_base(base);
    let separator = if base.ends_with('/') { "" } else { "/" };
    Ok(format!("{base}{separator}{}", components.join("/")))
}

/// Manifest entries may be brotli-compressed (`.br`); the stored file drops the suffix.
pub fn manifest_target_name(file_name: &str) -> &str {
    file_name.strip_suffix(".br").unwrap_or(file_name)
}

pub fn resolve_manifest_target_path(base: &str, file_name: &str) -> CoreResult<String> {
    resolve_path_inside(base, manifest_target_name(file_name))
}

/// Path of a manifest file inside the builtin web assets (`public/...`).
pub fn builtin_asset_path(file_name: &str) -> CoreResult<String> {
    let resolved = resolve_manifest_target_path(BUILTIN_ASSETS_ROOT, file_name)?;
    let relative = &resolved[BUILTIN_ASSETS_ROOT.len() + 1..];
    Ok(format!("public/{relative}"))
}

/// Cache file names embed the hash, so only accept plain SHA-256 (64) or CRC32 (8) hex.
pub fn is_safe_cache_hash(hash: Option<&str>) -> bool {
    match hash {
        Some(hash) => (hash.len() == 64 || hash.len() == 8) && hash.bytes().all(|c| c.is_ascii_hexdigit()),
        None => false,
    }
}

/// SHA-256 hash-named cache files were verified when written: existence is
/// enough for non-empty files; empty files are only reused for the empty SHA-256.
/// CRC32 is too collision-prone to trust without a re-read.
/// `size` is `None` when the cache file does not exist (or is not a regular file).
pub fn is_reusable_cache_file(hash: Option<&str>, size: Option<i64>) -> bool {
    let Some(hash) = hash else {
        return false;
    };
    if !is_safe_cache_hash(Some(hash)) || hash.len() != 64 {
        return false;
    }
    match size {
        Some(size) if size > 0 => true,
        Some(0) => hash.eq_ignore_ascii_case(EMPTY_SHA256),
        _ => false,
    }
}

/// `{hash}_{basename}` name of a delta-cache entry for a manifest file.
pub fn cache_file_name(hash: &str, file_name: &str) -> String {
    let base_name = file_name.rsplit('/').next().unwrap_or(file_name);
    format!("{hash}_{}", manifest_target_name(base_name))
}

/// Name of the resumable partial download for a manifest entry.
pub fn manifest_partial_name(hash: Option<&str>, file_name: &str) -> String {
    let token = short_path_key(file_name);
    match hash {
        Some(hash) if is_safe_cache_hash(Some(hash)) && hash.len() == 64 => {
            format!("partial_{hash}_{token}.tmp")
        }
        _ => {
            let digest = short_path_key(&format!("{}\0{file_name}", hash.unwrap_or_default()));
            format!("partial_{digest}_{token}.tmp")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_against_root() {
        assert_eq!(resolve_path_inside("/", "a").unwrap(), "/a");
        assert_eq!(resolve_path_inside("/base/", "a//b").unwrap(), "/base/a/b");
    }

    #[test]
    fn cache_name_strips_directories_and_brotli() {
        assert_eq!(cache_file_name("abc", "js/app.js.br"), "abc_app.js");
        assert_eq!(cache_file_name("abc", "index.html"), "abc_index.html");
    }
}
