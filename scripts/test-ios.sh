#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Always rebuild the Rust core so tests never run against a stale xcframework.
"$ROOT_DIR/scripts/build-core.sh" ios

SIMULATOR_ID=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/{print $2; exit}')

if [[ -z "${SIMULATOR_ID:-}" ]]; then
  echo "No available iPhone simulator found. Please install one via Xcode." >&2
  exit 1
fi

xcodebuild test -scheme CapgoCapacitorUpdater -destination "id=${SIMULATOR_ID}" "$@"
