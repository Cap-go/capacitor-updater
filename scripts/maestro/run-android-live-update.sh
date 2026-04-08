#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="$ROOT_DIR/.maestro-artifacts"
HOST_SERVER_PORT="${CAPGO_MAESTRO_PORT:-3192}"
HOST_SERVER_URL="${CAPGO_MAESTRO_HOST_BASE_URL:-http://127.0.0.1:${HOST_SERVER_PORT}}"
APP_ID="app.capgo.updater"
APK_PATH="$ROOT_DIR/example-app/android/app/build/outputs/apk/debug/app-debug.apk"
SCENARIO_SELECTION="${1:-all}"
SERVER_PID=""
FLOW_RETRY_PATTERN="TcpForwarder.waitFor|allocateForwarder|TimeoutException|Android driver did not start up in time|UNAVAILABLE: io exception|Connection refused"

if [[ "$SCENARIO_SELECTION" == "all" ]]; then
  for scenario in deferred always at-install on-launch; do
    "$0" "$scenario"
  done
  exit 0
fi

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  stop_stale_fake_server
  return 0
}

stop_stale_fake_server() {
  local pids
  pids="$(lsof -ti "tcp:$HOST_SERVER_PORT" 2>/dev/null || true)"

  if [[ -n "$pids" ]]; then
    echo "$pids" | xargs kill >/dev/null 2>&1 || true
    sleep 1
  fi

  return 0
}

wait_for_server() {
  for _ in $(seq 1 30); do
    if curl --silent --fail "$HOST_SERVER_URL/health" >/dev/null; then
      return 0
    fi
    sleep 1
  done

  echo "Fake Capgo server did not start in time." >&2
  return 1
}

reset_adb_forwarding() {
  adb forward --remove-all >/dev/null 2>&1 || true
  adb reverse --remove-all >/dev/null 2>&1 || true
  return 0
}

ensure_android_device() {
  adb wait-for-device >/dev/null 2>&1
  if ! adb devices | awk 'NR > 1 && $2 == "device" { found = 1 } END { exit(found ? 0 : 1) }'; then
    echo "No Android emulator/device is available for Maestro." >&2
    exit 1
  fi

  return 0
}

