//! JNI entry point for `ee.forgr.capacitor_updater.CapgoCoreNative`.

use jni::objects::{JClass, JString};
use jni::sys::jstring;
use jni::JNIEnv;
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::api;
use crate::error::CoreError;

fn read(env: &mut JNIEnv, value: &JString) -> Result<String, CoreError> {
    if value.is_null() {
        return Ok(String::new());
    }
    env.get_string(value)
        .map(Into::into)
        .map_err(|error| CoreError::invalid_input(format!("Invalid Java string: {error}")))
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
    env.new_string(output)
        .map(|value| value.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

// ---------------------------------------------------------------------------
// Engine handle with a Java host (`CapgoEngineHost`).

use std::sync::Arc;

use jni::objects::{GlobalRef, JObject, JValue};
use jni::sys::jlong;
use jni::JavaVM;

use crate::engine::Engine;
use crate::host::{Host, LogLevel};

struct JniHost {
    vm: JavaVM,
    host: GlobalRef,
}

impl JniHost {
    fn with_env<R>(&self, f: impl FnOnce(&mut JNIEnv) -> jni::errors::Result<R>) -> Option<R> {
        let mut env = self.vm.attach_current_thread().ok()?;
        let result = f(&mut env);
        if env.exception_check().unwrap_or(false) {
            let _ = env.exception_describe();
            let _ = env.exception_clear();
            return None;
        }
        result.ok()
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
                env.set_object_array_element(&certificates, index as i32, bytes)?;
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
    env.new_string(output)
        .map(|value| value.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

/// `static native void engineDestroy(long engine)`
#[no_mangle]
pub extern "system" fn Java_ee_forgr_capacitor_1updater_CapgoCoreNative_engineDestroy<'local>(
    _env: JNIEnv<'local>,
    _class: JClass<'local>,
    engine: jlong,
) {
    if engine != 0 {
        drop(unsafe { Arc::from_raw(engine as *const Engine) });
    }
}
