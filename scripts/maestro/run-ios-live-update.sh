#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXAMPLE_DIR="$ROOT_DIR/example-app"
ARTIFACT_DIR="$ROOT_DIR/.maestro-artifacts"
RESULTS_DIR="${CAPGO_MAESTRO_RESULTS_DIR:-$ROOT_DIR/maestro-results-ios-live-update}"
HOST_SERVER_PORT="${CAPGO_MAESTRO_PORT:-3192}"
HOST_SERVER_URL="${CAPGO_MAESTRO_HOST_BASE_URL:-http://127.0.0.1:${HOST_SERVER_PORT}}"
APP_ID="app.capgo.updater"
SCENARIO_SELECTION="${1:-all}"
SERVER_PID=""
SIMULATOR_BOOT_TIMEOUT_SECONDS="${CAPGO_MAESTRO_IOS_BOOT_TIMEOUT_SECONDS:-180}"
MAESTRO_TIMEOUT_SECONDS="${CAPGO_MAESTRO_TIMEOUT_SECONDS:-900}"
export MAESTRO_CLI_NO_ANALYTICS="${MAESTRO_CLI_NO_ANALYTICS:-1}"
export MAESTRO_DRIVER_STARTUP_TIMEOUT="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-600000}"
MAESTRO_TEST_RETRIES="${CAPGO_MAESTRO_TEST_RETRIES:-3}"
FLOW_RETRY_PATTERN="iOS driver not ready in time|Failed to connect to /127\\.0\\.0\\.1:[0-9]+|Connection refused|Broken pipe|No visible element found|Request for viewHierarchy failed, because of unknown reason|XCTestDriver request failed\\. Status code: 500, path: viewHierarchy|Application .* is not running|Detected app crash|App crashed or stopped|failed to terminate dev\\.mobile\\.maestro-driver-iosUITests\\.xctrunner|found nothing to terminate|Assertion is false: \"@capgo/capacitor-updater\" is visible|Assertion is false: \".*Harness: ready.*\" is visible|Marker: download:success|Marker: download-store:success"
SCENARIO_SEQUENCE=(deferred always legacy-true at-install on-launch manual-zip manual-zip-config-guards manual-manifest)
APP_MARKETING_VERSION=""
readonly ASSERT_AUTO_UPDATE_ENABLED='Auto update enabled: true'
readonly ASSERT_AUTO_UPDATE_AVAILABLE='Auto update available: true'
readonly ASSERT_SOURCE_BUILTIN='Current bundle source: builtin'
readonly ASSERT_SOURCE_DOWNLOADED='Current bundle source: downloaded'

default_simulator_id() {
  xcrun simctl list devices available | sed -nE 's/^[[:space:]]*iPhone.*\(([0-9A-F-]{36})\) \([^)]*\)[[:space:]]*$/\1/p' | head -n 1
}

detect_host_ipv4() {
  local default_interface=""
  local host_ip=""

  default_interface="$(
    route -n get default 2>/dev/null |
      sed -n 's/^[[:space:]]*interface: //p' |
      head -n 1
  )"

  if [[ -n "$default_interface" ]]; then
    host_ip="$(ipconfig getifaddr "$default_interface" 2>/dev/null || true)"
  fi

  if [[ -z "$host_ip" ]]; then
    host_ip="$(
      ifconfig 2>/dev/null |
        awk '
          /^[a-z0-9]+: / { iface = $1; sub(/:$/, "", iface) }
          iface !~ /^(lo|bridge|utun|awdl)/ && /inet / && $2 != "127.0.0.1" { print $2; exit }
        '
    )"
  fi

  if [[ -n "$host_ip" ]]; then
    printf '%s\n' "$host_ip"
    return 0
  fi

  return 1
}

if [[ -n "${CAPGO_MAESTRO_DEVICE_BASE_URL:-}" ]]; then
  DEVICE_SERVER_URL="$CAPGO_MAESTRO_DEVICE_BASE_URL"
elif [[ -n "${CAPGO_MAESTRO_DEVICE_HOST_IP:-}" ]]; then
  DEVICE_SERVER_URL="http://${CAPGO_MAESTRO_DEVICE_HOST_IP}:${HOST_SERVER_PORT}"
