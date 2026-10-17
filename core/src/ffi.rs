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
use crate::host::{Host, HttpTransportEvent, HttpTransportOutcome, HttpTransportRequest, LogLevel};

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
    /// Optional transport through the platform network stack (see `CapgoHttpRequest`
    /// and `http_request` in `include/capgo_updater_core.h`). NULL: the engine's own client.
    pub http_request: Option<HttpRequestCallback>,
}

pub type VerifyServerCertificate =
    unsafe extern "C" fn(*mut c_void, *const c_char, *const *const u8, *const usize, usize, *mut *mut c_char) -> i32;

pub type HttpRequestCallback =
    unsafe extern "C" fn(*mut c_void, *const CapgoHttpRequest, *const CapgoHttpSink, *mut *mut c_char) -> i32;

/// `http_request` return values.
pub const CAPGO_HTTP_UNAVAILABLE: i32 = 0;
pub const CAPGO_HTTP_COMPLETED: i32 = 1;
pub const CAPGO_HTTP_FAILED: i32 = 2;

/// One request for the host transport (strings valid during the call).
#[repr(C)]
pub struct CapgoHttpRequest {
    pub method: *const c_char,
    pub url: *const c_char,
    /// JSON array of `[name, value]` pairs, `User-Agent` first.
    pub headers_json: *const c_char,
    /// NULL when the request has no body.
    pub body: *const u8,
    pub body_length: usize,
    /// Idle timeout in milliseconds.
    pub timeout_ms: u64,
    /// NULL: the body goes to `on_data`. Otherwise the host appends it to this file.
    pub body_path: *const c_char,
}

/// Where the host reports a response, on the thread that called `http_request`, one call
/// at a time, before `http_request` returns. Each function returns 0 to continue; any
/// other value cancels the request.
#[repr(C)]
pub struct CapgoHttpSink {
    pub handle: *mut c_void,
    /// Status and response headers (JSON array of `[name, value]` pairs), before any body byte.
    pub on_head: Option<unsafe extern "C" fn(*mut c_void, i32, *const c_char) -> i32>,
    /// Body bytes (requests without `body_path`).
    pub on_data: Option<unsafe extern "C" fn(*mut c_void, *const u8, usize) -> i32>,
    /// Total body bytes appended to `body_path` so far.
    pub on_progress: Option<unsafe extern "C" fn(*mut c_void, u64) -> i32>,
}

type SinkFn<'a> = &'a mut dyn FnMut(HttpTransportEvent<'_>) -> bool;

/// `[["name","value"], ...]` from a host; anything else is skipped.
fn header_pairs(json: &str) -> Vec<(String, String)> {
    let Ok(serde_json::Value::Array(items)) = serde_json::from_str::<serde_json::Value>(json) else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|pair| Some((pair.get(0)?.as_str()?.to_string(), pair.get(1)?.as_str()?.to_string())))
        .collect()
}

