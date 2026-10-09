//! Stateless core operations for hosts (`capgo_core_call` / JNI `CapgoCoreNative.call`).
//!
//! Hosts call `call(operation, input)` with a JSON object and get a JSON
//! object back. Only `resolvePathInside` is exposed: the hosts resolve bundle
//! ids under the bundle root with it before touching the file system. Every
//! other rule runs inside the engine.

use serde_json::{json, Map, Value};

use crate::error::{CoreError, CoreResult};
use crate::paths;

fn req_str<'a>(input: &'a Value, key: &str) -> CoreResult<&'a str> {
    match input.get(key) {
        Some(Value::String(value)) => Ok(value),
        None | Some(Value::Null) => Err(CoreError::invalid_input(format!("`{key}` is required"))),
        Some(_) => Err(CoreError::invalid_input(format!("`{key}` must be a string"))),
    }
}

/// Runs one core operation.
pub fn call(operation: &str, input: &Value) -> CoreResult<Value> {
    let empty = Value::Object(Map::new());
    let input = if input.is_null() { &empty } else { input };
    if !input.is_object() {
        return Err(CoreError::invalid_input("input must be a JSON object"));
    }

    match operation {
        "resolvePathInside" => Ok(json!({
            "path": paths::resolve_path_inside(req_str(input, "base")?, req_str(input, "path")?)?
        })),
        #[cfg(feature = "test-support")]
        other if other.starts_with(crate::testing::PREFIX) => crate::testing::call(&other[crate::testing::PREFIX.len()..], input),
        other => Err(CoreError::new(
            "unknown_operation",
            format!("Unknown core operation: {other}"),
        )),
    }
}

/// Runs an operation from JSON text and always returns a JSON envelope:
/// `{"ok":true,"value":{...}}` or `{"ok":false,"error":{"code":"...","message":"..."}}`.
pub fn call_json(operation: &str, input_json: &str) -> String {
    let result = if input_json.trim().is_empty() {
        call(operation, &Value::Null)
    } else {
        serde_json::from_str::<Value>(input_json)
            .map_err(|error| CoreError::invalid_input(format!("Invalid JSON input: {error}")))
            .and_then(|input| call(operation, &input))
    };
    envelope(result)
}

pub fn envelope(result: CoreResult<Value>) -> String {
    match result {
        Ok(value) => json!({ "ok": true, "value": value }),
        Err(error) => {
            json!({ "ok": false, "error": { "code": error.code, "message": error.message } })
        }
    }
    .to_string()
}
