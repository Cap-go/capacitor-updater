#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAESTRO_WORKSPACE_CONFIG="$ROOT_DIR/.maestro/config.yaml"
# shellcheck source=scripts/maestro/maestro-cli-pass.sh
source "$ROOT_DIR/scripts/maestro/maestro-cli-pass.sh"
EXAMPLE_DIR="$ROOT_DIR/example-app"
RESULTS_DIR="${CAPGO_MAESTRO_RESULTS_DIR:-$ROOT_DIR/maestro-results-ios}"
SKIP_BUILD="${CAPGO_MAESTRO_SKIP_BUILD:-0}"
SKIP_BUNDLE_BUILD="${CAPGO_MAESTRO_SKIP_BUNDLE_BUILD:-0}"
RUN_NATIVE_RESET="${CAPGO_MAESTRO_RUN_NATIVE_RESET:-0}"
CLEAR_SWIFTPM_CAPACITOR_ARTIFACT_CACHE="${CAPGO_MAESTRO_CLEAR_SWIFTPM_CAPACITOR_ARTIFACT_CACHE:-0}"
ASSUME_CLEAN_INSTALL="${CAPGO_MAESTRO_IOS_ASSUME_CLEAN_INSTALL:-0}"
SCENARIO_ID="${CAPGO_MAESTRO_SMOKE_SCENARIO:-manual-zip}"
FLOW_PATH="$ROOT_DIR/.maestro/ios/example-app-smoke.yaml"
if [[ "$SCENARIO_ID" == "manual-zip-config-guards" ]]; then
  FLOW_PATH="$ROOT_DIR/.maestro/ios/example-app-smoke-config-guards.yaml"
elif [[ "$SCENARIO_ID" == "manual-zip-no-persist" ]]; then
  FLOW_PATH="$ROOT_DIR/.maestro/ios/example-app-smoke-no-persist.yaml"
fi
ARTIFACT_DIR="$ROOT_DIR/.maestro-artifacts"
HOST_SERVER_PORT="${CAPGO_MAESTRO_PORT:-3192}"
HOST_SERVER_URL="${CAPGO_MAESTRO_HOST_BASE_URL:-http://127.0.0.1:${HOST_SERVER_PORT}}"
DEVICE_SERVER_URL="${CAPGO_MAESTRO_DEVICE_BASE_URL:-${HOST_SERVER_URL}}"
SIMULATOR_BOOT_TIMEOUT_SECONDS="${CAPGO_MAESTRO_IOS_BOOT_TIMEOUT_SECONDS:-300}"
MAESTRO_TIMEOUT_SECONDS="${CAPGO_MAESTRO_TIMEOUT_SECONDS:-600}"
NATIVE_RESET_TIMEOUT_SECONDS="${CAPGO_MAESTRO_NATIVE_RESET_TIMEOUT_SECONDS:-600}"
APP_ID="app.capgo.updater"
SERVER_PID=""
export MAESTRO_DRIVER_STARTUP_TIMEOUT="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-600000}"
export MAESTRO_CLI_NO_ANALYTICS="${MAESTRO_CLI_NO_ANALYTICS:-1}"
MAESTRO_TEST_RETRIES="${CAPGO_MAESTRO_TEST_RETRIES:-3}"
FLOW_RETRY_PATTERN="iOS driver not ready in time|Failed to connect to /127\\.0\\.0\\.1:[0-9]+|Connection refused|Broken pipe|Request for viewHierarchy failed, because of unknown reason|XCTestDriver request failed\\. Status code: 500, path: viewHierarchy|Application .* is not running|Detected app crash|App crashed or stopped|smoke-sequence:success.*is visible|failed to terminate dev\\.mobile\\.maestro-driver-iosUITests\\.xctrunner|found nothing to terminate|Assertion is false: \"@capgo/capacitor-updater\" is visible|Assertion is false: \".*Harness: ready.*\" is visible|Assertion is false: \".*persisted:success.*\" is visible"
export CAPGO_MAESTRO_DEVICE_BASE_URL="$DEVICE_SERVER_URL"

default_simulator_id() {
  "$ROOT_DIR/scripts/maestro/select-ios-simulator.sh"
}

default_app_path() {
  if [[ -n "${DERIVED_DATA_PATH:-}" ]]; then
    printf '%s\n' "$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/App.app"
    return 0
  fi

  ls -td "$HOME"/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug-iphonesimulator/App.app 2>/dev/null | head -n 1 || true
}

if [[ -n "${CAPGO_MAESTRO_IOS_DERIVED_DATA_PATH:-}" ]]; then
  DERIVED_DATA_PATH="$CAPGO_MAESTRO_IOS_DERIVED_DATA_PATH"
