//! Update policy decisions: auto-update modes, direct-update rules, launch
//! notifications and default-channel resets. Pure functions, no I/O.

pub const AUTO_UPDATE_OFF: &str = "off";
pub const AUTO_UPDATE_BACKGROUND: &str = "atBackground";
pub const AUTO_UPDATE_INSTALL: &str = "atInstall";
pub const AUTO_UPDATE_LAUNCH: &str = "onLaunch";
pub const AUTO_UPDATE_ALWAYS: &str = "always";
pub const AUTO_UPDATE_ONLY_DOWNLOAD: &str = "onlyDownload";

/// Direct update mode string used when no direct update applies.
pub const DIRECT_UPDATE_DISABLED: &str = "false";

pub const SHAKE_GESTURE_SHAKE: &str = "shake";
pub const SHAKE_GESTURE_THREE_FINGER_PINCH: &str = "threeFingerPinch";

/// Minimum periodic check delay, in seconds, when periodic checks are enabled.
pub const MIN_PERIOD_CHECK_DELAY_SECONDS: i64 = 600;

/// `0` (or negative) disables periodic checks; anything else is clamped to 10 minutes.
pub fn normalized_period_check_delay_seconds(seconds: i64) -> i64 {
    if seconds <= 0 {
        0
    } else {
        seconds.max(MIN_PERIOD_CHECK_DELAY_SECONDS)
    }
}

/// Normalizes the `autoUpdate` config value (legacy booleans included).
pub fn normalized_auto_update_mode(value: Option<&str>) -> &'static str {
    match value {
        Some("false") | Some(AUTO_UPDATE_OFF) => AUTO_UPDATE_OFF,
        Some(AUTO_UPDATE_INSTALL) => AUTO_UPDATE_INSTALL,
        Some(AUTO_UPDATE_LAUNCH) => AUTO_UPDATE_LAUNCH,
        Some(AUTO_UPDATE_ALWAYS) => AUTO_UPDATE_ALWAYS,
        Some(AUTO_UPDATE_ONLY_DOWNLOAD) => AUTO_UPDATE_ONLY_DOWNLOAD,
        _ => AUTO_UPDATE_BACKGROUND,
    }
}

pub fn is_auto_update_mode_enabled(mode: &str) -> bool {
    mode != AUTO_UPDATE_OFF
}

pub fn should_auto_update_mode_set_next_bundle(mode: &str) -> bool {
    is_auto_update_mode_enabled(mode) && mode != AUTO_UPDATE_ONLY_DOWNLOAD
}

pub fn direct_update_mode_for_auto_update_mode(mode: &str) -> &'static str {
    match mode {
        AUTO_UPDATE_INSTALL => AUTO_UPDATE_INSTALL,
        AUTO_UPDATE_LAUNCH => AUTO_UPDATE_LAUNCH,
        AUTO_UPDATE_ALWAYS => AUTO_UPDATE_ALWAYS,
        _ => DIRECT_UPDATE_DISABLED,
    }
}

/// Maps the legacy `directUpdate` config value to an `autoUpdate` mode.
pub fn auto_update_mode_for_legacy_direct_update_mode(direct_update_mode: &str) -> &'static str {
    match direct_update_mode {
        AUTO_UPDATE_INSTALL => AUTO_UPDATE_INSTALL,
        AUTO_UPDATE_LAUNCH => AUTO_UPDATE_LAUNCH,
        AUTO_UPDATE_ALWAYS => AUTO_UPDATE_ALWAYS,
        _ => AUTO_UPDATE_BACKGROUND,
    }
}

pub fn is_direct_update_mode(direct_update_mode: &str) -> bool {
    matches!(
        direct_update_mode,
        AUTO_UPDATE_INSTALL | AUTO_UPDATE_LAUNCH | AUTO_UPDATE_ALWAYS
    )
}

