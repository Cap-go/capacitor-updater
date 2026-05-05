#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXAMPLE_DIR="$ROOT_DIR/example-app"
ARTIFACT_DIR="$ROOT_DIR/.maestro-artifacts/ios-native-reset"
RESULTS_DIR="$ROOT_DIR/maestro-results-ios-native-reset"
ASSERT_FLOW="$ROOT_DIR/.maestro/assert-state.yaml"
LAUNCH_FLOW="$ROOT_DIR/.maestro/helpers/relaunch-app.yaml"
SCENARIO_ID="native-reset"
HOST_SERVER_PORT="${CAPGO_MAESTRO_PORT:-3192}"
HOST_SERVER_URL="${CAPGO_MAESTRO_HOST_BASE_URL:-http://127.0.0.1:${HOST_SERVER_PORT}}"
DEVICE_SERVER_URL="${CAPGO_MAESTRO_DEVICE_BASE_URL:-http://127.0.0.1:${HOST_SERVER_PORT}}"
SIMULATOR_BOOT_TIMEOUT_SECONDS="${CAPGO_MAESTRO_IOS_BOOT_TIMEOUT_SECONDS:-180}"
MAESTRO_TIMEOUT_SECONDS="${CAPGO_MAESTRO_TIMEOUT_SECONDS:-300}"
APP_ID="app.capgo.updater"
DERIVED_DATA_V1="$(mktemp -d "${TMPDIR:-/tmp}/capgo-ios-native-reset-v1.XXXXXX")"
DERIVED_DATA_V2="$(mktemp -d "${TMPDIR:-/tmp}/capgo-ios-native-reset-v2.XXXXXX")"
SERVER_PID=""

default_simulator_id() {
  xcrun simctl list devices available | sed -nE 's/^[[:space:]]*iPhone.*\(([0-9A-F-]{36})\) \([^)]*\)[[:space:]]*$/\1/p' | head -n 1
}

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi

  rm -rf "$DERIVED_DATA_V1" "$DERIVED_DATA_V2"
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
}

wait_for_server() {
  for _ in $(seq 1 30); do
    if curl --silent --fail "$HOST_SERVER_URL/health" >/dev/null; then
      return 0
    fi
    sleep 1
  done

  echo "Fake Capgo server did not start in time for iOS native reset." >&2
  return 1
}

start_server() {
  mkdir -p "$ARTIFACT_DIR"
  export CAPGO_MAESTRO_DEVICE_BASE_URL="$DEVICE_SERVER_URL"
  export CAPGO_MAESTRO_HOST_BASE_URL="$HOST_SERVER_URL"
  export CAPGO_MAESTRO_PORT="$HOST_SERVER_PORT"
  bun "$ROOT_DIR/scripts/maestro/fake-capgo-server.mjs" >"$ARTIFACT_DIR/fake-capgo-server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_server
}

control_server() {
  local action="$1"
  curl --silent --show-error --fail -X POST "$HOST_SERVER_URL/api/control/$action?scenario=$SCENARIO_ID" >/dev/null
}

