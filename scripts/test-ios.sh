#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SIMULATOR_ID=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/{print $2; exit}')

if [[ -z "${SIMULATOR_ID:-}" ]]; then
  echo "No available iPhone simulator found. Please install one via Xcode." >&2
  exit 1
fi

# Boot the simulator ourselves so it stays up between xcodebuild invocations
# (native tests, then the CLI crypto contract run) instead of each run paying
# for a cold boot and shutdown.
xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null 2>&1 || true

# Reuse one DerivedData folder so later runs in the same job are incremental,
# and skip post-test diagnostics collection, which only adds idle time in CI.
DERIVED_DATA_PATH="${CAPGO_IOS_TEST_DERIVED_DATA:-$ROOT_DIR/.build/ios-test-derived-data}"

xcodebuild test \
  -scheme CapgoCapacitorUpdater \
  -destination "id=${SIMULATOR_ID}" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -collect-test-diagnostics never \
  "$@"