wait_for_android_boot() {
  local boot_completed=""

  for _ in $(seq 1 30); do
    boot_completed="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
    if [[ "$boot_completed" == "1" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "Android emulator did not finish booting in time for Maestro." >&2
  return 1
}

unlock_android_device() {
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
  adb shell input keyevent 82 >/dev/null 2>&1 || true
  adb shell settings put global stay_on_while_plugged_in 3 >/dev/null 2>&1 || true
  return 0
}

restart_adb_server() {
  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null 2>&1 || true
  return 0
}

prepare_device_for_maestro() {
  ensure_android_device
  wait_for_android_boot
  unlock_android_device
  return 0
}

wait_for_package_manager() {
  for _ in $(seq 1 30); do
    if adb shell cmd package list packages >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "Android package manager did not become ready in time for APK installation." >&2
  return 1
}

install_apk() {
  local attempt=1
  local max_attempts=3
  local output_file

  prepare_device_for_maestro
  wait_for_package_manager

  while [[ $attempt -le $max_attempts ]]; do
    output_file="$(mktemp)"
    adb uninstall "$APP_ID" >/dev/null 2>&1 || true

    if adb install -r "$APK_PATH" >"$output_file" 2>&1; then
      rm -f "$output_file"
      return 0
    fi

    if grep -Eq 'Broken pipe|Can.t find service: package|no devices/emulators found|device offline' "$output_file" && [[ $attempt -lt $max_attempts ]]; then
      rm -f "$output_file"
      attempt=$((attempt + 1))
      restart_adb_server
      prepare_device_for_maestro
      wait_for_package_manager
      sleep 5
      continue
    fi

    cat "$output_file" >&2
    rm -f "$output_file"
    return 1
  done

  return 1
}

control_server() {
  local action="$1"
  local scenario="$2"
  curl --silent --show-error --fail -X POST "$HOST_SERVER_URL/api/control/$action?scenario=$scenario" >/dev/null
  return 0
}

clear_logcat() {
  adb logcat -c >/dev/null 2>&1 || true
  return 0
}

dump_relevant_logcat() {
  adb logcat -d -v brief CapgoUpdater:I AndroidRuntime:I '*:S' 2>/dev/null || true
  return 0
}

filter_logcat() {
  local pattern="$1"

  if command -v rg >/dev/null 2>&1; then
    dump_relevant_logcat | rg "$pattern" || true
    return 0
  fi

  dump_relevant_logcat | grep -E "$pattern" || true
  return 0
}

logcat_contains_all() {
  local dump="$1"
  shift
  local expected

  for expected in "$@"; do
    if ! printf '%s\n' "$dump" | grep -Eq -- "$expected"; then
      return 1
    fi
  done

  return 0
}

wait_for_log_patterns() {
  local description="$1"
  shift
  local dump=""

  for _ in $(seq 1 180); do
    dump="$(dump_relevant_logcat)"
    if [[ -n "$dump" ]] && logcat_contains_all "$dump" "$@"; then
      return 0
    fi

    sleep 1
  done

  echo "Logcat did not reach expected state: $description" >&2
  echo "${dump:-<no relevant logcat output>}" | tail -n 200 >&2
  return 1
}

run_flow() {
  local flow_file="$1"
  shift
  local -a maestro_args=()
  local attempt=1
  local max_attempts=3
  local output_file
  local env_arg

  while [[ $# -gt 0 ]]; do
    env_arg="$1"
    maestro_args+=("-e" "$env_arg")
    shift
  done

  while [[ $attempt -le $max_attempts ]]; do
    prepare_device_for_maestro
    reset_adb_forwarding
    clear_logcat
    output_file="$(mktemp)"

    if maestro test "${maestro_args[@]}" "$ROOT_DIR/.maestro/$flow_file" 2>&1 | tee "$output_file"; then
      rm -f "$output_file"
      return 0
    fi

    if grep -Eq "$FLOW_RETRY_PATTERN" "$output_file" && [[ $attempt -lt $max_attempts ]]; then
      echo "Retrying $flow_file after Maestro ADB forwarding timeout..." >&2
      rm -f "$output_file"
      attempt=$((attempt + 1))
      restart_adb_server
      prepare_device_for_maestro
      reset_adb_forwarding
      sleep 5
      continue
    fi

    rm -f "$output_file"
    return 1
  done

  return 1
}

prepare_scenario() {
  local scenario="$1"
  bun "$ROOT_DIR/scripts/maestro/prepare-android-scenario.mjs" "$scenario"
  install_apk
  return 0
}

mkdir -p "$ARTIFACT_DIR"
trap cleanup EXIT

command -v maestro >/dev/null 2>&1 || {
  echo "Maestro CLI is required. Install it with https://maestro.mobile.dev/getting-started/installing-maestro." >&2
  exit 1
}

command -v adb >/dev/null 2>&1 || {
  echo "adb is required to run the Android live update test." >&2
  exit 1
}

ensure_android_device

(cd "$ROOT_DIR/example-app" && bun install)
bun "$ROOT_DIR/scripts/maestro/build-bundles.mjs"
stop_stale_fake_server
bun "$ROOT_DIR/scripts/maestro/fake-capgo-server.mjs" >"$ARTIFACT_DIR/fake-capgo-server.log" 2>&1 &
SERVER_PID=$!
wait_for_server

case "$SCENARIO_SELECTION" in
  deferred)
    control_server reset deferred
    prepare_scenario deferred
    run_flow \
      deferred-download.yaml \
      SCENARIO_ID=deferred \
      DIRECT_UPDATE_MODE=false \
      BUILTIN_LABEL=deferred-builtin \
      FIRST_RELEASE=deferred-v1
    wait_for_log_patterns \
      "deferred release downloads while builtin bundle stays active" \
      'New bundle: deferred-v1 found\. Current is: 1\.0\. Update will occur next time app moves to background\.' \
      'Download succeeded: SUCCEEDED' \
      'updateAvailable: .*"version":"deferred-v1"' \
      'setNext: true' \
      'directUpdate: false'
    run_flow \
      apply-after-background.yaml \
      SOURCE_LABEL=deferred-builtin \
      EXPECTED_LABEL=deferred-v1 \
      EXPECTED_RELEASE=deferred-v1
    wait_for_log_patterns \
      "deferred release applies after the app backgrounds and resumes" \
      'ProcessLifecycleOwner: App moved to background' \
      'Updated to bundle: deferred-v1' \
      'Current bundle loaded successfully\..*"version":"deferred-v1"'
    ;;
  always)
    control_server reset always
    prepare_scenario always
    run_flow \
      initial-direct-update.yaml \
      SCENARIO_ID=always \
      DIRECT_UPDATE_MODE=always \
      EXPECTED_LABEL=always-v1 \
      EXPECTED_RELEASE=always-v1
    wait_for_log_patterns \
      "always direct update applies the first release on launch" \
      'New bundle: always-v1 found\. Current is: 1\.0\. Update will occur now\.' \
      'Download succeeded: SUCCEEDED' \
      'directUpdate: true' \
      'Current bundle set to: .*always-v1' \
      'Current bundle loaded successfully\..*"version":"always-v1"'
    control_server advance always
    run_flow \
      resume-direct-update.yaml \
      SOURCE_LABEL=always-v1 \
      EXPECTED_LABEL=always-v2 \
      EXPECTED_RELEASE=always-v2
    wait_for_log_patterns \
      "always direct update applies the second release after resume" \
      'ProcessLifecycleOwner: App moved to background' \
      'New bundle: always-v2 found\. Current is: always-v1\. Update will occur now\.' \
      'Download succeeded: SUCCEEDED' \
      'directUpdate: true' \
      'Current bundle set to: .*always-v2' \
      'Current bundle loaded successfully\..*"version":"always-v2"'
    ;;
  at-install)
    control_server reset at-install
    prepare_scenario at-install
    run_flow \
      initial-direct-update.yaml \
      SCENARIO_ID=at-install \
      DIRECT_UPDATE_MODE=atInstall \
      EXPECTED_LABEL=at-install-v1 \
      EXPECTED_RELEASE=at-install-v1
    wait_for_log_patterns \
      "atInstall applies the first release on initial launch" \
      'New bundle: at-install-v1 found\. Current is: 1\.0\. Update will occur now\.' \
      'Download succeeded: SUCCEEDED' \
      'directUpdate: true' \
      'Current bundle set to: .*at-install-v1' \
      'Current bundle loaded successfully\..*"version":"at-install-v1"'
    control_server advance at-install
    run_flow \
      apply-after-background.yaml
    wait_for_log_patterns \
      "atInstall downloads the second release and queues it for the next launch" \
      'ProcessLifecycleOwner: App moved to background' \
      'New bundle: at-install-v2 found\. Current is: at-install-v1\. Update will occur next time app moves to background\.' \
      'Download succeeded: SUCCEEDED' \
      'setNext: true' \
      'directUpdate: false'
    run_flow \
      apply-after-background.yaml
    wait_for_log_patterns \
      "atInstall applies the second release after another background and resume" \
      'ProcessLifecycleOwner: App moved to background' \
      'Updated to bundle: at-install-v2' \
      'Current bundle loaded successfully\..*"version":"at-install-v2"'
    ;;
  on-launch)
    control_server reset on-launch
    prepare_scenario on-launch
    run_flow \
      initial-direct-update.yaml \
      SCENARIO_ID=on-launch \
      DIRECT_UPDATE_MODE=onLaunch \
      EXPECTED_LABEL=on-launch-v1 \
      EXPECTED_RELEASE=on-launch-v1
    wait_for_log_patterns \
      "onLaunch applies the first release on the initial cold launch" \
      'New bundle: on-launch-v1 found\. Current is: 1\.0\. Update will occur now\.' \
      'Download succeeded: SUCCEEDED' \
      'directUpdate: true' \
      'Current bundle set to: .*on-launch-v1' \
      'Current bundle loaded successfully\..*"version":"on-launch-v1"'
    control_server advance on-launch
    run_flow \
      kill-then-direct-update.yaml \
      SOURCE_LABEL=on-launch-v1 \
      EXPECTED_LABEL=on-launch-v2 \
      EXPECTED_RELEASE=on-launch-v2
    wait_for_log_patterns \
      "onLaunch applies the second release after a full cold start" \
      'New bundle: on-launch-v2 found\. Current is: on-launch-v1\. Update will occur now\.' \
      'Download succeeded: SUCCEEDED' \
      'directUpdate: true' \
      'Current bundle set to: .*on-launch-v2' \
      'Current bundle loaded successfully\..*"version":"on-launch-v2"'
    ;;
  *)
    echo "Unknown Maestro scenario selection: $SCENARIO_SELECTION" >&2
    exit 1
    ;;
esac
