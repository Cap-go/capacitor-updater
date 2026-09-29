//! Bundle model shared by every host, stored and exchanged as JSON.

use serde_json::{json, Map, Value};

pub const ID_BUILTIN: &str = "builtin";
pub const VERSION_UNKNOWN: &str = "unknown";
pub const DOWNLOADED_BUILTIN: &str = "1970-01-01T00:00:00.000Z";

pub const STATUSES: [&str; 6] = [
    "success",
    "error",
    "pending",
    "deleted",
    "deleting",
    "downloading",
];

/// Parses a stored bundle status. Surrounding whitespace and case are ignored,
/// an empty value means `pending`, unknown values are rejected (`None`).
pub fn parse_bundle_status(value: Option<&str>) -> Option<&'static str> {
    let normalized = value.unwrap_or_default().trim().to_ascii_lowercase();
    if normalized.is_empty() {
        return Some("pending");
    }
    STATUSES
        .iter()
        .copied()
        .find(|status| *status == normalized)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BundleStatus {
    Success,
    Error,
    Pending,
    Deleted,
    Deleting,
    Downloading,
}

impl BundleStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            BundleStatus::Success => "success",
            BundleStatus::Error => "error",
            BundleStatus::Pending => "pending",
            BundleStatus::Deleted => "deleted",
            BundleStatus::Deleting => "deleting",
            BundleStatus::Downloading => "downloading",
        }
    }

    pub fn parse(value: Option<&str>) -> Option<Self> {
        Some(match parse_bundle_status(value)? {
            "success" => BundleStatus::Success,
            "error" => BundleStatus::Error,
            "pending" => BundleStatus::Pending,
            "deleted" => BundleStatus::Deleted,
            "deleting" => BundleStatus::Deleting,
            _ => BundleStatus::Downloading,
        })
    }
}

/// A downloaded (or builtin) web bundle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BundleInfo {
    pub id: String,
    /// `None` / empty means "builtin" (the version name of the builtin bundle).
    pub version: Option<String>,
    pub downloaded: String,
    pub checksum: String,
    pub status: BundleStatus,
    pub link: Option<String>,
    pub comment: Option<String>,
}

