#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="$ROOT_DIR/.maestro-artifacts"
HOST_SERVER_PORT="${CAPGO_MAESTRO_PORT:-3192}"
HOST_SERVER_URL="${CAPGO_MAESTRO_HOST_BASE_URL:-http://127.0.0.1:${HOST_SERVER_PORT}}"
DEVICE_SERVER_URL="${CAPGO_MAESTRO_DEVICE_BASE_URL:-http://127.0.0.1:${HOST_SERVER_PORT}}"
APP_ID="app.capgo.updater"
APK_PATH="$ROOT_DIR/example-app/android/app/build/outputs/apk/debug/app-debug.apk"
SCENARIO_SELECTION="${1:-all}"
SERVER_PID=""
FLOW_RETRY_PATTERN="TcpForwarder.waitFor|allocateForwarder|TimeoutException|Android driver did not start up in time|UNAVAILABLE: io exception|Connection refused"
MAESTRO_CLI_NO_ANALYTICS="${MAESTRO_CLI_NO_ANALYTICS:-1}"
MAESTRO_DRIVER_STARTUP_TIMEOUT_VALUE="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-300000}"
MAESTRO_FLOW_TIMEOUT_SECONDS="${MAESTRO_FLOW_TIMEOUT_SECONDS:-360}"
LOG_WAIT_TIMEOUT_SECONDS="${LOG_WAIT_TIMEOUT_SECONDS:-180}"
ADB_COMMAND_TIMEOUT_SECONDS="${ADB_COMMAND_TIMEOUT_SECONDS:-15}"
TIMEOUT_CMD="$(command -v gtimeout || command -v timeout || true)"
SCENARIO_SEQUENCE=(deferred always at-install on-launch)
LOG_PATTERN_APP_TO_BACKGROUND='ProcessLifecycleOwner: App moved to background'
LOG_PATTERN_DOWNLOAD_SUCCEEDED='Download succeeded: SUCCEEDED'
LOG_PATTERN_DIRECT_UPDATE_TRUE='directUpdate: true'

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
  configure_server_routing
  return 0
}

configure_server_routing() {
  adb reverse "tcp:${HOST_SERVER_PORT}" "tcp:${HOST_SERVER_PORT}" >/dev/null 2>&1 || true
  return 0
}

ensure_android_device() {
  local state=""

  for _ in $(seq 1 30); do
    state="$(adb get-state 2>/dev/null || true)"
    if [[ "$state" == "device" ]] && adb devices | awk 'NR > 1 && $2 == "device" { found = 1 } END { exit(found ? 0 : 1) }'; then
      return 0
    fi
    sleep 2
  done

  echo "No Android emulator/device became available for Maestro." >&2
  return 1
}

load_scenario_config() {
  local scenario_id="$1"

  bun --eval "
import { getScenario } from '${ROOT_DIR}/scripts/maestro/scenarios.mjs';

const scenario = getScenario(process.argv[1]);
console.log([scenario.builtinLabel, ...scenario.releases.map((release) => release.version)].join('\t'));
" "$scenario_id"

  return 0
}