elif [[ "$SKIP_BUILD" != "1" ]]; then
  DERIVED_DATA_PATH="$(mktemp -d "${TMPDIR:-/tmp}/capgo-maestro-ios-derived-data.XXXXXX")"
else
  DERIVED_DATA_PATH=""
fi

SIMULATOR_ID="${CAPGO_MAESTRO_IOS_SIMULATOR_ID:-$(default_simulator_id)}"
APP_PATH="${CAPGO_MAESTRO_IOS_APP_PATH:-$(default_app_path)}"

maestro_runtime_js() {
  if command -v bun >/dev/null 2>&1 && [[ "${CAPGO_MAESTRO_PREFER_BUN_JS:-0}" == "1" ]]; then
    bun "$@"
    return
  fi
  node "$@"
}

cleanup() {
  if [[ -f "$ARTIFACT_DIR/fake-capgo-server-ios-smoke.log" ]]; then
    mkdir -p "$RESULTS_DIR"
    cp "$ARTIFACT_DIR/fake-capgo-server-ios-smoke.log" "$RESULTS_DIR/fake-capgo-server-ios-smoke.log" 2>/dev/null || true
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

run_cleanup_command() {
  local timeout_seconds="$1"
  shift

  set +e
  run_with_timeout "$timeout_seconds" "$@" >/dev/null 2>&1
  local status=$?
  set -e

  if [[ $status -eq 124 ]]; then
    echo "Timed out after ${timeout_seconds}s while cleaning up: $*" >&2
  fi

  return 0
}
maestro_xcodebuild_pids() {
  local driver_pattern="maestro-driver-iosUITests"

  ps ax -o pid= -o command= |
    awk -v driver="$driver_pattern" '
      $0 ~ /xcodebuild/ && index($0, driver) > 0 && $0 !~ /awk/ {
        print $1
      }
    '
}

terminate_maestro_xcodebuild() {
  local pid=""

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    run_cleanup_command 5 kill "$pid"
  done < <(maestro_xcodebuild_pids)
}

install_example_app() {
  local started="$SECONDS"

  if [[ "$ASSUME_CLEAN_INSTALL" == "1" ]]; then
    echo "Installing iOS app without pre-uninstall on clean simulator."
  else
    run_cleanup_command 10 xcrun simctl terminate "$SIMULATOR_ID" "$APP_ID"
    run_cleanup_command 20 xcrun simctl uninstall "$SIMULATOR_ID" "$APP_ID"
  fi

  xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"
  echo "Installed iOS app in $((SECONDS - started))s."
  ASSUME_CLEAN_INSTALL=0
}

reset_ios_maestro_driver() {
  run_cleanup_command 10 xcrun simctl terminate "$SIMULATOR_ID" dev.mobile.maestro-driver-iosUITests.xctrunner
  run_cleanup_command 10 xcrun simctl terminate "$SIMULATOR_ID" dev.mobile.maestro-driver-iosUITests
  run_cleanup_command 5 pkill -f 'maestro-driver-iosUITests'
  terminate_maestro_xcodebuild
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

assert_fake_server_process_alive() {
  if [[ -z "$SERVER_PID" ]] || ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "Fake Capgo server process exited before readiness completed." >&2
    wait "$SERVER_PID" 2>/dev/null || true
    return 1
  fi

  return 0
}

start_fake_server() {
  mkdir -p "$ARTIFACT_DIR"
  maestro_runtime_js "$ROOT_DIR/scripts/maestro/fake-capgo-server.mjs" >"$ARTIFACT_DIR/fake-capgo-server-ios-smoke.log" 2>&1 &
  SERVER_PID=$!

  wait_for_server
  sleep 1
  assert_fake_server_process_alive
}

assert_prebuilt_maestro_assets() {
  if [[ -d "$ROOT_DIR/dist" && -d "$ARTIFACT_DIR/bundles" && -d "$ARTIFACT_DIR/manifest" ]]; then
    return 0
  fi

  echo "Prebuilt dist/ and .maestro-artifacts/ assets are required when CAPGO_MAESTRO_SKIP_BUILD=1 or CAPGO_MAESTRO_SKIP_BUNDLE_BUILD=1." >&2
  exit 1
}

reset_fake_server() {
  curl --silent --show-error --fail -X POST "$HOST_SERVER_URL/api/control/reset?scenario=$SCENARIO_ID" >/dev/null
}

read_smoke_server_state() {
  curl --silent --show-error --fail "$HOST_SERVER_URL/api/control/state?scenario=$SCENARIO_ID"
}

server_request_count() {
  local server_state="$1"
  local request_kind="$2"

  maestro_runtime_js "$ROOT_DIR/scripts/maestro/smoke-server-request-count.mjs" "$server_state" "$request_kind"
}

wait_for_queued_boot_verification() {
  local before_state=""
  local before_channel_count="0"
  local server_state=""
  local max_attempts="${CAPGO_MAESTRO_BOOT_VERIFY_ATTEMPTS:-60}"
  local sleep_seconds="${CAPGO_MAESTRO_BOOT_VERIFY_SLEEP_SECONDS:-2}"

  before_state="$(read_smoke_server_state)"
  before_channel_count="$(server_request_count "$before_state" channel)"

  echo "Running queued iOS boot verification with simctl relaunch."
  xcrun simctl terminate "$SIMULATOR_ID" "$APP_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$SIMULATOR_ID" "$APP_ID" >/dev/null

  for _ in $(seq 1 "$max_attempts"); do
    server_state="$(read_smoke_server_state)"
    if maestro_runtime_js "$ROOT_DIR/scripts/maestro/smoke-boot-verification.mjs" \
      "$server_state" "$SCENARIO_ID" "$before_channel_count" "$APP_ID"; then
      return 0
    fi
    sleep "$sleep_seconds"
  done

  echo "Queued iOS boot verification did not hit the fake server after relaunch." >&2
  return 1
}

assert_smoke_server_state() {
  local server_state=""

  server_state="$(read_smoke_server_state)"

  maestro_runtime_js "$ROOT_DIR/scripts/maestro/smoke-server-assert.mjs" "$server_state" "$SCENARIO_ID"

  case "$SCENARIO_ID" in
    manual-zip-no-persist)
      if ! grep -Eq "/api/channel\\?scenario=${SCENARIO_ID}.*app_id=app\\.capgo\\.updater\\.e2e" \
        "$ARTIFACT_DIR/fake-capgo-server-ios-smoke.log"; then
        echo "Smoke server assertions failed:" >&2
        echo "- missing runtime app ID override in channel request log" >&2
        exit 1
      fi
      ;;
    manual-zip-config-guards)
      if grep -Eq "/api/channel\\?scenario=${SCENARIO_ID}.*app_id=app\\.capgo\\.updater\\.e2e" \
        "$ARTIFACT_DIR/fake-capgo-server-ios-smoke.log"; then
        echo "Smoke server assertions failed:" >&2
        echo "- guarded config unexpectedly accepted the runtime app ID override" >&2
        exit 1
      fi
      ;;
  esac
}
if ! command -v maestro >/dev/null 2>&1; then
  echo "maestro is required to run iOS Maestro tests." >&2
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

