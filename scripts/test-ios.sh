#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SIMULATOR_ID=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/{print $2; exit}')

if [[ -z "${SIMULATOR_ID:-}" ]]; then
  echo "No available iPhone simulator found. Please install one via Xcode." >&2
  exit 1
fi

# On CI the simulator is already booting (see scripts/prewarm-ios-simulator.sh).
# Booting is idempotent; keeping it up lets later xcodebuild runs in the same job
# reuse it. Post-test diagnostics collection only adds idle time, so skip it.
xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true

xcodebuild test \
  -scheme CapgoCapacitorUpdater \
  -destination "id=${SIMULATOR_ID}" \
  -collect-test-diagnostics never \
  "$@"
