#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE_DIR="$ROOT_DIR/example-app"
RESULTS_DIR="${CAPGO_MAESTRO_RESULTS_DIR:-$ROOT_DIR/maestro-results-ios}"
FLOW_PATH="$ROOT_DIR/.maestro/ios/example-app-smoke.yaml"
SKIP_BUILD="${CAPGO_MAESTRO_SKIP_BUILD:-0}"
SIMULATOR_BOOT_TIMEOUT_SECONDS="${CAPGO_MAESTRO_IOS_BOOT_TIMEOUT_SECONDS:-180}"
MAESTRO_TIMEOUT_SECONDS="${CAPGO_MAESTRO_TIMEOUT_SECONDS:-300}"
APP_ID="app.capgo.updater"

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

cd "$ROOT_DIR"

if [[ "$SKIP_BUILD" != "1" ]]; then
  if [[ ! -d node_modules ]]; then
    bun install
  fi

  bun run build

  (
    cd "$EXAMPLE_DIR"
    bun install
    bun run build
    bunx cap sync ios
  )

  xcodebuild \
    -project "$EXAMPLE_DIR/ios/App/App.xcodeproj" \
    -scheme App \
    -configuration Debug \
    -destination "id=$SIMULATOR_ID" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build
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
xcrun simctl terminate "$SIMULATOR_ID" "$APP_ID" >/dev/null 2>&1 || true

rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

if run_with_timeout "$MAESTRO_TIMEOUT_SECONDS" maestro test \
  -p ios \
  --device "$SIMULATOR_ID" \
  "$FLOW_PATH" \
  --format junit \
  --output "$RESULTS_DIR/junit.xml" \
  --debug-output "$RESULTS_DIR/debug" \
  --flatten-debug-output \
  --test-output-dir "$RESULTS_DIR/artifacts"; then
  :
else
  status=$?
  if [[ $status -eq 124 ]]; then
    echo "Maestro test timed out after ${MAESTRO_TIMEOUT_SECONDS} seconds." >&2
  fi
  exit "$status"
fi

if [[ "$SKIP_BUILD" != "1" ]]; then
  "$ROOT_DIR/scripts/maestro/run-ios-native-update-reset.sh"
else
  echo "Skipping iOS native reset Maestro flow because CAPGO_MAESTRO_SKIP_BUILD=1." >&2
fi
