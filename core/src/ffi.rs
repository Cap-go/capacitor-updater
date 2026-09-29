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
            CString::new(
                "{\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"NUL in output\"}}",
            )
            .unwrap()
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
pub unsafe extern "C" fn capgo_core_call(
    operation: *const c_char,
    input_json: *const c_char,
) -> *mut c_char {
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
