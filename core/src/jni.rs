//! JNI entry point for `ee.forgr.capacitor_updater.CapgoCoreNative`.

use jni::objects::{JClass, JString};
use jni::sys::jstring;
use jni::JNIEnv;
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::api;
use crate::error::CoreError;

/// Clears a pending Java exception (an OutOfMemoryError from a failed JNI call): calling
/// Java with one pending aborts under CheckJNI and is undefined otherwise.
fn clear_exception(env: &mut JNIEnv) {
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_describe();
        let _ = env.exception_clear();
    }
}

fn read(env: &mut JNIEnv, value: &JString) -> Result<String, CoreError> {
    if value.is_null() {
        return Ok(String::new());
    }
    env.get_string(value).map(Into::into).map_err(|error| {
        clear_exception(env);
        CoreError::invalid_input(format!("Invalid Java string: {error}"))
    })
}

/// The result string for Java, or null (Java reports "no result") when it cannot be made.
fn java_string(env: &mut JNIEnv, output: String) -> jstring {
    clear_exception(env);
    match env.new_string(output) {
        Ok(value) => value.into_raw(),
        Err(_) => {
            clear_exception(env);
            std::ptr::null_mut()
        }
    }
}

/// `static native String call(String operation, String inputJson)`
#[no_mangle]
pub extern "system" fn Java_ee_forgr_capacitor_1updater_CapgoCoreNative_call<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    operation: JString<'local>,
    input_json: JString<'local>,
) -> jstring {
    let output = catch_unwind(AssertUnwindSafe(|| {
        let operation = match read(&mut env, &operation) {
            Ok(value) => value,
            Err(error) => return api::envelope(Err(error)),
        };
        match read(&mut env, &input_json) {
            Ok(input) => api::call_json(&operation, &input),
            Err(error) => api::envelope(Err(error)),
        }
    }))
    .unwrap_or_else(|_| api::envelope(Err(CoreError::new("internal", "Core operation panicked"))));
    java_string(&mut env, output)
}

// ---------------------------------------------------------------------------
// Engine handle with a Java host (`CapgoEngineHost`).

use std::sync::Arc;

use jni::objects::{GlobalRef, JByteBuffer, JObject, JValue};
use jni::sys::{jint, jlong};
use jni::JavaVM;

use crate::engine::Engine;
use crate::host::{Host, HttpTransportEvent, HttpTransportOutcome, HttpTransportRequest, LogLevel};

struct JniHost {
    vm: JavaVM,
    host: GlobalRef,
}

impl JniHost {
    fn with_env<R>(&self, f: impl FnOnce(&mut JNIEnv) -> jni::errors::Result<R>) -> Option<R> {
        let mut env = self.vm.attach_current_thread().ok()?;
        // A local frame frees this callback's local references when it returns. On a Java
        // thread that called into the engine they would otherwise pile up until that call
        // returns, and Android 7 (API 24/25) aborts the process past 512 of them.
        let frame = env.with_local_frame(16, |env| {
            // A panic must not skip the frame pop: it is caught here and resumed after it.
            let result = catch_unwind(AssertUnwindSafe(|| f(env)));
            if env.exception_check().unwrap_or(false) {
                let _ = env.exception_describe();
                let _ = env.exception_clear();
                return Ok(result.map(|_| None));
            }
            Ok::<_, jni::errors::Error>(result.map(Result::ok))
        });
        match frame {
            Ok(Ok(value)) => value,
            Ok(Err(panic)) => std::panic::resume_unwind(panic),
            // The frame could not be pushed (out of memory): its exception is still pending.
            Err(_) => {
                clear_exception(&mut env);
                None
            }
        }
    }

    fn string_arg<'a>(env: &mut JNIEnv<'a>, value: &str) -> jni::errors::Result<JObject<'a>> {
        Ok(JObject::from(env.new_string(value)?))
    }
}

impl Host for JniHost {
    fn log(&self, level: LogLevel, message: &str) {
        self.with_env(|env| {
            let message = Self::string_arg(env, message)?;
            env.call_method(
                self.host.as_obj(),
                "log",
                "(ILjava/lang/String;)V",
                &[JValue::Int(level as i32), JValue::Object(&message)],
            )?;
            Ok(())
        });
    }

