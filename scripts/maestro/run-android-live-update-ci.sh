#!/usr/bin/env bash
set -euo pipefail

cleanup_android_emulator() {
  local port="${EMULATOR_PORT:-5554}"
  local serial="${ANDROID_SERIAL:-emulator-${port}}"

  if command -v adb >/dev/null 2>&1; then
    adb -s "$serial" emu kill >/dev/null 2>&1 || true
    sleep 2
    adb kill-server >/dev/null 2>&1 || true
  fi

  if command -v pkill >/dev/null 2>&1; then
    pkill -9 -f "emulator.*-port[ ]${port}" >/dev/null 2>&1 || true
    pkill -9 -f "qemu-system.*-port[ ]${port}" >/dev/null 2>&1 || true
  fi
}

trap cleanup_android_emulator EXIT

"$(dirname "$0")/run-android-live-update.sh" "$@"
