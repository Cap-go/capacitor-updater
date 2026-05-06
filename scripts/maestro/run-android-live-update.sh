#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="$ROOT_DIR/.maestro-artifacts"
HOST_SERVER_PORT="${CAPGO_MAESTRO_PORT:-3192}"
HOST_SERVER_URL="${CAPGO_MAESTRO_HOST_BASE_URL:-http://127.0.0.1:${HOST_SERVER_PORT}}"
DEVICE_SERVER_URL="${CAPGO_MAESTRO_DEVICE_BASE_URL:-http://127.0.0.1:${HOST_SERVER_PORT}}"
APP_ID="app.capgo.updater"
APP_ACTIVITY="${CAPGO_MAESTRO_ANDROID_ACTIVITY:-app.capgo.updater/.MainActivity}"
APP_READY_TITLE="CAPGO OTA VALIDATION"
APP_READY_ACTION="Run notifyAppReady"
APK_PATH="$ROOT_DIR/example-app/android/app/build/outputs/apk/debug/app-debug.apk"
SCENARIO_SELECTION="${1:-all}"
SERVER_PID=""
FLOW_RETRY_PATTERN="TcpForwarder.waitFor|allocateForwarder|TimeoutException|Android driver did not start up in time|UNAVAILABLE: io exception|Connection refused|Broken pipe|Failure calling service package|Can.t find service: package|Can.t find service: settings|Cannot access system provider: 'settings'"
MAESTRO_CLI_NO_ANALYTICS="${MAESTRO_CLI_NO_ANALYTICS:-1}"
MAESTRO_DRIVER_STARTUP_TIMEOUT_VALUE="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-300000}"
MAESTRO_FLOW_TIMEOUT_SECONDS="${MAESTRO_FLOW_TIMEOUT_SECONDS:-360}"
APP_BACKGROUND_SETTLE_SECONDS="${CAPGO_MAESTRO_BACKGROUND_SETTLE_SECONDS:-3}"
APP_LAUNCH_RETRIES="${CAPGO_MAESTRO_APP_LAUNCH_RETRIES:-3}"
APP_START_TIMEOUT_SECONDS="${CAPGO_MAESTRO_APP_START_TIMEOUT_SECONDS:-20}"
APP_UI_TIMEOUT_SECONDS="${CAPGO_MAESTRO_APP_UI_TIMEOUT_SECONDS:-180}"
UI_STATE_TIMEOUT_SECONDS="${CAPGO_MAESTRO_UI_STATE_TIMEOUT_SECONDS:-300}"
DIRECT_UPDATE_SETTLE_TIMEOUT_SECONDS="${CAPGO_MAESTRO_DIRECT_UPDATE_SETTLE_TIMEOUT_SECONDS:-120}"
DIRECT_UPDATE_BACKGROUND_SETTLE_SECONDS="${CAPGO_MAESTRO_DIRECT_UPDATE_BACKGROUND_SETTLE_SECONDS:-6}"
ADB_COMMAND_TIMEOUT_SECONDS="${CAPGO_MAESTRO_ADB_COMMAND_TIMEOUT_SECONDS:-20}"
ADB_INSTALL_TIMEOUT_SECONDS="${CAPGO_MAESTRO_ADB_INSTALL_TIMEOUT_SECONDS:-180}"
TIMEOUT_CMD="$(command -v gtimeout || command -v timeout || true)"
SCENARIO_SEQUENCE=(deferred always at-install on-launch)

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  stop_stale_fake_server
  return 0
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  "$TIMEOUT_CMD" --foreground "${timeout_seconds}s" "$@"
}

run_adb_command() {
  local timeout_seconds="$1"
  shift
  run_with_timeout "$timeout_seconds" adb "$@"
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
  run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" forward --remove-all >/dev/null 2>&1 || true
  run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" reverse --remove-all >/dev/null 2>&1 || true
  configure_server_routing
  return 0
}

