#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE_DIR="$ROOT_DIR/example-app"
APK_PATH="$EXAMPLE_DIR/android/app/build/outputs/apk/debug/app-debug.apk"
RESULTS_DIR="$ROOT_DIR/maestro-results"
SKIP_BUILD="${CAPGO_MAESTRO_SKIP_BUILD:-0}"

if ! command -v adb >/dev/null 2>&1; then
  echo "adb is required to run Android Maestro tests." >&2
  exit 1
fi

if ! command -v maestro >/dev/null 2>&1; then
  echo "maestro is required to run Android Maestro tests." >&2
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

if [[ "$SKIP_BUILD" != "1" ]]; then
  if [[ ! -d node_modules ]]; then
    bun install
  fi

  bun run build

  # Build the plugin first so the example app's file:.. dependency has dist/ available.
  (
    cd "$EXAMPLE_DIR"
    bun install
    bun run build
    bunx cap sync android
  )

  (
    cd "$EXAMPLE_DIR/android"
    ./gradlew assembleDebug
  )
fi

if [[ ! -f "$APK_PATH" ]]; then
  echo "Expected debug APK at $APK_PATH" >&2
  exit 1
fi

adb wait-for-device
adb shell settings put global window_animation_scale 0 || true
adb shell settings put global transition_animation_scale 0 || true
adb shell settings put global animator_duration_scale 0 || true
adb install -r "$APK_PATH"

rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

if ! timeout 5m maestro test \
  "$ROOT_DIR/.maestro" \
  --format junit \
  --output "$RESULTS_DIR/junit.xml" \
  --debug-output "$RESULTS_DIR/debug" \
  --flatten-debug-output \
  --test-output-dir "$RESULTS_DIR/artifacts"; then
  status=$?
  if [[ $status -eq 124 ]]; then
    echo "Maestro test timed out after 5 minutes." >&2
  fi
  exit "$status"
fi