else
  DETECTED_HOST_IP="$(detect_host_ipv4 || true)"
  if [[ -n "$DETECTED_HOST_IP" ]]; then
    DEVICE_SERVER_URL="http://${DETECTED_HOST_IP}:${HOST_SERVER_PORT}"
  else
    DEVICE_SERVER_URL="$HOST_SERVER_URL"
  fi
fi

export CAPGO_MAESTRO_DEVICE_BASE_URL="$DEVICE_SERVER_URL"

if [[ -n "${CAPGO_MAESTRO_IOS_DERIVED_DATA_PATH:-}" ]]; then
  DERIVED_DATA_PATH="$CAPGO_MAESTRO_IOS_DERIVED_DATA_PATH"
else
  DERIVED_DATA_PATH="$(mktemp -d "${TMPDIR:-/tmp}/capgo-maestro-ios-derived-data.XXXXXX")"
fi

SIMULATOR_ID="${CAPGO_MAESTRO_IOS_SIMULATOR_ID:-$(default_simulator_id)}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/App.app"
RESULTS_DIR_READY=0

cleanup() {
  if [[ "$RESULTS_DIR_READY" == "1" && -f "$ARTIFACT_DIR/fake-capgo-server-ios.log" ]]; then
    cp "$ARTIFACT_DIR/fake-capgo-server-ios.log" "$RESULTS_DIR/fake-capgo-server-ios.log" 2>/dev/null || true
  fi

  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi

  if [[ -z "${CAPGO_MAESTRO_IOS_DERIVED_DATA_PATH:-}" && -d "$DERIVED_DATA_PATH" ]]; then
    rm -rf "$DERIVED_DATA_PATH"
  fi

  return 0
}

trap cleanup EXIT

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  python3 - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]

try:
    completed = subprocess.run(command, timeout=timeout_seconds)
except subprocess.TimeoutExpired:
    sys.exit(124)

sys.exit(completed.returncode)
PY
  return $?
}

flow_has_retryable_failure() {
  local output_file="$1"
  local debug_log="$2"

  if grep -Eq "$FLOW_RETRY_PATTERN" "$output_file"; then
    return 0
  fi

  if [[ -f "$debug_log" ]] && grep -Eq "$FLOW_RETRY_PATTERN" "$debug_log"; then
    return 0
  fi

  return 1
}

resolve_path() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
  return $?
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

listening_pid_for_port() {
  lsof -nP -tiTCP:"$HOST_SERVER_PORT" -sTCP:LISTEN 2>/dev/null | head -n 1
}

is_supported_scenario() {
  case "$1" in
    deferred|always|legacy-true|at-install|on-launch|manual-zip|manual-zip-config-guards|manual-manifest)
      return 0
      ;;
  esac

  return 1
}

ensure_server_port_available() {
  local existing_pid=""
  local existing_command=""

  existing_pid="$(listening_pid_for_port || true)"
  if [[ -z "$existing_pid" ]]; then
    return 0
  fi

  existing_command="$(ps -p "$existing_pid" -o command= 2>/dev/null || true)"
  if [[ "$existing_command" == *"fake-capgo-server.mjs"* ]]; then
    echo "Stopping stale fake Capgo server on port $HOST_SERVER_PORT (pid $existing_pid)." >&2
    kill "$existing_pid" >/dev/null 2>&1 || true

    for _ in $(seq 1 10); do
      if [[ -z "$(listening_pid_for_port || true)" ]]; then
        return 0
      fi
      sleep 1
    done
  fi

  existing_pid="$(listening_pid_for_port || true)"
  if [[ -n "$existing_pid" ]]; then
    existing_command="$(ps -p "$existing_pid" -o command= 2>/dev/null || true)"
    echo "Port $HOST_SERVER_PORT is already in use by pid $existing_pid: $existing_command" >&2
    return 1
  fi

  return 0
}

start_fake_server() {
  ensure_server_port_available

  bun "$ROOT_DIR/scripts/maestro/fake-capgo-server.mjs" >"$ARTIFACT_DIR/fake-capgo-server-ios.log" 2>&1 &
  SERVER_PID=$!

  sleep 1
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "Fake Capgo server exited immediately." >&2
    sed -n '1,200p' "$ARTIFACT_DIR/fake-capgo-server-ios.log" >&2 || true
    return 1
  fi

  if wait_for_server; then
    return 0
  fi

  sed -n '1,200p' "$ARTIFACT_DIR/fake-capgo-server-ios.log" >&2 || true
  return 1
}

