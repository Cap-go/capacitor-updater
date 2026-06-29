#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-}"
PLATFORM="${2:-all}"

usage() {
  echo "Usage: $0 <compile|test> [ios|android|all]" >&2
}

run_ios_compile() {
  cd "$ROOT_DIR"
  xcodebuild build-for-testing -scheme CapgoCapacitorUpdater -destination generic/platform=iOS "$@"
}

run_ios_test() {
  "$ROOT_DIR/scripts/test-ios.sh" "$@"
}

run_android_compile() {
  cd "$ROOT_DIR/android"
  ./gradlew compileDebugUnitTestSources "$@"
}

run_android_test() {
  cd "$ROOT_DIR/android"
  ./gradlew test "$@"
}

if [[ "$ACTION" != "compile" && "$ACTION" != "test" ]]; then
  usage
  exit 2
fi

case "$PLATFORM" in
  ios)
    "run_ios_${ACTION}" "${@:3}"
    ;;
  android)
    "run_android_${ACTION}" "${@:3}"
    ;;
  all)
    "run_ios_${ACTION}" "${@:3}"
    "run_android_${ACTION}" "${@:3}"
    ;;
  *)
    usage
    exit 2
    ;;
esac
