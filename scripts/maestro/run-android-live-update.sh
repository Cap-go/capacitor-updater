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
}

stop_stale_fake_server() {
  local pids
  pids="$(lsof -ti "tcp:$HOST_SERVER_PORT" 2>/dev/null || true)"

  if [[ -n "$pids" ]]; then
    echo "$pids" | xargs kill >/dev/null 2>&1 || true
    sleep 1
  fi
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
}

ensure_android_device() {
  adb wait-for-device >/dev/null 2>&1
  if ! adb devices | awk 'NR > 1 && $2 == "device" { found = 1 } END { exit(found ? 0 : 1) }'; then
    echo "No Android emulator/device is available for Maestro." >&2
    exit 1
  fi
}

install_apk() {
  adb uninstall "$APP_ID" >/dev/null 2>&1 || true
  adb install -r "$APK_PATH" >/dev/null
}

control_server() {
  local action="$1"
  local scenario="$2"
  curl --silent --show-error --fail -X POST "$HOST_SERVER_URL/api/control/$action?scenario=$scenario" >/dev/null
}

run_flow() {
  local flow_file="$1"
  shift
  local maestro_args=()
  local attempt=1
  local max_attempts=2
  local output_file

  while [[ $# -gt 0 ]]; do
    maestro_args+=("-e" "$1")
    shift
  done

  while [[ $attempt -le $max_attempts ]]; do
    reset_adb_forwarding
    output_file="$(mktemp)"

    if maestro test "${maestro_args[@]}" "$ROOT_DIR/.maestro/$flow_file" 2>&1 | tee "$output_file"; then
      rm -f "$output_file"
      return 0
    fi

    if grep -q "TcpForwarder.waitFor\|allocateForwarder\|TimeoutException" "$output_file" && [[ $attempt -lt $max_attempts ]]; then
      echo "Retrying $flow_file after Maestro ADB forwarding timeout..." >&2
      rm -f "$output_file"
      attempt=$((attempt + 1))
      sleep 2
      continue
    fi

    rm -f "$output_file"
    return 1
  done
}

prepare_scenario() {
  local scenario="$1"
  bun "$ROOT_DIR/scripts/maestro/prepare-android-scenario.mjs" "$scenario"
  install_apk
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
    run_flow \
      apply-after-background.yaml \
      SOURCE_LABEL=deferred-builtin \
      FINAL_LABEL=deferred-v1 \
      FINAL_RELEASE=deferred-v1
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
    control_server advance always
    run_flow \
      resume-direct-update.yaml \
      SOURCE_LABEL=always-v1 \
      EXPECTED_LABEL=always-v2 \
      EXPECTED_RELEASE=always-v2
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
    control_server advance at-install
    run_flow \
      resume-download-then-background.yaml \
      SOURCE_LABEL=at-install-v1 \
      PENDING_RELEASE=at-install-v2 \
      FINAL_LABEL=at-install-v2 \
      FINAL_RELEASE=at-install-v2
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
    control_server advance on-launch
    run_flow \
      kill-then-direct-update.yaml \
      SOURCE_LABEL=on-launch-v1 \
      FINAL_LABEL=on-launch-v2 \
      FINAL_RELEASE=on-launch-v2
    ;;
  *)
    echo "Unknown Maestro scenario selection: $SCENARIO_SELECTION" >&2
    exit 1
    ;;
esac
