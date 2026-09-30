//! C ABI. Any runtime able to call C (Swift, Kotlin/Java via JNI, Dart FFI,
//! N-API, .NET P/Invoke, ...) can drive the core with two functions.
//!
//! ```c
//! char *capgo_core_call(const char *operation, const char *input_json);
//! void capgo_core_free(char *value);
//! ```

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::api;
use crate::error::CoreError;

fn to_c_string(value: String) -> *mut c_char {
    // JSON output never contains interior NULs (serde escapes them), but stay total.
    CString::new(value)
        .unwrap_or_else(|_| {
            CString::new("{\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"NUL in output\"}}").unwrap()
        })
        .into_raw()
}

unsafe fn read_str<'a>(value: *const c_char) -> Result<&'a str, CoreError> {
    if value.is_null() {
        return Ok("");
    }
    CStr::from_ptr(value)
        .to_str()
        .map_err(|_| CoreError::invalid_input("Arguments must be UTF-8"))
}

/// Runs a core operation. Returns a heap-allocated UTF-8 JSON envelope that
/// must be released with [`capgo_core_free`]. Never returns NULL.
///
/// # Safety
/// `operation` and `input_json` must be NULL or valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn capgo_core_call(operation: *const c_char, input_json: *const c_char) -> *mut c_char {
    let output = catch_unwind(AssertUnwindSafe(|| {
        let operation = match read_str(operation) {
            Ok(value) => value,
            Err(error) => return api::envelope(Err(error)),
        };
        match read_str(input_json) {
            Ok(input) => api::call_json(operation, input),
            Err(error) => api::envelope(Err(error)),
        }
    }))
    .unwrap_or_else(|_| api::envelope(Err(CoreError::new("internal", "Core operation panicked"))));
    to_c_string(output)
}

/// Releases a string returned by [`capgo_core_call`].
///
/// # Safety
/// `value` must come from `capgo_core_call` and be released only once.
#[no_mangle]
pub unsafe extern "C" fn capgo_core_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

// ---------------------------------------------------------------------------
// Engine handle with host callbacks.

use std::ffi::c_void;
use std::sync::Arc;

use crate::engine::Engine;
use crate::host::{Host, LogLevel};

/// Host services provided by a C-ABI host (iOS, or any other runtime).
///
/// All callbacks may be invoked from any thread. Strings passed to the host
/// are only valid during the call. `kv_get` returns a string allocated by the
/// host (or NULL) that the engine releases with `free_string`.
#[repr(C)]
pub struct CapgoHostCallbacks {
    pub context: *mut c_void,
    pub log: Option<unsafe extern "C" fn(*mut c_void, i32, *const c_char)>,
    pub kv_get: Option<unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_char>,
    pub kv_set: Option<unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char)>,
    /// Returns every persisted key as a JSON array string (host allocated, released with `free_string`).
    pub kv_keys: Option<unsafe extern "C" fn(*mut c_void) -> *mut c_char>,
    pub emit: Option<unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char)>,
    pub free_string: Option<unsafe extern "C" fn(*mut c_void, *mut c_char)>,
    /// Optional platform hooks (`willSwitchBundle`, `cancelVersionDownload`,
    /// `beforeDownload`, `cancelAllDownloads`, `sendStats`): hook name and JSON
    /// payload in, JSON object reply (host allocated) or NULL out.
    pub hook: Option<unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char) -> *mut c_char>,
    /// Called once when the engine is destroyed, to release `context`.
    pub release: Option<unsafe extern "C" fn(*mut c_void)>,
}

struct CHost(CapgoHostCallbacks);

// The host contract requires thread-safe callbacks.
unsafe impl Send for CHost {}
unsafe impl Sync for CHost {}

impl Drop for CHost {
    fn drop(&mut self) {
        if let Some(release) = self.0.release {
            unsafe { release(self.0.context) };
        }
    }
}

fn c_string(value: &str) -> CString {
    CString::new(value.replace('\0', "")).unwrap_or_default()
}

impl CHost {
    fn take_string(&self, raw: *mut c_char) -> Option<String> {
        if raw.is_null() {
            return None;
        }
        let value = unsafe { CStr::from_ptr(raw) }.to_string_lossy().into_owned();
        if let Some(free_string) = self.0.free_string {
            unsafe { free_string(self.0.context, raw) };
        }
        Some(value)
    }
}

impl Host for CHost {
    fn log(&self, level: LogLevel, message: &str) {
        if let Some(log) = self.0.log {
            let message = c_string(message);
            unsafe { log(self.0.context, level as i32, message.as_ptr()) };
        }
    }

    fn kv_get(&self, key: &str, default: Option<&str>) -> Option<String> {
        let kv_get = self.0.kv_get?;
        let key = c_string(key);
        let raw = unsafe { kv_get(self.0.context, key.as_ptr()) };
        self.take_string(raw).or_else(|| default.map(str::to_string))
    }