    fn kv_get(&self, key: &str, default: Option<&str>) -> Option<String> {
        self.with_env(|env| {
            let key = Self::string_arg(env, key)?;
            let default = match default {
                Some(default) => Self::string_arg(env, default)?,
                None => JObject::null(),
            };
            let value = env
                .call_method(
                    self.host.as_obj(),
                    "kvGet",
                    "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
                    &[JValue::Object(&key), JValue::Object(&default)],
                )?
                .l()?;
            if value.is_null() {
                return Ok(None);
            }
            Ok(Some(env.get_string(&JString::from(value))?.into()))
        })
        .flatten()
    }

    fn kv_set(&self, key: &str, value: Option<&str>) {
        self.with_env(|env| {
            let key = Self::string_arg(env, key)?;
            let value = match value {
                Some(value) => Self::string_arg(env, value)?,
                None => JObject::null(),
            };
            env.call_method(
                self.host.as_obj(),
                "kvSet",
                "(Ljava/lang/String;Ljava/lang/String;)V",
                &[JValue::Object(&key), JValue::Object(&value)],
            )?;
            Ok(())
        });
    }

    fn kv_contains(&self, key: &str) -> bool {
        self.with_env(|env| {
            let key = Self::string_arg(env, key)?;
            env.call_method(
                self.host.as_obj(),
                "kvContains",
                "(Ljava/lang/String;)Z",
                &[JValue::Object(&key)],
            )?
            .z()
        })
        .unwrap_or(false)
    }

    fn kv_keys(&self) -> Vec<String> {
        self.with_env(|env| {
            let keys = env
                .call_method(self.host.as_obj(), "kvKeysJson", "()Ljava/lang/String;", &[])?
                .l()?;
            if keys.is_null() {
                return Ok(Vec::new());
            }
            let json: String = env.get_string(&JString::from(keys))?.into();
            Ok(serde_json::from_str(&json).unwrap_or_default())
        })
        .unwrap_or_default()
    }

    fn emit(&self, event: &str, payload: &serde_json::Value) {
        self.with_env(|env| {
            let event = Self::string_arg(env, event)?;
            let payload = Self::string_arg(env, &payload.to_string())?;
            env.call_method(
                self.host.as_obj(),
                "emit",
                "(Ljava/lang/String;Ljava/lang/String;)V",
                &[JValue::Object(&event), JValue::Object(&payload)],
            )?;
            Ok(())
        });
    }

    fn hook(&self, name: &str, payload: &serde_json::Value) -> Option<serde_json::Value> {
        self.with_env(|env| {
            let name = Self::string_arg(env, name)?;
            let payload = Self::string_arg(env, &payload.to_string())?;
            let value = env
                .call_method(
                    self.host.as_obj(),
                    "hook",
                    "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
                    &[JValue::Object(&name), JValue::Object(&payload)],
                )?
                .l()?;
            if value.is_null() {
                return Ok(None);
            }
            let reply: String = env.get_string(&JString::from(value))?.into();
            Ok(serde_json::from_str(&reply).ok())
        })
        .flatten()
    }

    fn will_switch_bundle(&self, path: &str) {
        self.with_env(|env| {
            let path = Self::string_arg(env, path)?;
            env.call_method(
                self.host.as_obj(),
                "willSwitchBundle",
                "(Ljava/lang/String;)V",
                &[JValue::Object(&path)],
            )?;
            Ok(())
        });
    }

    fn cancel_version_download(&self, version: &str) -> bool {
        self.with_env(|env| {
            let version = Self::string_arg(env, version)?;
            env.call_method(
                self.host.as_obj(),
                "cancelVersionDownload",
                "(Ljava/lang/String;)Z",
                &[JValue::Object(&version)],
            )?
            .z()
        })
        .unwrap_or(false)
    }

    fn before_download(&self) -> Result<(), String> {
        let error = self.with_env(|env| {
            let value = env
                .call_method(self.host.as_obj(), "beforeDownload", "()Ljava/lang/String;", &[])?
                .l()?;
            if value.is_null() {
                return Ok(None);
            }
            Ok(Some(env.get_string(&JString::from(value))?.into()))
        });
        match error {
            Some(None) => Ok(()),
            Some(Some(message)) => Err(message),
            None => Err("Download gate failed".to_string()),
        }
    }

    fn cancel_all_downloads(&self) {
        self.with_env(|env| {
            env.call_method(self.host.as_obj(), "cancelAllDownloads", "()V", &[])?;
            Ok(())
        });
    }