if ! node -e "process.exit(Number(process.versions.node.split('.')[0]) >= 22 ? 0 : 1)"; then
  echo "Node.js >=22 is required because Capacitor CLI no longer supports older versions." >&2
  exit 1
fi

if [[ -z "${SIMULATOR_ID:-}" ]]; then
  echo "No available iPhone simulator found. Please install one via Xcode." >&2
  exit 1
fi

if [[ -z "${APP_PATH:-}" ]]; then
  echo "Unable to locate a built iOS example app. Set CAPGO_MAESTRO_IOS_APP_PATH or run without CAPGO_MAESTRO_SKIP_BUILD=1." >&2
  exit 1
fi

mkdir -p "$ARTIFACT_DIR" "$RESULTS_DIR"
printf 'scenario=%s\n' "$SCENARIO_ID" >"$RESULTS_DIR/runner-metadata.txt"

xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true

cd "$ROOT_DIR"

if [[ "$SKIP_BUILD" != "1" ]]; then
  if [[ ! -d node_modules ]]; then
    bun install
  fi

  if [[ "$SKIP_BUNDLE_BUILD" == "1" ]]; then
    assert_prebuilt_maestro_assets
  else
    bun "$ROOT_DIR/scripts/maestro/build-bundles.mjs" "$SCENARIO_ID"
  fi
  start_fake_server
  reset_fake_server
  bun "$ROOT_DIR/scripts/maestro/prepare-ios-scenario.mjs" "$SCENARIO_ID"
  if [[ "$CLEAR_SWIFTPM_CAPACITOR_ARTIFACT_CACHE" == "1" ]]; then
    rm -rf "$HOME/Library/Caches/org.swift.swiftpm/artifacts"/https___github_com_ionic_team_capacitor_swift_pm_releases_download_8_0_0_*
  fi
  xcodebuild \
    -project "$EXAMPLE_DIR/ios/App/App.xcodeproj" \
    -scheme App \
    -configuration Debug \
    -destination "id=$SIMULATOR_ID" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build
else
  assert_prebuilt_maestro_assets
  start_fake_server
  reset_fake_server
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected simulator app at $APP_PATH" >&2
  exit 1
