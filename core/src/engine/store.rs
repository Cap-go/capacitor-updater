//! Bundle store: the registry of downloaded bundles (`<id>_info` records),
//! the current / next / fallback pointers, and the bundle directories.
//!
//! Keys, value formats and directory layout match every previous plugin
//! version so existing installs keep working after upgrade (and downgrade).

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::json;

use super::Engine;
use crate::bundle::{iso8601_now, BundleInfo, BundleStatus, ID_BUILTIN, VERSION_UNKNOWN};
use crate::error::{CoreError, CoreResult};
use crate::host::HostLog;

pub const TEMP_UNZIP_PREFIX: &str = "capgo_unzip_";
const DELETE_PACE: Duration = Duration::from_millis(75);
const ID_ALPHABET: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// Snapshot of the pointers a reset rewrites, restorable if the reload fails.
#[derive(Debug, Clone)]
pub struct ResetState {
    pub current_bundle_path: String,
    pub fallback_bundle_id: String,
    pub next_bundle_id: Option<String>,
}

/// 10 random `[0-9A-Za-z]` characters (bundle ids, temp folder names).
pub fn random_id() -> String {
    use ring::rand::SecureRandom;
    let rng = ring::rand::SystemRandom::new();
    let mut bytes = [0u8; 10];
    rng.fill(&mut bytes).expect("system RNG available");
    bytes
        .iter()
        .map(|byte| ID_ALPHABET[(*byte as usize) % ID_ALPHABET.len()] as char)
        .collect()
}

fn is_stored_bundle_id(key: &str, suffix: &str) -> Option<String> {
    let id = key.strip_suffix(suffix)?;
    (id.len() == 10 && id.bytes().all(|c| c.is_ascii_alphanumeric())).then(|| id.to_string())
}

/// Resolves `id` inside `root`, rejecting traversal, and (when it exists)
/// symlinks that point outside `root`.
pub fn resolve_inside(root: &Path, relative: &str) -> CoreResult<PathBuf> {
    let resolved = PathBuf::from(crate::paths::resolve_path_inside(&root.to_string_lossy(), relative)?);
    if let (Ok(canonical_root), Ok(canonical_target)) = (fs::canonicalize(root), fs::canonicalize(&resolved)) {
        if canonical_target == canonical_root || !canonical_target.starts_with(&canonical_root) {
            return Err(CoreError::new(
                "escapes_base",
                format!("Path escapes base directory: {relative}"),
            ));
        }
    }
    Ok(resolved)
}

pub(crate) fn remove_path(path: &Path) -> std::io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

impl Engine {
    fn kv(&self, key: &str) -> Option<String> {
        self.host.kv_get(key, None)
    }

    fn kv_or(&self, key: &str, default: &str) -> String {
        self.host
            .kv_get(key, Some(default))
            .unwrap_or_else(|| default.to_string())
    }

    fn kv_put(&self, key: &str, value: Option<&str>) {
        self.host.kv_set(key, value);
    }

    fn info_key(&self, id: &str) -> String {
        format!("{id}{}", self.config().keys.info_suffix)
    }

    pub fn has_stored_bundle_info(&self, id: &str) -> bool {
        !id.is_empty() && id != ID_BUILTIN && id != VERSION_UNKNOWN && self.host.kv_contains(&self.info_key(id))
    }

    pub fn get_bundle_info(&self, id: Option<&str>) -> BundleInfo {
        let id = id.unwrap_or(VERSION_UNKNOWN);
        if id == ID_BUILTIN {
            let version_build = self.config().version_build.clone();
            return BundleInfo::new(
                ID_BUILTIN,
                (!version_build.is_empty()).then_some(version_build),
                BundleStatus::Success,
                "",
                "",
            );
        }
        if id == VERSION_UNKNOWN {
            return BundleInfo::new(VERSION_UNKNOWN, None, BundleStatus::Error, "", "");
        }
        match Some(self.kv_or(&self.info_key(id), "")) {
            None => BundleInfo::new(id, None, BundleStatus::Pending, "", ""),
            Some(stored) if stored.is_empty() => BundleInfo::new(id, None, BundleStatus::Pending, "", ""),
            Some(stored) => match BundleInfo::from_stored_json(&stored) {
                Some(bundle) => bundle,
                None => {
                    self.host.error("Failed to parse bundle info");
                    self.host.debug(format!("Bundle ID: {id}"));
                    self.kv_put(&self.info_key(id), None);
                    BundleInfo::new(id, None, BundleStatus::Error, "", "")
                }
            },
        }
    }