configure_server_routing() {
  local attempt=1
  local max_attempts=3

  case "$DEVICE_SERVER_URL" in
    http://127.0.0.1:*|http://localhost:*|https://127.0.0.1:*|https://localhost:*)
      ;;
    *)
      return 0
      ;;
  esac

  while [[ $attempt -le $max_attempts ]]; do
    if run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" reverse "tcp:${HOST_SERVER_PORT}" "tcp:${HOST_SERVER_PORT}" >/dev/null 2>&1; then
      return 0
    fi

    if [[ $attempt -lt $max_attempts ]]; then
      echo "adb reverse tcp:${HOST_SERVER_PORT} failed (attempt ${attempt}/${max_attempts}); retrying." >&2
      ensure_android_device || true
      sleep 2
    fi

    attempt=$((attempt + 1))
  done

  echo "Failed to establish adb reverse tcp:${HOST_SERVER_PORT} for ${DEVICE_SERVER_URL}." >&2
  return 1
}

clear_device_logs() {
  run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" logcat -c >/dev/null 2>&1 || true
  return 0
}

dump_ui_hierarchy() {
  run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" exec-out uiautomator dump /dev/tty 2>/dev/null | tr -d '\r' | tr '\n' ' ' || true
  return 0
}

tap_android_anr_wait_button_if_present() {
  local hierarchy="$1"
  local wait_button_pattern='text="Wait".*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"'
  local x=""
  local y=""

  if [[ "$hierarchy" =~ $wait_button_pattern ]]; then
    x=$(((BASH_REMATCH[1] + BASH_REMATCH[3]) / 2))
    y=$(((BASH_REMATCH[2] + BASH_REMATCH[4]) / 2))
    echo "Detected Android ANR dialog; tapping Wait." >&2
    run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell input tap "$x" "$y" >/dev/null 2>&1 || true
    sleep 1
    return 0
  fi

  return 1
}

get_device_screen_size() {
  local size_line=""

  size_line="$(
    {
      run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell wm size 2>/dev/null || true
    } | tr -d '\r' | sed -n 's/.*Physical size: \([0-9]\+\)x\([0-9]\+\).*/\1 \2/p' | tail -n 1
  )"

  if [[ -z "$size_line" ]]; then
    echo "1080 2400"
    return 0
  fi

  echo "$size_line"
  return 0
}

scroll_page_down() {
  local width=""
  local height=""
  local x=""
  local start_y=""
  local end_y=""

  read -r width height <<<"$(get_device_screen_size)"
  x=$((width / 2))
  start_y=$(((height * 4) / 5))
  end_y=$((height / 5))
  run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell input swipe "$x" "$start_y" "$x" "$end_y" 300 >/dev/null 2>&1 || true
  sleep 1
  return 0
}

scroll_page_to_top() {
  local width=""
  local height=""
  local x=""
  local start_y=""
  local end_y=""
  local attempt

  read -r width height <<<"$(get_device_screen_size)"
  x=$((width / 2))
  start_y=$((height / 4))
  end_y=$(((height * 4) / 5))

  for attempt in 1 2 3 4; do
    run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell input swipe "$x" "$start_y" "$x" "$end_y" 250 >/dev/null 2>&1 || true
    sleep 1
  done

  return 0
}

wait_for_example_app_ui() {
  local attempt=1
  local hierarchy=""
  local deadline=0

  while (( attempt <= APP_LAUNCH_RETRIES )); do
    launch_android_app
    deadline=$((SECONDS + APP_UI_TIMEOUT_SECONDS))

    while (( SECONDS < deadline )); do
      hierarchy="$(dump_ui_hierarchy)"
      tap_android_anr_wait_button_if_present "$hierarchy" || true
      if [[ "$hierarchy" == *"$APP_READY_TITLE"* || "$hierarchy" == *"$APP_READY_ACTION"* ]]; then
        return 0
      fi
      sleep 5
    done

    echo "Example app UI did not appear on Android launch attempt ${attempt}; restarting the app." >&2
    run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
    wait_for_package_manager || true
    sleep 2
    ((attempt += 1))
  done

  echo "Example app UI never became visible on Android after ${APP_LAUNCH_RETRIES} attempts." >&2
  return 1
}

