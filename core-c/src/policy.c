/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#include "policy.h"

#include <stdlib.h>
#include <string.h>

#include "rt/str.h"

int64_t cg_policy_normalized_period_check_delay_seconds(int64_t seconds) {
    if (seconds <= 0) return 0;
    return seconds > CG_MIN_PERIOD_CHECK_DELAY_SECONDS ? seconds : CG_MIN_PERIOD_CHECK_DELAY_SECONDS;
}

const char *cg_policy_normalized_auto_update_mode(const char *value) {
    if (!value) return CG_AUTO_UPDATE_BACKGROUND;
    if (strcmp(value, "false") == 0 || strcmp(value, CG_AUTO_UPDATE_OFF) == 0) return CG_AUTO_UPDATE_OFF;
    if (strcmp(value, CG_AUTO_UPDATE_INSTALL) == 0) return CG_AUTO_UPDATE_INSTALL;
    if (strcmp(value, CG_AUTO_UPDATE_LAUNCH) == 0) return CG_AUTO_UPDATE_LAUNCH;
    if (strcmp(value, CG_AUTO_UPDATE_ALWAYS) == 0) return CG_AUTO_UPDATE_ALWAYS;
    if (strcmp(value, CG_AUTO_UPDATE_ONLY_DOWNLOAD) == 0) return CG_AUTO_UPDATE_ONLY_DOWNLOAD;
    return CG_AUTO_UPDATE_BACKGROUND;
}

bool cg_policy_is_auto_update_mode_enabled(const char *mode) { return !cg_eq(mode, CG_AUTO_UPDATE_OFF); }

bool cg_policy_should_auto_update_mode_set_next_bundle(const char *mode) {
    return cg_policy_is_auto_update_mode_enabled(mode) && !cg_eq(mode, CG_AUTO_UPDATE_ONLY_DOWNLOAD);
}

const char *cg_policy_direct_update_mode_for_auto_update_mode(const char *mode) {
    if (cg_eq(mode, CG_AUTO_UPDATE_INSTALL)) return CG_AUTO_UPDATE_INSTALL;
    if (cg_eq(mode, CG_AUTO_UPDATE_LAUNCH)) return CG_AUTO_UPDATE_LAUNCH;
    if (cg_eq(mode, CG_AUTO_UPDATE_ALWAYS)) return CG_AUTO_UPDATE_ALWAYS;
    return CG_DIRECT_UPDATE_DISABLED;
}

const char *cg_policy_auto_update_mode_for_legacy_direct_update_mode(const char *direct_update_mode) {
    if (cg_eq(direct_update_mode, CG_AUTO_UPDATE_INSTALL)) return CG_AUTO_UPDATE_INSTALL;
    if (cg_eq(direct_update_mode, CG_AUTO_UPDATE_LAUNCH)) return CG_AUTO_UPDATE_LAUNCH;
    if (cg_eq(direct_update_mode, CG_AUTO_UPDATE_ALWAYS)) return CG_AUTO_UPDATE_ALWAYS;
    return CG_AUTO_UPDATE_BACKGROUND;
}

bool cg_policy_should_consume_on_launch_direct_update(const char *direct_update_mode, bool planned) {
    return planned && cg_eq(direct_update_mode, CG_AUTO_UPDATE_LAUNCH);
}

const char *cg_policy_normalized_update_response_kind(const char *kind) {
    if (cg_eq(kind, "up_to_date")) return "up_to_date";
    if (cg_eq(kind, "blocked")) return "blocked";
    return "failed";
}

const char *cg_policy_normalized_shake_menu_gesture(const char *value) {
    if (!value) return CG_SHAKE_GESTURE_SHAKE;
    size_t start, len;
    cg_trim_range(value, &start, &len);
    if (len == strlen(CG_SHAKE_GESTURE_THREE_FINGER_PINCH) &&
        memcmp(value + start, CG_SHAKE_GESTURE_THREE_FINGER_PINCH, len) == 0)
        return CG_SHAKE_GESTURE_THREE_FINGER_PINCH;
    return CG_SHAKE_GESTURE_SHAKE;
}

const char *cg_policy_stats_action_for_webview_error_type(const char *error_type) {
    static const char *const MAP[][2] = {
        {"unhandled_rejection", "webview_unhandled_rejection"},
        {"resource_error", "webview_resource_error"},
        {"security_policy_violation", "webview_security_policy_violation"},
        {"webview_unclean_restart", "webview_unclean_restart"},
        {"render_process_gone", "webview_render_process_gone"},
        {"web_content_process_terminated", "webview_content_process_terminated"},
        {"webview_dom_content_loaded", "webview_dom_content_loaded"},
        {"webview_page_loaded", "webview_page_loaded"},
    };
    for (size_t i = 0; i < sizeof(MAP) / sizeof(MAP[0]); i++)
        if (cg_eq(error_type, MAP[i][0])) return MAP[i][1];
    return "webview_javascript_error";
}

bool cg_policy_should_reset_for_foreign_bundle(const char *bundle_path, bool is_builtin, bool has_stored_bundle_info) {
    if (!bundle_path) return false;
    size_t start, len;
    cg_trim_range(bundle_path, &start, &len);
    if (len == 0) return false;
    return !is_builtin && !has_stored_bundle_info;
}

bool cg_policy_should_clear_persisted_default_channel(bool persist_default_channel_on_reinstall,
                                                      bool reset_when_update, bool native_build_version_changed,
                                                      bool restored_reinstall) {
    return !persist_default_channel_on_reinstall &&
           (restored_reinstall || (reset_when_update && native_build_version_changed));
}

int64_t cg_policy_manifest_max_concurrent_files(int64_t processor_count) {
    int64_t count = processor_count > 1 ? processor_count : 1;
    int64_t scaled = count > INT64_MAX / 8 ? INT64_MAX : count * 8;
    return scaled < 32 ? 32 : scaled > 64 ? 64 : scaled;
}
