//! Delay conditions (`setMultiDelay`): pending installs wait until every stored
//! condition is gone. Conditions are re-evaluated at launch (kill), background
//! and foreground.

use serde_json::{json, Value};

use super::keys;
use crate::engine::Engine;
use crate::host::HostLog;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DelaySource {
    Killed,
    Background,
    Foreground,
}

impl DelaySource {
    fn name(self) -> &'static str {
        match self {
            DelaySource::Killed => "KILLED",
            DelaySource::Background => "BACKGROUND",
            DelaySource::Foreground => "FOREGROUND",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DelayCondition {
    pub kind: String,
    pub value: Option<String>,
}

impl DelayCondition {
    fn to_json(&self) -> Value {
        match &self.value {
            Some(value) => json!({ "kind": self.kind, "value": value }),
            None => json!({ "kind": self.kind }),
        }
    }
}

const KINDS: [&str; 4] = ["background", "kill", "date", "nativeVersion"];

/// Parses stored conditions, dropping malformed entries and unknown kinds.
pub fn parse_delay_conditions(raw: &str, log: &mut dyn FnMut(String)) -> Vec<DelayCondition> {
    let parsed: Value = match serde_json::from_str(raw) {
        Ok(value) => value,
        Err(error) => {
            log(format!("Failed to parse delay conditions: {error}"));
            return Vec::new();
        }
    };
    let Some(items) = parsed.as_array() else {
        log("Failed to parse delay conditions: not an array".into());
        return Vec::new();
    };
    let mut conditions = Vec::new();
    for (index, item) in items.iter().enumerate() {
        let Some(object) = item.as_object() else {
            continue;
        };
        let Some(kind) = object.get("kind").and_then(Value::as_str) else {
            log(format!("Delay condition missing kind at index {index}"));
            continue;
        };
        if !KINDS.contains(&kind) {
            log(format!("Unknown delay condition kind '{kind}' at index {index}"));
            continue;
        }
        let value = match object.get("value") {
            Some(Value::String(value)) => Some(value.clone()),
            Some(Value::Number(number)) => Some(number.to_string()),
            _ => None,
        };
        conditions.push(DelayCondition {
            kind: kind.to_string(),
            value,
        });
    }
    conditions
}

/// `true` when `now_ms` is past the ISO 8601 `value` (offsets honoured, local
/// time when none). `None` when unparseable.
pub fn is_date_passed(value: &str, now_ms: i64) -> Option<bool> {
    parse_iso8601_ms(value).map(|deadline| now_ms > deadline)
}

fn digits(text: &str) -> Option<i64> {
    (!text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit()))
        .then(|| text.parse().ok())
        .flatten()
}

/// `yyyy-MM-ddTHH:mm:ss[.SSS][Z|±HH:mm|±HHmm|±HH]`.
pub fn parse_iso8601_ms(value: &str) -> Option<i64> {
    let value = value.trim();
    if value.len() < 19 || value.as_bytes()[10] != b'T' {
        return None;
    }
    let (date, rest) = value.split_at(10);
    let rest = &rest[1..];
    let mut date_parts = date.split('-');
    let year = digits(date_parts.next()?)?;
    let month = digits(date_parts.next()?)?;
    let day = digits(date_parts.next()?)?;
    if date_parts.next().is_some() || !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let time = &rest[..8];
    let mut time_parts = time.split(':');
    let hour = digits(time_parts.next()?)?;
    let minute = digits(time_parts.next()?)?;
    let second = digits(time_parts.next()?)?;
    if hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    let mut tail = &rest[8..];
    let mut millis = 0;
    if let Some(fraction) = tail.strip_prefix('.') {
        let end = fraction
            .find(|character: char| !character.is_ascii_digit())
            .unwrap_or(fraction.len());
        if end == 0 {
            return None;
        }
        let padded = format!("{:0<3}", &fraction[..end.min(3)]);
        millis = padded.parse::<i64>().ok()?;
        tail = &fraction[end..];
    }
    let offset_minutes = match tail {
        "" => None,
        "Z" | "z" => Some(0),
        _ => {
            let sign = match tail.as_bytes()[0] {
                b'+' => 1,
                b'-' => -1,
                _ => return None,
            };
            let body = tail[1..].replace(':', "");
            let (hours, minutes) = match body.len() {
                2 => (digits(&body)?, 0),
                4 => (digits(&body[..2])?, digits(&body[2..])?),
                _ => return None,
            };
            Some(sign * (hours * 60 + minutes))
        }
    };
    let days = days_from_civil(year, month, day);
    let seconds = days * 86_400 + hour * 3600 + minute * 60 + second;
    let utc_seconds = match offset_minutes {
        Some(offset) => seconds - offset * 60,
        None => seconds - local_offset_seconds(seconds),
    };
    Some(utc_seconds * 1000 + millis)
}

/// Days since 1970-01-01 (proleptic Gregorian).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let yoe = year - era * 400;
    let month_index = (month + 9) % 12;
    let doy = (153 * month_index + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Local UTC offset (seconds) for a local wall-clock time expressed as epoch seconds.
fn local_offset_seconds(local_seconds: i64) -> i64 {
    #[cfg(unix)]
    unsafe {
        let time = local_seconds as libc::time_t;
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&time, &mut tm).is_null() {
            return 0;
        }
        tm.tm_gmtoff as i64
    }
    #[cfg(not(unix))]
    {
        let _ = local_seconds;
        0
    }
}

/// Native version comparison (numeric components, then pre-release < release).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeVersion {
    numbers: Vec<u64>,
    prerelease: Option<String>,
}