boot_simulator() {
  local status=0

  xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true

  if run_with_timeout "$SIMULATOR_BOOT_TIMEOUT_SECONDS" xcrun simctl bootstatus "$SIMULATOR_ID" -b; then
    return 0
  else
    status=$?
  fi

  if [[ $status -eq 124 ]]; then
    echo "Simulator failed to boot within ${SIMULATOR_BOOT_TIMEOUT_SECONDS} seconds." >&2
  fi
  return "$status"
}

control_server() {
  local action="$1"
  local scenario="$2"
  curl --silent --show-error --fail -X POST "$HOST_SERVER_URL/api/control/$action?scenario=$scenario" >/dev/null
}

assert_server_debug_state() {
  local scenario="$1"
  local assertion_script="$2"
  local server_state=""

  server_state="$(curl --silent --show-error --fail "$HOST_SERVER_URL/api/control/state?scenario=$scenario")"
  bun --eval "$assertion_script" "$server_state" "$scenario"
}

load_scenario_config() {
  local scenario_id="$1"
  local builtin_version=""

  builtin_version="$(read_app_marketing_version)" || return $?

  bun --eval "
import { getScenario } from '${ROOT_DIR}/scripts/maestro/scenarios.mjs';

const scenario = getScenario(process.argv[1]);
const builtinVersion = process.argv[2];

if (!builtinVersion) {
  throw new Error('Unable to determine example-app iOS MARKETING_VERSION');
}

console.log([scenario.builtinLabel, builtinVersion.trim(), ...scenario.releases.map((release) => release.version)].join('\t'));
" "$scenario_id" "$builtin_version"
}

clear_swiftpm_capacitor_artifact_cache() {
  rm -rf "$HOME/Library/Caches/org.swift.swiftpm/artifacts"/https___github_com_ionic_team_capacitor_swift_pm_releases_download_8_0_0_*
  return 0
}

read_app_marketing_version() {
  if [[ -n "$APP_MARKETING_VERSION" ]]; then
    printf '%s\n' "$APP_MARKETING_VERSION"
    return 0
  fi

  APP_MARKETING_VERSION="$(
    xcodebuild \
      -project "$EXAMPLE_DIR/ios/App/App.xcodeproj" \
      -scheme App \
      -configuration Debug \
      -showBuildSettings 2>/dev/null |
      sed -n 's/^[[:space:]]*MARKETING_VERSION = //p' |
      head -n 1
  )"

  if [[ -z "$APP_MARKETING_VERSION" ]]; then
    echo "Unable to determine example-app iOS MARKETING_VERSION." >&2
    return 1
  fi

  printf '%s\n' "$APP_MARKETING_VERSION"
  return 0
}

