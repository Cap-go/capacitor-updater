#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE_DIR="$ROOT_DIR/example-app"
RESULTS_DIR="${CAPGO_MAESTRO_RESULTS_DIR:-$ROOT_DIR/maestro-results-ios}"
SKIP_BUILD="${CAPGO_MAESTRO_SKIP_BUILD:-0}"
SCENARIO_ID="${CAPGO_MAESTRO_SMOKE_SCENARIO:-manual-zip}"
FLOW_PATH="$ROOT_DIR/.maestro/ios/example-app-smoke.yaml"
if [[ "$SCENARIO_ID" == "manual-zip-config-guards" ]]; then
  FLOW_PATH="$ROOT_DIR/.maestro/ios/example-app-smoke-config-guards.yaml"
fi
ARTIFACT_DIR="$ROOT_DIR/.maestro-artifacts"
HOST_SERVER_PORT="${CAPGO_MAESTRO_PORT:-3192}"
HOST_SERVER_URL="${CAPGO_MAESTRO_HOST_BASE_URL:-http://127.0.0.1:${HOST_SERVER_PORT}}"
DEVICE_SERVER_URL="${CAPGO_MAESTRO_DEVICE_BASE_URL:-$HOST_SERVER_URL}"
SIMULATOR_BOOT_TIMEOUT_SECONDS="${CAPGO_MAESTRO_IOS_BOOT_TIMEOUT_SECONDS:-180}"
MAESTRO_TIMEOUT_SECONDS="${CAPGO_MAESTRO_TIMEOUT_SECONDS:-600}"
APP_ID="app.capgo.updater"
APP_LAUNCH_RETRIES="${CAPGO_MAESTRO_IOS_APP_LAUNCH_RETRIES:-3}"
APP_LAUNCH_WAIT_SECONDS="${CAPGO_MAESTRO_IOS_APP_LAUNCH_WAIT_SECONDS:-5}"
SERVER_PID=""
export MAESTRO_DRIVER_STARTUP_TIMEOUT="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-600000}"
MAESTRO_TEST_RETRIES="${CAPGO_MAESTRO_TEST_RETRIES:-3}"
FLOW_RETRY_PATTERN="iOS driver not ready in time|Failed to connect to /127\\.0\\.0\\.1:[0-9]+|Connection refused|Broken pipe|Request for viewHierarchy failed, because of unknown reason|XCTestDriver request failed\\. Status code: 500, path: viewHierarchy|failed to terminate dev\\.mobile\\.maestro-driver-iosUITests\\.xctrunner|found nothing to terminate"

