//! The updater engine: everything that used to live in `CapgoUpdater.java`
//! / `CapgoUpdater.swift` and the update decisions of the Capacitor plugins.
//!
//! Hosts create one engine per process with their [`Host`] services and a
//! JSON configuration, then drive it with [`Engine::call`] (blocking; call it
//! off the UI thread). Long-running work reports progress through events.

pub mod archive;
pub mod backend;
pub mod config;
pub mod download;
pub mod fsutil;
pub mod manifest;
mod ops;
pub mod plugin;
pub mod stats;
pub mod store;

use std::sync::{Arc, Mutex, RwLock, RwLockReadGuard, RwLockWriteGuard, Weak};
use std::time::Duration;

use serde_json::Value;

use crate::error::{CoreError, CoreResult};
use crate::host::Host;
use crate::net::Http;

pub use config::EngineConfig;

pub struct Engine {
    pub(crate) host: Arc<dyn Host>,
    pub(crate) http: Http,
    config: RwLock<EngineConfig>,
    pub(crate) stats: stats::StatsState,
    pub(crate) delete_lock: Mutex<()>,
    pub(crate) downloads: Mutex<std::collections::HashMap<String, download::Cancel>>,
    pub(crate) plugin: plugin::Plugin,
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
            config: RwLock::new(config),
            stats: stats::StatsState::default(),
            delete_lock: Mutex::new(()),
            downloads: Mutex::new(Default::default()),
            plugin: plugin::Plugin::default(),
            weak: weak.clone(),
        });
        engine.http.set_allow_https_to_http_redirect(allow_downgrade);
        Ok(engine)
    }

    pub fn host(&self) -> &Arc<dyn Host> {
        &self.host
    }

    pub fn config(&self) -> RwLockReadGuard<'_, EngineConfig> {
        self.config.read().unwrap_or_else(|poison| poison.into_inner())
    }

    pub(crate) fn config_mut(&self) -> RwLockWriteGuard<'_, EngineConfig> {
        self.config.write().unwrap_or_else(|poison| poison.into_inner())
    }

    pub(crate) fn weak_self(&self) -> Weak<Engine> {
        self.weak.clone()
    }

    /// Applies runtime settings (endpoints, ids, public key, preview session, timeout).
    pub fn configure(&self, value: &Value) -> CoreResult<()> {
        let (user_agent, timeout, allow_downgrade) = {
            let mut config = self.config_mut();
            config.apply(value)?;
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
