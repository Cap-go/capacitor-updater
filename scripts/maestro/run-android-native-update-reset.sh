#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXAMPLE_DIR="$ROOT_DIR/example-app"
ARTIFACT_DIR="$ROOT_DIR/.maestro-artifacts/android-native-reset"
RESULTS_DIR="$ROOT_DIR/maestro-results-android-native-reset"
ASSERT_FLOW="$ROOT_DIR/.maestro/assert-state.yaml"
LAUNCH_FLOW="$ROOT_DIR/.maestro/helpers/relaunch-app.yaml"
SCENARIO_ID="native-reset"
HOST_SERVER_PORT="${CAPGO_MAESTRO_PORT:-3192}"
HOST_SERVER_URL="${CAPGO_MAESTRO_HOST_BASE_URL:-http://127.0.0.1:${HOST_SERVER_PORT}}"
DEVICE_SERVER_URL="${CAPGO_MAESTRO_DEVICE_BASE_URL:-}"
APP_ID="app.capgo.updater"
APK_PATH="$EXAMPLE_DIR/android/app/build/outputs/apk/debug/app-debug.apk"
APK_V1="$ARTIFACT_DIR/native-reset-v1.apk"
APK_V2="$ARTIFACT_DIR/native-reset-v2.apk"
ANDROID_BOOT_TIMEOUT_SECONDS="${CAPGO_MAESTRO_EMULATOR_BOOT_TIMEOUT_SECONDS:-180}"
MAESTRO_TIMEOUT_SECONDS="${CAPGO_MAESTRO_TIMEOUT_SECONDS:-300}"
TIMEOUT_CMD="$(command -v gtimeout || command -v timeout || true)"
SERVER_PID=""
ANDROID_DEVICE_ID="${CAPGO_MAESTRO_ANDROID_DEVICE_ID:-}"
DEVICE_SERVER_URL_IS_REVERSED="0"

cleanup() {
  if [[ "$DEVICE_SERVER_URL_IS_REVERSED" == "1" ]]; then
    adb_cmd reverse --remove "tcp:${HOST_SERVER_PORT}" >/dev/null 2>&1 || true
  fi

  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi

  return 0
}

trap cleanup EXIT

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  "$TIMEOUT_CMD" --foreground "${timeout_seconds}s" "$@"
  return $?
}

adb_cmd() {
  if [[ -n "${ANDROID_DEVICE_ID:-}" ]]; then
    adb -s "$ANDROID_DEVICE_ID" "$@"
  else
    adb "$@"
  fi
  return $?
}

wait_for_emulator_boot() {
  # Note: run_with_timeout shells out through the external timeout binary, so it
  # must invoke adb directly instead of the adb_cmd shell helper.
  if run_with_timeout "$ANDROID_BOOT_TIMEOUT_SECONDS" adb -s "$ANDROID_DEVICE_ID" wait-for-device >/dev/null; then
    :
  else
    local status=$?
    if [[ $status -eq 124 ]]; then
      echo "Android emulator did not become available within ${ANDROID_BOOT_TIMEOUT_SECONDS} seconds for the native reset Maestro test." >&2
    fi
    return "$status"
  fi

  local deadline=$((SECONDS + ANDROID_BOOT_TIMEOUT_SECONDS))
  local boot_completed=""

  while (( SECONDS < deadline )); do
    boot_completed="$(adb_cmd shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [[ "$boot_completed" == "1" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "Android emulator failed to boot for the native reset Maestro test." >&2
  return 1
}

