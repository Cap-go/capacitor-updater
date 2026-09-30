//! Statistics events: queued, batched (one POST per second at most),
//! persisted across launches (`capgo_pending_stats.json`) and retried on
//! transient failures.

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use serde_json::{json, Map, Value};

use super::Engine;
use crate::host::HostLog;

pub const PENDING_STATS_FILE: &str = "capgo_pending_stats.json";
pub const MAX_PENDING_STATS: usize = 200;
const FLUSH_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Clone)]
pub(crate) struct QueuedEvent {
    pub event: Value,
    /// Host callback id, emitted as `statsSent` once the event reached the server.
    pub callback_id: Option<String>,
}

/// Key/value writes (`None` removes the key).
pub(crate) type KvWrites = Vec<(String, Option<String>)>;

#[derive(Default)]
pub(crate) struct StatsState {
    pub queue: Mutex<Vec<QueuedEvent>>,
    pub in_flight: Mutex<Vec<QueuedEvent>>,
    pub persist_lock: Mutex<()>,
    pub flush_in_flight: AtomicBool,
    pub stopped: AtomicBool,
    pub timer_started: AtomicBool,
    /// Engine-owned acknowledgements: persisted key/value writes applied once the
    /// event reached the server (snapshots that must retry until delivered).
    pub acks: Mutex<std::collections::HashMap<String, KvWrites>>,
}

fn millis_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default()
}

impl Engine {
    fn stats_file(&self) -> Option<PathBuf> {
        let dir = self.config().stats_dir.clone();
        (!dir.as_os_str().is_empty()).then(|| dir.join(PENDING_STATS_FILE))
    }

    /// Emits a statistics event from engine logic. The host may observe/route
    /// it (see [`crate::host::Host::send_stats`]); otherwise it is queued.
    pub fn send_stats(
        &self,
        action: &str,
        version_name: Option<&str>,
        old_version_name: Option<&str>,
        metadata: Option<&Map<String, Value>>,
    ) {
        if metadata.is_none() {
            let version = match version_name {
                Some(version) => version.to_string(),
                None => self.current_bundle().version_name().to_string(),
            };
            if self
                .host
                .send_stats(action, &version, old_version_name.unwrap_or_default())
            {
                return;
            }
            self.send_stats_with_callback(action, Some(&version), old_version_name, None, None);
            return;
        }
        self.send_stats_with_callback(action, version_name, old_version_name, metadata, None);
    }

    pub fn send_stats_with_callback(
        &self,
        action: &str,
        version_name: Option<&str>,
        old_version_name: Option<&str>,
        metadata: Option<&Map<String, Value>>,
        callback_id: Option<String>,
    ) {
        if self.stats.stopped.load(Ordering::SeqCst) {
            return;
        }
        if self.config().preview_session {
            self.host.debug("Skipping sendStats during preview session.");
            return;
        }
        if self.config().stats_url.is_empty() {
            return;
        }
        let version_name = match version_name {
            Some(version) => version.to_string(),
            None => self.current_bundle().version_name().to_string(),
        };
        let mut event = self.info_object(None);
        event.insert("version_name".into(), json!(version_name));
        event.insert("old_version_name".into(), json!(old_version_name.unwrap_or_default()));
        event.insert("action".into(), json!(action));
        event.insert("timestamp".into(), json!(millis_now()));
        if let Some(metadata) = metadata.filter(|metadata| !metadata.is_empty()) {
            event.insert("metadata".into(), Value::Object(metadata.clone()));
        }
        {
            let mut queue = self.stats.queue.lock().unwrap();
            if self.stats.stopped.load(Ordering::SeqCst) {
                return;
            }
            while queue.len() >= MAX_PENDING_STATS {
                queue.remove(0);
            }
            queue.push(QueuedEvent {
                event: Value::Object(event),
                callback_id,
            });
        }
        self.ensure_stats_timer();
    }

    pub fn pending_stats_count(&self) -> usize {
        self.stats.queue.lock().unwrap().len()
    }

    fn ensure_stats_timer(&self) {
        if self.stats.stopped.load(Ordering::SeqCst) || self.stats.timer_started.swap(true, Ordering::SeqCst) {
            return;
        }
        let weak: Weak<Engine> = self.weak_self();
        std::thread::Builder::new()
            .name("capgo-stats".into())
            .spawn(move || loop {
                std::thread::sleep(FLUSH_INTERVAL);
                let Some(engine) = weak.upgrade() else {
                    return;
                };
                if engine.stats.stopped.load(Ordering::SeqCst) {
                    return;
                }
                engine.flush_stats();
            })
            .ok();
    }