run_scenario() {
  local scenario_id="$1"
  local builtin_label=""
  local first_release=""
  local second_release=""

  IFS=$'\t' read -r builtin_label first_release second_release _ <<<"$(load_scenario_config "$scenario_id")"
  echo "=== Running Maestro scenario: $scenario_id ==="

  case "$scenario_id" in
    deferred)
      control_server reset deferred
      prepare_scenario deferred
      run_flow \
        deferred-download.yaml \
        SCENARIO_ID=deferred \
        DIRECT_UPDATE_MODE=false \
        BUILTIN_LABEL="$builtin_label" \
        FIRST_RELEASE="$first_release"
      wait_for_log_patterns \
        "deferred release downloads while builtin bundle stays active" \
        "New bundle: ${first_release} found\\. Current is: 1\\.0\\. Update will occur next time app moves to background\\." \
        "$LOG_PATTERN_DOWNLOAD_SUCCEEDED" \
        "updateAvailable: .*\"version\":\"${first_release}\"" \
        'setNext: true' \
        'directUpdate: false'
      run_flow \
        apply-after-background.yaml \
        SOURCE_LABEL="$builtin_label" \
        EXPECTED_LABEL="$first_release" \
        EXPECTED_RELEASE="$first_release"
      wait_for_log_patterns \
        "deferred release applies after the app backgrounds and resumes" \
        "$LOG_PATTERN_APP_TO_BACKGROUND" \
        "Updated to bundle: ${first_release}" \
        "Current bundle loaded successfully\\..*\"version\":\"${first_release}\""
      ;;
    always)
      control_server reset always
      prepare_scenario always
      run_flow \
        initial-direct-update.yaml \
        SCENARIO_ID=always \
        DIRECT_UPDATE_MODE=always \
        EXPECTED_LABEL="$first_release" \
        EXPECTED_RELEASE="$first_release"
      wait_for_log_patterns \
        "always direct update applies the first release on launch" \
        "New bundle: ${first_release} found\\. Current is: 1\\.0\\. Update will occur now\\." \
        "$LOG_PATTERN_DOWNLOAD_SUCCEEDED" \
        "$LOG_PATTERN_DIRECT_UPDATE_TRUE" \
        "Current bundle set to: .*${first_release}" \
        "Current bundle loaded successfully\\..*\"version\":\"${first_release}\""
      control_server advance always
      run_flow \
        resume-direct-update.yaml \
        SOURCE_LABEL="$first_release" \
        EXPECTED_LABEL="$second_release" \
        EXPECTED_RELEASE="$second_release"
      wait_for_log_patterns \
        "always direct update applies the second release after resume" \
        "$LOG_PATTERN_APP_TO_BACKGROUND" \
        "New bundle: ${second_release} found\\. Current is: ${first_release}\\. Update will occur now\\." \
        "$LOG_PATTERN_DOWNLOAD_SUCCEEDED" \
        "$LOG_PATTERN_DIRECT_UPDATE_TRUE" \
        "Current bundle set to: .*${second_release}" \
        "Current bundle loaded successfully\\..*\"version\":\"${second_release}\""
      ;;
    at-install)
      control_server reset at-install
      prepare_scenario at-install
      run_flow \
        initial-direct-update.yaml \
        SCENARIO_ID=at-install \
        DIRECT_UPDATE_MODE=atInstall \
        EXPECTED_LABEL="$first_release" \
        EXPECTED_RELEASE="$first_release"
      wait_for_log_patterns \
        "atInstall applies the first release on initial launch" \
        "New bundle: ${first_release} found\\. Current is: 1\\.0\\. Update will occur now\\." \
        "$LOG_PATTERN_DOWNLOAD_SUCCEEDED" \
        "$LOG_PATTERN_DIRECT_UPDATE_TRUE" \
        "Current bundle set to: .*${first_release}" \
        "Current bundle loaded successfully\\..*\"version\":\"${first_release}\""
      control_server advance at-install
      run_flow \
        apply-after-background.yaml
      wait_for_log_patterns \
        "atInstall downloads the second release and queues it for the next launch" \
        "$LOG_PATTERN_APP_TO_BACKGROUND" \
        "New bundle: ${second_release} found\\. Current is: ${first_release}\\. Update will occur next time app moves to background\\." \
        "$LOG_PATTERN_DOWNLOAD_SUCCEEDED" \
        'setNext: true' \
        'directUpdate: false'
      run_flow \
        apply-after-background.yaml
      wait_for_log_patterns \
        "atInstall applies the second release after another background and resume" \
        "$LOG_PATTERN_APP_TO_BACKGROUND" \
        "Updated to bundle: ${second_release}" \
        "Current bundle loaded successfully\\..*\"version\":\"${second_release}\""
      ;;
    on-launch)
      control_server reset on-launch
      prepare_scenario on-launch
      run_flow \
        initial-direct-update.yaml \
        SCENARIO_ID=on-launch \
        DIRECT_UPDATE_MODE=onLaunch \
        EXPECTED_LABEL="$first_release" \
        EXPECTED_RELEASE="$first_release"
      wait_for_log_patterns \
        "onLaunch applies the first release on the initial cold launch" \
        "New bundle: ${first_release} found\\. Current is: 1\\.0\\. Update will occur now\\." \
        "$LOG_PATTERN_DOWNLOAD_SUCCEEDED" \
        "$LOG_PATTERN_DIRECT_UPDATE_TRUE" \
        "Current bundle set to: .*${first_release}" \
        "Current bundle loaded successfully\\..*\"version\":\"${first_release}\""
      control_server advance on-launch
      run_flow \
        kill-then-direct-update.yaml \
        SOURCE_LABEL="$first_release" \
        EXPECTED_LABEL="$second_release" \
        EXPECTED_RELEASE="$second_release"
      wait_for_log_patterns \
        "onLaunch applies the second release after a full cold start" \
        "New bundle: ${second_release} found\\. Current is: ${first_release}\\. Update will occur now\\." \
        "$LOG_PATTERN_DOWNLOAD_SUCCEEDED" \
        "$LOG_PATTERN_DIRECT_UPDATE_TRUE" \
        "Current bundle set to: .*${second_release}" \
        "Current bundle loaded successfully\\..*\"version\":\"${second_release}\""
      ;;
    *)
      echo "Unknown Maestro scenario selection: $scenario_id" >&2
      return 1
      ;;
  esac

  echo "=== Completed Maestro scenario: $scenario_id ==="

  return 0
}

run_selected_scenarios() {
  local scenario_id

  if [[ "$SCENARIO_SELECTION" == "all" ]]; then
    for scenario_id in "${SCENARIO_SEQUENCE[@]}"; do
      run_scenario "$scenario_id"
    done
    return 0
  fi

  run_scenario "$SCENARIO_SELECTION"
  return 0
}

wait_for_android_boot() {
  local boot_completed=""

  for _ in $(seq 1 30); do
    boot_completed="$(
      {
        adb shell getprop sys.boot_completed 2>/dev/null || true
      } | tr -d '\r'
    )"
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
  configure_server_routing
  return 0
}