    pub fn save_bundle_info(&self, id: &str, info: Option<&BundleInfo>) -> bool {
        if let Some(info) = info {
            if info.is_builtin() || info.is_unknown() {
                self.host.debug(format!("Not saving info for bundle: [{id}]"));
                return false;
            }
        }
        let key = self.info_key(id);
        match info {
            None => {
                self.host.debug(format!("Removing info for bundle [{id}]"));
                self.kv_put(&key, None);
            }
            Some(info) => {
                let stored = info.with_id(id).to_stored_json();
                self.host.debug(format!("Storing info for bundle [{id}] {stored}"));
                self.kv_put(&key, Some(&stored));
            }
        }
        true
    }

    pub fn set_bundle_status(&self, id: &str, status: BundleStatus) {
        let info = self.get_bundle_info(Some(id));
        self.host
            .debug(format!("Setting status for bundle [{id}] to {}", status.as_str()));
        self.save_bundle_info(id, Some(&info.with_status(status)));
    }

    /// Bundles on disk (`raw == false`) or every stored record (`raw == true`).
    pub fn list(&self, raw: bool) -> Vec<BundleInfo> {
        if raw {
            let suffix = self.config().keys.info_suffix.clone();
            let mut ids: Vec<String> = self
                .host
                .kv_keys()
                .iter()
                .filter_map(|key| is_stored_bundle_id(key, &suffix))
                .collect();
            ids.sort();
            ids.dedup();
            return ids.iter().map(|id| self.get_bundle_info(Some(id))).collect();
        }
        let root = self.config().bundle_root.clone();
        let Ok(entries) = fs::read_dir(&root) else {
            self.host
                .info(format!("No versions available to list {}", root.display()));
            return Vec::new();
        };
        let mut ids: Vec<String> = entries
            .filter_map(Result::ok)
            .filter_map(|entry| entry.file_name().to_str().map(str::to_string))
            .filter(|name| !name.starts_with('.'))
            .collect();
        ids.sort();
        ids.iter().map(|id| self.get_bundle_info(Some(id))).collect()
    }

    pub fn get_bundle_info_by_name(&self, version: &str) -> Option<BundleInfo> {
        self.list(false)
            .into_iter()
            .find(|bundle| bundle.version_name() == version)
    }

    pub fn bundle_directory(&self, id: &str) -> CoreResult<PathBuf> {
        resolve_inside(&self.config().bundle_root, id)
    }

    pub fn bundle_exists(&self, id: &str) -> bool {
        let Ok(dir) = self.bundle_directory(id) else {
            return false;
        };
        let info = self.get_bundle_info(Some(id));
        dir.is_dir() && dir.join("index.html").exists() && !info.is_deleted() && !info.is_deleting()
    }

    // ---- current / fallback / next -------------------------------------------------

    pub fn current_bundle_path(&self) -> String {
        let builtin = self.config().builtin_server_path.clone();
        let key = self.config().keys.server_path.clone();
        let path = if builtin.is_empty() {
            self.kv(&key).unwrap_or_default()
        } else {
            self.kv_or(&key, &builtin)
        };
        if path.trim().is_empty() {
            builtin
        } else {
            path
        }
    }

    pub fn is_using_builtin(&self) -> bool {
        let path = self.current_bundle_path();
        path.trim().is_empty() || path == self.config().builtin_server_path || path == "public"
    }