    /// Sends queued events now (also called by the 1 s timer).
    pub fn flush_stats(&self) {
        if self.stats.stopped.load(Ordering::SeqCst) || self.stats.queue.lock().unwrap().is_empty() {
            return;
        }
        // While Retry-After is active, keep stats queued and skip the network call.
        if self.is_remote_blocked() {
            self.host.debug("Deferring stats flush until Retry-After expires.");
            return;
        }
        let stats_url = self.config().stats_url.clone();
        if stats_url.is_empty() {
            self.stats.queue.lock().unwrap().clear();
            self.stats.in_flight.lock().unwrap().clear();
            self.persist_stats(false);
            return;
        }
        if self.stats.flush_in_flight.swap(true, Ordering::SeqCst) {
            return;
        }
        let events: Vec<QueuedEvent> = {
            let mut queue = self.stats.queue.lock().unwrap();
            let events = std::mem::take(&mut *queue);
            *self.stats.in_flight.lock().unwrap() = events.clone();
            events
        };
        if events.is_empty() {
            self.stats.flush_in_flight.store(false, Ordering::SeqCst);
            return;
        }
        self.persist_stats(false);
        let body = Value::Array(events.iter().map(|queued| queued.event.clone()).collect());
        let result = self.http.post_json(&stats_url, &body);
        if self.stats.stopped.load(Ordering::SeqCst) {
            self.stats.flush_in_flight.store(false, Ordering::SeqCst);
            return;
        }
        match result {
            Err(error) => {
                self.requeue_stats(events);
                self.host.error("Failed to send stats batch");
                self.host.debug(format!("Error: {error}"));
            }
            Ok(response) => {
                if self.handle_rate_limit(&response).blocked {
                    self.requeue_stats(events);
                } else if response.is_success() {
                    self.stats.in_flight.lock().unwrap().clear();
                    self.persist_stats(false);
                    self.host.info("Stats batch sent successfully");
                    self.host.debug(format!("Sent {} events", events.len()));
                    for callback_id in events.iter().filter_map(|queued| queued.callback_id.clone()) {
                        let ack = self.stats.acks.lock().unwrap().remove(&callback_id);
                        if let Some(writes) = ack {
                            for (key, value) in writes {
                                self.host.kv_set(&key, value.as_deref());
                            }
                            continue;
                        }
                        self.host.emit("statsSent", &json!({ "callbackId": callback_id }));
                    }
                } else if crate::http::is_retryable_http_status(response.status as i64) {
                    self.requeue_stats(events);
                    self.host.error("Error sending stats batch");
                    self.host
                        .debug(format!("Retrying later, response code: {}", response.status));
                } else {
                    self.stats.in_flight.lock().unwrap().clear();
                    self.persist_stats(false);
                    self.host.error("Dropping stats batch after permanent error");
                    self.host.debug(format!("Response code: {}", response.status));
                }
            }
        }
        self.stats.flush_in_flight.store(false, Ordering::SeqCst);
    }

    fn requeue_stats(&self, events: Vec<QueuedEvent>) {
        if self.stats.stopped.load(Ordering::SeqCst) || events.is_empty() {
            return;
        }
        {
            let mut queue = self.stats.queue.lock().unwrap();
            self.stats.in_flight.lock().unwrap().clear();
            let mut combined = events;
            combined.append(&mut queue);
            let overflow = combined.len().saturating_sub(MAX_PENDING_STATS);
            combined.drain(..overflow);
            *queue = combined;
        }
        self.persist_stats(false);
        self.ensure_stats_timer();
    }

    /// Writes in-flight + queued events (newest 200) so a kill does not lose them.
    pub fn persist_stats(&self, force: bool) {
        let Some(file) = self.stats_file() else {
            return;
        };
        let _guard = self.stats.persist_lock.lock().unwrap();
        if self.stats.stopped.load(Ordering::SeqCst) && !force {
            return;
        }
        let events: Vec<Value> = {
            let queue = self.stats.queue.lock().unwrap();
            let in_flight = self.stats.in_flight.lock().unwrap();
            let combined: Vec<Value> = in_flight
                .iter()
                .chain(queue.iter())
                .map(|queued| queued.event.clone())
                .collect();
            let start = combined.len().saturating_sub(MAX_PENDING_STATS);
            combined[start..].to_vec()
        };
        let bytes = Value::Array(events).to_string();
        if let Err(error) = write_atomically(&file, bytes.as_bytes()) {
            self.host.error("Failed to persist stats queue");
            self.host.debug(format!("Error: {error}"));
        }
    }

    /// Restores events persisted by a previous launch.
    pub fn restore_pending_stats(&self) {
        let Some(file) = self.stats_file() else {
            return;
        };
        let backup = backup_path(&file);
        if !file.exists() && backup.exists() && fs::rename(&backup, &file).is_err() {
            self.host.error("Failed to restore stats backup");
            return;
        }
        let Ok(raw) = fs::read_to_string(&file) else {
            return;
        };
        let Ok(Value::Array(events)) = serde_json::from_str::<Value>(&raw) else {
            self.host.error("Failed to restore pending stats");
            return;
        };
        let restored = {
            let mut queue = self.stats.queue.lock().unwrap();
            for event in events.into_iter().filter(Value::is_object) {
                if queue.len() >= MAX_PENDING_STATS {
                    break;
                }
                queue.push(QueuedEvent {
                    event,
                    callback_id: None,
                });
            }
            queue.len()
        };
        let _ = fs::remove_file(&backup);
        if restored > 0 {
            self.host.info(format!("Restored {restored} pending stats events"));
            self.ensure_stats_timer();
        }
    }

    /// Stops the stats timer and persists what is left.
    pub fn shutdown_stats(&self) {
        self.stats.stopped.store(true, Ordering::SeqCst);
        self.persist_stats(true);
    }
}

fn backup_path(file: &std::path::Path) -> PathBuf {
    PathBuf::from(format!("{}.bak", file.display()))
}

fn write_atomically(file: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = file.parent() {
        fs::create_dir_all(parent)?;
    }
    let temp = PathBuf::from(format!("{}.tmp", file.display()));
    fs::write(&temp, bytes)?;
    let result = fs::rename(&temp, file);
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    } else {
        let _ = fs::remove_file(backup_path(file));
    }
    result
}

#[allow(dead_code)]
pub(crate) fn assert_send_sync() {
    fn check<T: Send + Sync>() {}
    check::<Arc<Engine>>();
}
