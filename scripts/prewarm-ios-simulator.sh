#!/usr/bin/env bash
# Start booting the first available iPhone simulator in the background on CI so
# the later native test steps do not pay for a cold boot. No-op outside CI.
set -euo pipefail

if [[ -z "${CI:-}" ]]; then
  exit 0
fi

SIMULATOR_ID=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/{print $2; exit}')
if [[ -z "${SIMULATOR_ID:-}" ]]; then
  exit 0
fi

nohup xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 &
