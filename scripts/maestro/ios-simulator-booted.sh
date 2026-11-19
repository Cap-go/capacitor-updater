#!/usr/bin/env bash
# Returns 0 when SIMULATOR_ID (or arg) is in Booted state.
set -euo pipefail

simulator_id="${1:-${CAPGO_MAESTRO_IOS_SIMULATOR_ID:-}}"
if [[ -z "$simulator_id" ]]; then
  exit 1
fi

xcrun simctl list devices booted -j 2>/dev/null |
  SIMULATOR_ID="$simulator_id" python3 -c "
import json, os, sys
target = os.environ.get('SIMULATOR_ID', '')
payload = json.load(sys.stdin)
for devices in payload.get('devices', {}).values():
  for device in devices:
    if device.get('udid') == target:
      sys.exit(0)
sys.exit(1)
"
