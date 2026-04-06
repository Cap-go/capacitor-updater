#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE_DIR="$ROOT_DIR/example-app"
APK_PATH="$EXAMPLE_DIR/android/app/build/outputs/apk/debug/app-debug.apk"
RESULTS_DIR="$ROOT_DIR/maestro-results"
SKIP_BUILD="${CAPGO_MAESTRO_SKIP_BUILD:-0}"
EMULATOR_BOOT_TIMEOUT_SECONDS="${CAPGO_MAESTRO_EMULATOR_BOOT_TIMEOUT_SECONDS:-180}"
MAESTRO_TIMEOUT_SECONDS="${CAPGO_MAESTRO_TIMEOUT_SECONDS:-300}"
MAESTRO_DRIVER_STARTUP_TIMEOUT="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-180000}"
APK_INSTALL_RETRIES="${CAPGO_MAESTRO_APK_INSTALL_RETRIES:-3}"
ANR_WATCHER_PID=""

cleanup() {
  if [[ -n "$ANR_WATCHER_PID" ]]; then
    kill "$ANR_WATCHER_PID" >/dev/null 2>&1 || true
    wait "$ANR_WATCHER_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT

wait_for_emulator_boot() {
  local deadline=$((SECONDS + EMULATOR_BOOT_TIMEOUT_SECONDS))
  local sys_boot_completed=""
  local dev_boot_completed=""

  if ! timeout "${EMULATOR_BOOT_TIMEOUT_SECONDS}s" adb wait-for-device; then
    echo "Emulator failed to connect within ${EMULATOR_BOOT_TIMEOUT_SECONDS} seconds." >&2
    exit 1
  fi

  while (( SECONDS < deadline )); do
    sys_boot_completed="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
    dev_boot_completed="$(adb shell getprop dev.bootcomplete 2>/dev/null | tr -d '\r')"
    if [[ "$sys_boot_completed" == "1" || "$dev_boot_completed" == "1" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "Emulator failed to complete boot within ${EMULATOR_BOOT_TIMEOUT_SECONDS} seconds." >&2
  exit 1
}

watch_for_android_anr_dialog() {
  local hierarchy=""
  local wait_button_pattern='text="Wait".*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"'
  local x=""
  local y=""

  while true; do
    hierarchy="$(adb exec-out uiautomator dump /dev/tty 2>/dev/null | tr -d '\r' | tr '\n' ' ' || true)"
    if [[ "$hierarchy" =~ $wait_button_pattern ]]; then
      x=$(((BASH_REMATCH[1] + BASH_REMATCH[3]) / 2))
      y=$(((BASH_REMATCH[2] + BASH_REMATCH[4]) / 2))
      echo "Detected Android ANR dialog; tapping Wait." >&2
      adb shell input tap "$x" "$y" >/dev/null 2>&1 || true
      sleep 1
      continue
    fi
    sleep 2
  done
}

install_apk_with_retries() {
  local attempt=1
  local status=0

  while (( attempt <= APK_INSTALL_RETRIES )); do
    adb install -r "$APK_PATH"
    status=$?
    if (( status == 0 )); then
      return 0
    fi

    if (( attempt == APK_INSTALL_RETRIES )); then
      echo "Failed to install the example APK after ${APK_INSTALL_RETRIES} attempts." >&2
      return "$status"
    fi

    echo "APK install attempt ${attempt} failed; waiting for the emulator before retrying." >&2
    adb wait-for-device >/dev/null 2>&1 || true
    wait_for_emulator_boot
    sleep 5
    ((attempt += 1))
  done

  return "$status"
}

if ! command -v adb >/dev/null 2>&1; then
  echo "adb is required to run Android Maestro tests." >&2
  exit 1
fi

if ! command -v maestro >/dev/null 2>&1; then
  echo "maestro is required to run Android Maestro tests." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to run Capacitor CLI commands." >&2
  exit 1
fi

if ! node -e "process.exit(Number(process.versions.node.split('.')[0]) >= 22 ? 0 : 1)"; then
  echo "Node.js >=22 is required because Capacitor CLI no longer supports older versions." >&2
  exit 1
fi

cd "$ROOT_DIR"

if [[ "$SKIP_BUILD" != "1" ]]; then
  if [[ ! -d node_modules ]]; then
    bun install
  fi

  bun run build

  # Build the plugin first so the example app's file:.. dependency has dist/ available.
  (
    cd "$EXAMPLE_DIR"
    bun install
    bun run build
    bunx cap sync android
  )

  (
    cd "$EXAMPLE_DIR/android"
    ./gradlew assembleDebug
  )
fi

if [[ ! -f "$APK_PATH" ]]; then
  echo "Expected debug APK at $APK_PATH" >&2
  exit 1
fi

wait_for_emulator_boot
ANDROID_DEVICE_ID="${CAPGO_MAESTRO_ANDROID_DEVICE_ID:-$(adb get-serialno 2>/dev/null | tr -d '\r')}"
if [[ -z "$ANDROID_DEVICE_ID" || "$ANDROID_DEVICE_ID" == "unknown" ]]; then
  echo "Unable to determine the Android emulator device ID for Maestro." >&2
  exit 1
fi

adb shell settings put global window_animation_scale 0 || true
adb shell settings put global transition_animation_scale 0 || true
adb shell settings put global animator_duration_scale 0 || true
adb shell input keyevent 82 || true
install_apk_with_retries

rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

watch_for_android_anr_dialog &
ANR_WATCHER_PID=$!

if timeout "${MAESTRO_TIMEOUT_SECONDS}s" env MAESTRO_DRIVER_STARTUP_TIMEOUT="$MAESTRO_DRIVER_STARTUP_TIMEOUT" maestro test \
  "$ROOT_DIR/.maestro" \
  --platform android \
  --udid "$ANDROID_DEVICE_ID" \
  --format junit \
  --output "$RESULTS_DIR/junit.xml" \
  --debug-output "$RESULTS_DIR/debug" \
  --flatten-debug-output \
  --test-output-dir "$RESULTS_DIR/artifacts"; then
  :
else
  status=$?
  if [[ $status -eq 124 ]]; then
    echo "Maestro test timed out after ${MAESTRO_TIMEOUT_SECONDS} seconds." >&2
  fi
  exit "$status"
fi
