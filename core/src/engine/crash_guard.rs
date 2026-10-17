//! Crash-loop breaker. The steps that can take the process down with them (a bundle download
//! with its verification, decryption and extraction; applying a new bundle) leave a marker in
//! the key-value storage while they run ([`keys::CRASH_GUARD`], one record per version). A
//! marker of another process still there at the next plugin load means that process died in
//! the step. Two such deaths in a row for the same version mark it failed: its bundle record
//! becomes ERROR, the app stays on (or goes back to) the bundle it ran before, the update cycle
//! skips the version until the server offers another one, and a `download_fail` / `set_fail`
//! statistic reports it.
//!
//! A death is counted when the platform reports a crash for that process (Android
//! `previousExits`: crash, native crash, ANR), or, without a report, when the step ran in the
//! foreground: the OS stops background apps at will, and a user closing the app sends it to the
//! background first.

use std::sync::{Mutex, OnceLock};

use serde_json::{json, Map, Value};

use super::plugin::keys;
use super::Engine;
use crate::bundle::{BundleInfo, BundleStatus, ID_BUILTIN};
use crate::host::HostLog;
use crate::sync::LockRecover;

pub(crate) const STEP_DOWNLOAD: &str = "download";
pub(crate) const STEP_SET: &str = "set";
/// Deaths in a row that mark a version failed.
const DEATHS_TO_FAIL: u64 = 2;
/// Android `ApplicationExitInfo` reasons that are crashes: CRASH, CRASH_NATIVE, ANR.
const CRASH_EXIT_REASONS: [i64; 3] = [4, 5, 6];

/// Serializes the read-modify-write of the records (every engine of the process shares the
/// storage). A leaf: only key-value calls run under it.
static LOCK: Mutex<()> = Mutex::new(());

/// Identifies this process in the records (a pid can be reused by the next process).
fn process_token() -> &'static str {
    static TOKEN: OnceLock<String> = OnceLock::new();
    TOKEN.get_or_init(super::store::random_id)
}

/// One version's record.
#[derive(Debug, Clone, Default, PartialEq)]
struct StepRecord {
    /// Last step started: `download` or `set`.
    step: String,
    /// Bundle id of that step (empty when unknown).
    id: String,
    /// Deaths in a row counted so far.
    attempts: u64,
    /// Steps of this version running in `process`.
    active: u64,
    process: String,
    pid: u64,
    /// The app was in the background (or the plugin not loaded) while the step ran.
    background: bool,
    /// Skipped by the update cycle until the server offers another version.
    failed: bool,
}

impl StepRecord {
    fn from_json(value: &Value) -> Self {
        let text = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
        let number = |key: &str| value.get(key).and_then(Value::as_u64).unwrap_or(0);
        let flag = |key: &str| value.get(key).and_then(Value::as_bool).unwrap_or(false);
        Self {
            step: text("step"),
            id: text("id"),
            attempts: number("attempts"),
            active: number("active"),
            process: text("process"),
            pid: number("pid"),
            background: flag("background"),
            failed: flag("failed"),
        }
    }

    fn to_json(&self) -> Value {
        json!({
            "step": self.step,
            "id": self.id,
            "attempts": self.attempts,
            "active": self.active,
            "process": self.process,
            "pid": self.pid,
            "background": self.background,
            "failed": self.failed,
        })
    }

    /// A step of this process is running.
    fn running_here(&self) -> bool {
        self.active > 0 && self.process == process_token()
    }
}

type Records = Vec<(String, StepRecord)>;

/// The version a step on `bundle` is recorded under (its id when it has no version).
pub(crate) fn step_version(bundle: &BundleInfo) -> &str {
    match bundle.version.as_deref() {
        Some(version) if !version.is_empty() => version,
        _ => bundle.id(),
    }
}

/// Ends the step when dropped (also when a panic unwinds through it).
pub(crate) struct NativeStep<'a> {
    engine: &'a Engine,
    version: String,
}

impl Drop for NativeStep<'_> {
    fn drop(&mut self) {
        self.engine.end_native_step(&self.version);
    }
}

impl Engine {
    fn load_native_steps(&self) -> Records {
        let stored = self.host.kv_get(keys::CRASH_GUARD, None).unwrap_or_default();
        let Ok(Value::Object(map)) = serde_json::from_str::<Value>(&stored) else {
            return Vec::new();
        };
        map.iter()
            .filter(|(_, value)| value.is_object())
            .map(|(version, value)| (version.clone(), StepRecord::from_json(value)))
            .collect()
    }

    fn save_native_steps(&self, records: &Records) {
        if records.is_empty() {
            self.host.kv_set(keys::CRASH_GUARD, None);
            return;
        }
        let map: Map<String, Value> = records
            .iter()
            .map(|(version, record)| (version.clone(), record.to_json()))
            .collect();
        self.host
            .kv_set(keys::CRASH_GUARD, Some(&Value::Object(map).to_string()));
    }

    /// The app is in the background, or no plugin runs in this process (a download job).
    fn native_step_in_background(&self) -> bool {
        let state = self.plugin_state();
        !state.loaded || state.in_background
    }

