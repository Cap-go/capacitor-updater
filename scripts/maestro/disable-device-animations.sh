#!/usr/bin/env bash
set -euo pipefail

disable_android_emulator_animations() {
  if ! command -v adb >/dev/null 2>&1; then
    return 0
  fi

  local serial_args=()
  if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    serial_args=(-s "$ANDROID_SERIAL")
  elif [[ -n "${CAPGO_MAESTRO_ANDROID_DEVICE_ID:-}" ]]; then
    serial_args=(-s "$CAPGO_MAESTRO_ANDROID_DEVICE_ID")
  fi

  adb "${serial_args[@]}" shell settings put global window_animation_scale 0 >/dev/null 2>&1 || true
  adb "${serial_args[@]}" shell settings put global transition_animation_scale 0 >/dev/null 2>&1 || true
  adb "${serial_args[@]}" shell settings put global animator_duration_scale 0 >/dev/null 2>&1 || true
}

disable_ios_simulator_animations() {
  local simulator_id="${1:-${CAPGO_MAESTRO_IOS_SIMULATOR_ID:-}}"

  if [[ -z "$simulator_id" ]]; then
    return 0
  fi

  xcrun simctl spawn "$simulator_id" defaults write com.apple.Accessibility ReduceMotionEnabled -bool true >/dev/null 2>&1 || true
}

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