/// Runs a sink callback; a panic cancels the request instead of unwinding into the host.
unsafe fn sink_call(handle: *mut c_void, event: HttpTransportEvent<'_>) -> i32 {
    if handle.is_null() {
        return 1;
    }
    let sink = &mut *(handle as *mut SinkFn<'_>);
    match catch_unwind(AssertUnwindSafe(|| sink(event))) {
        Ok(true) => 0,
        _ => 1,
    }
}

unsafe extern "C" fn sink_on_head(handle: *mut c_void, status: i32, headers_json: *const c_char) -> i32 {
    let headers = if headers_json.is_null() {
        Vec::new()
    } else {
        header_pairs(&CStr::from_ptr(headers_json).to_string_lossy())
    };
    let status = u16::try_from(status).unwrap_or(0);
    sink_call(handle, HttpTransportEvent::Head { status, headers })
}

unsafe extern "C" fn sink_on_data(handle: *mut c_void, data: *const u8, length: usize) -> i32 {
    if length == 0 {
        return 0;
    }
    if data.is_null() {
        return 1;
    }
    sink_call(
        handle,
        HttpTransportEvent::Data(std::slice::from_raw_parts(data, length)),
    )
}

unsafe extern "C" fn sink_on_progress(handle: *mut c_void, written: u64) -> i32 {
    sink_call(handle, HttpTransportEvent::Written(written))
}

/// Runs `f` with a C sink that forwards to `sink` (valid only during `f`).
pub(crate) fn with_c_sink<R>(
    sink: &mut dyn FnMut(HttpTransportEvent<'_>) -> bool,
    f: impl FnOnce(&CapgoHttpSink) -> R,
) -> R {
    let mut sink: SinkFn<'_> = sink;
    let c_sink = CapgoHttpSink {
        handle: &mut sink as *mut SinkFn<'_> as *mut c_void,
        on_head: Some(sink_on_head),
        on_data: Some(sink_on_data),
        on_progress: Some(sink_on_progress),
    };
    f(&c_sink)
}

#[cfg(feature = "jni")]
/// Calls a host sink function (JNI natives forward Java calls here). Returns 1 (cancel)
/// for a NULL sink or callback.
///
/// # Safety
/// `sink` must be NULL or the sink of an `http_request` call still running on this thread.
pub(crate) unsafe fn sink_head(sink: *const CapgoHttpSink, status: i32, headers_json: *const c_char) -> i32 {
    match sink.as_ref() {
        Some(CapgoHttpSink {
            handle,
            on_head: Some(on_head),
            ..
        }) => on_head(*handle, status, headers_json),
        _ => 1,
    }
}

#[cfg(feature = "jni")]
/// # Safety
/// See [`sink_head`]; `data` holds `length` bytes.
pub(crate) unsafe fn sink_data(sink: *const CapgoHttpSink, data: *const u8, length: usize) -> i32 {
    match sink.as_ref() {
        Some(CapgoHttpSink {
            handle,
            on_data: Some(on_data),
            ..
        }) => on_data(*handle, data, length),
        _ => 1,
    }
}

#[cfg(feature = "jni")]
/// # Safety
/// See [`sink_head`].
pub(crate) unsafe fn sink_progress(sink: *const CapgoHttpSink, written: u64) -> i32 {
    match sink.as_ref() {
        Some(CapgoHttpSink {
            handle,
            on_progress: Some(on_progress),
            ..
        }) => on_progress(*handle, written),
        _ => 1,
    }
}

/// The outcome of an `http_request` call: its return value and result JSON
/// (`{"protocol": ...}` or `{"error": kind, "message": ...}`).
pub(crate) fn transport_outcome(code: i32, reply: Option<&str>) -> HttpTransportOutcome {
    let reply: serde_json::Value = reply
        .and_then(|json| serde_json::from_str(json).ok())
        .unwrap_or(serde_json::Value::Null);
    let text = |key: &str| reply.get(key).and_then(serde_json::Value::as_str).map(str::to_string);
    match code {
        CAPGO_HTTP_UNAVAILABLE => HttpTransportOutcome::Unavailable,
        CAPGO_HTTP_COMPLETED => HttpTransportOutcome::Completed {
            protocol: text("protocol"),
        },
        _ => HttpTransportOutcome::Failed {
            kind: text("error").unwrap_or_else(|| "network".into()),
            message: text("message").unwrap_or_else(|| "HTTP request failed in the host".into()),
        },
    }
}

/// The request headers as the host gets them.
pub(crate) fn headers_json(headers: &[(String, String)]) -> String {
    serde_json::Value::Array(
        headers
            .iter()
            .map(|(name, value)| serde_json::json!([name, value]))
            .collect(),
    )
    .to_string()
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

    fn http_request(
        &self,
        request: &HttpTransportRequest<'_>,
        sink: &mut dyn FnMut(HttpTransportEvent<'_>) -> bool,
    ) -> HttpTransportOutcome {
        let Some(callback) = self.0.http_request else {
            return HttpTransportOutcome::Unavailable;
        };
        let method = c_string(request.method);
        let url = c_string(request.url);
        let headers = c_string(&headers_json(request.headers));
        let path = request.body_path.map(|path| c_string(&path.to_string_lossy()));
        let c_request = CapgoHttpRequest {
            method: method.as_ptr(),
            url: url.as_ptr(),
            headers_json: headers.as_ptr(),
            body: request.body.map_or(std::ptr::null(), <[u8]>::as_ptr),
            body_length: request.body.map_or(0, <[u8]>::len),
            timeout_ms: u64::try_from(request.timeout.as_millis()).unwrap_or(u64::MAX),
            body_path: path.as_ref().map_or(std::ptr::null(), |path| path.as_ptr()),
        };
        let mut result: *mut c_char = std::ptr::null_mut();
        let code = with_c_sink(sink, |c_sink| unsafe {
            callback(self.0.context, &c_request, c_sink, &mut result)
        });
        let reply = self.take_string(result);
        transport_outcome(code, reply.as_deref())
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
