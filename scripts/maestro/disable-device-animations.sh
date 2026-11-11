#!/usr/bin/env bash
set -euo pipefail

run_animation_setting() {
  python3 - "$@" <<'PYTHON'
import subprocess
import sys
try:
    subprocess.run(sys.argv[1:], check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
except (OSError, subprocess.SubprocessError) as error:
    print(f"Could not disable device animations: {error}", file=sys.stderr)
PYTHON
}

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

  run_animation_setting adb "${serial_args[@]}" shell settings put global window_animation_scale 0
  run_animation_setting adb "${serial_args[@]}" shell settings put global transition_animation_scale 0
  run_animation_setting adb "${serial_args[@]}" shell settings put global animator_duration_scale 0
}

disable_ios_simulator_animations() {
  local simulator_id="${1:-${CAPGO_MAESTRO_IOS_SIMULATOR_ID:-}}"

  if [[ -z "$simulator_id" ]]; then
    return 0
  fi

  run_animation_setting xcrun simctl spawn "$simulator_id" defaults write com.apple.Accessibility ReduceMotionEnabled -bool true
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
