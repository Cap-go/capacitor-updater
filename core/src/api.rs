//! Language-neutral operation dispatch.
//!
//! Every host calls `call(operation, input)` with a JSON object and gets a
//! JSON object back. Operation names and payloads are the group names and
//! `input`/`expect` objects of the shared fixtures in `native-contract-tests/`.

use std::path::Path;

use serde_json::{json, Map, Value};

use crate::crypto::{self, DecryptOutcome, RsaPublicKey};
use crate::error::{CoreError, CoreResult};
use crate::text::{hex_decode, hex_encode};
use crate::{bundle, http, paths, policy};

fn field<'a>(input: &'a Value, key: &str) -> Option<&'a Value> {
    input.get(key).filter(|value| !value.is_null())
}

fn opt_str<'a>(input: &'a Value, key: &str) -> CoreResult<Option<&'a str>> {
    match field(input, key) {
        None => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        Some(_) => Err(CoreError::invalid_input(format!(
            "`{key}` must be a string"
        ))),
    }
}

fn req_str<'a>(input: &'a Value, key: &str) -> CoreResult<&'a str> {
    opt_str(input, key)?.ok_or_else(|| CoreError::invalid_input(format!("`{key}` is required")))
}

fn req_bool(input: &Value, key: &str) -> CoreResult<bool> {
    field(input, key)
        .and_then(Value::as_bool)
        .ok_or_else(|| CoreError::invalid_input(format!("`{key}` must be a boolean")))
}

fn opt_i64(input: &Value, key: &str) -> CoreResult<Option<i64>> {
    match field(input, key) {
        None => Ok(None),
        Some(value) => value
            .as_i64()
            .or_else(|| {
                value
                    .as_f64()
                    .filter(|v| v.fract() == 0.0)
                    .map(|v| v as i64)
            })
            .map(Some)
            .ok_or_else(|| CoreError::invalid_input(format!("`{key}` must be an integer"))),
    }
}

fn req_i64(input: &Value, key: &str) -> CoreResult<i64> {
    opt_i64(input, key)?.ok_or_else(|| CoreError::invalid_input(format!("`{key}` is required")))
}

/// Every operation understood by [`call`].
pub const OPERATIONS: &[&str] = &[
    "coreInfo",
    // update policy
    "periodCheckDelay",
    "autoUpdateMode",
    "legacyDirectUpdateAutoMode",
    "isDirectUpdateMode",
    "onLaunchDirectUpdateConsumption",
    "updateResponseKind",
    "shakeMenuGesture",
    "webViewErrorStatsAction",
    "launchDownloadReady",
    "foreignBundleReset",
    "clearPersistedDefaultChannel",
    "manifestConcurrency",
    "bundleStatus",
    // http
    "userAgent",
    "retryableHttpStatus",
    "contentRange",
    "zipResumePlan",
    "appendHttpBody",
    "rateLimitDeadline",
    "remoteError",
    // paths / security
    "pathTraversalSegment",
    "resolvePathInside",
    "manifestTargetPath",
    "builtinAssetPath",
    "safeCacheHash",
    "reusableCacheFile",
    "cacheFileName",
    "manifestPartialName",
    "shortPathKey",
    // crypto
    "sessionKeyValid",
    "keyId",
    "publicKeyValid",
    "checksumAlgorithm",
    "checksumFile",
    "decryptChecksum",
    "decryptFile",
    "rsaPublicDecrypt",
    "rsaUnpadSignature",
    "publicKeyInfo",
    "aesDecrypt",
    "aesDecryptFile",
];

fn aes_key_and_iv(input: &Value) -> CoreResult<([u8; 16], [u8; 16])> {
    let key: [u8; 16] = hex_decode(req_str(input, "keyHex")?)
        .and_then(|key| key.try_into().ok())
        .ok_or_else(|| CoreError::new("invalid_session_key", "AES key must be 16 bytes of hex"))?;
    let iv: [u8; 16] = hex_decode(req_str(input, "ivHex")?)
        .and_then(|iv| iv.try_into().ok())
        .ok_or_else(|| CoreError::new("invalid_iv", "IV must be 16 bytes of hex"))?;
    Ok((key, iv))
}

