//! Test-only operations (`test.<name>`), built with the `test-support` feature.
//!
//! The test suite drives a core only through the C ABI, so the same tests run
//! against any implementation of `include/capgo_updater_core.h` (set
//! `CAPGO_CORE_LIB` to its shared library). Rules that are not reachable from
//! the engine operations (the contract fixture groups, archive and crypto
//! primitives, the HTTP client) are exposed here. Shipped builds never contain
//! these operations.

use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};

use crate::crypto::{self, aes_cbc, RsaPublicKey};
use crate::engine::archive::{extract_zip, install_extracted, ExtractError};
use crate::engine::Engine;
use crate::error::{CoreError, CoreResult};
use crate::host::HttpProxy;
use crate::net::{Http, NetError, NetErrorKind, Stream};
use crate::text::{hex_decode, hex_encode};
use crate::{bundle, http, paths, policy};

pub const PREFIX: &str = "test.";

fn bad(message: impl Into<String>) -> CoreError {
    CoreError::invalid_input(message)
}

fn opt_str<'a>(input: &'a Value, key: &str) -> CoreResult<Option<&'a str>> {
    match input.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        Some(other) => Err(bad(format!("`{key}` must be a string, got {other}"))),
    }
}

fn str_or_empty<'a>(input: &'a Value, key: &str) -> CoreResult<&'a str> {
    Ok(opt_str(input, key)?.unwrap_or_default())
}

fn req_str<'a>(input: &'a Value, key: &str) -> CoreResult<&'a str> {
    opt_str(input, key)?.ok_or_else(|| bad(format!("`{key}` is required")))
}

fn req_bool(input: &Value, key: &str) -> CoreResult<bool> {
    input[key]
        .as_bool()
        .ok_or_else(|| bad(format!("`{key}` must be a boolean")))
}

fn opt_i64(input: &Value, key: &str) -> CoreResult<Option<i64>> {
    match input.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_i64()
            .or_else(|| value.as_f64().filter(|v| v.fract() == 0.0).map(|v| v as i64))
            .map(Some)
            .ok_or_else(|| bad(format!("`{key}` must be an integer"))),
    }
}

fn req_i64(input: &Value, key: &str) -> CoreResult<i64> {
    opt_i64(input, key)?.ok_or_else(|| bad(format!("`{key}` is required")))
}

fn hex(input: &Value, key: &str) -> CoreResult<Vec<u8>> {
    hex_decode(req_str(input, key)?).ok_or_else(|| bad(format!("`{key}` must be hex")))
}

fn block16(input: &Value, key: &str) -> CoreResult<[u8; 16]> {
    hex(input, key)?
        .try_into()
        .map_err(|_| bad(format!("`{key}` must be 16 bytes")))
}

fn extract_error(error: ExtractError) -> CoreError {
    match error {
        ExtractError::WindowsPath(name) => CoreError::new("windows_path", name),
        ExtractError::PathEscape(name) => CoreError::new("path_escape", name),
        ExtractError::Directory(name) => CoreError::new("directory", name),
        ExtractError::Failed(message) => CoreError::new("failed", message),
        ExtractError::Cancelled => CoreError::new("cancelled", ""),
    }
}

pub(crate) fn net_error(error: NetError) -> CoreError {
    let code = match error.kind {
        NetErrorKind::Timeout => "timeout",
        NetErrorKind::Network => "network",
        NetErrorKind::Tls => "tls",
        NetErrorKind::InvalidUrl => "invalid_url",
        NetErrorKind::InsecureRedirect => "insecure_redirect",
        NetErrorKind::Io => "io",
    };
    CoreError::new(code, error.message)
}

