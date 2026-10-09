//! The core under test, reached only through the C ABI of
//! `include/capgo_updater_core.h`.
//!
//! By default the tests drive this crate (its own `extern "C"` functions). Set
//! `CAPGO_CORE_LIB=/path/to/libcapgo_updater_core.{so,dylib}` to run the same
//! tests against another implementation of the header (built with its test
//! operations, `test.*`).

use std::ffi::{c_char, c_void, CStr, CString};
use std::fmt;
use std::sync::{Arc, OnceLock};

use capgo_updater_core::ffi::CapgoHostCallbacks;
use capgo_updater_core::host::{Host, LogLevel, RETAIN_EVENT_KEY};
use serde_json::{json, Value};

type CoreCall = unsafe extern "C" fn(*const c_char, *const c_char) -> *mut c_char;
type CoreFree = unsafe extern "C" fn(*mut c_char);
type EngineNew = unsafe extern "C" fn(*const c_char, CapgoHostCallbacks) -> *mut c_void;
type EngineCall = unsafe extern "C" fn(*const c_void, *const c_char, *const c_char) -> *mut c_char;
type EngineFree = unsafe extern "C" fn(*mut c_void);

/// The five functions of the C ABI.
pub struct Core {
    pub name: String,
    core_call: CoreCall,
    core_free: CoreFree,
    engine_new: EngineNew,
    engine_call: EngineCall,
    engine_free: EngineFree,
}

/// The core selected for this test run (`CAPGO_CORE_LIB` or this crate).
pub fn core() -> &'static Core {
    static CORE: OnceLock<Core> = OnceLock::new();
    CORE.get_or_init(|| match std::env::var("CAPGO_CORE_LIB") {
        Ok(path) if !path.is_empty() => unsafe {
            let library = libloading::Library::new(&path).unwrap_or_else(|error| panic!("load {path}: {error}"));
            // Loaded once for the whole run.
            let library: &'static libloading::Library = Box::leak(Box::new(library));
            let symbol = |name: &[u8]| -> *const c_void {
                *library
                    .get::<*const c_void>(name)
                    .unwrap_or_else(|error| panic!("{path}: {error}"))
            };
            Core {
                name: path.clone(),
                core_call: std::mem::transmute::<*const c_void, CoreCall>(symbol(b"capgo_core_call\0")),
                core_free: std::mem::transmute::<*const c_void, CoreFree>(symbol(b"capgo_core_free\0")),
                engine_new: std::mem::transmute::<*const c_void, EngineNew>(symbol(b"capgo_engine_new\0")),
                engine_call: std::mem::transmute::<*const c_void, EngineCall>(symbol(b"capgo_engine_call\0")),
                engine_free: std::mem::transmute::<*const c_void, EngineFree>(symbol(b"capgo_engine_free\0")),
            }
        },
        _ => {
            use capgo_updater_core::ffi;
            unsafe {
                Core {
                    name: "rust".into(),
                    core_call: ffi::capgo_core_call,
                    core_free: ffi::capgo_core_free,
                    engine_new: std::mem::transmute::<*const (), EngineNew>(ffi::capgo_engine_new as *const ()),
                    engine_call: std::mem::transmute::<*const (), EngineCall>(ffi::capgo_engine_call as *const ()),
                    engine_free: std::mem::transmute::<*const (), EngineFree>(ffi::capgo_engine_free as *const ()),
                }
            }
        }
    })
}

/// A failed operation: the envelope's `{code, message}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AbiError {
    pub code: String,
    pub message: String,
}

impl fmt::Display for AbiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for AbiError {}

pub type AbiResult<T> = Result<T, AbiError>;

fn c_string(value: &str) -> CString {
    CString::new(value).expect("no NUL in test strings")
}

impl Core {
    fn take(&self, raw: *mut c_char) -> String {
        assert!(!raw.is_null(), "{}: the core returned NULL", self.name);
        let text = unsafe { CStr::from_ptr(raw) }
            .to_str()
            .expect("UTF-8 output")
            .to_string();
        unsafe { (self.core_free)(raw) };
        text
    }

    /// `capgo_core_call` with raw text in and out.
    pub fn call_raw(&self, operation: &str, input: Option<&str>) -> String {
        let operation = c_string(operation);
        let input = input.map(c_string);
        let raw = unsafe {
            (self.core_call)(
                operation.as_ptr(),
                input.as_ref().map_or(std::ptr::null(), |input| input.as_ptr()),
            )
        };
        self.take(raw)
    }

