//! HTTP helper decisions shared by every host: user agent, resumable
//! downloads and rate-limit (429) handling. The hosts own the actual network
//! stack; the core only decides.

use serde_json::Value;

use crate::text::java_trim;

/// Upper bound for a client-side 429 block, so a bogus Retry-After cannot block for days.
pub const MAX_RATE_LIMIT_WINDOW_MS: f64 = 24.0 * 60.0 * 60.0 * 1000.0;

const HTTP_OK: i64 = 200;
const HTTP_PARTIAL: i64 = 206;

fn sanitize_user_agent_value(value: &str) -> String {
    let filtered: String = value
        .chars()
        .filter(|c| {
            let cp = *c as u32;
            (0x20..=0x7e).contains(&cp) || (0xa0..=0xff).contains(&cp)
        })
        .collect();
    let trimmed = filtered.trim_matches(|c: char| c == ' ' || c == '\u{a0}');
    if trimmed.is_empty() {
        "unknown".to_string()
    } else {
        trimmed.to_string()
    }
}

/// `CapacitorUpdater/<plugin> (<appId>) <platform>/<os>` restricted to header-safe ISO-8859-1.
pub fn user_agent(app_id: &str, plugin_version: &str, version_os: &str, platform: &str) -> String {
    format!(
        "CapacitorUpdater/{} ({}) {}/{}",
        sanitize_user_agent_value(plugin_version),
        sanitize_user_agent_value(app_id),
        sanitize_user_agent_value(platform),
        sanitize_user_agent_value(version_os)
    )
}

pub fn is_retryable_http_status(status: i64) -> bool {
    status >= 500 || status == 408 || status == 429
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContentRange {
    pub start: i64,
    pub end: i64,
    /// `-1` when the server answered `*`.
    pub total: i64,
}

fn parse_java_long(value: &str) -> Option<i64> {
    java_trim(value).parse::<i64>().ok()
}

/// Parses `Content-Range: bytes <start>-<end>/<total|*>`.
pub fn parse_content_range(header: Option<&str>) -> Option<ContentRange> {
    let trimmed = java_trim(header?);
    let rest = trimmed.strip_prefix("bytes ")?;
    let slash = rest.find('/')?;
    let dash = rest.find('-')?;
    if dash >= slash {
        return None;
    }
    let start = parse_java_long(&rest[..dash])?;
    let end = parse_java_long(&rest[dash + 1..slash])?;
    let total_part = java_trim(&rest[slash + 1..]);
    let total = if total_part == "*" {
        -1
    } else {
        parse_java_long(total_part)?
    };
    if end < start {
        return None;
    }
    Some(ContentRange { start, end, total })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ZipWritePlan {
    pub response_code: i64,
    pub write_offset: i64,
}

/// Decides how a (possibly resumed) zip download response must be written.
/// Errors with `invalid_content_range` when a 206 does not continue the partial file.
pub fn plan_zip_resume_write(
    response_code: i64,
    downloaded_bytes: i64,
    content_range: Option<&str>,
) -> Result<ZipWritePlan, &'static str> {
    if response_code == HTTP_PARTIAL {
        let range_start = parse_content_range(content_range).map_or(-1, |range| range.start);
        if range_start == downloaded_bytes {
            return Ok(ZipWritePlan {
                response_code: HTTP_PARTIAL,
                write_offset: downloaded_bytes,
            });
        }
        if range_start == 0 {
            return Ok(ZipWritePlan {
                response_code: HTTP_OK,
                write_offset: 0,
            });
        }
        return Err("invalid_content_range");
    }
    if response_code == HTTP_OK && downloaded_bytes > 0 {
        return Ok(ZipWritePlan {
            response_code: HTTP_OK,
            write_offset: 0,
        });
    }
    Ok(ZipWritePlan {
        response_code,
        write_offset: downloaded_bytes,
    })
}

pub fn should_append_http_body(status_code: i64, existing_bytes: i64) -> bool {
    existing_bytes > 0 && status_code == HTTP_PARTIAL
}

fn parse_json_object(body: Option<&str>) -> Option<serde_json::Map<String, Value>> {
    match serde_json::from_str::<Value>(body?) {
        Ok(Value::Object(map)) => Some(map),
        _ => None,
    }
}

/// `{"error": "...", "message": "..."}` from a backend error body; empty strings when absent.
pub fn parse_remote_error(body: Option<&str>) -> (String, String) {
    let Some(json) = parse_json_object(body) else {
        return (String::new(), String::new());
    };
    let field = |key: &str| {
        json.get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string()
    };
    (field("error"), field("message"))
}

fn raw_rate_limit_deadline_ms(retry_after: Option<&str>, body: Option<&str>, now_ms: f64) -> f64 {
    if let Some(header) = retry_after {
        if let Ok(seconds) = java_trim(header).parse::<f64>() {
            if seconds >= 0.0 {
                return now_ms + seconds * 1000.0;
            }
        }
    }

    if let Some(json) = parse_json_object(body) {
        let more_info = json.get("moreInfo").and_then(Value::as_object);
        let number = |key: &str| {
            more_info
                .and_then(|info| info.get(key))
                .and_then(Value::as_f64)
                .or_else(|| json.get(key).and_then(Value::as_f64))
        };
        if let Some(retry_after_seconds) = number("retryAfterSeconds") {
            if retry_after_seconds >= 0.0 {
                return now_ms + retry_after_seconds * 1000.0;
            }
        }
        if let Some(reset_at) = number("rateLimitResetAt") {
            return reset_at;
        }
    }

    // No retry hint: no client-side block, allow an immediate retry.
    0.0
}

/// Epoch ms until which requests must be blocked after a 429, or `0` for no block.
/// Honours `Retry-After`, then `retryAfterSeconds`, then `rateLimitResetAt`, capped at one day.
pub fn rate_limit_blocked_until_ms(
    retry_after: Option<&str>,
    body: Option<&str>,
    now_ms: i64,
) -> i64 {
    let now = now_ms as f64;
    let candidate = raw_rate_limit_deadline_ms(retry_after, body, now);
    // NaN and past deadlines mean "no client-side block"; anything further out is capped.
    if candidate.is_nan() || candidate <= now {
        return 0;
    }
    candidate.min(now + MAX_RATE_LIMIT_WINDOW_MS) as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nan_retry_after_is_ignored() {
        assert_eq!(rate_limit_blocked_until_ms(Some("NaN"), None, 1000), 0);
    }

    #[test]
    fn infinite_retry_after_is_capped() {
        assert_eq!(
            rate_limit_blocked_until_ms(Some("inf"), None, 0),
            MAX_RATE_LIMIT_WINDOW_MS as i64
        );
    }
}