    fn kv_set(&self, key: &str, value: Option<&str>) {
        if let Some(kv_set) = self.0.kv_set {
            let key = c_string(key);
            let value = value.map(c_string);
            unsafe {
                kv_set(
                    self.0.context,
                    key.as_ptr(),
                    value.as_ref().map_or(std::ptr::null(), |value| value.as_ptr()),
                )
            };
        }
    }

    fn kv_keys(&self) -> Vec<String> {
        let Some(kv_keys) = self.0.kv_keys else {
            return Vec::new();
        };
        let raw = unsafe { kv_keys(self.0.context) };
        self.take_string(raw)
            .and_then(|json| serde_json::from_str(&json).ok())
            .unwrap_or_default()
    }

    fn emit(&self, event: &str, payload: &serde_json::Value) {
        if let Some(emit) = self.0.emit {
            let event = c_string(event);
            let payload = c_string(&payload.to_string());
            unsafe { emit(self.0.context, event.as_ptr(), payload.as_ptr()) };
        }
    }

    fn hook(&self, name: &str, payload: &serde_json::Value) -> Option<serde_json::Value> {
        let hook = self.0.hook?;
        let name = c_string(name);
        let payload = c_string(&payload.to_string());
        let raw = unsafe { hook(self.0.context, name.as_ptr(), payload.as_ptr()) };
        self.take_string(raw).and_then(|json| serde_json::from_str(&json).ok())
    }

    fn will_switch_bundle(&self, path: &str) {
        self.hook("willSwitchBundle", &serde_json::json!({ "path": path }));
    }

    fn cancel_version_download(&self, version: &str) -> bool {
        self.hook("cancelVersionDownload", &serde_json::json!({ "version": version }))
            .and_then(|reply| reply.get("cancelled").and_then(serde_json::Value::as_bool))
            .unwrap_or(true)
    }

    fn before_download(&self) -> Result<(), String> {
        match self.hook("beforeDownload", &serde_json::json!({})).and_then(|reply| {
            reply
                .get("error")
                .and_then(serde_json::Value::as_str)
                .map(str::to_string)
        }) {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    fn cancel_all_downloads(&self) {
        self.hook("cancelAllDownloads", &serde_json::json!({}));
    }

    fn send_stats(&self, action: &str, version_name: &str, old_version_name: &str) -> bool {
        self.hook(
            "sendStats",
            &serde_json::json!({ "action": action, "versionName": version_name, "oldVersionName": old_version_name }),
        )
        .and_then(|reply| reply.get("handled").and_then(serde_json::Value::as_bool))
        .unwrap_or(false)
    }
}

/// Creates an engine. Returns NULL on invalid configuration (the error is logged to the host).
///
/// # Safety
/// `config_json` must be NULL or a valid NUL-terminated string; `host` callbacks must stay valid
/// until `release` is called.
#[no_mangle]
pub unsafe extern "C" fn capgo_engine_new(config_json: *const c_char, host: CapgoHostCallbacks) -> *mut Engine {
    let host: Arc<dyn Host> = Arc::new(CHost(host));
    let result = catch_unwind(AssertUnwindSafe(|| {
        let config = read_str(config_json)?;
        let config: serde_json::Value = if config.trim().is_empty() {
            serde_json::Value::Null
        } else {
            serde_json::from_str(config)
                .map_err(|error| CoreError::invalid_input(format!("Invalid engine config: {error}")))?
        };
        Engine::new(host.clone(), &config)
    }));
    match result {
        Ok(Ok(engine)) => std::sync::Arc::into_raw(engine) as *mut Engine,
        Ok(Err(error)) => {
            host.log(LogLevel::Error, &format!("Capgo engine init failed: {error}"));
            std::ptr::null_mut()
        }
        Err(_) => {
            host.log(LogLevel::Error, "Capgo engine init panicked");
            std::ptr::null_mut()
        }
    }
}

/// Runs an engine operation; same envelope and ownership rules as [`capgo_core_call`].
///
/// # Safety
/// `engine` must come from [`capgo_engine_new`] and not be freed.
#[no_mangle]
pub unsafe extern "C" fn capgo_engine_call(
    engine: *const Engine,
    operation: *const c_char,
    input_json: *const c_char,
) -> *mut c_char {
    let output = catch_unwind(AssertUnwindSafe(|| {
        let Some(engine) = engine.as_ref() else {
            return api::envelope(Err(CoreError::invalid_input("Engine handle is NULL")));
        };
        let operation = match read_str(operation) {
            Ok(value) => value,
            Err(error) => return api::envelope(Err(error)),
        };
        match read_str(input_json) {
            Ok(input) => engine.call_json(operation, input),
            Err(error) => api::envelope(Err(error)),
        }
    }))
    .unwrap_or_else(|_| api::envelope(Err(CoreError::new("internal", "Engine operation panicked"))));
    to_c_string(output)
}

/// Destroys an engine and releases the host context.
///
/// # Safety
/// `engine` must come from [`capgo_engine_new`]; no call may be in flight.
#[no_mangle]
pub unsafe extern "C" fn capgo_engine_free(engine: *mut Engine) {
    if !engine.is_null() {
        drop(std::sync::Arc::from_raw(engine as *const Engine));
    }
}
