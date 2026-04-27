#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE_DIR="$ROOT_DIR/example-app"
APK_PATH="$EXAMPLE_DIR/android/app/build/outputs/apk/debug/app-debug.apk"
RESULTS_DIR="$ROOT_DIR/maestro-results"
SKIP_BUILD="${CAPGO_MAESTRO_SKIP_BUILD:-0}"
SCENARIO_ID="${CAPGO_MAESTRO_SMOKE_SCENARIO:-manual-zip}"
FLOW_PATH="$ROOT_DIR/.maestro/android/example-app-smoke.yaml"
if [[ "$SCENARIO_ID" == "manual-zip-config-guards" ]]; then
  FLOW_PATH="$ROOT_DIR/.maestro/android/example-app-smoke-config-guards.yaml"
elif [[ "$SCENARIO_ID" == "manual-zip-no-persist" ]]; then
  FLOW_PATH="$ROOT_DIR/.maestro/android/example-app-smoke-no-persist.yaml"
fi
ARTIFACT_DIR="$ROOT_DIR/.maestro-artifacts"
HOST_SERVER_PORT="${CAPGO_MAESTRO_PORT:-3192}"
HOST_SERVER_URL="${CAPGO_MAESTRO_HOST_BASE_URL:-http://127.0.0.1:${HOST_SERVER_PORT}}"
DEVICE_SERVER_URL="${CAPGO_MAESTRO_DEVICE_BASE_URL:-http://127.0.0.1:${HOST_SERVER_PORT}}"
EMULATOR_BOOT_TIMEOUT_SECONDS="${CAPGO_MAESTRO_EMULATOR_BOOT_TIMEOUT_SECONDS:-180}"
MAESTRO_TIMEOUT_SECONDS="${CAPGO_MAESTRO_TIMEOUT_SECONDS:-600}"
MAESTRO_DRIVER_STARTUP_TIMEOUT="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-180000}"
MAESTRO_CLI_NO_ANALYTICS="${MAESTRO_CLI_NO_ANALYTICS:-1}"
MAESTRO_JAVA_TOOL_OPTIONS="${CAPGO_MAESTRO_JAVA_TOOL_OPTIONS:--Djava.net.preferIPv4Stack=true}"
MAESTRO_TEST_RETRIES="${CAPGO_MAESTRO_TEST_RETRIES:-3}"
APK_INSTALL_RETRIES="${CAPGO_MAESTRO_APK_INSTALL_RETRIES:-3}"
PACKAGE_SERVICE_TIMEOUT_SECONDS="${CAPGO_MAESTRO_ANDROID_PACKAGE_TIMEOUT_SECONDS:-120}"
APP_ACTIVITY="${CAPGO_MAESTRO_ANDROID_ACTIVITY:-app.capgo.updater/.MainActivity}"
APP_LAUNCH_RETRIES="${CAPGO_MAESTRO_APP_LAUNCH_RETRIES:-3}"
APP_UI_TIMEOUT_SECONDS="${CAPGO_MAESTRO_APP_UI_TIMEOUT_SECONDS:-150}"
POST_INSTALL_STABILIZE_SECONDS="${CAPGO_MAESTRO_POST_INSTALL_STABILIZE_SECONDS:-8}"
APP_READY_TITLE="@capgo/capacitor-updater"
APP_READY_ACTION="Run notifyAppReady"
APP_ID="app.capgo.updater"
FLOW_RETRY_PATTERN="TcpForwarder.waitFor|allocateForwarder|TimeoutException|Android driver did not start up in time|Maestro Android driver did not start up in time|UNAVAILABLE: io exception|Connection refused|Broken pipe|Failure calling service package|Can.t find service: package|Can.t find service: settings|Cannot access system provider: 'settings'"
TIMEOUT_CMD="$(command -v gtimeout || command -v timeout || true)"
SERVER_PID=""

if [[ -n "${JAVA_TOOL_OPTIONS:-}" ]]; then
  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS} ${MAESTRO_JAVA_TOOL_OPTIONS}"
else
  export JAVA_TOOL_OPTIONS="${MAESTRO_JAVA_TOOL_OPTIONS}"
fi

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi

  return 0
}

trap cleanup EXIT

