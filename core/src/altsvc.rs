//! HTTP/3 discovery: `Alt-Svc` (RFC 7838) parsing and the per-origin cache.
//!
//! An origin is only reached over HTTP/3 after one of its responses announced `h3` on the
//! same host. The announcement is kept for its `ma` (default 24 h, at most 7 days) and
//! persisted in the host's key-value storage, so the next launch starts on HTTP/3.
//! The C core implements the same rules in `core-c/src/altsvc.c`.

use std::collections::BTreeMap;
use std::sync::Mutex;

use serde_json::{json, Map, Value};

use crate::host::Host;
use crate::sync::LockRecover;

/// Storage key of the persisted announcements.
pub const STORAGE_KEY: &str = "CapacitorUpdater.altSvc";
/// Origins kept at most (the soonest to expire goes first).
pub const MAX_ENTRIES: usize = 16;
/// `ma` when the announcement has none (RFC 7838: 24 hours).
pub const DEFAULT_MAX_AGE_SECONDS: u64 = 86_400;
/// Longest `ma` honored.
pub const MAX_MAX_AGE_SECONDS: u64 = 7 * 86_400;
/// A refreshed announcement is written back only when it extends the stored expiry by at least
/// this much (one storage write per hour per origin, not one per response).
pub const PERSIST_SLACK_MS: i64 = 3_600_000;

/// An `h3` alternative on the origin's own host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct H3Alternative {
    pub port: u16,
    pub max_age_seconds: u64,
}

/// What an `Alt-Svc` header value says about HTTP/3.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AltSvc {
    /// Not valid `Alt-Svc` syntax: ignored, the cache is unchanged.
    Invalid,
    /// `clear`: forget the origin.
    Clear,
    /// A valid list: its first usable `h3` alternative, or none (forget the origin).
    List(Option<H3Alternative>),
}

fn is_tchar(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte)
}

fn is_ows(byte: u8) -> bool {
    byte == b' ' || byte == b'\t'
}

struct Cursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn skip_ows(&mut self) {
        while self.peek().is_some_and(is_ows) {
            self.pos += 1;
        }
    }

    fn token(&mut self) -> Option<&'a [u8]> {
        let start = self.pos;
        while self.peek().is_some_and(is_tchar) {
            self.pos += 1;
        }
        (self.pos > start).then(|| &self.bytes[start..self.pos])
    }

    /// RFC 9110 quoted-string, unescaped.
    fn quoted(&mut self) -> Option<Vec<u8>> {
        if self.peek() != Some(b'"') {
            return None;
        }
        self.pos += 1;
        let mut out = Vec::new();
        loop {
            let byte = self.peek()?;
            self.pos += 1;
            match byte {
                b'"' => return Some(out),
                b'\\' => {
                    let escaped = self.peek()?;
                    if !(escaped == b'\t' || escaped == b' ' || (0x21..=0x7e).contains(&escaped) || escaped >= 0x80) {
                        return None;
                    }
                    self.pos += 1;
                    out.push(escaped);
                }
                b'\t' | b' ' | 0x21 | 0x23..=0x5b | 0x5d..=0x7e | 0x80..=0xff => out.push(byte),
                _ => return None,
            }
        }
    }
}

/// Digits only, saturating; `None` when empty or not all digits.
fn delta_seconds(value: &[u8]) -> Option<u64> {
    if value.is_empty() || !value.iter().all(u8::is_ascii_digit) {
        return None;
    }
    Some(value.iter().fold(0u64, |total, digit| {
        total.saturating_mul(10).saturating_add(u64::from(digit - b'0'))
    }))
}

/// `[host]:port` on `origin_host` (empty host = the origin's), port 1-65535.
fn same_host_port(authority: &[u8], origin_host: &str) -> Option<u16> {
    let colon = authority.iter().rposition(|byte| *byte == b':')?;
    let (host, port) = (&authority[..colon], &authority[colon + 1..]);
    if port.is_empty() || port.len() > 5 || !port.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let port: u32 = port.iter().fold(0, |total, digit| total * 10 + u32::from(digit - b'0'));
    if port == 0 || port > 65_535 {
        return None;
    }
    if !host.is_empty() && !host.eq_ignore_ascii_case(origin_host.as_bytes()) {
        return None;
    }
    Some(port as u16)
}