wait_for_ui_state_with_timeout() {
  local description="$1"
  local timeout_seconds="$2"
  shift 2
  local -a fragments=("$@")
  local deadline=$((SECONDS + timeout_seconds))
  local hierarchy=""
  local fragment=""
  local found_fragments=""
  local matched=0
  local swipe_count=0

  echo "Waiting for UI state: ${description}"

  while ((SECONDS < deadline)); do
    scroll_page_to_top
    found_fragments=""

    for swipe_count in 0 1 2 3 4 5; do
      hierarchy="$(dump_ui_hierarchy)"
      tap_android_anr_wait_button_if_present "$hierarchy" || true

      for fragment in "${fragments[@]}"; do
        if [[ "$hierarchy" == *"$fragment"* ]] && ! printf '%s' "$found_fragments" | grep -Fqx "$fragment"; then
          found_fragments="${found_fragments}${fragment}"$'\n'
        fi
      done

      matched=1
      for fragment in "${fragments[@]}"; do
        if ! printf '%s' "$found_fragments" | grep -Fqx "$fragment"; then
          matched=0
          break
        fi
      done

      if [[ $matched -eq 1 ]]; then
        echo "Verified UI state: ${description}"
        return 0
      fi

      scroll_page_down
    done

    sleep 2
  done

  echo "Timed out waiting for UI state: ${description}" >&2
  dump_ui_hierarchy >&2 || true
  return 1
}

wait_for_ui_state() {
  local description="$1"
  shift

  wait_for_ui_state_with_timeout "$description" "$UI_STATE_TIMEOUT_SECONDS" "$@"
  return 0
}

wait_for_direct_update_ui_state() {
  local description="$1"
  shift
  local -a fragments=("$@")

  if wait_for_ui_state_with_timeout "$description" "$DIRECT_UPDATE_SETTLE_TIMEOUT_SECONDS" "${fragments[@]}"; then
    return 0
  fi

  echo "Direct update UI did not settle for ${description}; force-stopping and relaunching once." >&2
  run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  relaunch_android_app
  wait_for_ui_state_with_timeout "$description" "$DIRECT_UPDATE_SETTLE_TIMEOUT_SECONDS" "${fragments[@]}"
  return 0
}

wait_for_at_install_direct_update_ui_state() {
  local description="$1"
  shift
  local -a fragments=("$@")
  local attempt=1
  local max_attempts=2
  local target_version=""
  local fragment=""

  for fragment in "${fragments[@]}"; do
    if [[ "$fragment" == Current\ bundle\ version:\ * ]]; then
      target_version="${fragment#Current bundle version: }"
      break
    fi
  done

  while [[ $attempt -le $max_attempts ]]; do
    if wait_for_ui_state_with_timeout "$description" "$DIRECT_UPDATE_SETTLE_TIMEOUT_SECONDS" "${fragments[@]}"; then
      return 0
    fi

    if [[ $attempt -lt $max_attempts ]]; then
      if [[ -n "$target_version" ]]; then
        if ! wait_for_ui_state_with_timeout \
          "atInstall finished preparing ${target_version} before the extra background cycle" \
          "$DIRECT_UPDATE_SETTLE_TIMEOUT_SECONDS" \
          'Direct update mode: atInstall' \
          'Current bundle source: downloaded' \
          "Next bundle version: ${target_version}" \
          "Last completed download: ${target_version}"; then
          echo "atInstall never exposed ${target_version} as the pending next bundle before the extra background cycle." >&2
        fi
      fi

      echo "atInstall UI did not settle for ${description}; driving one extra background cycle without force-stopping the current bundle." >&2
      background_and_resume_app "$DIRECT_UPDATE_BACKGROUND_SETTLE_SECONDS"
    fi

    attempt=$((attempt + 1))
  done

  return 1
}

ensure_android_device() {
  local state=""
  local state_output=""

  for _ in $(seq 1 30); do
    state_output="$(
      {
        run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" get-state 2>&1 || true
      } | tr -d '\r' | awk 'NF { last = $0 } END { print last }'
    )"
    state="$state_output"
    if [[ "$state" == "device" ]] && run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" devices | awk 'NR > 1 && $2 == "device" { found = 1 } END { exit(found ? 0 : 1) }'; then
      return 0
    fi

    if [[ "$state_output" == *"Unable to connect to adb daemon"* || "$state_output" == *"cannot connect to daemon"* ]]; then
      echo "ADB daemon unavailable while waiting for Android device; restarting adb." >&2
      restart_adb_server
    fi

    sleep 2
  done

  echo "No Android emulator/device became available for Maestro." >&2
  return 1
}

