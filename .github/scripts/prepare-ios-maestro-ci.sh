#!/usr/bin/env bash
# Overlaps simulator bootstatus with artifact downloads to shrink iOS Maestro job setup.
set -euo pipefail

web_artifact_name="${1:?web artifact name required}"
ios_artifact_name="${2:?ios artifact name required}"
ios_artifact_dir="${3:?ios artifact directory required}"
simulator_id="${CAPGO_MAESTRO_IOS_SIMULATOR_ID:?CAPGO_MAESTRO_IOS_SIMULATOR_ID is required}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required to download workflow artifacts in parallel." >&2
  exit 1
fi

xcrun simctl bootstatus "$simulator_id" -b &
boot_pid=$!

gh run download "$GITHUB_RUN_ID" -n "$web_artifact_name" -D . &
web_pid=$!

gh run download "$GITHUB_RUN_ID" -n "$ios_artifact_name" -D "$ios_artifact_dir" &
ios_pid=$!

wait "$web_pid"
wait "$ios_pid"
wait "$boot_pid"