run_flow() {
  local label="$1"
  local flow_path="$2"
  shift 2
  local flow_results_dir="$RESULTS_DIR/$label"
  local -a maestro_args=()
  local attempt=1
  local env_arg=""
  local output_file=""
  local status=0

  while [[ $# -gt 0 ]]; do
    env_arg="$1"
    maestro_args+=("-e" "$env_arg")
    shift
  done

  while [[ $attempt -le $MAESTRO_TEST_RETRIES ]]; do
    rm -rf "$flow_results_dir"
    mkdir -p "$flow_results_dir"
    output_file="$(mktemp)"

    echo "Running iOS Maestro flow: ${label} (attempt ${attempt}/${MAESTRO_TEST_RETRIES})"

    set +e
    if ((${#maestro_args[@]} > 0)); then
      run_with_timeout "$MAESTRO_TIMEOUT_SECONDS" \
        maestro test \
          -p ios \
          --device "$SIMULATOR_ID" \
          "${maestro_args[@]}" \
          "$flow_path" \
          --format junit \
          --output "$flow_results_dir/junit.xml" \
          --debug-output "$flow_results_dir/debug" \
          --flatten-debug-output \
          --test-output-dir "$flow_results_dir/artifacts" 2>&1 | tee "$output_file"
    else
      run_with_timeout "$MAESTRO_TIMEOUT_SECONDS" \
        maestro test \
          -p ios \
          --device "$SIMULATOR_ID" \
          "$flow_path" \
          --format junit \
          --output "$flow_results_dir/junit.xml" \
          --debug-output "$flow_results_dir/debug" \
          --flatten-debug-output \
          --test-output-dir "$flow_results_dir/artifacts" 2>&1 | tee "$output_file"
    fi
    status=${PIPESTATUS[0]}
    set -e

    if [[ $status -eq 0 ]]; then
      rm -f "$output_file"
      return 0
    fi

    if [[ $status -eq 124 ]]; then
      echo "Maestro flow timed out after ${MAESTRO_TIMEOUT_SECONDS} seconds: ${flow_path}" >&2
    fi

    if [[ $attempt -lt $MAESTRO_TEST_RETRIES ]] && {
      [[ $status -eq 124 ]] || flow_has_retryable_failure "$output_file" "$flow_results_dir/debug/maestro.log"
    }; then
      echo "Retrying iOS Maestro flow after simulator/XCTest instability: ${flow_path}" >&2
      rm -f "$output_file"
      xcrun simctl terminate "$SIMULATOR_ID" "$APP_ID" >/dev/null 2>&1 || true
      xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
      boot_simulator
      sleep 5
      attempt=$((attempt + 1))
      continue
    fi

    rm -f "$output_file"
    return "$status"
  done

  return 1
}

regex_escape_for_maestro() {
  python3 - "$1" <<'PY'
import re
import sys

print(re.escape(sys.argv[1]))
PY
}

regex_contains_for_maestro() {
  printf '.*%s.*' "$(regex_escape_for_maestro "$1")"
}

run_core_assert() {
  local label="$1"
  local build_label="$2"
  local scenario_line="$3"
  local direct_update_line="$4"
  local auto_update_enabled_line="$5"
  local auto_update_available_line="$6"
  local notify_ready_line="$7"
  local current_source_line="$8"
  local current_version_line="$9"

  run_flow \
    "$label" \
    "$ROOT_DIR/.maestro/ios/assert-live-update-core.yaml" \
    "BUILD_LABEL=$(regex_contains_for_maestro "$build_label")" \
    "SCENARIO_LINE=$(regex_contains_for_maestro "$scenario_line")" \
    "DIRECT_UPDATE_LINE=$(regex_contains_for_maestro "$direct_update_line")" \
    "AUTO_UPDATE_ENABLED_LINE=$(regex_contains_for_maestro "$auto_update_enabled_line")" \
    "AUTO_UPDATE_AVAILABLE_LINE=$(regex_contains_for_maestro "$auto_update_available_line")" \
    "NOTIFY_READY_LINE=$(regex_contains_for_maestro "$notify_ready_line")" \
    "CURRENT_SOURCE_LINE=$(regex_contains_for_maestro "$current_source_line")" \
    "CURRENT_VERSION_LINE=$(regex_contains_for_maestro "$current_version_line")"
}

run_download_assert() {
  local label="$1"
  local build_label="$2"
  local scenario_line="$3"
  local direct_update_line="$4"
  local auto_update_enabled_line="$5"
  local auto_update_available_line="$6"
  local notify_ready_line="$7"
  local current_source_line="$8"
  local current_version_line="$9"
  local next_version_line="${10}"
  local last_download_line="${11}"

  run_flow \
    "$label" \
    "$ROOT_DIR/.maestro/ios/assert-live-update-download.yaml" \
    "BUILD_LABEL=$(regex_contains_for_maestro "$build_label")" \
    "SCENARIO_LINE=$(regex_contains_for_maestro "$scenario_line")" \
    "DIRECT_UPDATE_LINE=$(regex_contains_for_maestro "$direct_update_line")" \
    "AUTO_UPDATE_ENABLED_LINE=$(regex_contains_for_maestro "$auto_update_enabled_line")" \
    "AUTO_UPDATE_AVAILABLE_LINE=$(regex_contains_for_maestro "$auto_update_available_line")" \
    "NOTIFY_READY_LINE=$(regex_contains_for_maestro "$notify_ready_line")" \
    "CURRENT_SOURCE_LINE=$(regex_contains_for_maestro "$current_source_line")" \
    "CURRENT_VERSION_LINE=$(regex_contains_for_maestro "$current_version_line")" \
    "NEXT_VERSION_LINE=$(regex_contains_for_maestro "$next_version_line")" \
    "LAST_DOWNLOAD_LINE=$(regex_contains_for_maestro "$last_download_line")"
}

build_and_install_scenario() {
  local scenario_id="$1"

  bun "$ROOT_DIR/scripts/maestro/prepare-ios-scenario.mjs" "$scenario_id"
  clear_swiftpm_capacitor_artifact_cache

  xcodebuild \
    -project "$EXAMPLE_DIR/ios/App/App.xcodeproj" \
    -scheme App \
    -configuration Debug \
    -destination "id=$SIMULATOR_ID" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build

  if [[ ! -d "$APP_PATH" ]]; then
    echo "Expected simulator app at $APP_PATH" >&2
    return 1
  fi

  xcrun simctl uninstall "$SIMULATOR_ID" "$APP_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"
}

run_scenario() {
  local scenario_id="$1"
  local scenario_config=""
  local builtin_label=""
  local builtin_version=""
  local first_release=""
  local second_release=""

  if ! is_supported_scenario "$scenario_id"; then
    echo "Unknown Maestro scenario selection: $scenario_id" >&2
    return 1
  fi

  scenario_config="$(load_scenario_config "$scenario_id")" || return $?
  IFS=$'\t' read -r builtin_label builtin_version first_release second_release _ <<<"$scenario_config"
  echo "=== Running iOS Maestro scenario: $scenario_id ==="

  control_server reset "$scenario_id"
  build_and_install_scenario "$scenario_id"
  run_flow "${scenario_id}-cold-launch" "$ROOT_DIR/.maestro/helpers/cold-launch-app.yaml"

  case "$scenario_id" in
    deferred)
      run_download_assert \
        "${scenario_id}-downloaded" \
        "Build label: $builtin_label" \
        'Scenario: deferred' \
        'Direct update mode: false' \
        "$ASSERT_AUTO_UPDATE_ENABLED" \
        "$ASSERT_AUTO_UPDATE_AVAILABLE" \
        "Notify app ready: ok ($builtin_version)" \
        "$ASSERT_SOURCE_BUILTIN" \
        "Current bundle version: $builtin_version" \
        "Next bundle version: $first_release" \
        "Last completed download: $first_release"
      run_flow "${scenario_id}-resume" "$ROOT_DIR/.maestro/helpers/relaunch-app.yaml"
      run_core_assert \
        "${scenario_id}-applied" \
        "Build label: $first_release" \
        'Scenario: deferred' \
        'Direct update mode: false' \
        "$ASSERT_AUTO_UPDATE_ENABLED" \
        "$ASSERT_AUTO_UPDATE_AVAILABLE" \
        "Notify app ready: ok ($first_release)" \
        "$ASSERT_SOURCE_DOWNLOADED" \
        "Current bundle version: $first_release"
      ;;
    always)
      run_core_assert \
        "${scenario_id}-first-release" \
        "Build label: $first_release" \
        'Scenario: always' \
        'Direct update mode: always' \
        "$ASSERT_AUTO_UPDATE_ENABLED" \
        "$ASSERT_AUTO_UPDATE_AVAILABLE" \
        "Notify app ready: ok ($first_release)" \
        "$ASSERT_SOURCE_DOWNLOADED" \
        "Current bundle version: $first_release"
      control_server advance "$scenario_id"
      run_flow "${scenario_id}-resume" "$ROOT_DIR/.maestro/helpers/relaunch-app.yaml"
      run_core_assert \
        "${scenario_id}-second-release" \
        "Build label: $second_release" \
        'Scenario: always' \
        'Direct update mode: always' \
        "$ASSERT_AUTO_UPDATE_ENABLED" \
        "$ASSERT_AUTO_UPDATE_AVAILABLE" \
        "Notify app ready: ok ($second_release)" \
        "$ASSERT_SOURCE_DOWNLOADED" \
        "Current bundle version: $second_release"
      ;;
    legacy-true)
      run_core_assert \
        "${scenario_id}-first-release" \
        "Build label: $first_release" \
        'Scenario: legacy-true' \
        'Direct update mode: true' \
        "$ASSERT_AUTO_UPDATE_ENABLED" \
        "$ASSERT_AUTO_UPDATE_AVAILABLE" \
        "Notify app ready: ok ($first_release)" \
        "$ASSERT_SOURCE_DOWNLOADED" \
        "Current bundle version: $first_release"
      control_server advance "$scenario_id"
      run_flow "${scenario_id}-resume" "$ROOT_DIR/.maestro/helpers/relaunch-app.yaml"
      run_core_assert \
        "${scenario_id}-second-release" \
        "Build label: $second_release" \
        'Scenario: legacy-true' \
        'Direct update mode: true' \
        "$ASSERT_AUTO_UPDATE_ENABLED" \
        "$ASSERT_AUTO_UPDATE_AVAILABLE" \
        "Notify app ready: ok ($second_release)" \
        "$ASSERT_SOURCE_DOWNLOADED" \
        "Current bundle version: $second_release"
      ;;
    at-install)
      run_core_assert \
        "${scenario_id}-first-release" \
        "Build label: $first_release" \
        'Scenario: at-install' \
        'Direct update mode: atInstall' \
        "$ASSERT_AUTO_UPDATE_ENABLED" \
        "$ASSERT_AUTO_UPDATE_AVAILABLE" \
        "Notify app ready: ok ($first_release)" \
        "$ASSERT_SOURCE_DOWNLOADED" \
        "Current bundle version: $first_release"
      control_server advance "$scenario_id"
      run_flow "${scenario_id}-resume-one" "$ROOT_DIR/.maestro/helpers/relaunch-app.yaml"
      run_download_assert \
        "${scenario_id}-downloaded" \
        "Build label: $first_release" \
        'Scenario: at-install' \
        'Direct update mode: atInstall' \
        "$ASSERT_AUTO_UPDATE_ENABLED" \
        "$ASSERT_AUTO_UPDATE_AVAILABLE" \
        "Notify app ready: ok ($first_release)" \
        "$ASSERT_SOURCE_DOWNLOADED" \
        "Current bundle version: $first_release" \
        "Next bundle version: $second_release" \
        "Last completed download: $second_release"
      run_flow "${scenario_id}-resume-two" "$ROOT_DIR/.maestro/helpers/relaunch-app.yaml"
      run_core_assert \
        "${scenario_id}-second-release" \
        "Build label: $second_release" \
        'Scenario: at-install' \
        'Direct update mode: atInstall' \
        "$ASSERT_AUTO_UPDATE_ENABLED" \
        "$ASSERT_AUTO_UPDATE_AVAILABLE" \
        "Notify app ready: ok ($second_release)" \
        "$ASSERT_SOURCE_DOWNLOADED" \
        "Current bundle version: $second_release"
      ;;
    on-launch)
      run_core_assert \
        "${scenario_id}-first-release" \
        "Build label: $first_release" \
        'Scenario: on-launch' \
        'Direct update mode: onLaunch' \
        "$ASSERT_AUTO_UPDATE_ENABLED" \
        "$ASSERT_AUTO_UPDATE_AVAILABLE" \
        "Notify app ready: ok ($first_release)" \
        "$ASSERT_SOURCE_DOWNLOADED" \
        "Current bundle version: $first_release"
      control_server advance "$scenario_id"
      run_flow "${scenario_id}-cold-relaunch" "$ROOT_DIR/.maestro/helpers/cold-launch-app.yaml"
      run_core_assert \
        "${scenario_id}-second-release" \
        "Build label: $second_release" \
        'Scenario: on-launch' \
        'Direct update mode: onLaunch' \
        "$ASSERT_AUTO_UPDATE_ENABLED" \
        "$ASSERT_AUTO_UPDATE_AVAILABLE" \
        "Notify app ready: ok ($second_release)" \
        "$ASSERT_SOURCE_DOWNLOADED" \
        "Current bundle version: $second_release"
      ;;
    manual-zip)
      run_flow "${scenario_id}-flow" "$ROOT_DIR/.maestro/ios/manual-zip-flow.yaml"
      ;;
    manual-zip-config-guards)
      run_flow "${scenario_id}-flow" "$ROOT_DIR/.maestro/ios/manual-zip-config-guards-flow.yaml"
      ;;
    manual-manifest)
      run_flow "${scenario_id}-flow" "$ROOT_DIR/.maestro/ios/manual-manifest-flow.yaml"
      assert_server_debug_state manual-manifest '
