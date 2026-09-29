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