/// Runs one core operation.
pub fn call(operation: &str, input: &Value) -> CoreResult<Value> {
    let empty = Value::Object(Map::new());
    let input = if input.is_null() { &empty } else { input };
    if !input.is_object() {
        return Err(CoreError::invalid_input("input must be a JSON object"));
    }

    Ok(match operation {
        "coreInfo" => json!({ "version": crate::CORE_VERSION, "operations": OPERATIONS }),

        "periodCheckDelay" => json!({
            "normalizedSeconds": policy::normalized_period_check_delay_seconds(req_i64(input, "seconds")?)
        }),
        "autoUpdateMode" => {
            let mode = policy::normalized_auto_update_mode(opt_str(input, "mode")?);
            json!({
                "mode": mode,
                "enabled": policy::is_auto_update_mode_enabled(mode),
                "directUpdateMode": policy::direct_update_mode_for_auto_update_mode(mode),
                "setNextBundle": policy::should_auto_update_mode_set_next_bundle(mode),
            })
        }
        "legacyDirectUpdateAutoMode" => json!({
            "mode": policy::auto_update_mode_for_legacy_direct_update_mode(req_str(input, "directUpdateMode")?)
        }),
        "isDirectUpdateMode" => json!({
            "direct": policy::is_direct_update_mode(req_str(input, "directUpdateMode")?)
        }),
        "onLaunchDirectUpdateConsumption" => json!({
            "consume": policy::should_consume_on_launch_direct_update(
                req_str(input, "mode")?,
                req_bool(input, "plannedDirectUpdate")?,
            )
        }),
        "updateResponseKind" => json!({
            "kind": policy::normalized_update_response_kind(opt_str(input, "kind")?)
        }),
        "shakeMenuGesture" => {
            let value = opt_str(input, "value")?;
            json!({
                "gesture": policy::normalized_shake_menu_gesture(value),
                "supported": policy::is_supported_shake_menu_gesture(value),
            })
        }
        "webViewErrorStatsAction" => json!({
            "action": policy::stats_action_for_webview_error_type(opt_str(input, "type")?.unwrap_or_default())
        }),
        "launchDownloadReady" => {
            let success = req_bool(input, "success")?;
            json!({
                "notify": policy::should_notify_launch_download_ready(
                    req_bool(input, "awaitedByCaller")?,
                    success,
                    req_bool(input, "directInstall")?,
                    req_bool(input, "previewSession")?,
                ),
                "status": policy::launch_download_ready_status(success, req_bool(input, "setNext")?),
            })
        }
        "foreignBundleReset" => json!({
            "reset": policy::should_reset_for_foreign_bundle(
                opt_str(input, "bundlePath")?,
                req_bool(input, "isBuiltin")?,
                req_bool(input, "hasStoredBundleInfo")?,
            )
        }),
        "clearPersistedDefaultChannel" => json!({
            "clear": policy::should_clear_persisted_default_channel(
                req_bool(input, "persistDefaultChannelOnReinstall")?,
                req_bool(input, "resetWhenUpdate")?,
                req_bool(input, "nativeBuildVersionChanged")?,
                req_bool(input, "restoredReinstall")?,
            )
        }),
        "manifestConcurrency" => json!({
            "maxConcurrentFiles": policy::manifest_max_concurrent_files(req_i64(input, "processorCount")?)
        }),
        "bundleStatus" => json!({
            "status": bundle::parse_bundle_status(opt_str(input, "value")?)
        }),

        "userAgent" => json!({
            "userAgent": http::user_agent(
                opt_str(input, "appId")?.unwrap_or_default(),
                opt_str(input, "pluginVersion")?.unwrap_or_default(),
                opt_str(input, "versionOs")?.unwrap_or_default(),
                req_str(input, "platform")?,
            )
        }),
        "retryableHttpStatus" => json!({
            "retryable": http::is_retryable_http_status(req_i64(input, "status")?)
        }),
        "contentRange" => json!({
            "range": http::parse_content_range(opt_str(input, "header")?)
                .map(|range| json!({ "start": range.start, "end": range.end, "total": range.total }))
        }),
        "zipResumePlan" => {
            let plan = http::plan_zip_resume_write(
                req_i64(input, "responseCode")?,
                req_i64(input, "downloadedBytes")?,
                opt_str(input, "contentRange")?,
            )
            .map_err(|code| {
                CoreError::new(code, "Content-Range does not continue the partial download")
            })?;
            json!({ "responseCode": plan.response_code, "writeOffset": plan.write_offset })
        }
        "appendHttpBody" => json!({
            "append": http::should_append_http_body(req_i64(input, "statusCode")?, req_i64(input, "existingBytes")?)
        }),
        "rateLimitDeadline" => json!({
            "blockedUntilMs": http::rate_limit_blocked_until_ms(
                opt_str(input, "retryAfter")?,
                opt_str(input, "body")?,
                req_i64(input, "nowMs")?,
            )
        }),
        "remoteError" => {
            let (error, message) = http::parse_remote_error(opt_str(input, "body")?);
            json!({ "error": error, "message": message })
        }

        "pathTraversalSegment" => json!({
            "traversal": paths::contains_path_traversal_segment(req_str(input, "path")?)
        }),
        "resolvePathInside" => json!({
            "path": paths::resolve_path_inside(req_str(input, "base")?, req_str(input, "path")?)?
        }),
        "manifestTargetPath" => json!({
            "path": paths::resolve_manifest_target_path(req_str(input, "base")?, req_str(input, "fileName")?)?
        }),
        "builtinAssetPath" => json!({
            "assetPath": paths::builtin_asset_path(req_str(input, "fileName")?)?
        }),
        "safeCacheHash" => json!({ "safe": paths::is_safe_cache_hash(opt_str(input, "hash")?) }),
        "reusableCacheFile" => json!({
            "reusable": paths::is_reusable_cache_file(opt_str(input, "hash")?, opt_i64(input, "size")?)
        }),
        "cacheFileName" => json!({
            "name": paths::cache_file_name(req_str(input, "hash")?, req_str(input, "fileName")?)
        }),
        "manifestPartialName" => json!({
            "name": paths::manifest_partial_name(opt_str(input, "hash")?, opt_str(input, "fileName")?.unwrap_or_default())
        }),
        "shortPathKey" => json!({
            "key": crypto::checksum::short_path_key(opt_str(input, "value")?.unwrap_or_default())
        }),

        "sessionKeyValid" => {
            json!({ "valid": crypto::is_valid_session_key(opt_str(input, "sessionKey")?) })
        }
        "keyId" => {
            json!({ "keyId": crypto::key_id(opt_str(input, "publicKey")?.unwrap_or_default()) })
        }
        "publicKeyValid" => json!({
            "valid": RsaPublicKey::from_pem(opt_str(input, "publicKey")?.unwrap_or_default()).is_ok()
        }),
        "checksumAlgorithm" => json!({
            "algorithm": crypto::detect_checksum_algorithm(opt_str(input, "checksum")?.unwrap_or_default())
        }),
        "checksumFile" => json!({
            "checksum": crypto::checksum::sha256_file(Path::new(req_str(input, "path")?))?
        }),
        "decryptChecksum" => json!({
            "checksum": crypto::decrypt_checksum(
                opt_str(input, "checksum")?.unwrap_or_default(),
                opt_str(input, "publicKey")?.unwrap_or_default(),
            )?
        }),
        "decryptFile" => {
            let outcome = crypto::decrypt_bundle_file(
                Path::new(req_str(input, "path")?),
                opt_str(input, "publicKey")?.unwrap_or_default(),
                opt_str(input, "sessionKey")?,
            )?;
            json!({
                "outcome": match outcome {
                    DecryptOutcome::Decrypted => "decrypted",
                    DecryptOutcome::NotEncrypted => "notEncrypted",
                    DecryptOutcome::UnsupportedPublicKey => "unsupportedPublicKey",
                }
            })
        }
        "rsaPublicDecrypt" => {
            let key = RsaPublicKey::from_pem(req_str(input, "publicKey")?)?;
            let ciphertext = hex_decode(req_str(input, "ciphertextHex")?)
                .ok_or_else(|| CoreError::invalid_input("`ciphertextHex` must be hex"))?;
            json!({ "plaintextHex": hex_encode(&key.public_decrypt(&ciphertext)?) })
        }

        "rsaUnpadSignature" => {
            let block = hex_decode(req_str(input, "blockHex")?)
                .ok_or_else(|| CoreError::invalid_input("`blockHex` must be hex"))?;
            let block_size = opt_i64(input, "blockSize")?.unwrap_or(256);
            let payload = (block.len() as i64 == block_size)
                .then(|| crypto::rsa::unpad_type1(&block))
                .flatten()
                .ok_or_else(|| {
                    CoreError::new("decrypt_failed", "Invalid PKCS#1 signature padding")
                })?;
            json!({ "payloadHex": hex_encode(&payload) })
        }

        "publicKeyInfo" => {
            use base64::Engine;
            let key = RsaPublicKey::from_pem(req_str(input, "publicKey")?)?;
            json!({
                "modulusBits": key.modulus_bits(),
                "spkiDerBase64": base64::engine::general_purpose::STANDARD.encode(key.to_spki_der()),
            })
        }
        "aesDecrypt" => {
            let (key, iv) = aes_key_and_iv(input)?;
            let ciphertext = hex_decode(req_str(input, "ciphertextHex")?)
                .ok_or_else(|| CoreError::invalid_input("`ciphertextHex` must be hex"))?;
            json!({ "plaintextHex": hex_encode(&crypto::aes_cbc::decrypt(&ciphertext, &key, &iv)?) })
        }
        "aesDecryptFile" => {
            let (key, iv) = aes_key_and_iv(input)?;
            crypto::aes_cbc::decrypt_file_in_place(Path::new(req_str(input, "path")?), &key, &iv)?;
            json!({})
        }

        other => {
            return Err(CoreError::new(
                "unknown_operation",
                format!("Unknown core operation: {other}"),
            ))
        }
    })
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