/// Parses an `Alt-Svc` field value received from `origin_host` (the URL host, IPv6 in
/// brackets). Strict RFC 7838 syntax: any error makes the whole value [`AltSvc::Invalid`].
/// The first `h3` alternative on the same host with a valid `ma` wins; draft versions
/// (`h3-29`...) and other hosts are ignored.
pub fn parse(value: &str, origin_host: &str) -> AltSvc {
    let bytes = value.as_bytes();
    let mut cursor = Cursor { bytes, pos: 0 };
    cursor.skip_ows();
    let start = cursor.pos;
    let mut end = bytes.len();
    while end > start && is_ows(bytes[end - 1]) {
        end -= 1;
    }
    if &bytes[start..end] == b"clear" {
        return AltSvc::Clear;
    }
    let mut chosen = None;
    let mut values = 0;
    loop {
        cursor.skip_ows();
        match cursor.peek() {
            None => break,
            // Empty list elements are allowed (RFC 9110 5.6.1).
            Some(b',') => {
                cursor.pos += 1;
                continue;
            }
            Some(_) => {}
        }
        let Some(protocol) = cursor.token() else {
            return AltSvc::Invalid;
        };
        if cursor.peek() != Some(b'=') {
            return AltSvc::Invalid;
        }
        cursor.pos += 1;
        let Some(authority) = cursor.quoted() else {
            return AltSvc::Invalid;
        };
        let mut max_age = Some(DEFAULT_MAX_AGE_SECONDS);
        let mut seen_max_age = false;
        loop {
            cursor.skip_ows();
            if cursor.peek() != Some(b';') {
                break;
            }
            cursor.pos += 1;
            cursor.skip_ows();
            let Some(name) = cursor.token() else {
                return AltSvc::Invalid;
            };
            if cursor.peek() != Some(b'=') {
                return AltSvc::Invalid;
            }
            cursor.pos += 1;
            let parameter = match cursor.token() {
                Some(token) => token.to_vec(),
                None => match cursor.quoted() {
                    Some(text) => text,
                    None => return AltSvc::Invalid,
                },
            };
            if name.eq_ignore_ascii_case(b"ma") && !seen_max_age {
                seen_max_age = true;
                max_age = delta_seconds(&parameter).map(|seconds| seconds.min(MAX_MAX_AGE_SECONDS));
            }
        }
        cursor.skip_ows();
        match cursor.peek() {
            None => {}
            Some(b',') => cursor.pos += 1,
            Some(_) => return AltSvc::Invalid,
        }
        values += 1;
        if chosen.is_none() && protocol == b"h3" {
            if let (Some(port), Some(max_age_seconds)) = (same_host_port(&authority, origin_host), max_age) {
                chosen = Some(H3Alternative { port, max_age_seconds });
            }
        }
    }
    if values == 0 {
        return AltSvc::Invalid;
    }
    AltSvc::List(chosen)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Entry {
    port: u16,
    /// Wall clock, milliseconds since the epoch.
    expires: i64,
    /// `expires` as last written to storage (0: never written).
    stored: i64,
}

/// Announced HTTP/3 alternatives per origin (`https://host:port`), loaded from and written to
/// the host's storage under [`STORAGE_KEY`].
#[derive(Default)]
pub struct AltSvcCache {
    entries: Mutex<Option<BTreeMap<String, Entry>>>,
}

fn load(host: &dyn Host) -> BTreeMap<String, Entry> {
    let mut entries = BTreeMap::new();
    let Some(text) = host.kv_get(STORAGE_KEY, None) else {
        return entries;
    };
    let Ok(Value::Object(stored)) = serde_json::from_str::<Value>(&text) else {
        return entries;
    };
    for (origin, value) in stored {
        if entries.len() >= MAX_ENTRIES {
            break;
        }
        let port = value["port"].as_u64().filter(|port| (1..=65_535).contains(port));
        let expires = value["expires"].as_i64();
        if let (Some(port), Some(expires)) = (port, expires) {
            entries.insert(
                origin,
                Entry {
                    port: port as u16,
                    expires,
                    stored: expires,
                },
            );
        }
    }
    entries
}

fn save(host: &dyn Host, entries: &mut BTreeMap<String, Entry>, now_ms: i64) {
    entries.retain(|_, entry| entry.expires > now_ms);
    let mut stored = Map::new();
    for (origin, entry) in entries.iter_mut() {
        entry.stored = entry.expires;
        stored.insert(origin.clone(), json!({ "port": entry.port, "expires": entry.expires }));
    }
    if stored.is_empty() {
        host.kv_set(STORAGE_KEY, None);
    } else {
        host.kv_set(STORAGE_KEY, Some(&Value::Object(stored).to_string()));
    }
}

impl AltSvcCache {
    fn with<T>(&self, host: &dyn Host, work: impl FnOnce(&mut BTreeMap<String, Entry>) -> T) -> T {
        let mut guard = self.entries.lock_or_recover();
        work(guard.get_or_insert_with(|| load(host)))
    }

    /// The announced HTTP/3 port of `origin`, while the announcement is fresh.
    pub fn lookup(&self, host: &dyn Host, origin: &str, now_ms: i64) -> Option<u16> {
        self.with(host, |entries| {
            entries
                .get(origin)
                .filter(|entry| entry.expires > now_ms)
                .map(|entry| entry.port)
        })
    }

    /// Applies an `Alt-Svc` value received from `origin`; writes the storage when the set of
    /// origins or a port changed, or an expiry moved by [`PERSIST_SLACK_MS`] or more.
    pub fn update(&self, host: &dyn Host, origin: &str, alt_svc: AltSvc, now_ms: i64) {
        self.with(host, |entries| {
            let changed = match alt_svc {
                AltSvc::Invalid => false,
                AltSvc::Clear | AltSvc::List(None) => entries.remove(origin).is_some(),
                AltSvc::List(Some(alternative)) => {
                    let expires = now_ms.saturating_add((alternative.max_age_seconds as i64).saturating_mul(1000));
                    if expires <= now_ms {
                        entries.remove(origin).is_some()
                    } else if let Some(entry) = entries.get_mut(origin) {
                        let port_changed = entry.port != alternative.port;
                        entry.port = alternative.port;
                        entry.expires = expires;
                        port_changed || expires.saturating_sub(entry.stored) >= PERSIST_SLACK_MS
                    } else {
                        if entries.len() >= MAX_ENTRIES {
                            entries.retain(|_, entry| entry.expires > now_ms);
                        }
                        if entries.len() >= MAX_ENTRIES {
                            let oldest = entries
                                .iter()
                                .min_by_key(|(_, entry)| entry.expires)
                                .map(|(origin, _)| origin.clone());
                            if let Some(oldest) = oldest {
                                entries.remove(&oldest);
                            }
                        }
                        entries.insert(
                            origin.to_string(),
                            Entry {
                                port: alternative.port,
                                expires,
                                stored: 0,
                            },
                        );
                        true
                    }
                }
            };
            if changed {
                save(host, entries, now_ms);
            }
        });
    }

    /// Forgets the loaded state (tests: the next use reads the storage again).
    pub fn reset(&self) {
        *self.entries.lock_or_recover() = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h3(port: u16, max_age_seconds: u64) -> AltSvc {
        AltSvc::List(Some(H3Alternative { port, max_age_seconds }))
    }

    #[test]
    fn parses_announcements() {
        assert_eq!(parse("h3=\":443\"", "a.com"), h3(443, 86_400));
        assert_eq!(parse("h3=\":8443\"; ma=60", "a.com"), h3(8443, 60));
        assert_eq!(parse(" h3-29=\":443\", h3=\"A.com:444\";ma=5 ", "a.com"), h3(444, 5));
        assert_eq!(parse("h3=\"b.com:443\"", "a.com"), AltSvc::List(None));
        assert_eq!(parse("h2=\":443\"", "a.com"), AltSvc::List(None));
        assert_eq!(parse("clear", "a.com"), AltSvc::Clear);
        assert_eq!(
            parse("h3=\":443\"; ma=99999999999999999999999", "a.com"),
            h3(443, MAX_MAX_AGE_SECONDS)
        );
        assert_eq!(parse("h3=\":443\"; ma=x, h3=\":444\"", "a.com"), h3(444, 86_400));
        assert_eq!(parse("h3=:443", "a.com"), AltSvc::Invalid);
        assert_eq!(parse("h3=\":443", "a.com"), AltSvc::Invalid);
        assert_eq!(parse("", "a.com"), AltSvc::Invalid);
        assert_eq!(parse("h3=\":0\"", "a.com"), AltSvc::List(None));
        assert_eq!(parse("h3=\"[::1]:443\"", "[::1]"), h3(443, 86_400));
    }
}
