//! Bundle model rules shared by every host.

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
