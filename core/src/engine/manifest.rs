//! Manifest (delta) downloads: every file is reused from the builtin bundle,
//! the APK assets (Android) or the delta cache when its hash matches, and only
//! the rest is fetched (resumable partials, brotli, per-file decryption).

use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};

use super::download::{Cancel, DownloadRequest};
use super::fsutil;
use super::store::remove_path;
use super::Engine;
use crate::bundle::BundleInfo;
use crate::crypto;
use crate::error::{CoreError, CoreResult};
use crate::host::HostLog;
use crate::net::NetError;
use crate::paths;

const PER_FILE_ESTIMATE: u64 = 100 * 1024;
/// Manifest workers started at once; the rest join as files finish.
const INITIAL_MANIFEST_WORKERS: usize = 16;
const MIN_FREE_BYTES: u64 = 50 * 1024 * 1024;

#[derive(Debug, Clone)]
struct Task {
    file_name: String,
    download_url: String,
    hash: String,
    brotli: bool,
    target: PathBuf,
    builtin: Option<PathBuf>,
    asset: Option<String>,
    cache: Option<PathBuf>,
    legacy_cache: Option<PathBuf>,
}

/// Reads builtin files out of the APK (`assets/public/...`) through an index
/// shared by every worker (see `apk.rs`).
struct ApkAssets {
    path: PathBuf,
}

impl ApkAssets {
    fn with_entry<R>(&self, name: &str, f: impl FnOnce(&mut dyn Read) -> io::Result<R>) -> Option<R> {
        super::apk::ApkIndex::shared(&self.path)?.with_entry(&format!("assets/{name}"), f)
    }

    fn matches(&self, name: &str, hash: &str) -> bool {
        self.with_entry(name, |reader| fsutil::sha256_reader(reader))
            .is_some_and(|actual| actual.eq_ignore_ascii_case(hash))
    }

    fn copy_if_matches(&self, name: &str, hash: &str, target: &Path) -> bool {
        self.with_entry(name, |reader| fsutil::write_verified(reader, target, Some(hash)))
            .flatten()
            .is_some()
    }
}

/// Per-path lock shared by every engine in the process (entries die with their last user).
fn partial_lock(path: &Path) -> std::sync::Arc<Mutex<()>> {
    use std::collections::HashMap;
    use std::sync::{Arc, OnceLock, Weak};
    static LOCKS: OnceLock<Mutex<HashMap<PathBuf, Weak<Mutex<()>>>>> = OnceLock::new();
    let mut locks = LOCKS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    if let Some(lock) = locks.get(path).and_then(Weak::upgrade) {
        return lock;
    }
    locks.retain(|_, lock| lock.strong_count() > 0);
    let lock = Arc::new(Mutex::new(()));
    locks.insert(path.to_path_buf(), Arc::downgrade(&lock));
    lock
}

fn entry_text<'a>(entry: &'a Value, key: &str) -> &'a str {
    entry.get(key).and_then(Value::as_str).unwrap_or_default()
}

fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Brotli decode with the Capgo CLI "stored" wrapper shortcuts. Returns the SHA-256 of the output.
fn decode_brotli(source: &Path, target: &Path, expected: &str) -> io::Result<Option<String>> {
    let bytes_len = fs::metadata(source)?.len();
    let mut head = [0u8; 3];
    let mut tail = [0u8; 1];
    let (has_head, last) = {
        let mut file = File::open(source)?;
        let has_head = bytes_len >= 3 && file.read_exact(&mut head).is_ok();
        if bytes_len > 3 {
            use std::io::Seek;
            file.seek(io::SeekFrom::End(-1))?;
            file.read_exact(&mut tail)?;
        }
        (has_head, tail[0])
    };
    if bytes_len == 0 || (bytes_len == 3 && has_head && head == [0x1b, 0x00, 0x06]) {
        return fsutil::write_verified(&mut io::empty(), target, Some(expected));
    }
    if bytes_len > 3 && last == 0x03 && has_head && (head == [0x1b, 0x00, 0x06] || head == [0x0b, 0x02, 0x80]) {
        use std::io::Seek;
        let mut file = File::open(source)?;
        file.seek(io::SeekFrom::Start(3))?;
        let mut limited = file.take(bytes_len - 4);
        return fsutil::write_verified(&mut limited, target, Some(expected));
    }
    let file = File::open(source)?;
    let mut decoder =
        brotli_decompressor::Decompressor::new(io::BufReader::new(file), crate::crypto::checksum::IO_BUFFER_BYTES);
    fsutil::write_verified(&mut decoder, target, Some(expected))
}