    fn verify_server_certificate(&self, chain: &[&[u8]], server_name: &str) -> Option<Result<(), String>> {
        let verdict = self.with_env(|env| {
            let byte_array_class = env.find_class("[B")?;
            let certificates = env.new_object_array(chain.len() as i32, byte_array_class, JObject::null())?;
            for (index, der) in chain.iter().enumerate() {
                let bytes = env.byte_array_from_slice(der)?;
                env.set_object_array_element(&certificates, index as i32, &bytes)?;
                // One local reference per certificate would overflow Android 7's 512 limit.
                env.delete_local_ref(bytes)?;
            }
            let server_name = Self::string_arg(env, server_name)?;
            let error = env
                .call_method(
                    self.host.as_obj(),
                    "verifyServerCertificate",
                    "([[BLjava/lang/String;)Ljava/lang/String;",
                    &[JValue::Object(&certificates), JValue::Object(&server_name)],
                )?
                .l()?;
            if error.is_null() {
                return Ok(Ok(()));
            }
            Ok(Err(env.get_string(&JString::from(error))?.into()))
        });
        Some(verdict.unwrap_or_else(|| Err("Certificate verification failed in host".to_string())))
    }

    /// `String httpRequest(String method, String url, String headersJson, byte[] body,
    /// long timeoutMs, String bodyPath, long sink)`: null when the host has no transport,
    /// else the result JSON. Java reports the response through `CapgoCoreNative.httpHead`,
    /// `httpData` and `httpProgress` with `sink`, on this thread.
    fn http_request(
        &self,
        request: &HttpTransportRequest<'_>,
        sink: &mut dyn FnMut(HttpTransportEvent<'_>) -> bool,
    ) -> HttpTransportOutcome {
        let reply = crate::ffi::with_c_sink(sink, |c_sink| {
            let sink_handle = c_sink as *const crate::ffi::CapgoHttpSink as jlong;
            self.with_env(|env| {
                let method = Self::string_arg(env, request.method)?;
                let url = Self::string_arg(env, request.url)?;
                let headers = Self::string_arg(env, &crate::ffi::headers_json(request.headers))?;
                let body = match request.body {
                    Some(body) => JObject::from(env.byte_array_from_slice(body)?),
                    None => JObject::null(),
                };
                let path = match request.body_path {
                    Some(path) => Self::string_arg(env, &path.to_string_lossy())?,
                    None => JObject::null(),
                };
                let timeout = i64::try_from(request.timeout.as_millis()).unwrap_or(i64::MAX);
                let value = env
                    .call_method(
                        self.host.as_obj(),
                        "httpRequest",
                        "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;[BJLjava/lang/String;J)Ljava/lang/String;",
                        &[
                            JValue::Object(&method),
                            JValue::Object(&url),
                            JValue::Object(&headers),
                            JValue::Object(&body),
                            JValue::Long(timeout),
                            JValue::Object(&path),
                            JValue::Long(sink_handle),
                        ],
                    )?
                    .l()?;
                if value.is_null() {
                    return Ok(None);
                }
                let json: String = env.get_string(&JString::from(value))?.into();
                Ok(Some(json))
            })
        });
        match reply {
            Some(None) => HttpTransportOutcome::Unavailable,
            Some(Some(json)) => {
                let failed = serde_json::from_str::<serde_json::Value>(&json)
                    .map(|reply| reply.get("error").is_some())
                    .unwrap_or(true);
                let code = if failed {
                    crate::ffi::CAPGO_HTTP_FAILED
                } else {
                    crate::ffi::CAPGO_HTTP_COMPLETED
                };
                crate::ffi::transport_outcome(code, Some(&json))
            }
            None => HttpTransportOutcome::Failed {
                kind: "network".into(),
                message: "HTTP request failed in host".into(),
            },
        }
    }
}

/// `static native int httpHead(long sink, int status, String headersJson)`
#[no_mangle]
pub extern "system" fn Java_ee_forgr_capacitor_1updater_CapgoCoreNative_httpHead<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    sink: jlong,
    status: jint,
    headers_json: JString<'local>,
) -> jint {
    let Ok(headers) = read(&mut env, &headers_json) else {
        return 1;
    };
    let headers = std::ffi::CString::new(headers.replace('\0', "")).unwrap_or_default();
    catch_unwind(AssertUnwindSafe(|| unsafe {
        crate::ffi::sink_head(sink as *const crate::ffi::CapgoHttpSink, status, headers.as_ptr())
    }))
    .unwrap_or(1)
}