default_simulator_id() {
  xcrun simctl list devices available | sed -nE 's/^[[:space:]]*iPhone.*\(([0-9A-F-]{36})\) \([^)]*\)[[:space:]]*$/\1/p' | head -n 1
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

cleanup() {
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

launch_example_app() {
  xcrun simctl launch "$SIMULATOR_ID" "$APP_ID" >/dev/null 2>&1
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

start_fake_server() {
  mkdir -p "$ARTIFACT_DIR"
  bun "$ROOT_DIR/scripts/maestro/fake-capgo-server.mjs" >"$ARTIFACT_DIR/fake-capgo-server-ios-smoke.log" 2>&1 &
  SERVER_PID=$!

  wait_for_server
}

reset_fake_server() {
  curl --silent --show-error --fail -X POST "$HOST_SERVER_URL/api/control/reset?scenario=$SCENARIO_ID" >/dev/null
}

assert_smoke_server_state() {
  local server_state=""

  server_state="$(curl --silent --show-error --fail "$HOST_SERVER_URL/api/control/state?scenario=$SCENARIO_ID")"

  bun --eval "
const state = JSON.parse(process.argv[1]);
const scenarioId = process.argv[2];
const failures = [];
const debug = state.debug ?? {};
const update = debug.lastUpdateRequest ?? {};
const channel = debug.lastChannelRequest ?? {};
const stats = debug.lastStatsRequest ?? {};
const updatePayload = update.payload ?? {};
const channelPayload = channel.payload ?? {};
const requestCounts = debug.requestCounts ?? {};

function expect(condition, message) {
  if (!condition) {
    failures.push(message);
  }
}

switch (scenarioId) {
  case 'manual-zip':
    expect(update.url?.includes('/api/updates/manual-zip?source=runtime-update'), 'missing persisted runtime update URL request');
    expect(channel.url?.includes('/api/channel?scenario=manual-zip&source=runtime-channel'), 'missing persisted runtime channel URL request');
    expect(stats.url?.includes('/api/stats?scenario=manual-zip&source=runtime-stats'), 'missing runtime stats URL request');
    expect((updatePayload.custom_id ?? channelPayload.custom_id) === 'qa-user-42', 'missing persisted custom ID');
    expect((requestCounts.channel ?? 0) >= 5, 'expected multiple channel operations to hit the fake server');
    expect((requestCounts.update ?? 0) >= 2, 'expected repeated update checks to hit the fake server');
    expect((requestCounts.stats ?? 0) >= 1, 'expected stats traffic to hit the fake server');
    break;
  case 'manual-zip-no-persist':
    expect(update.url?.includes('/api/updates/manual-zip-no-persist'), 'missing default update URL request after relaunch');
    expect(!update.url?.includes('source=runtime-update'), 'update URL unexpectedly stayed on the runtime override');
    expect(channel.url?.includes('/api/channel?scenario=manual-zip-no-persist'), 'missing default channel URL request after relaunch');
    expect(!channel.url?.includes('source=runtime-channel'), 'channel URL unexpectedly stayed on the runtime override');
    expect((updatePayload.custom_id ?? channelPayload.custom_id ?? '') !== 'qa-user-42', 'custom ID unexpectedly persisted across relaunch');
    expect((requestCounts.channel ?? 0) >= 2, 'expected repeated channel checks to hit the fake server');
    expect((requestCounts.update ?? 0) >= 2, 'expected repeated update checks to hit the fake server');
    expect((requestCounts.stats ?? 0) >= 1, 'expected stats traffic to hit the fake server');
    break;
  case 'manual-zip-config-guards':
    expect(update.url?.includes('/api/updates/manual-zip-config-guards'), 'missing default update URL request for guarded config');
    expect(!update.url?.includes('source=runtime-update'), 'guarded config unexpectedly accepted a runtime update URL override');
    expect(channel.url?.includes('/api/channel?scenario=manual-zip-config-guards'), 'missing default channel URL request for guarded config');
    expect(!channel.url?.includes('source=runtime-channel'), 'guarded config unexpectedly accepted a runtime channel URL override');
    expect((updatePayload.custom_id ?? channelPayload.custom_id) === 'qa-user-42', 'custom ID should still persist when only URL/App ID setters are guarded');
    expect((requestCounts.channel ?? 0) >= 2, 'expected guarded config channel checks to hit the fake server');
    expect((requestCounts.update ?? 0) >= 2, 'expected guarded config update checks to hit the fake server');
    expect((requestCounts.stats ?? 0) >= 1, 'expected stats traffic to hit the fake server');
    break;
  default:
    expect(update.url?.includes('/api/updates/' + scenarioId), 'missing update request');
    expect(channel.url?.includes('/api/channel?scenario=' + scenarioId), 'missing channel request');
    expect((requestCounts.channel ?? 0) >= 1, 'expected channel traffic to hit the fake server');
    expect((requestCounts.update ?? 0) >= 1, 'expected update traffic to hit the fake server');
    break;
}

if (failures.length) {
  console.error('Smoke server assertions failed:');
  for (const failure of failures) {
    console.error('- ' + failure);
  }
  process.exit(1);
}
" "$server_state" "$SCENARIO_ID"

  case "$SCENARIO_ID" in
    manual-zip|manual-zip-no-persist)
      if ! grep -Eq "GET /api/channel\\?scenario=${SCENARIO_ID}.*app_id=app\\.capgo\\.updater\\.e2e" \
        "$ARTIFACT_DIR/fake-capgo-server-ios-smoke.log"; then
        echo "Smoke server assertions failed:" >&2
        echo "- missing runtime app ID override in channel request log" >&2
        exit 1
      fi
      ;;
    manual-zip-config-guards)
      if grep -Eq "GET /api/channel\\?scenario=${SCENARIO_ID}.*app_id=app\\.capgo\\.updater\\.e2e" \
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

export CAPGO_MAESTRO_DEVICE_BASE_URL="$DEVICE_SERVER_URL"

cd "$ROOT_DIR"

if [[ "$SKIP_BUILD" != "1" ]]; then
  if [[ ! -d node_modules ]]; then
    bun install
  fi

  bun "$ROOT_DIR/scripts/maestro/build-bundles.mjs" "$SCENARIO_ID"
  start_fake_server
  reset_fake_server
  bun "$ROOT_DIR/scripts/maestro/prepare-ios-scenario.mjs" "$SCENARIO_ID"
  xcodebuild \
    -project "$EXAMPLE_DIR/ios/App/App.xcodeproj" \
    -scheme App \
    -configuration Debug \
    -destination "id=$SIMULATOR_ID" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build
else
  start_fake_server
  reset_fake_server
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected simulator app at $APP_PATH" >&2
  exit 1
fi

xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
if run_with_timeout "$SIMULATOR_BOOT_TIMEOUT_SECONDS" xcrun simctl bootstatus "$SIMULATOR_ID" -b; then
  :
else
  status=$?
  if [[ $status -eq 124 ]]; then
    echo "Simulator failed to boot within ${SIMULATOR_BOOT_TIMEOUT_SECONDS} seconds." >&2
  fi
  exit "$status"
fi

xcrun simctl uninstall "$SIMULATOR_ID" "$APP_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"

launch_attempt=1
while (( launch_attempt <= APP_LAUNCH_RETRIES )); do
  if launch_example_app; then
    sleep "$APP_LAUNCH_WAIT_SECONDS"
    break
  fi

  if (( launch_attempt == APP_LAUNCH_RETRIES )); then
    echo "Unable to launch the iOS example app after ${APP_LAUNCH_RETRIES} attempts." >&2
    exit 1
  fi

  sleep 2
  ((launch_attempt += 1))
done

attempt=1
while (( attempt <= MAESTRO_TEST_RETRIES )); do
  rm -rf "$RESULTS_DIR"
  mkdir -p "$RESULTS_DIR"
  output_file="$(mktemp)"

  echo "Running iOS Maestro smoke flow (attempt ${attempt}/${MAESTRO_TEST_RETRIES})"

  set +e
  run_with_timeout "$MAESTRO_TIMEOUT_SECONDS" maestro test \
    -p ios \
    --device "$SIMULATOR_ID" \
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

  if [[ $status -eq 124 ]]; then
    echo "Maestro test timed out after ${MAESTRO_TIMEOUT_SECONDS} seconds." >&2
  fi

  if (( attempt < MAESTRO_TEST_RETRIES )) && { [[ $status -eq 124 ]] || grep -Eq "$FLOW_RETRY_PATTERN" "$output_file"; }; then
    echo "Retrying iOS Maestro smoke flow after simulator/XCTest instability." >&2
    rm -f "$output_file"
    xcrun simctl terminate "$SIMULATOR_ID" "$APP_ID" >/dev/null 2>&1 || true
    xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
    xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
    run_with_timeout "$SIMULATOR_BOOT_TIMEOUT_SECONDS" xcrun simctl bootstatus "$SIMULATOR_ID" -b || true
    launch_example_app || true
    sleep "$APP_LAUNCH_WAIT_SECONDS"
    attempt=$((attempt + 1))
    continue
  fi

  rm -f "$output_file"
  exit "$status"
done

assert_smoke_server_state