    /// `capgo_core_call` with JSON; the envelope unwrapped.
    pub fn call(&self, operation: &str, input: &Value) -> AbiResult<Value> {
        unwrap_envelope(&self.call_raw(operation, Some(&input.to_string())))
    }

    /// A test operation (`test.<name>`), panicking on failure.
    pub fn test(&self, name: &str, input: Value) -> Value {
        self.call(&format!("test.{name}"), &input)
            .unwrap_or_else(|error| panic!("test.{name} failed: {error}"))
    }

    /// A test operation that may fail.
    pub fn try_test(&self, name: &str, input: Value) -> AbiResult<Value> {
        self.call(&format!("test.{name}"), &input)
    }
}

pub fn unwrap_envelope(text: &str) -> AbiResult<Value> {
    let envelope: Value = serde_json::from_str(text).unwrap_or_else(|error| panic!("bad envelope {text}: {error}"));
    if envelope["ok"] == true {
        Ok(envelope.get("value").cloned().unwrap_or(Value::Null))
    } else {
        Err(AbiError {
            code: envelope["error"]["code"].as_str().unwrap_or_default().to_string(),
            message: envelope["error"]["message"].as_str().unwrap_or_default().to_string(),
        })
    }
}

/// An engine created through `capgo_engine_new`. Thread-safe like the C ABI.
pub struct AbiEngine {
    raw: *mut c_void,
}

unsafe impl Send for AbiEngine {}
unsafe impl Sync for AbiEngine {}

impl AbiEngine {
    /// `capgo_engine_new` with `host` behind the C callbacks; `None` when the core refuses the config.
    pub fn new(host: Arc<dyn Host>, config: &Value) -> Option<Arc<Self>> {
        Self::with_callbacks(host_callbacks(host), config)
    }

    /// `capgo_engine_new` with hand-written callbacks.
    pub fn with_callbacks(callbacks: CapgoHostCallbacks, config: &Value) -> Option<Arc<Self>> {
        let config = c_string(&config.to_string());
        let raw = unsafe { (core().engine_new)(config.as_ptr(), callbacks) };
        (!raw.is_null()).then(|| Arc::new(Self { raw }))
    }

    pub fn call(&self, operation: &str, input: &Value) -> AbiResult<Value> {
        let operation = c_string(operation);
        let input = c_string(&input.to_string());
        let core = core();
        let raw = unsafe { (core.engine_call)(self.raw, operation.as_ptr(), input.as_ptr()) };
        unwrap_envelope(&core.take(raw))
    }

    /// `capgo_engine_call` with raw text in and out.
    pub fn call_raw(&self, operation: &str, input: Option<&str>) -> String {
        let operation = c_string(operation);
        let input = input.map(c_string);
        let core = core();
        let raw = unsafe {
            (core.engine_call)(
                self.raw,
                operation.as_ptr(),
                input.as_ref().map_or(std::ptr::null(), |input| input.as_ptr()),
            )
        };
        core.take(raw)
    }

    fn expect(&self, operation: &str, input: Value) -> Value {
        self.call(operation, &input)
            .unwrap_or_else(|error| panic!("{operation} failed: {error}"))
    }

    pub fn flush_stats(&self) {
        self.expect("statsFlush", json!({}));
    }

    pub fn pending_stats_count(&self) -> usize {
        self.expect("statsPendingCount", json!({}))["count"].as_u64().unwrap() as usize
    }

    pub fn wait_for_cleanup_for_tests(&self) {
        self.expect("test.waitForCleanup", json!({}));
    }

    pub fn fetch_json(&self, url: &str) -> AbiResult<Value> {
        self.call("test.fetchJson", &json!({ "url": url }))
    }
}

impl Drop for AbiEngine {
    fn drop(&mut self) {
        unsafe { (core().engine_free)(self.raw) };
    }
}

// ---------------------------------------------------------------------------
// A Rust `Host` behind the C callbacks, so tests keep scripting hosts in Rust.
// Host services that the C ABI carries as hooks (header: willSwitchBundle,
// cancelVersionDownload, ...) are routed to the matching `Host` methods.

struct Context(Arc<dyn Host>);

unsafe fn context<'a>(raw: *mut c_void) -> &'a Arc<dyn Host> {
    &(*(raw as *const Context)).0
}

unsafe fn text<'a>(raw: *const c_char) -> &'a str {
    if raw.is_null() {
        ""
    } else {
        CStr::from_ptr(raw).to_str().unwrap_or_default()
    }
}