load_scenario_config() {
  local scenario_id="$1"

  bun --eval "
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { exampleAppDir, getScenario } from '${ROOT_DIR}/scripts/maestro/scenarios.mjs';

const scenario = getScenario(process.argv[1]);
const buildGradle = readFileSync(path.join(exampleAppDir, 'android', 'app', 'build.gradle'), 'utf8');
const versionLine = buildGradle
  .split(/\\r?\\n/)
  .find((line) => /^\\s*versionName\\s*=/.test(line));
const versionMatches = versionLine ? [...versionLine.matchAll(/['\\\"]([^'\\\"]+)['\\\"]/g)] : [];
const builtinVersion = versionMatches.at(-1)?.[1];

if (!builtinVersion) {
  throw new Error('Unable to determine example-app Android versionName');
}

console.log([scenario.builtinLabel, builtinVersion, ...scenario.releases.map((release) => release.version)].join('\t'));
" "$scenario_id"

  return 0
}

run_scenario() {
  local scenario_id="$1"
  local builtin_label=""
  local builtin_version=""
  local first_release=""
  local second_release=""

  IFS=$'\t' read -r builtin_label builtin_version first_release second_release _ <<<"$(load_scenario_config "$scenario_id")"
  echo "=== Running Maestro scenario: $scenario_id ==="

  case "$scenario_id" in
    deferred)
      control_server reset deferred
      prepare_scenario deferred
      run_flow deferred-download.yaml
      wait_for_example_app_ui
      wait_for_ui_state \
        "deferred release downloads while builtin bundle stays active" \
        "Build label: $builtin_label" \
        'Scenario: deferred' \
        'Direct update mode: false' \
        'Current bundle source: builtin' \
        "Current bundle version: $builtin_version" \
        "Next bundle version: $first_release" \
        "Last completed download: $first_release"
      background_and_resume_app
      wait_for_ui_state \
        "deferred release applies after the app backgrounds and resumes" \
        "Build label: $first_release" \
        'Scenario: deferred' \
        'Direct update mode: false' \
        'Current bundle source: downloaded' \
        "Current bundle version: $first_release"
      ;;
    always)
      control_server reset always
      prepare_scenario always
      run_flow initial-direct-update.yaml
      wait_for_direct_update_ui_state \
        "always direct update applies on first launch" \
        "Build label: $first_release" \
        'Scenario: always' \
        'Direct update mode: always' \
        'Current bundle source: downloaded' \
        "Current bundle version: $first_release"
      control_server advance always
      background_and_resume_app
      wait_for_direct_update_ui_state \
        "always direct update applies a newer release after resume" \
        "Build label: $second_release" \
        'Scenario: always' \
        'Direct update mode: always' \
        'Current bundle source: downloaded' \
        "Current bundle version: $second_release"
      ;;
    at-install)
      control_server reset at-install
      prepare_scenario at-install
      run_flow initial-direct-update.yaml
      wait_for_direct_update_ui_state \
        "atInstall applies the first downloaded release on first launch" \
        "Build label: $first_release" \
        'Scenario: at-install' \
        'Direct update mode: atInstall' \
        'Current bundle source: downloaded' \
        "Current bundle version: $first_release"
      control_server advance at-install
      background_and_resume_app
      wait_for_ui_state \
        "atInstall downloads the next release on resume before applying it" \
        "Build label: $first_release" \
        'Scenario: at-install' \
        'Direct update mode: atInstall' \
        'Current bundle source: downloaded' \
        "Current bundle version: $first_release" \
        "Next bundle version: $second_release" \
        "Last completed download: $second_release"
      background_and_resume_app "$DIRECT_UPDATE_BACKGROUND_SETTLE_SECONDS"
      wait_for_at_install_direct_update_ui_state \
        "atInstall applies the downloaded release after the next background cycle" \
        "Build label: $second_release" \
        'Scenario: at-install' \
        'Direct update mode: atInstall' \
        'Current bundle source: downloaded' \
        "Current bundle version: $second_release"
      ;;
    on-launch)
      control_server reset on-launch
      prepare_scenario on-launch
      run_flow initial-direct-update.yaml
      wait_for_direct_update_ui_state \
        "onLaunch applies the first downloaded release on first launch" \
        "Build label: $first_release" \
        'Scenario: on-launch' \
        'Direct update mode: onLaunch' \
        'Current bundle source: downloaded' \
        "Current bundle version: $first_release"
      control_server advance on-launch
      run_flow kill-then-direct-update.yaml
      wait_for_direct_update_ui_state \
        "onLaunch applies the next release after a cold relaunch" \
        "Build label: $second_release" \
        'Scenario: on-launch' \
        'Direct update mode: onLaunch' \
        'Current bundle source: downloaded' \
        "Current bundle version: $second_release"
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
        run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell getprop sys.boot_completed 2>/dev/null || true
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
  run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell input keyevent 82 >/dev/null 2>&1 || true
  run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell settings put global stay_on_while_plugged_in 3 >/dev/null 2>&1 || true
  return 0
}