/// `onLaunch` direct updates are one-shot: consume the attempt once planned.
pub fn should_consume_on_launch_direct_update(direct_update_mode: &str, planned: bool) -> bool {
    planned && direct_update_mode == AUTO_UPDATE_LAUNCH
}

pub fn normalized_update_response_kind(kind: Option<&str>) -> &'static str {
    match kind {
        Some("up_to_date") => "up_to_date",
        Some("blocked") => "blocked",
        _ => "failed",
    }
}

pub fn normalized_shake_menu_gesture(value: Option<&str>) -> &'static str {
    match value.map(str::trim) {
        Some(SHAKE_GESTURE_THREE_FINGER_PINCH) => SHAKE_GESTURE_THREE_FINGER_PINCH,
        _ => SHAKE_GESTURE_SHAKE,
    }
}

/// Missing values fall back to the default gesture; blank or unknown values are rejected.
pub fn is_supported_shake_menu_gesture(value: Option<&str>) -> bool {
    match value.map(str::trim) {
        None => true,
        Some(normalized) => {
            normalized == SHAKE_GESTURE_SHAKE || normalized == SHAKE_GESTURE_THREE_FINGER_PINCH
        }
    }
}

pub fn stats_action_for_webview_error_type(error_type: &str) -> &'static str {
    match error_type {
        "unhandled_rejection" => "webview_unhandled_rejection",
        "resource_error" => "webview_resource_error",
        "security_policy_violation" => "webview_security_policy_violation",
        "webview_unclean_restart" => "webview_unclean_restart",
        "render_process_gone" => "webview_render_process_gone",
        "web_content_process_terminated" => "webview_content_process_terminated",
        "webview_dom_content_loaded" => "webview_dom_content_loaded",
        "webview_page_loaded" => "webview_page_loaded",
        _ => "webview_javascript_error",
    }
}

/// Launch downloads have no waiter; the host emits `appReady` for them unless
/// the bundle is applied right away (direct install / preview session).
pub fn should_notify_launch_download_ready(
    awaited_by_caller: bool,
    success: bool,
    direct_install: bool,
    preview_session: bool,
) -> bool {
    if awaited_by_caller {
        return false;
    }
    if !success {
        return true;
    }
    !direct_install && !preview_session
}

pub fn launch_download_ready_status(success: bool, set_next: bool) -> &'static str {
    if !success {
        "Error downloading file"
    } else if set_next {
        "update downloaded, will install next background"
    } else {
        "update downloaded, autoUpdate onlyDownload"
    }
}

/// A bundle path configured by something other than the updater (and not the
/// builtin bundle) must be reset to builtin.
pub fn should_reset_for_foreign_bundle(
    bundle_path: Option<&str>,
    is_builtin: bool,
    has_stored_bundle_info: bool,
) -> bool {
    match bundle_path {
        Some(path) if !path.trim().is_empty() => !is_builtin && !has_stored_bundle_info,
        _ => false,
    }
}

pub fn should_clear_persisted_default_channel(
    persist_default_channel_on_reinstall: bool,
    reset_when_update: bool,
    native_build_version_changed: bool,
    restored_reinstall: bool,
) -> bool {
    !persist_default_channel_on_reinstall
        && (restored_reinstall || (reset_when_update && native_build_version_changed))
}

/// HTTP + decode share one pool: 2x cores, at least 8, at most 64.
pub fn manifest_max_concurrent_files(processor_count: i64) -> i64 {
    processor_count.max(1).saturating_mul(2).clamp(8, 64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn period_delay() {
        assert_eq!(normalized_period_check_delay_seconds(-1), 0);
        assert_eq!(normalized_period_check_delay_seconds(1), 600);
        assert_eq!(normalized_period_check_delay_seconds(3600), 3600);
    }

    #[test]
    fn concurrency_never_overflows() {
        assert_eq!(manifest_max_concurrent_files(i64::MAX / 2), 64);
    }
}
