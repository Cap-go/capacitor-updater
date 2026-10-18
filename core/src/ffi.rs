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
    /// Persists a value durably; a NULL value removes the key.
    pub kv_set: Option<unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char)>,
    /// Returns every persisted key as a JSON array string (host allocated, released with `free_string`).
    pub kv_keys: Option<unsafe extern "C" fn(*mut c_void) -> *mut c_char>,
    pub emit: Option<unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char)>,
    pub free_string: Option<unsafe extern "C" fn(*mut c_void, *mut c_char)>,
    /// Optional platform hooks (full list in `include/capgo_updater_core.h`): hook
    /// name and JSON payload in, JSON object reply (host allocated) or NULL out.
    pub hook: Option<unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char) -> *mut c_char>,
    /// Called once when the engine is destroyed, to release `context`.
    pub release: Option<unsafe extern "C" fn(*mut c_void)>,
    /// Verifies a TLS server chain with the platform trust store:
    /// `(context, server_name, certificates, lengths, count, error)`, where
    /// `certificates[i]` is a DER certificate of `lengths[i]` bytes, leaf first.
    /// Returns 1 when the chain is trusted; any other value rejects it and
    /// `*error` may receive a host-allocated reason (released with
    /// `free_string`). NULL refuses every HTTPS connection.
    pub verify_server_certificate: Option<VerifyServerCertificate>,
}

pub type VerifyServerCertificate =
    unsafe extern "C" fn(*mut c_void, *const c_char, *const *const u8, *const usize, usize, *mut *mut c_char) -> i32;

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

    fn verify_server_certificate(&self, chain: &[&[u8]], server_name: &str) -> Option<Result<(), String>> {
        let verify = self.0.verify_server_certificate?;
        let server_name = c_string(server_name);
        let pointers: Vec<*const u8> = chain.iter().map(|cert| cert.as_ptr()).collect();
        let lengths: Vec<usize> = chain.iter().map(|cert| cert.len()).collect();
        let mut error: *mut c_char = std::ptr::null_mut();
        let verdict = unsafe {
            verify(
                self.0.context,
                server_name.as_ptr(),
                pointers.as_ptr(),
                lengths.as_ptr(),
                chain.len(),
                &mut error,
            )
        };
        let message = self.take_string(error);
        // Only an explicit 1 trusts the chain.
        Some(if verdict == 1 {
            Ok(())
        } else {
            Err(message.unwrap_or_else(|| "Certificate rejected by the platform trust store".to_string()))
        })
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

/// The [`Host`] a C-ABI host gets, for tests of the callback marshalling.
#[cfg(feature = "test-support")]
pub fn host_from_callbacks_for_tests(host: CapgoHostCallbacks) -> Arc<dyn Host> {
    Arc::new(CHost(host))
}

/// Creates an engine. Returns NULL on invalid configuration (the error is logged to the host).
///
/// Ownership of `host.context` passes to the engine in every case: on failure
/// `release(context)` has already been called when NULL is returned, so the
/// caller must not release it again.
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
        // A panic unwinding out of an `extern "C"` function aborts the process.
        let engine = std::sync::Arc::from_raw(engine as *const Engine);
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || drop(engine)));
    }
}