/// AES key of an encrypted manifest download: one RSA operation, done the
/// first time a file actually has to be decrypted (reused files need none).
pub(crate) struct LazySession<'a> {
    public_key: String,
    session_key: &'a str,
    cell: std::sync::OnceLock<Result<Option<crypto::SessionKey>, String>>,
}

impl LazySession<'_> {
    fn get(&self) -> Result<Option<&crypto::SessionKey>, String> {
        self.cell
            .get_or_init(|| {
                crypto::bundle_session_key(&self.public_key, self.session_key)
                    .map_err(|error| format!("Failed to decrypt session key: {}", error.message))
            })
            .as_ref()
            .map(Option::as_ref)
            .map_err(Clone::clone)
    }
}

impl Engine {
    fn apk_assets(&self) -> Option<ApkAssets> {
        let path = self.config().builtin_apk.clone();
        (!path.as_os_str().is_empty() && path.is_file()).then_some(ApkAssets { path })
    }

    fn manifest_hash(&self, entry: &Value, session_key: &str) -> Option<String> {
        let hash = entry_text(entry, "file_hash");
        if hash.is_empty() {
            return None;
        }
        let public_key = self.config().public_key.clone();
        if public_key.is_empty() {
            return Some(hash.to_string());
        }
        if !crypto::is_valid_session_key(Some(session_key)) {
            return None;
        }
        crypto::decrypt_checksum(hash, &public_key).ok()
    }

    fn cache_paths(&self, hash: &str, file_name: &str) -> (Option<PathBuf>, Option<PathBuf>) {
        let cache = self.config().cache_dir.clone();
        if cache.as_os_str().is_empty() || !paths::is_safe_cache_hash(Some(hash)) {
            return (None, None);
        }
        let current = cache.join(paths::cache_file_name(hash, file_name));
        let legacy = file_name
            .ends_with(".br")
            .then(|| cache.join(format!("{hash}_{}", basename(file_name))));
        (Some(current), legacy)
    }

    fn reusable(path: Option<&PathBuf>, hash: &str) -> bool {
        path.is_some_and(|path| {
            let size = fs::metadata(path)
                .ok()
                .filter(|metadata| metadata.is_file())
                .map(|metadata| metadata.len() as i64);
            paths::is_reusable_cache_file(Some(hash), size)
        })
    }

    /// `{missing, total, missingCount, reusableCount}` for a manifest.
    pub fn missing_bundle_files(&self, manifest: &[Value], session_key: &str) -> Value {
        let builtin = self.config().builtin_dir.clone();
        let assets = self.apk_assets();
        let missing: Vec<Value> = manifest
            .iter()
            .filter(|entry| {
                let file_name = entry_text(entry, "file_name");
                let Some(hash) = self.manifest_hash(entry, session_key) else {
                    return true;
                };
                if file_name.is_empty() {
                    return true;
                }
                if let Ok(path) = paths::resolve_manifest_target_path(&builtin.to_string_lossy(), file_name) {
                    if !builtin.as_os_str().is_empty() && fsutil::file_matches_hash(Path::new(&path), &hash) {
                        return false;
                    }
                }
                if let (Some(assets), Ok(asset)) = (&assets, paths::builtin_asset_path(file_name)) {
                    if assets.matches(&asset, &hash) {
                        return false;
                    }
                }
                let (cache, legacy) = self.cache_paths(&hash, file_name);
                !(Self::reusable(cache.as_ref(), &hash) || Self::reusable(legacy.as_ref(), &hash))
            })
            .cloned()
            .collect();
        json!({
            "missing": missing,
            "total": manifest.len(),
            "missingCount": missing.len(),
            "reusableCount": manifest.len() - missing.len(),
        })
    }