/// Stateless test operations (`capgo_core_call("test.<name>", ...)`). `name` is a
/// contract fixture group or one of the primitives below.
pub fn call(name: &str, input: &Value) -> CoreResult<Value> {
    Ok(match name {
        // ---- contract fixture groups (native-contract-tests/*.json)
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
        "onLaunchDirectUpdateConsumption" => json!({
            "consume": policy::should_consume_on_launch_direct_update(
                req_str(input, "mode")?,
                req_bool(input, "plannedDirectUpdate")?,
            )
        }),
        "updateResponseKind" => json!({
            "kind": policy::normalized_update_response_kind(opt_str(input, "kind")?)
        }),
        "shakeMenuGesture" => json!({
            "gesture": policy::normalized_shake_menu_gesture(opt_str(input, "value")?)
        }),
        "webViewErrorStatsAction" => json!({
            "action": policy::stats_action_for_webview_error_type(str_or_empty(input, "type")?)
        }),
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
        "bundleStatus" => json!({ "status": bundle::parse_bundle_status(opt_str(input, "value")?) }),
        "userAgent" => json!({
            "userAgent": http::user_agent(
                str_or_empty(input, "appId")?,
                str_or_empty(input, "pluginVersion")?,
                str_or_empty(input, "versionOs")?,
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
            .map_err(|code| CoreError::new(code, code))?;
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
        "manifestPartialName" => json!({
            "name": paths::manifest_partial_name(opt_str(input, "hash")?, str_or_empty(input, "fileName")?)
        }),
        "shortPathKey" => json!({
            "key": crypto::checksum::short_path_key(str_or_empty(input, "value")?)
        }),
        "sessionKeyValid" => json!({ "valid": crypto::is_valid_session_key(opt_str(input, "sessionKey")?) }),
        "keyId" => json!({ "keyId": crypto::key_id(str_or_empty(input, "publicKey")?) }),
        "publicKeyValid" => json!({
            "valid": RsaPublicKey::from_pem(str_or_empty(input, "publicKey")?).is_ok()
        }),
        "checksumFile" => {
            let content = hex(input, "contentHex")?;
            let repeat = opt_i64(input, "repeat")?.unwrap_or(1) as usize;
            let path = Path::new(req_str(input, "tempDir")?).join("checksum.bin");
            fs::write(&path, content.repeat(repeat)).map_err(|error| CoreError::io("write", error))?;
            json!({ "checksum": crypto::checksum::sha256_file(&path)? })
        }
        "decryptChecksum" => json!({
            "checksum": crypto::decrypt_checksum(str_or_empty(input, "checksum")?, str_or_empty(input, "publicKey")?)?
        }),
        // What download.rs runs on a zip: session key, then in-place AES-CBC decryption.
        "decryptFile" => {
            let path = Path::new(req_str(input, "tempDir")?).join("bundle.zip");
            fs::write(&path, hex(input, "ciphertextHex")?).map_err(|error| CoreError::io("write", error))?;
            let session =
                crypto::bundle_session_key(str_or_empty(input, "publicKey")?, str_or_empty(input, "sessionKey")?)?;
            if let Some(session) = session {
                aes_cbc::decrypt_file_in_place_hashed(&path, &session.key, &session.iv)?;
            }
            json!({ "plaintextHex": hex_encode(&fs::read(&path).map_err(|error| CoreError::io("read", error))?) })
        }
        "rsaPublicDecrypt" => {
            let key = RsaPublicKey::from_pem(req_str(input, "publicKey")?)?;
            json!({ "plaintextHex": hex_encode(&key.public_decrypt(&hex(input, "ciphertextHex")?)?) })
        }

        // ---- primitives
        "rsaKeyFromDer" => json!({ "valid": RsaPublicKey::from_der(&hex(input, "derHex")?).is_ok() }),
        "rsaPublicOp" => {
            let key = RsaPublicKey::from_der(&hex(input, "derHex")?)?;
            json!({ "outputHex": hex_encode(&key.public_op(&hex(input, "inputHex")?)?) })
        }
        "rsaUnpadType1" => json!({
            "payloadHex": crypto::rsa::unpad_type1(&hex(input, "blockHex")?).map(|payload| hex_encode(&payload))
        }),
        "sessionKey" => {
            let session =
                crypto::bundle_session_key(str_or_empty(input, "publicKey")?, str_or_empty(input, "sessionKey")?)?;
            json!({ "session": session.map(|s| json!({ "keyHex": hex_encode(&s.key), "ivHex": hex_encode(&s.iv) })) })
        }
        // Streaming AES-128-CBC with PKCS#7: `chunkSize` bytes per update.
        "aesCbcDecrypt" => {
            let ciphertext = hex(input, "ciphertextHex")?;
            let chunk = opt_i64(input, "chunkSize")?
                .unwrap_or(ciphertext.len().max(1) as i64)
                .max(1) as usize;
            let mut decryptor = aes_cbc::CbcDecryptor::new(&block16(input, "keyHex")?, &block16(input, "ivHex")?);
            let mut out = Vec::new();
            for part in ciphertext.chunks(chunk) {
                decryptor.update(part, &mut out);
            }
            decryptor.finish(&mut out)?;
            json!({ "plaintextHex": hex_encode(&out) })
        }
        "decryptFileInPlace" => json!({
            "hash": aes_cbc::decrypt_file_in_place_hashed(
                Path::new(req_str(input, "path")?),
                &block16(input, "keyHex")?,
                &block16(input, "ivHex")?,
            )?
        }),
        "decryptFileTo" => json!({
            "hash": aes_cbc::decrypt_file_to(
                Path::new(req_str(input, "source")?),
                Path::new(req_str(input, "destination")?),
                &block16(input, "keyHex")?,
                &block16(input, "ivHex")?,
            )?
        }),
        "sha256File" => json!({ "checksum": crypto::checksum::sha256_file(Path::new(req_str(input, "path")?))? }),
        // `report: true` answers a failure as `{error: {code, name, stat, message}}`: `name` is
        // the error's subject (entry name, path or reason), `stat` the stats action the
        // download sends for it, `message` the download error message.
        "extractZip" => {
            let cancelled = input["cancelled"].as_bool().unwrap_or(false);
            let result = extract_zip(
                Path::new(req_str(input, "zip")?),
                Path::new(req_str(input, "destination")?),
                &mut |_, _| {},
                &|| cancelled,
            );
            match result {
                Ok(()) => json!({ "error": null }),
                Err(error) if input["report"].as_bool().unwrap_or(false) => {
                    let (stat, message) = (error.stat(), error.message());
                    let error = extract_error(error);
                    json!({ "error": { "code": error.code, "name": error.message, "stat": stat, "message": message } })
                }
                Err(error) => return Err(extract_error(error)),
            }
        }
        "installExtracted" => {
            install_extracted(
                Path::new(req_str(input, "source")?),
                Path::new(req_str(input, "destination")?),
            )?;
            json!({})
        }
        "redirectAllowed" => json!({
            "allowed": crate::net::redirect_allowed(
                req_str(input, "from")?,
                req_str(input, "to")?,
                req_bool(input, "allowDowngrade")?,
            )
        }),
        "manifestSizeUrl" => json!({
            "url": crate::engine::backend::manifest_size_url(req_str(input, "updateUrl")?)
        }),
        "proxyFromReply" => json!({
            "proxy": HttpProxy::from_reply(&input["reply"]).map(|proxy| json!({ "host": proxy.host, "port": proxy.port }))
        }),
        other => {
            return Err(CoreError::new(
                "unknown_operation",
                format!("Unknown test operation: {PREFIX}{other}"),
            ))
        }
    })
}

/// Engine test operations (`capgo_engine_call("test.<name>", ...)`): `None` when `name`
/// is not one, so the stateless ones above run.
pub(crate) fn engine_call(engine: &Engine, name: &str, input: &Value) -> Option<CoreResult<Value>> {
    Some(match name {
        "waitForCleanup" => {
            engine.wait_for_cleanup_for_tests();
            Ok(json!({}))
        }
        "fetchJson" => req_str(input, "url").and_then(|url| engine.fetch_json(url)),
        // Foreground handling and one `periodCheckDelay` tick, synchronously (hosts get them
        // from `appForeground` on a lifecycle thread and from the periodic thread).
        "pluginForeground" => {
            engine.plugin_foreground_for_tests();
            Ok(json!({}))
        }
        "pluginPeriodicTick" => {
            engine.plugin_periodic_tick_for_tests();
            Ok(json!({}))
        }
        // The launch sweep of download leftovers (normally run by the plugin load flow).
        "cleanupDownloadTempFiles" => {
            engine.cleanup_download_temp_files();
            Ok(json!({}))
        }
        // One request with a fresh client (no pooled connection or TLS session).
        "http" => http_request(engine, input),
        _ => return None,
    })
}

fn http_request(engine: &Engine, input: &Value) -> CoreResult<Value> {
    let user_agent = match opt_str(input, "userAgent")? {
        Some(user_agent) => user_agent.to_string(),
        None => engine.http.user_agent(),
    };
    let timeout = Duration::from_millis(opt_i64(input, "timeoutMs")?.unwrap_or(10_000).max(1) as u64);
    let client = Http::new(Arc::clone(&engine.host), user_agent, timeout);
    let url = req_str(input, "url")?;
    let headers_of =
        |headers: &[(String, String)]| -> Value { headers.iter().map(|(name, value)| json!([name, value])).collect() };
    if input["download"].as_bool().unwrap_or(false) {
        let mut body = Vec::new();
        let head = client
            .download(url, &[], &mut |event| {
                if let Stream::Chunk(chunk) = event {
                    body.extend_from_slice(chunk);
                }
                Ok(())
            })
            .map_err(net_error)?;
        return Ok(json!({
            "status": head.status,
            "headers": headers_of(&head.headers),
            "bodyHex": hex_encode(&body),
        }));
    }
    let method = opt_str(input, "method")?.unwrap_or("GET");
    let response = match input.get("json") {
        Some(body) if !body.is_null() => client.send_json(method, url, body),
        _ => client.send(method, url, &[], None),
    }
    .map_err(net_error)?;
    Ok(json!({
        "status": response.status,
        "headers": headers_of(&response.headers),
        "bodyHex": hex_encode(&response.body),
    }))
}
