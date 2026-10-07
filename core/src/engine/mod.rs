//! The updater engine: everything that used to live in `CapgoUpdater.java`
//! / `CapgoUpdater.swift` and the update decisions of the Capacitor plugins.
//!
//! Hosts create one engine per process with their [`Host`] services and a
//! JSON configuration, then drive it with [`Engine::call`] (blocking; call it
//! off the UI thread). Long-running work reports progress through events.

mod apk;
pub mod archive;
pub mod backend;
pub mod config;
pub mod download;
pub mod fsutil;
pub mod manifest;
mod ops;
pub mod plugin;
mod scheduled;
pub mod stats;
pub mod store;

use std::sync::{Arc, Mutex, RwLock, RwLockWriteGuard, Weak};
use std::time::Duration;

use serde_json::Value;

use crate::error::{CoreError, CoreResult};
use crate::host::{Host, HostLog};
use crate::net::Http;

pub use config::EngineConfig;

pub(crate) struct ConfigWrite<'a>(RwLockWriteGuard<'a, Arc<EngineConfig>>);

impl std::ops::Deref for ConfigWrite<'_> {
    type Target = EngineConfig;
    fn deref(&self) -> &EngineConfig {
        &self.0
    }
}

impl std::ops::DerefMut for ConfigWrite<'_> {
    fn deref_mut(&mut self) -> &mut EngineConfig {
        // Snapshots taken earlier keep the old values.
        Arc::make_mut(&mut self.0)
    }
}

pub struct Engine {
    pub(crate) host: Arc<dyn Host>,
    pub(crate) http: Http,
    /// Readers take a snapshot and never hold the lock: a read guard kept across a host
    /// callback, a network call or a second `config()` deadlocked as soon as a writer queued
    /// (std's RwLock blocks new readers behind a waiting writer), hanging main-thread calls.
    config: RwLock<Arc<EngineConfig>>,
    pub(crate) stats: stats::StatsState,
    pub(crate) delete_lock: Mutex<()>,
    /// In-flight downloads per version (the same version can download twice at once,
    /// e.g. `download()` overlapping the update cycle).
    pub(crate) downloads: Mutex<std::collections::HashMap<String, Vec<download::Cancel>>>,
    pub(crate) plugin: plugin::Plugin,
    /// Set when the host releases the engine: callers waiting for a scheduled download return.
    pub(crate) downloads_detached: std::sync::atomic::AtomicBool,
    weak: Weak<Engine>,
}

impl Engine {
    pub fn new(host: Arc<dyn Host>, config: &Value) -> CoreResult<Arc<Self>> {
        let config = EngineConfig::from_json(config)?;
        let user_agent = crate::http::user_agent(
            &config.app_id,
            &config.plugin_version,
            &config.version_os,
            &config.platform,
        );
        let timeout = Duration::from_millis(config.timeout_ms);
        let allow_downgrade = config.allow_https_to_http_redirect;
        let engine = Arc::new_cyclic(|weak| Self {
            http: Http::new(host.clone(), user_agent, timeout),
            host,
            config: RwLock::new(Arc::new(config)),
            stats: stats::StatsState::default(),
            delete_lock: Mutex::new(()),
            downloads: Mutex::new(Default::default()),
            plugin: plugin::Plugin::default(),
            downloads_detached: Default::default(),
            weak: weak.clone(),
        });
        engine.http.set_allow_https_to_http_redirect(allow_downgrade);
        Ok(engine)
    }

    /// A snapshot of the settings; later changes do not affect it.
    pub fn config(&self) -> Arc<EngineConfig> {
        self.config.read().unwrap_or_else(|poison| poison.into_inner()).clone()
    }

    /// Exclusive access for a change. Keep it to the change itself: no `config()`, host
    /// callback or network call while it is alive.
    pub(crate) fn config_mut(&self) -> ConfigWrite<'_> {
        ConfigWrite(self.config.write().unwrap_or_else(|poison| poison.into_inner()))
    }

    /// Starts a worker thread. `std::thread::spawn` panics when the OS cannot create one
    /// (out of threads or memory); this logs and returns false so callers can undo.
    pub(crate) fn spawn(&self, name: &str, work: impl FnOnce() + Send + 'static) -> bool {
        match std::thread::Builder::new().name(format!("capgo-{name}")).spawn(work) {
            Ok(_) => true,
            Err(error) => {
                self.host.error(format!("Could not start the {name} thread: {error}"));
                false
            }
        }
    }

    pub(crate) fn weak_self(&self) -> Weak<Engine> {
        self.weak.clone()
    }

    /// Applies runtime settings (endpoints, ids, public key, preview session, timeout).
    pub fn configure(&self, value: &Value) -> CoreResult<()> {
        let (user_agent, timeout, allow_downgrade) = {
            let mut config = self.config_mut();
            // All or nothing: an invalid public key must not leave half the settings applied.
            let mut updated = config.clone();
            updated.apply(value)?;
            *config = updated;
            let allow_downgrade = config.allow_https_to_http_redirect;
            (
                crate::http::user_agent(
                    &config.app_id,
                    &config.plugin_version,
                    &config.version_os,
                    &config.platform,
                ),
                Duration::from_millis(config.timeout_ms),
                allow_downgrade,
            )
        };
        self.http.set_user_agent(user_agent);
        self.http.set_timeout(timeout);
        self.http.set_allow_https_to_http_redirect(allow_downgrade);
        Ok(())
    }

    /// Runs one engine operation (see `ops.rs`); unknown names fall back to the
    /// stateless core operations of [`crate::api`].
    pub fn call(&self, operation: &str, input: &Value) -> CoreResult<Value> {
        let empty = Value::Object(Default::default());
        let input = if input.is_null() { &empty } else { input };
        if !input.is_object() {
            return Err(CoreError::invalid_input("input must be a JSON object"));
        }
        match self.call_engine(operation, input) {
            Some(result) => result,
            None => crate::api::call(operation, input).map_err(|error| {
                if error.code == "unknown_operation" {
                    CoreError::new("unknown_operation", format!("Unknown engine operation: {operation}"))
                } else {
                    error
                }
            }),
        }
    }

    pub fn call_json(&self, operation: &str, input_json: &str) -> String {
        let result = if input_json.trim().is_empty() {
            self.call(operation, &Value::Null)
        } else {
            serde_json::from_str::<Value>(input_json)
                .map_err(|error| CoreError::invalid_input(format!("Invalid JSON input: {error}")))
                .and_then(|input| self.call(operation, &input))
        };
        crate::api::envelope(result)
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.shutdown_stats();
    }
}