run_maestro_flow() {
  local flow_path="$1"
  shift
  local -a extra_args=("$@")
  local -a command=(
    maestro
    test
    -p
    ios
    --device
    "$SIMULATOR_ID"
  )

  if (( ${#extra_args[@]} > 0 )); then
    command+=("${extra_args[@]}")
  fi

  command+=("$flow_path")

  if run_with_timeout "$MAESTRO_TIMEOUT_SECONDS" "${command[@]}"; then
    return 0
  else
    local status=$?
    if [[ $status -eq 124 ]]; then
      echo "iOS Maestro flow timed out after ${MAESTRO_TIMEOUT_SECONDS} seconds: ${flow_path}" >&2
    fi
    return "$status"
  fi
}

build_ios_app() {
  local app_label="$1"
  local auto_update="$2"
  local direct_update="$3"
  local marketing_version="$4"
  local build_version="$5"
  local derived_data_path="$6"
  local update_url="$DEVICE_SERVER_URL/api/updates/$SCENARIO_ID"

  (
    cd "$EXAMPLE_DIR"
    VITE_CAPGO_APP_LABEL="$app_label" \
      VITE_CAPGO_SCENARIO="$SCENARIO_ID" \
      VITE_CAPGO_DIRECT_UPDATE="$direct_update" \
      VITE_CAPGO_SERVER_URL="$update_url" \
      CAPGO_AUTO_UPDATE="$auto_update" \
      CAPGO_DIRECT_UPDATE="$direct_update" \
      CAPGO_UPDATE_URL="$update_url" \
      CAPGO_STATS_URL="$DEVICE_SERVER_URL/api/stats" \
      CAPGO_CHANNEL_URL="$DEVICE_SERVER_URL/api/channel" \
      bun run build

    VITE_CAPGO_APP_LABEL="$app_label" \
      VITE_CAPGO_SCENARIO="$SCENARIO_ID" \
      VITE_CAPGO_DIRECT_UPDATE="$direct_update" \
      VITE_CAPGO_SERVER_URL="$update_url" \
      CAPGO_AUTO_UPDATE="$auto_update" \
      CAPGO_DIRECT_UPDATE="$direct_update" \
      CAPGO_UPDATE_URL="$update_url" \
      CAPGO_STATS_URL="$DEVICE_SERVER_URL/api/stats" \
      CAPGO_CHANNEL_URL="$DEVICE_SERVER_URL/api/channel" \
      bunx cap sync ios
  )

  xcodebuild \
    -project "$EXAMPLE_DIR/ios/App/App.xcodeproj" \
    -scheme App \
    -configuration Debug \
    -destination "id=$SIMULATOR_ID" \
    -derivedDataPath "$derived_data_path" \
    MARKETING_VERSION="$marketing_version" \
    CURRENT_PROJECT_VERSION="$build_version" \
    build >/dev/null
}

install_ios_app() {
  local app_path="$1"
  local uninstall_first="${2:-0}"

  xcrun simctl terminate "$SIMULATOR_ID" "$APP_ID" >/dev/null 2>&1 || true
  if [[ "$uninstall_first" == "1" ]]; then
    xcrun simctl uninstall "$SIMULATOR_ID" "$APP_ID" >/dev/null 2>&1 || true
  fi
  xcrun simctl install "$SIMULATOR_ID" "$app_path"
}

assert_state() {
  local expect_1="$1"
  local expect_2="$2"
  local expect_3="$3"
  local expect_4="$4"
  local expect_5="$5"

  run_maestro_flow \
    "$ASSERT_FLOW" \
    -e "EXPECT_1=$expect_1" \
    -e "EXPECT_2=$expect_2" \
    -e "EXPECT_3=$expect_3" \
    -e "EXPECT_4=$expect_4" \
    -e "EXPECT_5=$expect_5"
}

if ! command -v maestro >/dev/null 2>&1; then
  echo "maestro is required to run the iOS native reset Maestro test." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to enforce iOS Maestro timeouts." >&2
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

SIMULATOR_ID="${CAPGO_MAESTRO_IOS_SIMULATOR_ID:-$(default_simulator_id)}"
if [[ -z "${SIMULATOR_ID:-}" ]]; then
  echo "No available iPhone simulator found for the iOS native reset Maestro test." >&2
  exit 1
fi

if [[ ! -d "$ROOT_DIR/node_modules" ]]; then
  (cd "$ROOT_DIR" && bun install)
fi

if [[ ! -d "$EXAMPLE_DIR/node_modules" ]]; then
  (cd "$EXAMPLE_DIR" && bun install)
fi

export CAPGO_MAESTRO_DEVICE_BASE_URL="$DEVICE_SERVER_URL"
export CAPGO_MAESTRO_HOST_BASE_URL="$HOST_SERVER_URL"
export CAPGO_MAESTRO_PORT="$HOST_SERVER_PORT"

mkdir -p "$ARTIFACT_DIR" "$RESULTS_DIR"
rm -rf -- "${RESULTS_DIR:?}/"*

if ! run_with_timeout "$SIMULATOR_BOOT_TIMEOUT_SECONDS" xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null 2>&1; then
  xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
  if ! run_with_timeout "$SIMULATOR_BOOT_TIMEOUT_SECONDS" xcrun simctl bootstatus "$SIMULATOR_ID" -b; then
    echo "iOS simulator failed to boot for the native reset Maestro test." >&2
    exit 1
  fi
fi

bun "$ROOT_DIR/scripts/maestro/build-bundles.mjs" "$SCENARIO_ID"
build_ios_app "native-reset-builtin-v1" "true" "always" "1.0.0" "1" "$DERIVED_DATA_V1"
build_ios_app "native-reset-builtin-v2" "false" "false" "2.0.0" "2" "$DERIVED_DATA_V2"
start_server
control_server reset

install_ios_app "$DERIVED_DATA_V1/Build/Products/Debug-iphonesimulator/App.app" "1"
run_maestro_flow "$LAUNCH_FLOW"
assert_state \
  "Build label: native-reset-live" \
  "Scenario: native-reset" \
  "Direct update mode: always" \
  "Current bundle source: downloaded" \
  "Current bundle version: native-reset-live"

install_ios_app "$DERIVED_DATA_V2/Build/Products/Debug-iphonesimulator/App.app"
run_maestro_flow "$LAUNCH_FLOW"
assert_state \
  "Build label: native-reset-builtin-v2" \
  "Scenario: native-reset" \
  "Direct update mode: false" \
  "Current bundle source: builtin" \
  "Current bundle version: 2.0.0"