    /// Downloads a manifest bundle into `versions/<id>`. Blocking.
    pub fn download_manifest(&self, request: &DownloadRequest) -> CoreResult<BundleInfo> {
        let manifest = request.manifest.clone().unwrap_or_default();
        self.require_session_key(&request.session_key, &request.version)?;
        self.host
            .before_download()
            .map_err(|message| CoreError::new("download_blocked", message))?;
        if let Some(existing) = self.get_bundle_info_by_name(&request.version) {
            if (existing.is_error() || existing.is_deleted() || existing.is_deleting())
                && !self.delete_bundle(existing.id(), true, false)
            {
                return Err(CoreError::new(
                    "delete_failed",
                    "Failed to delete existing bundle before retry",
                ));
            }
        }
        let cancel = self.register_download_token(&request.version);
        let record = self.start_record(request);
        self.progress(record.id(), 0);
        let result = self.download_manifest_inner(request, &manifest, &record, &cancel);
        self.unregister_download_token(&request.version, &cancel);
        match result {
            Ok(installed) => Ok(installed),
            Err(error) => {
                if let Ok(dir) = self.bundle_directory(record.id()) {
                    let _ = remove_path(&dir);
                }
                self.fail_download(&record, &error, request.emit_events);
                Err(error)
            }
        }
    }

    fn manifest_path_fail(&self, version: &str, file_name: &str) {
        self.send_stats(
            "manifest_path_fail",
            Some(&format!("{version}:{file_name}")),
            None,
            None,
        );
    }

    fn plan_tasks(&self, request: &DownloadRequest, manifest: &[Value], destination: &Path) -> CoreResult<Vec<Task>> {
        let builtin = self.config().builtin_dir.clone();
        let mut seen = BTreeSet::new();
        let mut tasks = Vec::with_capacity(manifest.len());
        let mut first_error: Option<CoreError> = None;
        let fail = |error: CoreError, first: &mut Option<CoreError>| {
            if first.is_none() {
                *first = Some(error);
            }
        };
        for entry in manifest {
            let file_name = entry_text(entry, "file_name").to_string();
            let download_url = entry_text(entry, "download_url").to_string();
            if file_name.is_empty() || download_url.is_empty() {
                fail(
                    CoreError::new(
                        "invalid_manifest",
                        "Manifest entry is missing file_name or download_url",
                    ),
                    &mut first_error,
                );
                continue;
            }
            if entry_text(entry, "file_hash").is_empty() {
                self.host
                    .error(format!("Missing file_hash for manifest entry: {file_name}"));
                fail(
                    CoreError::new(
                        "invalid_manifest",
                        format!("Manifest entry is missing file_hash for {file_name}"),
                    ),
                    &mut first_error,
                );
                continue;
            }
            let Some(hash) = self.manifest_hash(entry, &request.session_key) else {
                self.host.error(format!("Checksum decryption failed for {file_name}"));
                fail(
                    CoreError::new("decrypt_fail", format!("Cannot decrypt file_hash for {file_name}")),
                    &mut first_error,
                );
                continue;
            };
            let target = match paths::resolve_manifest_target_path(&destination.to_string_lossy(), &file_name) {
                Ok(target) => PathBuf::from(target),
                Err(_) => {
                    self.host.error(format!("Invalid manifest file path: {file_name}"));
                    self.manifest_path_fail(&request.version, &file_name);
                    fail(
                        CoreError::new("invalid_manifest", format!("Invalid manifest file path: {file_name}")),
                        &mut first_error,
                    );
                    continue;
                }
            };
            if !seen.insert(target.clone()) {
                self.host.error(format!("Duplicate manifest target path: {file_name}"));
                self.manifest_path_fail(&request.version, &file_name);
                fail(
                    CoreError::new(
                        "invalid_manifest",
                        format!("Duplicate manifest target path for {file_name}"),
                    ),
                    &mut first_error,
                );
                continue;
            }
            let builtin_file = (!builtin.as_os_str().is_empty())
                .then(|| {
                    paths::resolve_manifest_target_path(&builtin.to_string_lossy(), &file_name)
                        .ok()
                        .map(PathBuf::from)
                })
                .flatten();
            let (cache, legacy_cache) = self.cache_paths(&hash, &file_name);
            tasks.push(Task {
                brotli: file_name.ends_with(".br"),
                asset: paths::builtin_asset_path(&file_name).ok(),
                file_name,
                download_url,
                hash,
                target,
                builtin: builtin_file,
                cache,
                legacy_cache,
            });
        }
        match first_error {
            Some(error) => Err(error),
            None => Ok(tasks),
        }
    }

