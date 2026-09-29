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
//! Hosts talk to the core through one language-neutral entry point,
//! [`api::call`], exposed as a C ABI ([`ffi`]) and, on Android, JNI ([`jni`]).
//! Every operation takes and returns JSON; the operation names and payloads
//! are pinned by the shared fixtures in `native-contract-tests/`.

pub mod api;
pub mod bundle;
pub mod crypto;
pub mod error;
pub mod ffi;
pub mod http;
#[cfg(feature = "jni")]
pub mod jni;
pub mod paths;
pub mod policy;
pub mod text;

pub use error::{CoreError, CoreResult};

/// Core version, bumped when the operation surface changes.
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