    pub fn current_bundle_id(&self) -> String {
        if self.is_using_builtin() {
            return ID_BUILTIN.to_string();
        }
        let path = self.current_bundle_path();
        path.rsplit('/').next().unwrap_or(&path).to_string()
    }

    pub fn current_bundle(&self) -> BundleInfo {
        self.get_bundle_info(Some(&self.current_bundle_id()))
    }

    fn set_current_bundle_path(&self, path: &str) {
        self.host.will_switch_bundle(path);
        self.kv_put(&self.config().keys.server_path, Some(path));
        self.host.info(format!(
            "Current bundle set to: {}",
            if path.is_empty() { ID_BUILTIN } else { path }
        ));
    }

    fn builtin_path(&self) -> String {
        self.config().builtin_server_path.clone()
    }

    pub fn fallback_bundle(&self) -> BundleInfo {
        let id = self.kv_or(&self.config().keys.fallback, ID_BUILTIN);
        self.get_bundle_info(Some(&id))
    }

    fn set_fallback_bundle(&self, fallback: Option<&BundleInfo>) {
        let id = fallback.map_or(ID_BUILTIN.to_string(), |bundle| bundle.id().to_string());
        self.kv_put(&self.config().keys.fallback, Some(&id));
    }

    pub fn next_bundle(&self) -> Option<BundleInfo> {
        let id = self.kv(&self.config().keys.next)?;
        Some(self.get_bundle_info(Some(&id)))
    }

    pub fn preview_fallback_bundle(&self) -> Option<BundleInfo> {
        let id = self.kv(&self.config().keys.preview_fallback)?;
        let bundle = self.get_bundle_info(Some(&id));
        if bundle.is_error() || (!bundle.is_builtin() && !self.bundle_exists(&id)) {
            self.set_preview_fallback_bundle(None);
            return None;
        }
        Some(bundle)
    }

    pub fn set_preview_fallback_bundle(&self, fallback: Option<&str>) -> bool {
        let key = self.config().keys.preview_fallback.clone();
        match fallback {
            None => self.kv_put(&key, None),
            Some(id) => {
                let bundle = self.get_bundle_info(Some(id));
                if bundle.is_error() || (!bundle.is_builtin() && !self.bundle_exists(id)) {
                    return false;
                }
                self.kv_put(&key, Some(id));
            }
        }
        true
    }

    pub fn set_next_bundle(&self, next: Option<&str>) -> bool {
        let key = self.config().keys.next.clone();
        let Some(next) = next else {
            self.kv_put(&key, None);
            return true;
        };
        let bundle = self.get_bundle_info(Some(next));
        if !bundle.is_builtin() && !self.bundle_exists(next) {
            return false;
        }
        if next == self.current_bundle_id() && bundle.status() == BundleStatus::Success {
            self.host.info(format!(
                "Bundle {next} is already the current successful bundle. Skip next()."
            ));
            return true;
        }
        self.kv_put(&key, Some(next));
        self.set_bundle_status(next, BundleStatus::Pending);
        let current = self.current_bundle().version_name().to_string();
        self.send_stats("set_next", Some(bundle.version_name()), Some(&current), None);
        self.host.emit("setNext", &json!({ "bundle": bundle.to_js() }));
        true
    }

    // ---- delete ------------------------------------------------------------------------

    fn pending_delete_ids(&self) -> Vec<String> {
        self.kv_or(&self.config().keys.pending_deletes, "")
            .split(',')
            .filter(|part| !part.is_empty())
            .map(str::to_string)
            .fold(Vec::new(), |mut ids, id| {
                if !ids.contains(&id) {
                    ids.push(id);
                }
                ids
            })
    }

    fn write_pending_delete_ids(&self, ids: &[String]) {
        let key = self.config().keys.pending_deletes.clone();
        if ids.is_empty() {
            self.kv_put(&key, None);
        } else {
            self.kv_put(&key, Some(&ids.join(",")));
        }
    }