    fn download_manifest_inner(
        &self,
        request: &DownloadRequest,
        manifest: &[Value],
        record: &BundleInfo,
        cancel: &Cancel,
    ) -> CoreResult<BundleInfo> {
        let id = record.id().to_string();
        self.check_disk_space(
            ((manifest.len() as u64) * PER_FILE_ESTIMATE).max(MIN_FREE_BYTES),
            &request.version,
        )?;
        let destination = self.bundle_directory(&id)?;
        fs::create_dir_all(&destination)
            .map_err(|error| CoreError::io("Failed to create destination directory", error))?;
        let cache = self.config().cache_dir.clone();
        if !cache.as_os_str().is_empty() {
            let _ = fs::create_dir_all(&cache);
        }
        self.send_stats("download_manifest_start", Some(&request.version), None, None);
        let tasks = self.plan_tasks(request, manifest, &destination)?;
        let session = LazySession {
            public_key: self.config().public_key.clone(),
            session_key: &request.session_key,
            cell: std::sync::OnceLock::new(),
        };
        let total = tasks.len();
        let workers = (crate::policy::manifest_max_concurrent_files(
            std::thread::available_parallelism()
                .map(|cores| cores.get() as i64)
                .unwrap_or(4),
        ) as usize)
            .min(total.max(1));
        let queue = Mutex::new(tasks.into_iter());
        let completed = AtomicUsize::new(0);
        let failed = AtomicBool::new(false);
        let first_error: Mutex<Option<CoreError>> = Mutex::new(None);
        let assets = self.apk_assets();
        // Connections open gradually: a burst of new connections to one host can stall
        // (dropped SYNs retry after 1 s). Each finished file admits one more worker.
        let admitted = Mutex::new(workers.min(INITIAL_MANIFEST_WORKERS));
        let admit = std::sync::Condvar::new();
        std::thread::scope(|scope| {
            for index in 0..workers {
                let (queue, completed, failed, first_error) = (&queue, &completed, &failed, &first_error);
                let (admitted, admit, session, assets, id) = (&admitted, &admit, &session, &assets, &id);
                scope.spawn(move || {
                    let mut open = admitted.lock().unwrap();
                    while index >= *open {
                        if failed.load(Ordering::SeqCst) || cancel.is_cancelled() {
                            return;
                        }
                        open = admit.wait_timeout(open, Duration::from_millis(100)).unwrap().0;
                    }
                    drop(open);
                    loop {
                        if failed.load(Ordering::SeqCst) || cancel.is_cancelled() {
                            return;
                        }
                        let Some(task) = queue.lock().unwrap().next() else {
                            return;
                        };
                        match self.process_manifest_file(&task, request, session, assets.as_ref(), cancel) {
                            Ok(()) => {
                                let done = completed.fetch_add(1, Ordering::SeqCst) + 1;
                                self.progress(id, 10 + (done * 60 / total.max(1)) as i64);
                                let mut open = admitted.lock().unwrap();
                                if *open < workers {
                                    *open += 1;
                                    admit.notify_all();
                                }
                            }
                            Err(error) => {
                                self.host.error(format!(
                                    "Manifest file download failed: {} ({})",
                                    task.file_name, error.message
                                ));
                                failed.store(true, Ordering::SeqCst);
                                first_error.lock().unwrap().get_or_insert(error);
                                return;
                            }
                        }
                    }
                });
            }
        });
        if cancel.is_cancelled() {
            return Err(CoreError::new("download_stopped", "Download cancelled"));
        }
        if let Some(error) = first_error.into_inner().unwrap() {
            return Err(error);
        }
        self.send_stats("download_manifest_complete", Some(&request.version), None, None);
        self.progress(&id, 71);
        self.progress(&id, 91);
        Ok(self.finish_install(record, "", request))
    }