    /// Records that `step` starts for `version` (bundle `id`) until the returned guard drops.
    pub(crate) fn begin_native_step(&self, step: &str, version: &str, id: &str) -> NativeStep<'_> {
        let background = self.native_step_in_background();
        if !version.is_empty() {
            let _lock = LOCK.lock_or_recover();
            let mut records = self.load_native_steps();
            let index = match records.iter().position(|(name, _)| name == version) {
                Some(index) => index,
                None => {
                    records.push((version.to_string(), StepRecord::default()));
                    records.len() - 1
                }
            };
            let record = &mut records[index].1;
            // A record left by another process is replaced (its death is counted at plugin load).
            if !record.running_here() {
                record.active = 0;
                record.process = process_token().to_string();
            }
            record.active += 1;
            record.step = step.to_string();
            if !id.is_empty() {
                record.id = id.to_string();
            }
            record.pid = u64::from(std::process::id());
            record.background = background;
            self.save_native_steps(&records);
        }
        NativeStep {
            engine: self,
            version: version.to_string(),
        }
    }

    /// The step ended (success or handled error): the record goes away with the last running
    /// step, so deaths only count in a row. A failed version keeps its record.
    fn end_native_step(&self, version: &str) {
        if version.is_empty() {
            return;
        }
        let _lock = LOCK.lock_or_recover();
        let mut records = self.load_native_steps();
        let Some(index) = records.iter().position(|(name, _)| name == version) else {
            return;
        };
        let record = &mut records[index].1;
        if !record.running_here() {
            return;
        }
        record.active -= 1;
        if record.active == 0 {
            if record.failed {
                record.process.clear();
                record.pid = 0;
                record.background = false;
            } else {
                records.remove(index);
            }
        }
        self.save_native_steps(&records);
    }

    /// The app moved to the background or the foreground while steps of this process run.
    pub(crate) fn mark_native_steps_background(&self, background: bool) {
        let _lock = LOCK.lock_or_recover();
        let mut records = self.load_native_steps();
        let mut changed = false;
        for (_, record) in records.iter_mut() {
            if record.running_here() && record.background != background {
                record.background = background;
                changed = true;
            }
        }
        if changed {
            self.save_native_steps(&records);
        }
    }

    /// Plugin load: counts the deaths of the steps earlier processes left running, and marks a
    /// version failed at the second death in a row. `exits` are the platform's reports of the
    /// previous process exits (Android, newest first), `None` without them.
    pub(crate) fn account_native_deaths(&self, exits: Option<&[Value]>) {
        let mut failed = Vec::new();
        let mut logs = Vec::new();
        {
            let _lock = LOCK.lock_or_recover();
            let mut records = self.load_native_steps();
            let mut changed = false;
            for (version, record) in records.iter_mut() {
                if record.active == 0 || record.process == process_token() {
                    continue;
                }
                let reported = exits.and_then(|exits| {
                    exits
                        .iter()
                        .find(|exit| exit.get("pid").and_then(Value::as_u64) == Some(record.pid))
                        .map(|exit| exit.get("reason").and_then(Value::as_i64).unwrap_or(0))
                });
                let crashed = match reported {
                    Some(reason) => CRASH_EXIT_REASONS.contains(&reason),
                    None => !record.background,
                };
                record.active = 0;
                record.process.clear();
                record.pid = 0;
                record.background = false;
                changed = true;
                if !crashed {
                    logs.push((
                        false,
                        format!(
                            "The previous process ended during the {} step of {version}, not as a crash: not counted",
                            record.step
                        ),
                    ));
                    continue;
                }
                record.attempts += 1;
                logs.push((
                    true,
                    format!(
                        "The previous process died during the {} step of {version} ({} in a row)",
                        record.step, record.attempts
                    ),
                ));
                if record.attempts >= DEATHS_TO_FAIL && !record.failed {
                    record.failed = true;
                    failed.push((version.clone(), record.clone()));
                }
            }
            if changed {
                self.save_native_steps(&records);
            }
        }
        // Logged without the lock: a host may call the engine from its log callback.
        for (warning, message) in logs {
            if warning {
                self.host.warn(message);
            } else {
                self.host.info(message);
            }
        }
        for (version, record) in failed {
            self.trip_native_breaker(&version, &record);
        }
    }

    /// `version` died twice in a row: ERROR record, back to the previous bundle, statistic.
    fn trip_native_breaker(&self, version: &str, record: &StepRecord) {
        self.host.error(format!(
            "Bundle {version} crashed the app {} times in a row during its {} step: marked failed, the update cycle skips it until the server offers another version",
            record.attempts, record.step
        ));
        if !record.id.is_empty() && record.id != ID_BUILTIN && self.has_stored_bundle_info(&record.id) {
            if self.current_bundle_id() == record.id {
                self.leave_failed_current_bundle(&record.id);
            }
            if self.next_bundle().is_some_and(|next| next.id() == record.id) {
                self.set_next_bundle(None);
            }
            self.set_bundle_status(&record.id, BundleStatus::Error);
        }
        let action = if record.step == STEP_SET {
            "set_fail"
        } else {
            "download_fail"
        };
        let mut metadata = Map::new();
        metadata.insert(
            "message".into(),
            json!(format!(
                "native crash during {} ({} in a row)",
                record.step, record.attempts
            )),
        );
        metadata.insert("step".into(), json!(record.step));
        metadata.insert("attempts".into(), json!(record.attempts.to_string()));
        self.send_stats(action, Some(version), None, Some(&metadata));
    }

    /// The update cycle skips this version.
    pub(crate) fn native_step_failed(&self, version: &str) -> bool {
        let _lock = LOCK.lock_or_recover();
        self.load_native_steps()
            .iter()
            .any(|(name, record)| name == version && record.failed)
    }

    /// The server offers `version`: the records of other versions (failed ones included) are
    /// forgotten, except steps running now.
    pub(crate) fn forget_native_steps_except(&self, version: &str) {
        let _lock = LOCK.lock_or_recover();
        let mut records = self.load_native_steps();
        let before = records.len();
        records.retain(|(name, record)| name == version || record.running_here());
        if records.len() != before {
            self.save_native_steps(&records);
        }
    }
}