const state = JSON.parse(process.argv[1]);
const scenarioId = process.argv[2];
const failures = [];
const debug = state.debug ?? {};
const requestCounts = debug.requestCounts ?? {};
const updateRequestUrl = debug.lastUpdateRequest?.url ?? "";

function expect(condition, message) {
  if (!condition) {
    failures.push(message);
  }
}

expect(state.activeRelease === "manual-manifest-v2", "fake server did not advance to the second manifest release");
expect(updateRequestUrl.includes("/api/updates/manual-manifest"), "missing manifest update request");
expect((requestCounts.update ?? 0) >= 2, "expected repeated manifest update checks");
expect((requestCounts.manifestFile ?? 0) >= 2, "expected manifest file downloads");
expect((requestCounts.stats ?? 0) >= 1, "expected manifest stats traffic");

if (failures.length) {
  console.error(`Server assertions failed for ${scenarioId}:`);
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}
'
      ;;
  esac

  echo "=== Completed iOS Maestro scenario: $scenario_id ==="
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

validate_results_dir() {
  local resolved_results_dir=""
  local resolved_default_results_dir=""
  local resolved_artifact_dir=""
  local resolved_root_dir=""
  local resolved_home_dir=""
  local resolved_example_dir=""

  if [[ -z "$RESULTS_DIR" ]]; then
    echo "Refusing to delete unsafe Maestro results directory: $RESULTS_DIR" >&2
    exit 1
  fi

  resolved_results_dir="$(resolve_path "$RESULTS_DIR")"
  resolved_default_results_dir="$(resolve_path "$ROOT_DIR/maestro-results-ios-live-update")"
  resolved_artifact_dir="$(resolve_path "$ARTIFACT_DIR")"
  resolved_root_dir="$(resolve_path "$ROOT_DIR")"
  resolved_home_dir="$(resolve_path "$HOME")"
  resolved_example_dir="$(resolve_path "$EXAMPLE_DIR")"

  case "$resolved_results_dir" in
    "/"|"$resolved_home_dir"|"$resolved_root_dir"|"$resolved_artifact_dir"|"$resolved_example_dir")
      echo "Refusing to delete unsafe Maestro results directory: $RESULTS_DIR" >&2
      exit 1
      ;;
  esac

  case "$resolved_results_dir" in
    "$resolved_default_results_dir"|"$resolved_default_results_dir"/*|"$resolved_artifact_dir"/*)
      RESULTS_DIR="$resolved_results_dir"
      return 0
      ;;
  esac

  echo "Refusing to delete Maestro results outside allowed paths: $RESULTS_DIR" >&2
  exit 1
}

if ! command -v maestro >/dev/null 2>&1; then
  echo "Maestro CLI is required. Install it with https://maestro.mobile.dev/getting-started/installing-maestro." >&2
  exit 1
fi

if ! command -v bun >/dev/null 2>&1; then
  echo "bun is required to run parts of this script." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to run Capacitor CLI commands." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required to build the iOS example app." >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required to manage the iOS simulator." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to enforce iOS Maestro timeouts." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to communicate with the fake Capgo server." >&2
  exit 1
fi

if ! command -v lsof >/dev/null 2>&1; then
  echo "lsof is required to detect stale fake Capgo server processes." >&2
  exit 1
fi

if ! node -e "process.exit(Number(process.versions.node.split('.')[0]) >= 22 ? 0 : 1)"; then
  echo "Node.js >=22 is required because Capacitor CLI no longer supports older versions." >&2
  exit 1
fi

if [[ "$SCENARIO_SELECTION" != "all" ]] && ! is_supported_scenario "$SCENARIO_SELECTION"; then
  echo "Unknown Maestro scenario selection: $SCENARIO_SELECTION" >&2
  exit 1
fi

if [[ -z "${SIMULATOR_ID:-}" ]]; then
  echo "No available iPhone simulator found. Please install one via Xcode." >&2
  exit 1
fi

mkdir -p "$ARTIFACT_DIR"
validate_results_dir
rm -rf -- "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
RESULTS_DIR_READY=1

echo "Using iOS device server URL: $DEVICE_SERVER_URL"

boot_simulator

cd "$ROOT_DIR"

if [[ ! -d node_modules ]]; then
  bun install
fi

bun "$ROOT_DIR/scripts/maestro/build-bundles.mjs" "$SCENARIO_SELECTION"

start_fake_server

run_selected_scenarios