    fn process_manifest_file(
        &self,
        task: &Task,
        request: &DownloadRequest,
        session: &LazySession<'_>,
        assets: Option<&ApkAssets>,
        cancel: &Cancel,
    ) -> CoreResult<()> {
        if let Some(parent) = task.target.parent() {
            fs::create_dir_all(parent).map_err(|error| CoreError::io("Failed to create parent directory", error))?;
        }
        // 1. Builtin bundle on disk.
        if let Some(builtin) = &task.builtin {
            if fsutil::file_matches_hash(builtin, &task.hash) && fsutil::copy_atomically(builtin, &task.target).is_ok()
            {
                return Ok(());
            }
        }
        // 2. Builtin APK assets (Android).
        if let (Some(assets), Some(asset)) = (assets, &task.asset) {
            if assets.copy_if_matches(asset, &task.hash, &task.target) {
                return Ok(());
            }
        }
        // 3. Delta cache (hash-named files were verified when written).
        for cached in [&task.cache, &task.legacy_cache].into_iter().flatten() {
            if Self::reusable(Some(cached), &task.hash) && fsutil::link_or_copy(cached, &task.target).is_ok() {
                return Ok(());
            }
        }
        // 4. Network.
        self.download_manifest_file(task, request, session, cancel)
    }

    fn download_manifest_file(
        &self,
        task: &Task,
        request: &DownloadRequest,
        session: &LazySession<'_>,
        cancel: &Cancel,
    ) -> CoreResult<()> {
        let cache = self.config().cache_dir.clone();
        let partial_dir = if cache.as_os_str().is_empty() {
            self.config().storage_root.clone()
        } else {
            cache.clone()
        };
        let _ = fs::create_dir_all(&partial_dir);
        let partial = partial_dir.join(paths::manifest_partial_name(Some(&task.hash), &task.file_name));
        // The partial is named by file and hash, so overlapping downloads that share a file
        // would append to, rename or delete each other's partial: one transfer at a time.
        let lock = partial_lock(&partial);
        let _owner = lock.lock().unwrap_or_else(|poison| poison.into_inner());
        // The transfer we waited for may have left the file in the delta cache.
        if let Some(cached) = &task.cache {
            if Self::reusable(Some(cached), &task.hash) && fsutil::link_or_copy(cached, &task.target).is_ok() {
                return Ok(());
            }
        }
        let stat_name = format!("{}:{}", request.version, task.file_name);
        let file_fail = |message: String| {
            self.send_stats("download_manifest_file_fail", Some(&stat_name), None, None);
            CoreError::new("download_manifest_file_fail", message)
        };
        let existing = fs::metadata(&partial).map(|metadata| metadata.len()).unwrap_or(0);
        let range = format!("bytes={existing}-");
        let headers: Vec<(&str, &str)> = if existing > 0 {
            vec![("Range", range.as_str())]
        } else {
            Vec::new()
        };
        let mut output: Option<io::BufWriter<File>> = None;
        // Hashed while downloading when the whole body comes in this response.
        let mut hasher: Option<ring::digest::Context> = None;
        let result = self
            .http
            .download(&task.download_url, &headers, &mut |event| match event {
                crate::net::Stream::Head(head) => {
                    if head.status == 416 && existing > 0 {
                        // The partial already holds the whole file.
                        return Ok(());
                    }
                    if head.status != 200 && head.status != 206 {
                        return Err(NetError {
                            kind: crate::net::NetErrorKind::Network,
                            message: format!("Unexpected response code: {}", head.status),
                        });
                    }
                    let append = crate::http::should_append_http_body(head.status as i64, existing as i64);
                    let file = OpenOptions::new()
                        .create(true)
                        .write(true)
                        .append(append)
                        .truncate(!append)
                        .open(&partial)
                        .map_err(|error| NetError {
                            kind: crate::net::NetErrorKind::Io,
                            message: error.to_string(),
                        })?;
                    // Network reads are small: batch them into large writes.
                    output = Some(io::BufWriter::with_capacity(256 * 1024, file));
                    hasher = (!append).then(|| ring::digest::Context::new(&ring::digest::SHA256));
                    Ok(())
                }
                crate::net::Stream::Chunk(chunk) => {
                    if cancel.is_cancelled() {
                        return Err(NetError {
                            kind: crate::net::NetErrorKind::Io,
                            message: "download_stopped".into(),
                        });
                    }
                    if let Some(hasher) = hasher.as_mut() {
                        hasher.update(chunk);
                    }
                    match output.as_mut() {
                        Some(file) => file.write_all(chunk).map_err(|error| NetError {
                            kind: crate::net::NetErrorKind::Io,
                            message: error.to_string(),
                        }),
                        None => Ok(()),
                    }
                }
            });
        let flushed = output.map_or(Ok(()), |mut output| output.flush());
        let result = result.and_then(|head| {
            flushed.map(|()| head).map_err(|error| NetError {
                kind: crate::net::NetErrorKind::Io,
                message: error.to_string(),
            })
        });
        let streamed_hash = hasher.map(|hasher| crate::text::hex_encode(hasher.finish().as_ref()));
        if let Err(error) = result {
            if error.message == "download_stopped" {
                return Err(CoreError::new("download_stopped", "Download cancelled"));
            }
            return Err(file_fail(format!("Failed to download {}: {error}", task.file_name)));
        }
        // The partial stays encrypted (resumable, reusable): decrypt while reading it.
        let decrypt_failed = |error: &dyn std::fmt::Display| {
            let _ = fs::remove_file(&partial);
            self.send_stats("decrypt_fail", Some(&request.version), None, None);
            CoreError::new("decrypt_fail", format!("Failed to decrypt {}: {error}", task.file_name))
        };
        let session = session.get().map_err(|message| decrypt_failed(&message))?;
        let mut work: Option<std::path::PathBuf> = None;
        let written = match session {
            // Brotli needs a seekable plaintext file: decrypt into a work file in one pass.
            Some(session) if task.brotli => {
                let path = partial_dir.join(format!(
                    "work_{}_{}",
                    super::store::random_id(),
                    basename(&task.file_name)
                ));
                if let Err(error) = crypto::aes_cbc::decrypt_file_to(&partial, &path, &session.key, &session.iv) {
                    let _ = fs::remove_file(&path);
                    return Err(decrypt_failed(&error.message));
                }
                work = Some(path.clone());
                decode_brotli(&path, &task.target, &task.hash)
            }
            Some(session) => {
                let input = File::open(&partial).map_err(|error| decrypt_failed(&error))?;
                let mut reader = crypto::aes_cbc::CbcDecryptReader::new(input, &session.key, &session.iv);
                match fsutil::write_verified(&mut reader, &task.target, Some(&task.hash)) {
                    Err(error) if error.kind() == io::ErrorKind::InvalidData => return Err(decrypt_failed(&error)),
                    other => other,
                }
            }
            None if task.brotli => decode_brotli(&partial, &task.target, &task.hash),
            // Plain file hashed while downloading: move it in place, no second pass.
            None => match &streamed_hash {
                Some(hash) if hash.eq_ignore_ascii_case(&task.hash) => {
                    fs::rename(&partial, &task.target).map(|()| Some(hash.clone()))
                }
                Some(_) => Ok(None),
                None => File::open(&partial)
                    .and_then(|mut file| fsutil::write_verified(&mut file, &task.target, Some(&task.hash))),
            },
        };
        if let Some(work) = &work {
            let _ = fs::remove_file(work);
        }
        let stat_target = format!("{}:{}", request.version, paths::manifest_target_name(&task.file_name));
        match written {
            Ok(Some(_)) => {}
            Ok(None) => {
                let _ = fs::remove_file(&partial);
                self.send_stats("download_manifest_checksum_fail", Some(&stat_target), None, None);
                return Err(CoreError::new(
                    "checksum_fail",
                    format!(
                        "Computed checksum is not equal to required checksum for file {} at url {}",
                        task.file_name, task.download_url
                    ),
                ));
            }
            Err(error) => {
                let _ = fs::remove_file(&partial);
                if task.brotli {
                    self.send_stats("download_manifest_brotli_fail", Some(&stat_target), None, None);
                    return Err(CoreError::new(
                        "brotli_fail",
                        format!("Brotli process failed for {}: {error}", task.file_name),
                    ));
                }
                return Err(file_fail(format!("Failed to write {}: {error}", task.file_name)));
            }
        }
        let _ = fs::remove_file(&partial);
        // Best effort: a full cache must not fail the update.
        if let Some(cache_file) = &task.cache {
            if !cache_file.exists() && fsutil::link_or_copy(&task.target, cache_file).is_err() {
                self.host
                    .debug(format!("Delta cache write failed: {}", cache_file.display()));
            }
        }
        Ok(())
    }