wait_for_package_manager() {
  local settings_output=""

  for _ in $(seq 1 30); do
    settings_output="$(
      {
        adb shell settings get global adb_enabled 2>&1 || true
      } | tr -d '\r' | awk 'NF { last = $0 } END { print last }'
    )"

    if adb shell cmd package list packages >/dev/null 2>&1 && [[ "$settings_output" =~ ^(0|1|null)$ ]]; then
      return 0
    fi
    sleep 2
  done

  echo "Android package manager and settings provider did not become ready in time for APK installation." >&2
  if [[ -n "$settings_output" ]]; then
    echo "Last settings readiness output: $settings_output" >&2
  fi
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

    if grep -Eq "Broken pipe|Can.t find service: package|Can.t find service: settings|Cannot access system provider: 'settings' before system providers are installed!|no devices/emulators found|device offline" "$output_file" && [[ $attempt -lt $max_attempts ]]; then
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
  local dump=""

  dump="$("$TIMEOUT_CMD" --foreground "${ADB_COMMAND_TIMEOUT_SECONDS}s" adb logcat -d -v brief 2>/dev/null || true)"

  if [[ -z "$dump" ]]; then
    return 0
  fi

  if command -v rg >/dev/null 2>&1; then
    printf '%s\n' "$dump" | rg 'CapgoUpdater|AndroidRuntime' || true
    return 0
  fi

  printf '%s\n' "$dump" | grep -E 'CapgoUpdater|AndroidRuntime' || true
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
  local deadline=$((SECONDS + LOG_WAIT_TIMEOUT_SECONDS))

  echo "Waiting for log state: $description"
  while (( SECONDS < deadline )); do
    dump="$(dump_relevant_logcat)"
    if [[ -n "$dump" ]] && logcat_contains_all "$dump" "$@"; then
      echo "Verified log state: $description"
      return 0
    fi

    sleep 1
  done

  echo "Logcat did not reach expected state within ${LOG_WAIT_TIMEOUT_SECONDS}s: $description" >&2
  echo "${dump:-<no relevant logcat output>}" | tail -n 200 >&2
  return 1
}

run_flow() {
  local flow_file="$1"
  shift
  local -a maestro_args=()
  local attempt=1
  local max_attempts=3
  local command_status=0
  local output_file
  local env_arg

  while [[ $# -gt 0 ]]; do
    env_arg="$1"
    maestro_args+=("-e" "$env_arg")
    shift
  done

  while [[ $attempt -le $max_attempts ]]; do
    echo "Running Maestro flow: $flow_file (attempt $attempt/$max_attempts)"
    prepare_device_for_maestro
    reset_adb_forwarding
    clear_logcat
    output_file="$(mktemp)"

    set +e
    MAESTRO_CLI_NO_ANALYTICS="$MAESTRO_CLI_NO_ANALYTICS" \
      MAESTRO_DRIVER_STARTUP_TIMEOUT="$MAESTRO_DRIVER_STARTUP_TIMEOUT_VALUE" \
      "$TIMEOUT_CMD" --foreground "${MAESTRO_FLOW_TIMEOUT_SECONDS}s" \
      maestro test "${maestro_args[@]}" "$ROOT_DIR/.maestro/$flow_file" 2>&1 | tee "$output_file"
    command_status=${PIPESTATUS[0]}
    set -e

    if [[ $command_status -eq 0 ]]; then
      rm -f "$output_file"
      return 0
    fi

    if [[ $command_status -eq 124 ]] && [[ $attempt -lt $max_attempts ]]; then
      echo "Retrying $flow_file after Maestro flow timeout (${MAESTRO_FLOW_TIMEOUT_SECONDS}s)..." >&2
      rm -f "$output_file"
      attempt=$((attempt + 1))
      restart_adb_server
      prepare_device_for_maestro
      reset_adb_forwarding
      sleep 5
      continue
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

if [[ -z "$TIMEOUT_CMD" ]]; then
  echo "GNU timeout is required to run Maestro flows. Install coreutils (gtimeout) on macOS or make sure timeout is available." >&2
  exit 1
fi

command -v maestro >/dev/null 2>&1 || {
  echo "Maestro CLI is required. Install it with https://maestro.mobile.dev/getting-started/installing-maestro." >&2
  exit 1
}

command -v adb >/dev/null 2>&1 || {
  echo "adb is required to run the Android live update test." >&2
  exit 1
}

export CAPGO_MAESTRO_DEVICE_BASE_URL="$DEVICE_SERVER_URL"

ensure_android_device

(cd "$ROOT_DIR/example-app" && bun install)
bun "$ROOT_DIR/scripts/maestro/build-bundles.mjs"
stop_stale_fake_server
bun "$ROOT_DIR/scripts/maestro/fake-capgo-server.mjs" >"$ARTIFACT_DIR/fake-capgo-server.log" 2>&1 &
SERVER_PID=$!
wait_for_server
run_selected_scenarios