/// The `unsafe` marshalling of this file, without the network or crypto code: these also run
/// under Miri (CI job `rust_core_sanitizers`, `cargo miri test --lib ffi::`).
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    unsafe fn call(operation: &[u8], input: &[u8]) -> serde_json::Value {
        let operation = CString::new(operation).unwrap();
        let input = CString::new(input).unwrap();
        let raw = capgo_core_call(operation.as_ptr(), input.as_ptr());
        let text = CStr::from_ptr(raw).to_str().unwrap().to_string();
        capgo_core_free(raw);
        serde_json::from_str(&text).unwrap()
    }

    #[test]
    fn core_calls_marshal_strings_both_ways() {
        unsafe {
            let reply = call(b"resolvePathInside", br#"{"base":"/data","path":"a/b"}"#);
            assert_eq!(reply["ok"], true, "{reply}");
            assert_eq!(reply["value"]["path"], "/data/a/b");
            let reply = call(b"resolvePathInside", br#"{"base":"/data","path":"../x"}"#);
            assert_eq!(reply["ok"], false, "{reply}");
            // Not UTF-8, NULL arguments, NULL free.
            let reply = call(b"\xff\xfe", b"{}");
            assert_eq!(reply["error"]["code"], "invalid_input", "{reply}");
            let raw = capgo_core_call(std::ptr::null(), std::ptr::null());
            assert!(!raw.is_null());
            capgo_core_free(raw);
            capgo_core_free(std::ptr::null_mut());
        }
    }

    struct Context {
        store: Mutex<Vec<(String, String)>>,
        released: Mutex<bool>,
    }

    unsafe extern "C" fn kv_get(context: *mut c_void, key: *const c_char) -> *mut c_char {
        let context = &*(context as *const Context);
        let key = CStr::from_ptr(key).to_str().unwrap();
        let store = context.store.lock().unwrap();
        match store.iter().find(|(name, _)| name == key) {
            Some((_, value)) => CString::new(value.as_str()).unwrap().into_raw(),
            None => std::ptr::null_mut(),
        }
    }

    unsafe extern "C" fn kv_set(context: *mut c_void, key: *const c_char, value: *const c_char) {
        let context = &*(context as *const Context);
        let key = CStr::from_ptr(key).to_str().unwrap().to_string();
        let mut store = context.store.lock().unwrap();
        store.retain(|(name, _)| *name != key);
        if !value.is_null() {
            store.push((key, CStr::from_ptr(value).to_str().unwrap().to_string()));
        }
    }

    unsafe extern "C" fn kv_keys(context: *mut c_void) -> *mut c_char {
        let context = &*(context as *const Context);
        let keys: Vec<String> = context
            .store
            .lock()
            .unwrap()
            .iter()
            .map(|(key, _)| key.clone())
            .collect();
        CString::new(serde_json::to_string(&keys).unwrap()).unwrap().into_raw()
    }

    unsafe extern "C" fn hook(_: *mut c_void, name: *const c_char, payload: *const c_char) -> *mut c_char {
        let name = CStr::from_ptr(name).to_str().unwrap();
        let payload: serde_json::Value = serde_json::from_str(CStr::from_ptr(payload).to_str().unwrap()).unwrap();
        let reply = serde_json::json!({ "name": name, "payload": payload });
        CString::new(reply.to_string()).unwrap().into_raw()
    }

    unsafe extern "C" fn verify(
        _: *mut c_void,
        server_name: *const c_char,
        certificates: *const *const u8,
        lengths: *const usize,
        count: usize,
        error: *mut *mut c_char,
    ) -> i32 {
        let first = std::slice::from_raw_parts(*certificates, *lengths);
        let name = CStr::from_ptr(server_name).to_str().unwrap();
        *error = CString::new(format!("{name} {count} {}", first.len()))
            .unwrap()
            .into_raw();
        0
    }

    unsafe extern "C" fn free_string(_: *mut c_void, value: *mut c_char) {
        drop(CString::from_raw(value));
    }

    unsafe extern "C" fn release(context: *mut c_void) {
        let context = Box::from_raw(context as *mut Context);
        *context.released.lock().unwrap() = true;
        // Leaked on purpose so the test can read the flag after the host is gone.
        Box::leak(context);
    }

    #[test]
    fn host_callbacks_marshal_strings_and_release_the_context() {
        let context = Box::into_raw(Box::new(Context {
            store: Mutex::new(Vec::new()),
            released: Mutex::new(false),
        }));
        let host = CHost(CapgoHostCallbacks {
            context: context as *mut c_void,
            log: None,
            kv_get: Some(kv_get),
            kv_set: Some(kv_set),
            kv_keys: Some(kv_keys),
            emit: None,
            free_string: Some(free_string),
            hook: Some(hook),
            release: Some(release),
            verify_server_certificate: Some(verify),
        });
        host.kv_set("a\0b", Some("value"));
        assert_eq!(host.kv_get("ab", None).as_deref(), Some("value"));
        assert_eq!(host.kv_get("missing", Some("fallback")).as_deref(), Some("fallback"));
        assert_eq!(host.kv_keys(), vec!["ab".to_string()]);
        host.kv_set("ab", None);
        assert!(host.kv_keys().is_empty());
        let reply = host.hook("name", &serde_json::json!({ "x": 1 })).unwrap();
        assert_eq!(reply["payload"]["x"], 1);
        let verdict = host.verify_server_certificate(&[b"cert", b"chain"], "example.com");
        assert_eq!(verdict, Some(Err("example.com 2 4".to_string())));
        host.log(LogLevel::Info, "ignored without a callback");
        drop(host);
        unsafe {
            assert!(*(*context).released.lock().unwrap());
            drop(Box::from_raw(context));
        }
    }
}