    pub(crate) fn register_download_token(&self, version: &str) -> Cancel {
        let token = Cancel::default();
        self.downloads
            .lock()
            .unwrap()
            .entry(version.to_string())
            .or_default()
            .push(token.clone());
        token
    }

    /// Removes this download's token only (another download of the version may still run).
    pub(crate) fn unregister_download_token(&self, version: &str, token: &Cancel) {
        let mut downloads = self.downloads.lock().unwrap();
        if let Some(tokens) = downloads.get_mut(version) {
            tokens.retain(|other| !std::sync::Arc::ptr_eq(&other.0, &token.0));
            if tokens.is_empty() {
                downloads.remove(version);
            }
        }
    }
}

#[allow(dead_code)]
const _UNUSED: Duration = Duration::from_secs(0);

#[cfg(test)]
mod token_tests {
    use crate::engine::Engine;
    use crate::host::MemoryHost;
    use serde_json::json;

    /// Two downloads of one version: finishing one keeps the other cancellable.
    #[test]
    fn overlapping_downloads_keep_their_own_tokens() {
        let dir = tempfile::tempdir().unwrap();
        let engine = Engine::new(
            std::sync::Arc::new(MemoryHost::default()),
            &json!({ "bundleRoot": dir.path().join("versions").to_string_lossy() }),
        )
        .unwrap();
        let first = engine.register_download_token("2.0.0");
        let second = engine.register_download_token("2.0.0");
        engine.unregister_download_token("2.0.0", &first);
        assert!(engine.is_downloading("2.0.0"));
        assert!(engine.cancel_download("2.0.0"));
        assert!(second.is_cancelled());
        assert!(!first.is_cancelled());
        engine.unregister_download_token("2.0.0", &second);
        assert!(!engine.is_downloading("2.0.0"));
    }
}