impl NativeVersion {
    pub fn parse(value: &str) -> Option<Self> {
        let value: String = value.chars().filter(|character| !character.is_whitespace()).collect();
        let value = value.strip_prefix('v').unwrap_or(&value);
        if !value.starts_with(|character: char| character.is_ascii_digit()) {
            return None;
        }
        let core = value.split('+').next().unwrap_or_default();
        let (numbers_part, prerelease) =
            match core.find(|character: char| !character.is_ascii_digit() && character != '.') {
                Some(index) => {
                    let suffix = core[index..].trim_start_matches(['-', '.']);
                    (
                        &core[..index],
                        (!suffix.is_empty()).then(|| suffix.to_ascii_lowercase()),
                    )
                }
                None => (core, None),
            };
        let mut numbers: Vec<u64> = numbers_part
            .split('.')
            .filter(|part| !part.is_empty())
            .map(|part| part.parse().unwrap_or(u64::MAX))
            .collect();
        while numbers.last() == Some(&0) {
            numbers.pop();
        }
        Some(Self { numbers, prerelease })
    }
}

impl PartialOrd for NativeVersion {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for NativeVersion {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        use std::cmp::Ordering;
        let length = self.numbers.len().max(other.numbers.len());
        for index in 0..length {
            let left = self.numbers.get(index).copied().unwrap_or(0);
            let right = other.numbers.get(index).copied().unwrap_or(0);
            match left.cmp(&right) {
                Ordering::Equal => {}
                ordering => return ordering,
            }
        }
        match (&self.prerelease, &other.prerelease) {
            (None, None) => Ordering::Equal,
            (None, Some(_)) => Ordering::Greater,
            (Some(_), None) => Ordering::Less,
            (Some(left), Some(right)) => left.cmp(right),
        }
    }
}

impl Engine {
    pub(crate) fn delay_conditions(&self) -> Vec<DelayCondition> {
        let raw = self.kv_text(keys::DELAY_CONDITIONS).unwrap_or_else(|| "[]".into());
        parse_delay_conditions(&raw, &mut |message| self.host.warn(message))
    }

    pub(crate) fn has_delay_conditions(&self) -> bool {
        !self.delay_conditions().is_empty()
    }

    /// Stores conditions; `background` without a value means "0 ms".
    pub(crate) fn set_multi_delay(&self, conditions: &[Value]) -> bool {
        let normalized: Vec<Value> = conditions
            .iter()
            .map(|condition| {
                let mut condition = condition.clone();
                if let Some(object) = condition.as_object_mut() {
                    let is_background = object.get("kind").and_then(Value::as_str) == Some("background");
                    let empty = object.get("value").map_or(true, |value| {
                        value.as_str().is_some_and(str::is_empty) || value.is_null()
                    });
                    if is_background && empty {
                        object.insert("value".into(), json!("0"));
                    }
                }
                condition
            })
            .collect();
        self.kv_write(keys::DELAY_CONDITIONS, Some(&Value::Array(normalized).to_string()));
        self.host.info("Delay update saved");
        true
    }

    pub(crate) fn cancel_delay(&self, source: &str) -> bool {
        self.kv_write(keys::DELAY_CONDITIONS, None);
        self.host.info(format!("All delays canceled from {source}"));
        true
    }