fi

ios_simulator_is_booted() {
  bash "$ROOT_DIR/scripts/maestro/ios-simulator-booted.sh" "$SIMULATOR_ID"
}

xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
if [[ "${CAPGO_MAESTRO_IOS_SKIP_BOOT:-0}" != "1" ]]; then
  if run_with_timeout "$SIMULATOR_BOOT_TIMEOUT_SECONDS" xcrun simctl bootstatus "$SIMULATOR_ID" -b; then
    :
  else
    status=$?
    if [[ $status -eq 124 ]]; then
      echo "Simulator failed to boot within ${SIMULATOR_BOOT_TIMEOUT_SECONDS} seconds." >&2
    fi
    exit "$status"
  fi
fi

"$ROOT_DIR/scripts/maestro/disable-device-animations.sh" ios "$SIMULATOR_ID"

install_example_app

attempt=1
while (( attempt <= MAESTRO_TEST_RETRIES )); do
  rm -rf "$RESULTS_DIR"
  mkdir -p "$RESULTS_DIR"
  output_file="$(mktemp)"

  echo "Running iOS Maestro smoke flow (attempt ${attempt}/${MAESTRO_TEST_RETRIES})"

  set +e
  run_with_timeout "$MAESTRO_TIMEOUT_SECONDS" maestro test \
    --config "$MAESTRO_WORKSPACE_CONFIG" \
    -p ios \
    --device "$SIMULATOR_ID" \
    --no-reinstall-driver \
    "$FLOW_PATH" \
    --format junit \
    --output "$RESULTS_DIR/junit.xml" \
    --debug-output "$RESULTS_DIR/debug" \
    --flatten-debug-output \
    --test-output-dir "$RESULTS_DIR/artifacts" 2>&1 | tee "$output_file"
  status=${PIPESTATUS[0]}
  set -e

  if [[ $status -eq 0 ]]; then
    rm -f "$output_file"
    break
  fi

  if [[ $status -eq 124 ]] && maestro_cli_reported_pass "$output_file"; then
    echo "Maestro flow passed but CLI teardown exceeded ${MAESTRO_TIMEOUT_SECONDS}s; resetting iOS driver." >&2
    reset_ios_maestro_driver
    rm -f "$output_file"
    break
  fi

  if [[ $status -eq 124 ]]; then
    echo "Maestro test timed out after ${MAESTRO_TIMEOUT_SECONDS} seconds." >&2
  fi

  if (( attempt < MAESTRO_TEST_RETRIES )) && { [[ $status -eq 124 ]] || grep -Eq "$FLOW_RETRY_PATTERN" "$output_file"; }; then
    echo "Retrying iOS Maestro smoke flow after simulator/XCTest instability." >&2
    rm -f "$output_file"
    run_cleanup_command 10 xcrun simctl terminate "$SIMULATOR_ID" "$APP_ID"
    reset_ios_maestro_driver
    run_with_timeout "$SIMULATOR_BOOT_TIMEOUT_SECONDS" xcrun simctl bootstatus "$SIMULATOR_ID" -b || true
    reset_fake_server
    if [[ "${CAPGO_MAESTRO_IOS_REINSTALL_ON_RETRY:-0}" == "1" ]]; then
      install_example_app
    else
      echo "Reusing installed iOS app for retry."
    fi
    attempt=$((attempt + 1))
    continue
  fi

  rm -f "$output_file"
  exit "$status"
done

case "$SCENARIO_ID" in
  manual-zip | manual-zip-config-guards | manual-zip-no-persist)
    wait_for_queued_boot_verification
    ;;
  *)
    ;;
esac

assert_smoke_server_state

if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
fi

if [[ "$RUN_NATIVE_RESET" == "1" && "$SKIP_BUILD" != "1" ]]; then
  if run_with_timeout "$NATIVE_RESET_TIMEOUT_SECONDS" "$ROOT_DIR/scripts/maestro/run-ios-native-update-reset.sh"; then
    :
  else
    status=$?
    if [[ $status -eq 124 ]]; then
      echo "iOS native reset flow timed out after ${NATIVE_RESET_TIMEOUT_SECONDS} seconds." >&2
    fi
    exit "$status"
  fi
elif [[ "$RUN_NATIVE_RESET" == "1" ]]; then
  echo "Skipping iOS native reset Maestro flow because CAPGO_MAESTRO_SKIP_BUILD=1." >&2
else
  echo "Skipping iOS native reset Maestro flow because CAPGO_MAESTRO_RUN_NATIVE_RESET is not enabled." >&2
fi

if [[ -n "${CI:-}" ]]; then
  reset_ios_maestro_driver
fi