    pub(crate) fn enqueue_pending_delete(&self, id: &str) {
        let mut ids = self.pending_delete_ids();
        if id.is_empty() || ids.iter().any(|existing| existing == id) {
            return;
        }
        ids.push(id.to_string());
        self.write_pending_delete_ids(&ids);
    }

    fn dequeue_pending_delete(&self, id: &str) {
        let mut ids = self.pending_delete_ids();
        let before = ids.len();
        ids.retain(|existing| existing != id);
        if ids.len() != before {
            self.write_pending_delete_ids(&ids);
        }
    }

    /// Deletes a bundle folder. Marks the record DELETING first so a kill mid-delete
    /// resumes on next launch; only drops the record once the folder is gone.
    pub fn delete_bundle(&self, id: &str, remove_info: bool, cancel_active_download: bool) -> bool {
        let _guard = self.delete_lock.lock().unwrap_or_else(|poison| poison.into_inner());
        let dir = match self.bundle_directory(id) {
            Ok(dir) => dir,
            Err(error) => {
                self.host.error("Cannot delete bundle with invalid id");
                self.host.debug(format!("Bundle ID: {id}, Error: {}", error.message));
                return false;
            }
        };
        let deleted = self.get_bundle_info(Some(id));
        if deleted.is_builtin() || self.current_bundle_id() == id {
            self.host.error("Cannot delete current or builtin bundle");
            self.host.debug(format!("Bundle ID: {id}"));
            return false;
        }
        let protected = |bundle: Option<BundleInfo>| {
            bundle.is_some_and(|bundle| {
                !bundle.is_deleted() && !bundle.is_error() && !bundle.is_deleting() && bundle.id() == id
            })
        };
        if protected(self.preview_fallback_bundle()) {
            self.host.error("Cannot delete the preview fallback bundle");
            self.host.debug(format!("Bundle ID: {id}"));
            return false;
        }
        if protected(self.next_bundle()) {
            self.host.error("Cannot delete the next bundle");
            self.host.debug(format!("Bundle ID: {id}"));
            return false;
        }
        if !self.has_stored_bundle_info(id) && !dir.exists() {
            self.host.error("Cannot delete unknown bundle");
            self.host.debug(format!("Bundle ID: {id}"));
            return false;
        }
        if !deleted.is_deleting() && !self.save_bundle_info(id, Some(&deleted.with_status(BundleStatus::Deleting))) {
            self.host
                .error("Failed to persist DELETING marker, aborting disk delete");
            return false;
        }
        if cancel_active_download && !self.cancel_version_download(deleted.version_name()) {
            self.host.error("Failed to cancel active download before delete");
            return false;
        }
        if dir.exists() {
            if let Err(error) = remove_path(&dir) {
                self.host.error("Failed to delete bundle folder, will retry later");
                self.host.debug(format!("Bundle ID: {id}, Error: {error}"));
                return false;
            }
        }
        if dir.exists() {
            self.host
                .error("Bundle folder still present after delete, will retry later");
            return false;
        }
        let finalized = if remove_info {
            self.save_bundle_info(id, None)
        } else {
            self.save_bundle_info(id, Some(&deleted.with_status(BundleStatus::Deleted)))
        };
        if !finalized {
            self.host
                .error("Failed to finalize delete registry update, will retry later");
            return false;
        }
        self.send_stats("delete", Some(deleted.version_name()), None, None);
        self.dequeue_pending_delete(id);
        self.host.info("Bundle deleted and confirmed gone");
        self.host.debug(format!("Bundle ID: {id}"));
        true
    }

