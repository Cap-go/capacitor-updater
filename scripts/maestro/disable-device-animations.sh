#!/usr/bin/env bash
set -euo pipefail

ANDROID_ANIMATION_KEYS=(window_animation_scale transition_animation_scale animator_duration_scale)
ANDROID_ANIMATION_ORIGINAL_VALUES=()
ANDROID_ANIMATION_DEVICE_ID=""

run_animation_setting() {
  python3 - "$@" <<'PYTHON'
import subprocess
import sys
try:
    result = subprocess.run(sys.argv[1:], check=True, timeout=10, capture_output=True, text=True)
    sys.stdout.write(result.stdout)
except (OSError, subprocess.SubprocessError) as error:
    print(f"Could not access device animation settings: {error}", file=sys.stderr)
    sys.exit(1)
PYTHON
}

capture_android_animation_settings() {
  if [[ -n "$ANDROID_ANIMATION_DEVICE_ID" ]]; then
    return 0
  fi

  local adb_command=(adb)
  local device_id=""
  local key=""
  local value=""
  local original_values=()
  if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    adb_command+=(-s "$ANDROID_SERIAL")
  elif [[ -n "${CAPGO_MAESTRO_ANDROID_DEVICE_ID:-}" ]]; then
    adb_command+=(-s "$CAPGO_MAESTRO_ANDROID_DEVICE_ID")
  fi

  device_id="$(run_animation_setting "${adb_command[@]}" get-serialno)" || return 1
  device_id="${device_id//$'\r'/}"
  if [[ -z "$device_id" || "$device_id" == "unknown" ]]; then
    echo "Skipping animation changes because the Android device could not be identified." >&2
    return 1
  fi

  # Capture every original before changing any setting, and keep it across retries.
  for key in "${ANDROID_ANIMATION_KEYS[@]}"; do
    value="$(run_animation_setting adb -s "$device_id" shell settings get global "$key")" || return 1
    value="${value//$'\r'/}"
    if [[ ! "$value" =~ ^(null|[0-9]+([.][0-9]+)?)$ ]]; then
      echo "Skipping animation changes because $key could not be read reliably." >&2
      return 1
    fi
    original_values+=("$value")
  done
  ANDROID_ANIMATION_ORIGINAL_VALUES=("${original_values[@]}")
  ANDROID_ANIMATION_DEVICE_ID="$device_id"
}

disable_android_emulator_animations() {
  if ! command -v adb >/dev/null 2>&1 || ! capture_android_animation_settings; then
    return 0
  fi

  local key=""
  for key in "${ANDROID_ANIMATION_KEYS[@]}"; do
    run_animation_setting adb -s "$ANDROID_ANIMATION_DEVICE_ID" shell settings put global "$key" 0 >/dev/null || true
  done
}

restore_android_animation_settings() {
  if [[ -z "$ANDROID_ANIMATION_DEVICE_ID" ]]; then
    return 0
  fi

  local index=""
  local key=""
  local value=""
  for index in "${!ANDROID_ANIMATION_KEYS[@]}"; do
    key="${ANDROID_ANIMATION_KEYS[$index]}"
    value="${ANDROID_ANIMATION_ORIGINAL_VALUES[$index]}"
    if [[ "$value" == "null" ]]; then
      run_animation_setting adb -s "$ANDROID_ANIMATION_DEVICE_ID" shell settings delete global "$key" >/dev/null || true
    else
      run_animation_setting adb -s "$ANDROID_ANIMATION_DEVICE_ID" shell settings put global "$key" "$value" >/dev/null || true
    fi
  done
}

disable_ios_simulator_animations() {
  local simulator_id="${1:-${CAPGO_MAESTRO_IOS_SIMULATOR_ID:-}}"

  if [[ -z "$simulator_id" ]]; then
    return 0
  fi

  run_animation_setting xcrun simctl spawn "$simulator_id" defaults write com.apple.Accessibility ReduceMotionEnabled -bool true >/dev/null || true
}

# Runners source this file so their exit traps can restore the saved settings.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

case "${1:-}" in
  android)
    disable_android_emulator_animations
    ;;
  ios)
    disable_ios_simulator_animations "${2:-}"
    ;;
  all)
    disable_android_emulator_animations
    disable_ios_simulator_animations "${2:-}"
    ;;
  *)
    echo "Usage: disable-device-animations.sh {android|ios [simulator_id]|all [simulator_id]}" >&2
    exit 1
    ;;
esac