wait_for_emulator_boot() {
  local sys_boot_completed=""
  local dev_boot_completed=""
  local deadline=0

  if ! timeout "${EMULATOR_BOOT_TIMEOUT_SECONDS}s" adb wait-for-device; then
    echo "Emulator failed to connect within ${EMULATOR_BOOT_TIMEOUT_SECONDS} seconds." >&2
    exit 1
  fi

  deadline=$((SECONDS + EMULATOR_BOOT_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    sys_boot_completed="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    dev_boot_completed="$(adb shell getprop dev.bootcomplete 2>/dev/null | tr -d '\r' || true)"
    if [[ "$sys_boot_completed" == "1" || "$dev_boot_completed" == "1" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "Emulator failed to complete boot within ${EMULATOR_BOOT_TIMEOUT_SECONDS} seconds." >&2
  exit 1
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

configure_server_routing() {
  case "$DEVICE_SERVER_URL" in
    http://127.0.0.1:*|http://localhost:*|https://127.0.0.1:*|https://localhost:*)
      adb reverse --remove "tcp:${HOST_SERVER_PORT}" >/dev/null 2>&1 || true
      adb reverse "tcp:${HOST_SERVER_PORT}" "tcp:${HOST_SERVER_PORT}" >/dev/null
      ;;
  esac

  return 0
}

reset_maestro_driver_packages() {
  adb shell am force-stop dev.mobile.maestro >/dev/null 2>&1 || true
  adb shell am force-stop dev.mobile.maestro.test >/dev/null 2>&1 || true
  adb uninstall dev.mobile.maestro >/dev/null 2>&1 || true
  adb uninstall dev.mobile.maestro.test >/dev/null 2>&1 || true
  return 0
}

start_fake_server() {
  mkdir -p "$ARTIFACT_DIR"
  bun "$ROOT_DIR/scripts/maestro/fake-capgo-server.mjs" >"$ARTIFACT_DIR/fake-capgo-server-android-smoke.log" 2>&1 &
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
        "$ARTIFACT_DIR/fake-capgo-server-android-smoke.log"; then
        echo "Smoke server assertions failed:" >&2
        echo "- missing runtime app ID override in channel request log" >&2
        exit 1
      fi
      ;;
    manual-zip-config-guards)
      if grep -Eq "GET /api/channel\\?scenario=${SCENARIO_ID}.*app_id=app\\.capgo\\.updater\\.e2e" \
        "$ARTIFACT_DIR/fake-capgo-server-android-smoke.log"; then
        echo "Smoke server assertions failed:" >&2
        echo "- guarded config unexpectedly accepted the runtime app ID override" >&2
        exit 1
      fi
      ;;
  esac
}

wait_for_android_package_service() {
  local deadline=0

  deadline=$((SECONDS + PACKAGE_SERVICE_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    if adb shell pm path android >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "Android package service did not become ready within ${PACKAGE_SERVICE_TIMEOUT_SECONDS} seconds." >&2
  return 1
}

dump_ui_hierarchy() {
  adb exec-out uiautomator dump /dev/tty 2>/dev/null | tr -d '\r' | tr '\n' ' ' || true
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
    adb shell input tap "$x" "$y" >/dev/null 2>&1 || true
    sleep 1
    return 0
  fi

  return 1
}

restart_adb_server() {
  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null 2>&1 || true
  return 0
}

launch_example_app() {
  adb shell am start -S -W -n "$APP_ACTIVITY" >/dev/null 2>&1 || \
    adb shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  return 0
}

stabilize_android_after_install() {
  wait_for_emulator_boot
  wait_for_android_package_service
  sleep "$POST_INSTALL_STABILIZE_SECONDS"
  return 0
}

wait_for_example_app_ui() {
  local attempt=1
  local hierarchy=""
  local deadline=0

  while (( attempt <= APP_LAUNCH_RETRIES )); do
    launch_example_app
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
    adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
    wait_for_android_package_service || true
    sleep 2
    ((attempt += 1))
  done

  echo "Example app UI never became visible on Android after ${APP_LAUNCH_RETRIES} attempts." >&2
  return 1
}

install_apk_with_retries() {
  local attempt=1
  local status=0

  while (( attempt <= APK_INSTALL_RETRIES )); do
    status=0

    if ! wait_for_android_package_service; then
      status=1
    else
      adb shell pm clear "$APP_ID" >/dev/null 2>&1 || true
      adb uninstall "$APP_ID" >/dev/null 2>&1 || true
    fi

    if [[ $status -ne 0 ]]; then
      :
    elif adb install -r "$APK_PATH"; then
      return 0
    else
      status=$?
    fi

    if (( attempt == APK_INSTALL_RETRIES )); then
      echo "Failed to install the example APK after ${APK_INSTALL_RETRIES} attempts." >&2
      return "$status"
    fi

    echo "APK install attempt ${attempt} failed; waiting for the emulator before retrying." >&2
    wait_for_emulator_boot
    wait_for_android_package_service || true
    sleep 5
    ((attempt += 1))
  done

  return "$status"
}

run_maestro_test_with_retries() {
  local attempt=1
  local output_file=""
  local command_status=0

  while (( attempt <= MAESTRO_TEST_RETRIES )); do
    echo "Running Android Maestro smoke flow (attempt ${attempt}/${MAESTRO_TEST_RETRIES})"
    reset_maestro_driver_packages
    output_file="$(mktemp)"

    set +e
    MAESTRO_CLI_NO_ANALYTICS="$MAESTRO_CLI_NO_ANALYTICS" \
      MAESTRO_DRIVER_STARTUP_TIMEOUT="$MAESTRO_DRIVER_STARTUP_TIMEOUT" \
      "$TIMEOUT_CMD" --foreground "${MAESTRO_TIMEOUT_SECONDS}s" \
      maestro test \
      "$FLOW_PATH" \
      --platform android \
      --udid "$ANDROID_DEVICE_ID" \
      --format junit \
      --output "$RESULTS_DIR/junit.xml" \
      --debug-output "$RESULTS_DIR/debug" \
      --flatten-debug-output \
      --test-output-dir "$RESULTS_DIR/artifacts" 2>&1 | tee "$output_file"
    command_status=${PIPESTATUS[0]}
    set -e

    if [[ $command_status -eq 0 ]]; then
      rm -f "$output_file"
      return 0
    fi

    if [[ $attempt -lt $MAESTRO_TEST_RETRIES ]] && { [[ $command_status -eq 124 ]] || grep -Eq "$FLOW_RETRY_PATTERN" "$output_file"; }; then
      echo "Retrying Android Maestro smoke after driver/bootstrap failure." >&2
      rm -f "$output_file"
      attempt=$((attempt + 1))
      adb reboot >/dev/null 2>&1 || true
      restart_adb_server
      wait_for_emulator_boot
      wait_for_android_package_service || true
      reset_maestro_driver_packages
      configure_server_routing
      adb shell input keyevent 82 >/dev/null 2>&1 || true
      wait_for_example_app_ui
      sleep 5
      continue
    fi

    rm -f "$output_file"
    return "$command_status"
  done

  return 1
}

if ! command -v adb >/dev/null 2>&1; then
  echo "adb is required to run Android Maestro tests." >&2
  exit 1
fi

if ! command -v maestro >/dev/null 2>&1; then
  echo "maestro is required to run Android Maestro tests." >&2
  exit 1
fi

if [[ -z "$TIMEOUT_CMD" ]]; then
  echo "GNU timeout is required to run Android Maestro tests." >&2
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
export CAPGO_MAESTRO_DEVICE_BASE_URL="$DEVICE_SERVER_URL"

if [[ "$SKIP_BUILD" != "1" ]]; then
  if [[ ! -d node_modules ]]; then
    bun install
  fi

  bun "$ROOT_DIR/scripts/maestro/build-bundles.mjs" "$SCENARIO_ID"
  start_fake_server
  reset_fake_server
  bun "$ROOT_DIR/scripts/maestro/prepare-android-scenario.mjs" "$SCENARIO_ID"
else
  start_fake_server
  reset_fake_server
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
configure_server_routing
install_apk_with_retries
stabilize_android_after_install
configure_server_routing
wait_for_example_app_ui

rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

if run_maestro_test_with_retries; then
  :
else
  status=$?
  if [[ $status -eq 124 ]]; then
    echo "Maestro test timed out after ${MAESTRO_TIMEOUT_SECONDS} seconds." >&2
  fi
  exit "$status"
fi

assert_smoke_server_state
