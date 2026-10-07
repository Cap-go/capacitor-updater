//! Capgo updater core.
//!
//! Platform-neutral logic shared by every Capgo updater host (the Android and
//! iOS Capacitor plugins today; any other OS or app runtime tomorrow):
//!
//! - [`policy`]: auto-update / direct-update decisions and default-channel rules
//! - [`http`]: user agent, resumable download and rate-limit decisions
//! - [`paths`]: path traversal, cache-name and partial-download guards
//! - [`crypto`]: RSA session-key/checksum recovery, AES bundle decryption, SHA-256
//! - [`bundle`]: bundle model rules
//!
//! Hosts drive the [`engine`] through a C ABI ([`ffi`]) and, on Android, JNI
//! ([`jni`]); every operation takes and returns JSON. The stateless
//! [`api::call`] only exposes the bundle path guard. The pure rules are pinned
//! by the shared fixtures in `native-contract-tests/` (`tests/contract.rs`).

pub mod api;
pub mod bundle;
pub mod crypto;
pub mod engine;
pub mod error;
pub mod ffi;
pub mod host;
pub mod http;
#[cfg(feature = "jni")]
pub mod jni;
pub mod net;
pub mod paths;
pub mod policy;
mod sync;
pub mod text;

pub use error::{CoreError, CoreResult};

/// Core version, bumped when the operation surface changes.
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