    /// Resumes deletes interrupted by a kill, one by one.
    pub fn drain_pending_deletes(&self) {
        let mut ids: Vec<String> = self
            .list(true)
            .into_iter()
            .filter(|info| info.is_deleting() && !info.id().is_empty())
            .map(|info| info.id().to_string())
            .collect();
        for id in self.pending_delete_ids() {
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
        for id in ids {
            self.host.info(format!("Resuming pending delete for bundle: {id}"));
            if self.delete_bundle(&id, true, true) {
                self.dequeue_pending_delete(&id);
            }
            std::thread::sleep(DELETE_PACE);
        }
    }

    // ---- set / reset -------------------------------------------------------------------

    pub fn set_bundle(&self, id: &str) -> bool {
        let bundle = self.get_bundle_info(Some(id));
        if bundle.is_builtin() {
            self.reset(false);
            return true;
        }
        let dir = match self.bundle_directory(id) {
            Ok(dir) => dir,
            Err(error) => {
                self.host.error("Invalid bundle id");
                self.host.debug(format!("Bundle ID: {id}, Error: {}", error.message));
                self.set_bundle_status(id, BundleStatus::Error);
                self.send_stats("set_fail", Some(bundle.version_name()), None, None);
                return false;
            }
        };
        self.host.info(format!("Setting next active bundle: {id}"));
        if self.bundle_exists(id) {
            let previous = self.current_bundle().version_name().to_string();
            self.set_current_bundle_path(&dir.to_string_lossy());
            self.set_bundle_status(id, BundleStatus::Pending);
            self.send_stats("set", Some(bundle.version_name()), Some(&previous), None);
            return true;
        }
        self.set_bundle_status(id, BundleStatus::Error);
        self.send_stats("set_fail", Some(bundle.version_name()), None, None);
        false
    }

    pub fn can_set(&self, bundle: &BundleInfo) -> bool {
        bundle.is_builtin() || self.bundle_exists(bundle.id())
    }

    pub fn stage_pending_reload(&self, bundle: &BundleInfo) -> bool {
        if bundle.is_builtin() || !self.bundle_exists(bundle.id()) {
            return false;
        }
        match self.bundle_directory(bundle.id()) {
            Ok(dir) => {
                self.set_current_bundle_path(&dir.to_string_lossy());
                true
            }
            Err(_) => false,
        }
    }

    pub fn stage_preview_fallback_reload(&self, bundle: &BundleInfo) -> bool {
        if bundle.is_error() {
            return false;
        }
        if bundle.is_builtin() {
            self.set_current_bundle_path(&self.builtin_path());
            return true;
        }
        self.stage_pending_reload(bundle)
    }

    pub fn finalize_pending_reload(&self, bundle: &BundleInfo, previous_bundle_name: &str) {
        if !bundle.is_builtin() {
            self.send_stats("set", Some(bundle.version_name()), Some(previous_bundle_name), None);
        }
    }

    pub fn capture_reset_state(&self) -> ResetState {
        ResetState {
            current_bundle_path: self.current_bundle_path(),
            fallback_bundle_id: self.kv_or(&self.config().keys.fallback, ID_BUILTIN),
            next_bundle_id: self.kv(&self.config().keys.next),
        }
    }

    pub fn restore_reset_state(&self, state: &ResetState) {
        let path = if state.current_bundle_path.trim().is_empty() {
            self.builtin_path()
        } else {
            state.current_bundle_path.clone()
        };
        self.kv_put(&self.config().keys.server_path, Some(&path));
        let fallback = if state.fallback_bundle_id.is_empty() {
            ID_BUILTIN
        } else {
            &state.fallback_bundle_id
        };
        self.kv_put(&self.config().keys.fallback, Some(fallback));
        match state.next_bundle_id.as_deref().filter(|next| !next.is_empty()) {
            Some(next) => self.kv_put(&self.config().keys.next, Some(next)),
            None => self.kv_put(&self.config().keys.next, None),
        }
    }

    pub fn prepare_reset_state_for_transition(&self) {
        self.set_current_bundle_path(&self.builtin_path());
        self.set_fallback_bundle(None);
        self.kv_put(&self.config().keys.next, None);
    }

    pub fn finalize_reset_transition(&self, previous_bundle_name: &str, internal: bool) {
        self.host.cancel_all_downloads();
        self.cancel_scheduled_downloads(None);
        if !internal {
            let current = self.current_bundle().version_name().to_string();
            self.send_stats("reset", Some(&current), Some(previous_bundle_name), None);
        }
    }

    pub fn reset(&self, internal: bool) {
        self.host.debug(format!("reset: {internal}"));
        let previous = self.current_bundle().version_name().to_string();
        self.prepare_reset_state_for_transition();
        self.finalize_reset_transition(&previous, internal);
    }

    fn stored_native_build_version(&self) -> String {
        let keys = self.config().keys.clone();
        let current = self.kv_or(&keys.native_build_version, "");
        if current.is_empty() {
            self.kv_or(&keys.legacy_native_build_version, "")
        } else {
            current
        }
    }

    /// Resets to builtin when the current bundle is gone, foreign, or the native app changed.
    pub fn auto_reset(&self, current_native_build_version: &str, reset_when_native_version_changed: bool) {
        let current = self.current_bundle();
        if !current.is_builtin() && !self.bundle_exists(current.id()) {
            self.host
                .info("Folder at bundle path does not exist. Triggering reset.");
            self.reset(false);
            return;
        }
        let bundle_path = self.kv(&self.config().keys.server_path);
        let has_info = self.has_stored_bundle_info(current.id());
        let builtin_path = self.builtin_path();
        let foreign_path = bundle_path
            .as_deref()
            .filter(|path| *path != builtin_path && *path != "public");
        if crate::policy::should_reset_for_foreign_bundle(foreign_path, current.is_builtin(), has_info) {
            self.host
                .info("Current bundle id is not one of the bundle ids stored by this plugin. Triggering reset.");
            self.reset(false);
            return;
        }
        let previous = self.stored_native_build_version();
        if reset_when_native_version_changed
            && !previous.is_empty()
            && !current_native_build_version.is_empty()
            && previous != current_native_build_version
        {
            self.host.info(format!(
                "Stored native build version {previous} does not match current native build version {current_native_build_version}. Triggering reset."
            ));
            self.reset(false);
        }
    }

    /// Marks `id` successful and makes it the fallback; optionally deletes the previous fallback.
    pub fn set_success(self: &std::sync::Arc<Self>, id: &str, auto_delete_previous: bool) {
        self.set_bundle_status(id, BundleStatus::Success);
        let fallback = self.fallback_bundle();
        let preview_fallback = self.preview_fallback_bundle();
        let fallback_is_preview = preview_fallback
            .as_ref()
            .is_some_and(|preview| preview.id() == fallback.id());
        let bundle = self.get_bundle_info(Some(id));
        self.host
            .info(format!("Version successfully loaded: {}", bundle.version_name()));
        let previous_id = fallback.id().to_string();
        let previous_version = fallback.version_name().to_string();
        let previous_is_next = self.next_bundle().is_some_and(|next| {
            next.id() == previous_id && !next.is_deleted() && !next.is_error() && !next.is_deleting()
        });
        let delete_previous = auto_delete_previous
            && !fallback.is_builtin()
            && previous_id != id
            && !fallback_is_preview
            && !previous_is_next;
        if delete_previous && !self.save_bundle_info(&previous_id, Some(&fallback.with_status(BundleStatus::Deleting)))
        {
            self.host
                .error("Failed to persist DELETING for previous bundle; queueing durable retry");
            self.enqueue_pending_delete(&previous_id);
        }
        self.set_fallback_bundle(Some(&bundle));
        if delete_previous {
            let engine = self.clone();
            self.spawn("delete", move || {
                if !engine.cancel_version_download(&previous_version) {
                    engine
                        .host
                        .error("Failed to cancel previous version download before delete");
                    return;
                }
                if engine.delete_bundle(&previous_id, true, false) {
                    engine.host.info(format!("Deleted previous bundle: {previous_version}"));
                } else {
                    engine
                        .host
                        .debug(format!("Previous bundle delete incomplete, will retry: {previous_id}"));
                }
            });
        }
    }

    pub fn set_error(&self, id: &str) {
        self.set_bundle_status(id, BundleStatus::Error);
    }

    // ---- cleanup -----------------------------------------------------------------------

    pub fn allowed_bundle_ids_for_cleanup(&self) -> BTreeSet<String> {
        let mut allowed: BTreeSet<String> = self
            .list(true)
            .into_iter()
            // DELETED tombstones must not protect leftover folders; DELETING stays
            // protected so drain_pending_deletes owns the removal.
            .filter(|info| !info.id().is_empty() && !info.is_deleted())
            .map(|info| info.id().to_string())
            .collect();
        allowed.insert(self.current_bundle_id());
        let fallback = self.fallback_bundle();
        if !fallback.is_deleting() {
            allowed.insert(fallback.id().to_string());
        }
        for bundle in [self.next_bundle(), self.preview_fallback_bundle()]
            .into_iter()
            .flatten()
        {
            if !bundle.is_deleting() {
                allowed.insert(bundle.id().to_string());
            }
        }
        allowed
    }

    /// Deletes bundle folders that no record protects.
    pub fn cleanup_download_directories(&self, allowed: &BTreeSet<String>, cancelled: &dyn Fn() -> bool) {
        let root = self.config().bundle_root.clone();
        let Ok(entries) = fs::read_dir(&root) else {
            return;
        };
        for entry in entries.filter_map(Result::ok) {
            if cancelled() {
                self.host.warn("cleanupDownloadDirectories was cancelled");
                return;
            }
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let id = entry.file_name().to_string_lossy().into_owned();
            if allowed.contains(&id) {
                continue;
            }
            match remove_path(&path) {
                Ok(()) if !path.exists() => {
                    self.save_bundle_info(&id, None);
                    self.host.info("Deleted orphan bundle directory");
                    self.host.debug(format!("Bundle ID: {id}"));
                }
                Ok(()) => self.host.error("Orphan bundle directory still present after delete"),
                Err(error) => {
                    self.host.error("Failed to delete orphan bundle directory");
                    self.host.debug(format!("Bundle ID: {id}, Error: {error}"));
                }
            }
        }
    }

    /// Deletes leftover `capgo_unzip_*` folders from interrupted installs.
    pub fn cleanup_orphaned_temp_folders(&self, cancelled: &dyn Fn() -> bool) {
        let root = self.config().storage_root.clone();
        let Ok(entries) = fs::read_dir(&root) else {
            return;
        };
        for entry in entries.filter_map(Result::ok) {
            if cancelled() {
                self.host.warn("cleanupOrphanedTempFolders was cancelled");
                return;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            if !entry.path().is_dir() || !name.starts_with(TEMP_UNZIP_PREFIX) {
                continue;
            }
            if super::scheduled::running_jobs() > 0 {
                // A scheduled download of this process may be extracting into it.
                self.host
                    .info("Scheduled download running, orphaned temp folders are swept next launch");
                return;
            }
            match remove_path(&entry.path()) {
                Ok(()) => self.host.info("Deleted orphaned temp unzip folder"),
                Err(error) => {
                    self.host.error("Failed to delete orphaned temp folder");
                    self.host.debug(format!("Folder: {name}, Error: {error}"));
                }
            }
        }
    }

    pub fn cleanup_delta_cache(&self) {
        let cache = self.config().cache_dir.clone();
        if cache.as_os_str().is_empty() || !cache.exists() {
            return;
        }
        match remove_path(&cache) {
            Ok(()) => self.host.info("Cleaned up delta cache folder"),
            Err(error) => {
                self.host.error("Failed to cleanup delta cache");
                self.host.debug(format!("Error: {error}"));
            }
        }
    }

    pub fn new_download_record(&self, version: &str) -> BundleInfo {
        let id = random_id();
        let info = BundleInfo::new(
            id.clone(),
            Some(version.to_string()),
            BundleStatus::Downloading,
            iso8601_now(),
            "",
        );
        self.save_bundle_info(&id, Some(&info));
        info
    }
}