    pub(crate) fn set_background_timestamp(&self, timestamp: i64) {
        self.kv_write(keys::BACKGROUND_TIMESTAMP, Some(&timestamp.to_string()));
    }

    pub(crate) fn unset_background_timestamp(&self) {
        self.kv_write(keys::BACKGROUND_TIMESTAMP, None);
    }

    fn background_timestamp(&self) -> i64 {
        self.kv_text(keys::BACKGROUND_TIMESTAMP)
            .and_then(|value| value.trim().parse().ok())
            .unwrap_or(0)
    }

    /// Drops the conditions satisfied by `source`; keeps the rest.
    pub(crate) fn check_cancel_delay(&self, source: DelaySource) {
        let conditions = self.delay_conditions();
        if conditions.is_empty() {
            return;
        }
        let native = NativeVersion::parse(&self.plugin_config().native_version);
        let now = super::now_ms();
        let mut kept = Vec::new();
        for (index, condition) in conditions.into_iter().enumerate() {
            let value = condition.value.clone().unwrap_or_default();
            let keep = match condition.kind.as_str() {
                "background" => {
                    if source == DelaySource::Foreground {
                        let delta = (now - self.background_timestamp()).max(0);
                        let limit: i64 = value.trim().parse().unwrap_or_else(|_| {
                            self.host.warn(format!(
                                "Background condition (value: {value}) had an invalid value at index {index}. We will likely remove it."
                            ));
                            0
                        });
                        delta <= limit
                    } else {
                        true
                    }
                }
                "kill" => source != DelaySource::Killed,
                "date" => {
                    if value.is_empty() {
                        self.host.error(format!(
                            "Date delay (value: {value}) condition removed due to empty value at index {index}"
                        ));
                        false
                    } else {
                        match is_date_passed(&value, now) {
                            Some(passed) => !passed,
                            None => {
                                self.host.error(format!(
                                    "Date delay (value: {value}) condition removed due to parsing issue at index {index}"
                                ));
                                false
                            }
                        }
                    }
                }
                "nativeVersion" => match (NativeVersion::parse(&value), &native) {
                    (Some(limit), Some(current)) => current < &limit,
                    _ => {
                        self.host.error(format!(
                            "Native version delay (value: {value}) condition removed due to parsing issue at index {index}"
                        ));
                        false
                    }
                },
                _ => false,
            };
            self.host.info(format!(
                "{} delay (value: {value}) {} at index {index} (source: {})",
                condition.kind,
                if keep { "kept" } else { "removed" },
                source.name()
            ));
            if keep {
                kept.push(condition);
            }
        }
        if kept.is_empty() {
            self.cancel_delay("checkCancelDelay");
        } else {
            let stored: Vec<Value> = kept.iter().map(DelayCondition::to_json).collect();
            self.kv_write(keys::DELAY_CONDITIONS, Some(&Value::Array(stored).to_string()));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_dates() {
        assert_eq!(parse_iso8601_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_iso8601_ms("1970-01-01T00:00:01.5Z"), Some(1500));
        assert_eq!(parse_iso8601_ms("1970-01-01T01:00:00+01:00"), Some(0));
        assert_eq!(parse_iso8601_ms("1970-01-01T01:00:00+0100"), Some(0));
        assert_eq!(parse_iso8601_ms("1970-01-01T01:00:00+01"), Some(0));
        assert_eq!(parse_iso8601_ms("2024-02-29T12:00:00.000Z"), Some(1_709_208_000_000));
        assert_eq!(parse_iso8601_ms("not a date"), None);
        assert_eq!(parse_iso8601_ms("2024-13-01T00:00:00Z"), None);
    }

    #[test]
    fn native_versions() {
        let v = |value: &str| NativeVersion::parse(value).unwrap();
        assert!(v("1.2.3") < v("1.10.0"));
        assert!(v("2.0.0-beta.1") < v("2.0.0"));
        assert_eq!(v("1.2"), v("1.2.0"));
        assert!(NativeVersion::parse("abc").is_none());
    }

    #[test]
    fn parse_skips_invalid_entries() {
        let mut logs = Vec::new();
        let parsed = parse_delay_conditions(
            r#"[{"kind":"background","value":"10"},{"value":"x"},{"kind":"nope"},3,{"kind":"kill"}]"#,
            &mut |message| logs.push(message),
        );
        assert_eq!(parsed.len(), 2);
        assert_eq!(logs.len(), 2);
        assert!(parse_delay_conditions("{", &mut |_| {}).is_empty());
    }
}