fn owned(value: &str) -> *mut c_char {
    CString::new(value.replace('\0', "")).unwrap().into_raw()
}

unsafe extern "C" fn cb_log(raw: *mut c_void, level: i32, message: *const c_char) {
    let level = match level {
        0 => LogLevel::Debug,
        1 => LogLevel::Info,
        2 => LogLevel::Warn,
        _ => LogLevel::Error,
    };
    context(raw).log(level, text(message));
}

unsafe extern "C" fn cb_kv_get(raw: *mut c_void, key: *const c_char) -> *mut c_char {
    context(raw)
        .kv_get(text(key), None)
        .map_or(std::ptr::null_mut(), |value| owned(&value))
}

unsafe extern "C" fn cb_kv_set(raw: *mut c_void, key: *const c_char, value: *const c_char) {
    let value = (!value.is_null()).then(|| text(value));
    context(raw).kv_set(text(key), value);
}

unsafe extern "C" fn cb_kv_keys(raw: *mut c_void) -> *mut c_char {
    owned(&Value::from(context(raw).kv_keys()).to_string())
}

unsafe extern "C" fn cb_emit(raw: *mut c_void, event: *const c_char, payload: *const c_char) {
    let host = context(raw);
    let mut payload: Value = serde_json::from_str(text(payload)).unwrap_or(Value::Null);
    let retained = payload
        .as_object_mut()
        .and_then(|object| object.remove(RETAIN_EVENT_KEY))
        .is_some_and(|flag| flag == true);
    if retained {
        host.emit_retained(text(event), &payload);
    } else {
        host.emit(text(event), &payload);
    }
}

unsafe extern "C" fn cb_free_string(_: *mut c_void, value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

unsafe extern "C" fn cb_hook(raw: *mut c_void, name: *const c_char, payload: *const c_char) -> *mut c_char {
    let host = context(raw);
    let payload: Value = serde_json::from_str(text(payload)).unwrap_or(Value::Null);
    let str_arg = |key: &str| payload.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
    let reply = match text(name) {
        "willSwitchBundle" => {
            host.will_switch_bundle(&str_arg("path"));
            None
        }
        "cancelVersionDownload" => Some(json!({ "cancelled": host.cancel_version_download(&str_arg("version")) })),
        "beforeDownload" => host.before_download().err().map(|error| json!({ "error": error })),
        "cancelAllDownloads" => {
            host.cancel_all_downloads();
            None
        }
        "sendStats" => Some(json!({
            "handled": host.send_stats(&str_arg("action"), &str_arg("versionName"), &str_arg("oldVersionName"))
        })),
        "cleartextPermitted" => host
            .cleartext_permitted(&str_arg("host"))
            .map(|permitted| json!({ "permitted": permitted })),
        name => host.hook(name, &payload),
    };
    reply.map_or(std::ptr::null_mut(), |reply| owned(&reply.to_string()))
}

unsafe extern "C" fn cb_release(raw: *mut c_void) {
    drop(Box::from_raw(raw as *mut Context));
}

unsafe extern "C" fn cb_verify(
    raw: *mut c_void,
    server_name: *const c_char,
    certificates: *const *const u8,
    lengths: *const usize,
    count: usize,
    error: *mut *mut c_char,
) -> i32 {
    let chain: Vec<&[u8]> = (0..count)
        .map(|index| std::slice::from_raw_parts(*certificates.add(index), *lengths.add(index)))
        .collect();
    let (verdict, message) = match context(raw).verify_server_certificate(&chain, text(server_name)) {
        Some(Ok(())) => (1, None),
        Some(Err(message)) => (0, Some(message)),
        None => (0, Some("No certificate verifier".to_string())),
    };
    if let (Some(message), false) = (message, error.is_null()) {
        *error = owned(&message);
    }
    verdict
}

/// C callbacks backed by `host`; the engine releases them with `release`.
pub fn host_callbacks(host: Arc<dyn Host>) -> CapgoHostCallbacks {
    CapgoHostCallbacks {
        context: Box::into_raw(Box::new(Context(host))) as *mut c_void,
        log: Some(cb_log),
        kv_get: Some(cb_kv_get),
        kv_set: Some(cb_kv_set),
        kv_keys: Some(cb_kv_keys),
        emit: Some(cb_emit),
        free_string: Some(cb_free_string),
        hook: Some(cb_hook),
        release: Some(cb_release),
        verify_server_certificate: Some(cb_verify),
    }
}