/// `static native int httpData(long sink, ByteBuffer buffer, int offset, int length)`; the
/// buffer must be direct.
#[no_mangle]
pub extern "system" fn Java_ee_forgr_capacitor_1updater_CapgoCoreNative_httpData<'local>(
    env: JNIEnv<'local>,
    _class: JClass<'local>,
    sink: jlong,
    buffer: JByteBuffer<'local>,
    offset: jint,
    length: jint,
) -> jint {
    let (Ok(offset), Ok(length)) = (usize::try_from(offset), usize::try_from(length)) else {
        return 1;
    };
    let (Ok(address), Ok(capacity)) = (
        env.get_direct_buffer_address(&buffer),
        env.get_direct_buffer_capacity(&buffer),
    ) else {
        return 1;
    };
    if address.is_null() || offset.checked_add(length).map_or(true, |end| end > capacity) {
        return 1;
    }
    catch_unwind(AssertUnwindSafe(|| unsafe {
        crate::ffi::sink_data(sink as *const crate::ffi::CapgoHttpSink, address.add(offset), length)
    }))
    .unwrap_or(1)
}

/// `static native int httpProgress(long sink, long written)`
#[no_mangle]
pub extern "system" fn Java_ee_forgr_capacitor_1updater_CapgoCoreNative_httpProgress<'local>(
    _env: JNIEnv<'local>,
    _class: JClass<'local>,
    sink: jlong,
    written: jlong,
) -> jint {
    let Ok(written) = u64::try_from(written) else {
        return 1;
    };
    catch_unwind(AssertUnwindSafe(|| unsafe {
        crate::ffi::sink_progress(sink as *const crate::ffi::CapgoHttpSink, written)
    }))
    .unwrap_or(1)
}

/// `static native long create(String configJson, CapgoEngineHost host)`; 0 on failure.
#[no_mangle]
pub extern "system" fn Java_ee_forgr_capacitor_1updater_CapgoCoreNative_engineCreate<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    config_json: JString<'local>,
    host: JObject<'local>,
) -> jlong {
    let Ok(vm) = env.get_java_vm() else {
        return 0;
    };
    let Ok(host) = env.new_global_ref(host) else {
        return 0;
    };
    let host: Arc<dyn Host> = Arc::new(JniHost { vm, host });
    let config = match read(&mut env, &config_json) {
        Ok(config) => config,
        Err(error) => {
            host.log(LogLevel::Error, &format!("Capgo engine init failed: {error}"));
            return 0;
        }
    };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let config: serde_json::Value = if config.trim().is_empty() {
            serde_json::Value::Null
        } else {
            serde_json::from_str(&config)
                .map_err(|error| CoreError::invalid_input(format!("Invalid engine config: {error}")))?
        };
        Engine::new(host.clone(), &config)
    }));
    match result {
        Ok(Ok(engine)) => Arc::into_raw(engine) as jlong,
        Ok(Err(error)) => {
            host.log(LogLevel::Error, &format!("Capgo engine init failed: {error}"));
            0
        }
        Err(_) => 0,
    }
}

/// `static native String engineCall(long engine, String operation, String inputJson)`
#[no_mangle]
pub extern "system" fn Java_ee_forgr_capacitor_1updater_CapgoCoreNative_engineCall<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    engine: jlong,
    operation: JString<'local>,
    input_json: JString<'local>,
) -> jstring {
    let output = catch_unwind(AssertUnwindSafe(|| {
        let Some(engine) = (unsafe { (engine as *const Engine).as_ref() }) else {
            return api::envelope(Err(CoreError::invalid_input("Engine handle is 0")));
        };
        let operation = match read(&mut env, &operation) {
            Ok(value) => value,
            Err(error) => return api::envelope(Err(error)),
        };
        match read(&mut env, &input_json) {
            Ok(input) => engine.call_json(&operation, &input),
            Err(error) => api::envelope(Err(error)),
        }
    }))
    .unwrap_or_else(|_| api::envelope(Err(CoreError::new("internal", "Engine operation panicked"))));
    java_string(&mut env, output)
}

/// `static native void engineDestroy(long engine)`
#[no_mangle]
pub extern "system" fn Java_ee_forgr_capacitor_1updater_CapgoCoreNative_engineDestroy<'local>(
    _env: JNIEnv<'local>,
    _class: JClass<'local>,
    engine: jlong,
) {
    if engine != 0 {
        // A panic unwinding out of a JNI function aborts the process.
        let engine = unsafe { Arc::from_raw(engine as *const Engine) };
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || drop(engine)));
    }
}
