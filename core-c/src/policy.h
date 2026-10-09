/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/* Update policy decisions (Rust policy.rs): auto-update modes, direct-update rules,
 * launch notifications and default-channel resets. Pure functions, no I/O.
 * Every returned `const char *` is a static string. */
#ifndef CG_POLICY_H
#define CG_POLICY_H

#include <stdbool.h>
#include <stdint.h>

#define CG_AUTO_UPDATE_OFF "off"
#define CG_AUTO_UPDATE_BACKGROUND "atBackground"
#define CG_AUTO_UPDATE_INSTALL "atInstall"
#define CG_AUTO_UPDATE_LAUNCH "onLaunch"
#define CG_AUTO_UPDATE_ALWAYS "always"
#define CG_AUTO_UPDATE_ONLY_DOWNLOAD "onlyDownload"

/* Direct update mode string used when no direct update applies. */
#define CG_DIRECT_UPDATE_DISABLED "false"

#define CG_SHAKE_GESTURE_SHAKE "shake"
#define CG_SHAKE_GESTURE_THREE_FINGER_PINCH "threeFingerPinch"

/* Minimum periodic check delay, in seconds, when periodic checks are enabled. */
#define CG_MIN_PERIOD_CHECK_DELAY_SECONDS 600

/* 0 (or negative) disables periodic checks; anything else is clamped to 10 minutes. */
int64_t cg_policy_normalized_period_check_delay_seconds(int64_t seconds);
/* Normalizes the `autoUpdate` config value (legacy booleans included). NULL = absent. */
const char *cg_policy_normalized_auto_update_mode(const char *value);
bool cg_policy_is_auto_update_mode_enabled(const char *mode);
bool cg_policy_should_auto_update_mode_set_next_bundle(const char *mode);
const char *cg_policy_direct_update_mode_for_auto_update_mode(const char *mode);
/* Maps the legacy `directUpdate` config value to an `autoUpdate` mode. */
const char *cg_policy_auto_update_mode_for_legacy_direct_update_mode(const char *direct_update_mode);
/* `onLaunch` direct updates are one-shot: consume the attempt once planned. */
bool cg_policy_should_consume_on_launch_direct_update(const char *direct_update_mode, bool planned);
/* "up_to_date", "blocked" or "failed". NULL = absent. */
const char *cg_policy_normalized_update_response_kind(const char *kind);
/* "threeFingerPinch" (value trimmed) or "shake". NULL = absent. */
const char *cg_policy_normalized_shake_menu_gesture(const char *value);
const char *cg_policy_stats_action_for_webview_error_type(const char *error_type);
/* A bundle path configured by something other than the updater (and not the builtin
 * bundle) must be reset to builtin. NULL bundle_path = absent. */
bool cg_policy_should_reset_for_foreign_bundle(const char *bundle_path, bool is_builtin, bool has_stored_bundle_info);
bool cg_policy_should_clear_persisted_default_channel(bool persist_default_channel_on_reinstall,
                                                      bool reset_when_update, bool native_build_version_changed,
                                                      bool restored_reinstall);
/* HTTP + decode share one pool: 8x cores, at least 32, at most 64 (overflow-safe). */
int64_t cg_policy_manifest_max_concurrent_files(int64_t processor_count);

#endif