restart_adb_server() {
  run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" kill-server >/dev/null 2>&1 || true
  run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" start-server >/dev/null 2>&1 || true
  return 0
}

prepare_device_for_maestro() {
  ensure_android_device
  wait_for_android_boot
  wait_for_package_manager
  unlock_android_device
  configure_server_routing
  return 0
}

wait_for_package_manager() {
  local settings_output=""

  for _ in $(seq 1 30); do
    settings_output="$(
      {
        run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell settings get global adb_enabled 2>&1 || true
      } | tr -d '\r' | awk 'NF { last = $0 } END { print last }'
    )"

    if run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell cmd package list packages >/dev/null 2>&1 && [[ "$settings_output" =~ ^(0|1|null)$ ]]; then
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

launch_android_app() {
  if run_adb_command "$APP_START_TIMEOUT_SECONDS" shell am start -n "$APP_ACTIVITY" >/dev/null 2>&1; then
    return 0
  fi

  echo "Android activity launch did not finish within ${APP_START_TIMEOUT_SECONDS}s; retrying with monkey." >&2
  if run_adb_command "$APP_START_TIMEOUT_SECONDS" shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
    return 0
  fi

  echo "Android app relaunch failed after the primary activity start timed out." >&2
  return 1
}

relaunch_android_app() {
  configure_server_routing

  if launch_android_app; then
    sleep 2
    return 0
  fi

  echo "Android relaunch failed; re-preparing the device before retrying." >&2
  prepare_device_for_maestro
  launch_android_app
  sleep 2
  return 0
}

background_and_resume_app() {
  local settle_seconds="${1:-$APP_BACKGROUND_SETTLE_SECONDS}"

  echo "Backgrounding ${APP_ID} and waiting ${settle_seconds}s for Android lifecycle delivery"
  run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
  sleep "$settle_seconds"
  relaunch_android_app
  return 0
}

install_apk() {
  local attempt=1
  local max_attempts=3
  local output_file

  prepare_device_for_maestro
  wait_for_package_manager

  while [[ $attempt -le $max_attempts ]]; do
    output_file="$(mktemp)"
    run_adb_command "$ADB_COMMAND_TIMEOUT_SECONDS" uninstall "$APP_ID" >/dev/null 2>&1 || true

    if run_adb_command "$ADB_INSTALL_TIMEOUT_SECONDS" install -r "$APK_PATH" >"$output_file" 2>&1; then
      rm -f "$output_file"
      return 0
    fi

    if grep -Eq "Broken pipe|Can.t find service: package|Can.t find service: settings|Cannot access system provider: 'settings' before system providers are installed!|no devices/emulators found|device offline|PackageManagerInternal\\.freeStorage|StorageManagerService\\.allocateBytes|java\\.lang\\.NullPointerException" "$output_file" && [[ $attempt -lt $max_attempts ]]; then
      rm -f "$output_file"
      attempt=$((attempt + 1))
      restart_adb_server
      prepare_device_for_maestro
      wait_for_package_manager
      sleep 15
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

restart_adb_server
ensure_android_device

(cd "$ROOT_DIR/example-app" && bun install)
bun "$ROOT_DIR/scripts/maestro/build-bundles.mjs" "$SCENARIO_SELECTION"
stop_stale_fake_server
bun "$ROOT_DIR/scripts/maestro/fake-capgo-server.mjs" >"$ARTIFACT_DIR/fake-capgo-server.log" 2>&1 &
SERVER_PID=$!
wait_for_server
run_selected_scenarios