wait_for_package_manager() {
  local deadline=$((SECONDS + ANDROID_BOOT_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    if adb_cmd shell cmd package list packages >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "Android package manager did not become ready for the native reset Maestro test." >&2
  return 1
}

ensure_android_device() {
  if [[ -n "$ANDROID_DEVICE_ID" && "$ANDROID_DEVICE_ID" != "unknown" ]]; then
    return 0
  fi

  if run_with_timeout "$ANDROID_BOOT_TIMEOUT_SECONDS" adb wait-for-device >/dev/null; then
    ANDROID_DEVICE_ID="$(adb get-serialno 2>/dev/null | tr -d '\r')"
  else
    local status=$?
    if [[ $status -eq 124 ]]; then
      echo "Android emulator did not become available within ${ANDROID_BOOT_TIMEOUT_SECONDS} seconds for the native reset Maestro test." >&2
    fi
    return "$status"
  fi
  if [[ -z "$ANDROID_DEVICE_ID" || "$ANDROID_DEVICE_ID" == "unknown" ]]; then
    echo "Unable to determine the Android emulator/device ID for the native reset Maestro test." >&2
    return 1
  fi
  return 0
}

configure_device_server_url() {
  if [[ -n "$DEVICE_SERVER_URL" ]]; then
    return 0
  fi

  if adb_cmd reverse "tcp:${HOST_SERVER_PORT}" "tcp:${HOST_SERVER_PORT}" >/dev/null; then
    DEVICE_SERVER_URL="http://127.0.0.1:${HOST_SERVER_PORT}"
    DEVICE_SERVER_URL_IS_REVERSED="1"
    return 0
  fi

  echo "Unable to configure adb reverse for the Android native reset Maestro test." >&2
  return 1
}

wait_for_server() {
  for _ in $(seq 1 30); do
    if curl --silent --fail "$HOST_SERVER_URL/health" >/dev/null; then
      return 0
    fi
    sleep 1
  done

  echo "Fake Capgo server did not start in time for Android native reset." >&2
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
  return $?
}

control_server() {
  local action="$1"
  curl --silent --show-error --fail -X POST "$HOST_SERVER_URL/api/control/$action?scenario=$SCENARIO_ID" >/dev/null
  return $?
}

build_android_app() {
  local app_label="$1"
  local auto_update="$2"
  local direct_update="$3"
  local version_name="$4"
  local version_code="$5"
  local update_url="$DEVICE_SERVER_URL/api/updates/$SCENARIO_ID"

  (
    cd "$EXAMPLE_DIR"
    export VITE_CAPGO_APP_LABEL="$app_label"
    export VITE_CAPGO_SCENARIO="$SCENARIO_ID"
    export VITE_CAPGO_DIRECT_UPDATE="$direct_update"
    export VITE_CAPGO_SERVER_URL="$update_url"
    export CAPGO_AUTO_UPDATE="$auto_update"
    export CAPGO_DIRECT_UPDATE="$direct_update"
    export CAPGO_UPDATE_URL="$update_url"
    export CAPGO_STATS_URL="$DEVICE_SERVER_URL/api/stats"
    export CAPGO_CHANNEL_URL="$DEVICE_SERVER_URL/api/channel"
    export CAPGO_NATIVE_VERSION_NAME="$version_name"
    export CAPGO_NATIVE_VERSION_CODE="$version_code"

    bun run build
    bunx cap sync android
  )

  (
    cd "$EXAMPLE_DIR/android"
    CAPGO_NATIVE_VERSION_NAME="$version_name" CAPGO_NATIVE_VERSION_CODE="$version_code" ./gradlew assembleDebug >/dev/null
  )
  return 0
}

run_maestro_flow() {
  local flow_path="$1"
  shift
  local -a extra_args=("$@")
  local -a command=(
    maestro
    test
    --platform
    android
    --udid
    "$ANDROID_DEVICE_ID"
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
      echo "Android Maestro flow timed out after ${MAESTRO_TIMEOUT_SECONDS} seconds: ${flow_path}" >&2
    fi
    return "$status"
  fi
}

install_apk() {
  local apk_path="$1"

  adb_cmd shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  adb_cmd install -r "$apk_path" >/dev/null
  return $?
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
  return $?
}

if ! command -v adb >/dev/null 2>&1; then
  echo "adb is required to run the Android native reset Maestro test." >&2
  exit 1
fi

if ! command -v maestro >/dev/null 2>&1; then
  echo "maestro is required to run the Android native reset Maestro test." >&2
  exit 1
fi

if [[ -z "$TIMEOUT_CMD" ]]; then
  echo "GNU timeout is required to run the Android native reset Maestro test." >&2
  exit 1
fi

if [[ ! -d "$ROOT_DIR/node_modules" ]]; then
  (cd "$ROOT_DIR" && bun install)
fi

if [[ ! -d "$EXAMPLE_DIR/node_modules" ]]; then
  (cd "$EXAMPLE_DIR" && bun install)
fi

mkdir -p "$ARTIFACT_DIR" "$RESULTS_DIR"
rm -rf -- "${RESULTS_DIR:?}/"*

ensure_android_device
wait_for_emulator_boot
wait_for_package_manager
configure_device_server_url

export CAPGO_MAESTRO_DEVICE_BASE_URL="$DEVICE_SERVER_URL"
export CAPGO_MAESTRO_HOST_BASE_URL="$HOST_SERVER_URL"
export CAPGO_MAESTRO_PORT="$HOST_SERVER_PORT"

bun "$ROOT_DIR/scripts/maestro/build-bundles.mjs" "$SCENARIO_ID"
build_android_app "native-reset-builtin-v1" "true" "always" "1.0.0" "1"
cp "$APK_PATH" "$APK_V1"
build_android_app "native-reset-builtin-v2" "false" "false" "2.0.0" "2"
cp "$APK_PATH" "$APK_V2"
start_server
control_server reset

adb_cmd uninstall "$APP_ID" >/dev/null 2>&1 || true
install_apk "$APK_V1"
run_maestro_flow "$LAUNCH_FLOW"
assert_state \
  "Build label: native-reset-live" \
  "Scenario: native-reset" \
  "Direct update mode: always" \
  "Current bundle source: downloaded" \
  "Current bundle version: native-reset-live"

install_apk "$APK_V2"
run_maestro_flow "$LAUNCH_FLOW"
assert_state \
  "Build label: native-reset-builtin-v2" \
  "Scenario: native-reset" \
  "Direct update mode: false" \
  "Current bundle source: builtin" \
  "Current bundle version: 2.0.0"