impl BundleInfo {
    pub fn new(
        id: impl Into<String>,
        version: Option<String>,
        status: BundleStatus,
        downloaded: impl Into<String>,
        checksum: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            version,
            downloaded: downloaded.into().trim().to_string(),
            checksum: checksum.into(),
            status,
            link: None,
            comment: None,
        }
    }

    pub fn is_builtin(&self) -> bool {
        self.id == ID_BUILTIN
    }

    pub fn is_unknown(&self) -> bool {
        self.id == VERSION_UNKNOWN
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn version_name(&self) -> &str {
        match self.version.as_deref() {
            Some(version) if !version.is_empty() => version,
            _ => ID_BUILTIN,
        }
    }

    pub fn status(&self) -> BundleStatus {
        if self.is_builtin() {
            BundleStatus::Success
        } else {
            self.status
        }
    }

    pub fn downloaded(&self) -> &str {
        if self.is_builtin() {
            DOWNLOADED_BUILTIN
        } else {
            &self.downloaded
        }
    }

    pub fn checksum(&self) -> &str {
        if self.is_builtin() {
            ""
        } else {
            &self.checksum
        }
    }

    pub fn is_error(&self) -> bool {
        self.status == BundleStatus::Error
    }
    pub fn is_deleted(&self) -> bool {
        self.status == BundleStatus::Deleted
    }
    pub fn is_deleting(&self) -> bool {
        self.status == BundleStatus::Deleting
    }
    pub fn is_downloading(&self) -> bool {
        self.status == BundleStatus::Downloading
    }

    pub fn is_downloaded(&self) -> bool {
        !self.is_builtin()
            && !self.downloaded.is_empty()
            && self.downloaded != DOWNLOADED_BUILTIN
            && !self.is_deleted()
            && !self.is_deleting()
    }

    pub fn with_status(&self, status: BundleStatus) -> Self {
        Self {
            status,
            ..self.clone()
        }
    }

    pub fn with_id(&self, id: &str) -> Self {
        Self {
            id: id.to_string(),
            ..self.clone()
        }
    }

    /// JSON shape exposed to JavaScript (`BundleInfo` in definitions.ts).
    pub fn to_js(&self) -> Value {
        let mut out = Map::new();
        out.insert("id".into(), json!(self.id()));
        out.insert("version".into(), json!(self.version_name()));
        out.insert("downloaded".into(), json!(self.downloaded()));
        out.insert("checksum".into(), json!(self.checksum()));
        out.insert("status".into(), json!(self.status().as_str()));
        if let Some(link) = self.link.as_deref().filter(|link| !link.is_empty()) {
            out.insert("link".into(), json!(link));
        }
        if let Some(comment) = self
            .comment
            .as_deref()
            .filter(|comment| !comment.is_empty())
        {
            out.insert("comment".into(), json!(comment));
        }
        Value::Object(out)
    }

    /// Raw fields for hosts that rebuild their own value type (nullable version).
    pub fn to_raw(&self) -> Value {
        json!({
            "id": self.id,
            "version": self.version,
            "downloaded": self.downloaded,
            "checksum": self.checksum,
            "status": self.status.as_str(),
            "link": self.link,
            "comment": self.comment,
        })
    }

    /// Inverse of [`BundleInfo::to_raw`].
    pub fn from_raw(value: &Value) -> Option<Self> {
        let object = value.as_object()?;
        let text = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_string);
        Some(Self {
            id: text("id").unwrap_or_default(),
            version: text("version"),
            downloaded: text("downloaded").unwrap_or_default().trim().to_string(),
            checksum: text("checksum").unwrap_or_default(),
            status: BundleStatus::parse(object.get("status").and_then(Value::as_str))
                .unwrap_or(BundleStatus::Error),
            link: text("link"),
            comment: text("comment"),
        })
    }

    /// JSON persisted under `<id>_info` (readable by every previous plugin version).
    pub fn to_stored_json(&self) -> String {
        let mut value = self.to_js();
        if let Some(object) = value.as_object_mut() {
            object.insert(
                "id".into(),
                json!(if self.is_builtin() {
                    ID_BUILTIN
                } else {
                    &self.id
                }),
            );
        }
        value.to_string()
    }

    /// Parses a stored `<id>_info` value (Android JSON string or iOS Codable JSON).
    pub fn from_stored_json(value: &str) -> Option<Self> {
        let json: Value = serde_json::from_str(value).ok()?;
        let object = json.as_object()?;
        let text = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_string);
        let status = match object.get("status") {
            None => BundleStatus::Pending,
            Some(status) => BundleStatus::parse(status.as_str()).unwrap_or(BundleStatus::Error),
        };
        Some(Self {
            id: text("id").unwrap_or_default(),
            version: Some(text("version").unwrap_or_else(|| VERSION_UNKNOWN.to_string())),
            downloaded: text("downloaded").unwrap_or_default().trim().to_string(),
            checksum: text("checksum").unwrap_or_default(),
            status,
            link: text("link"),
            comment: text("comment"),
        })
    }
}

/// ISO-8601 UTC timestamp with milliseconds (`2024-01-02T03:04:05.678Z`).
pub fn iso8601_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    iso8601_from_millis(now.as_millis() as i64)
}

pub fn iso8601_from_millis(millis: i64) -> String {
    let seconds = millis.div_euclid(1000);
    let ms = millis.rem_euclid(1000);
    let days = seconds.div_euclid(86_400);
    let secs_of_day = seconds.rem_euclid(86_400);
    // Civil-from-days (Howard Hinnant).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        y,
        m,
        d,
        secs_of_day / 3600,
        (secs_of_day % 3600) / 60,
        secs_of_day % 60,
        ms
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_iso_dates() {
        assert_eq!(iso8601_from_millis(0), DOWNLOADED_BUILTIN);
        assert_eq!(
            iso8601_from_millis(1_700_000_000_123),
            "2023-11-14T22:13:20.123Z"
        );
    }

    #[test]
    fn reads_android_and_ios_stored_json() {
        let android = r#"{"id":"abc","version":"1.0.0","downloaded":"2023-11-14T22:13:20.123+0000","checksum":"x","status":"success"}"#;
        let bundle = BundleInfo::from_stored_json(android).unwrap();
        assert_eq!(bundle.status, BundleStatus::Success);
        let ios = r#"{"id":"abc","version":"1.0.0","downloaded":"2023-11-14T22:13:20.123Z","checksum":"x","status":"pending","link":"l"}"#;
        let bundle = BundleInfo::from_stored_json(ios).unwrap();
        assert_eq!(bundle.link.as_deref(), Some("l"));
        assert!(BundleInfo::from_stored_json(&bundle.to_stored_json()).is_some());
    }

    #[test]
    fn builtin_rules() {
        let builtin = BundleInfo::new(ID_BUILTIN, None, BundleStatus::Error, "", "sum");
        assert_eq!(builtin.status(), BundleStatus::Success);
        assert_eq!(builtin.version_name(), "builtin");
        assert_eq!(builtin.checksum(), "");
        assert!(!builtin.is_downloaded());
    }
}
