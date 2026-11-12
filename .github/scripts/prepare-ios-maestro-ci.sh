#!/usr/bin/env bash
# Overlaps simulator bootstatus with artifact downloads to shrink iOS Maestro job setup.
set -euo pipefail

web_artifact_name="${CAPGO_MAESTRO_WEB_ARTIFACT:-${1:-}}"
ios_artifact_name="${CAPGO_MAESTRO_IOS_ARTIFACT:-${2:-}}"
ios_artifact_dir="${CAPGO_MAESTRO_IOS_ARTIFACT_DIR:-${3:-}}"
simulator_id="${CAPGO_MAESTRO_IOS_SIMULATOR_ID:?CAPGO_MAESTRO_IOS_SIMULATOR_ID is required}"

if [[ -z "$web_artifact_name" || -z "$ios_artifact_name" || -z "$ios_artifact_dir" ]]; then
  echo "Maestro artifact names and iOS artifact directory are required." >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required to download workflow artifacts in parallel." >&2
  exit 1
fi

download_run_artifact() {
  local artifact_name="$1"
  local destination="$2"
  local attempt=1

  while [[ $attempt -le 3 ]]; do
    if gh run download "$GITHUB_RUN_ID" -n "$artifact_name" -D "$destination"; then
      return 0
    fi

    echo "Artifact download failed for ${artifact_name} (attempt ${attempt}/3)." >&2
    if [[ $attempt -lt 3 ]]; then
      sleep 15
    fi
    attempt=$((attempt + 1))
  done

  echo "Unable to download artifact ${artifact_name} from run ${GITHUB_RUN_ID}." >&2
  return 1
}

xcrun simctl bootstatus "$simulator_id" -b &
boot_pid=$!

download_run_artifact "$web_artifact_name" . &
web_pid=$!

download_run_artifact "$ios_artifact_name" "$ios_artifact_dir" &
ios_pid=$!

if [[ -n "${BUN_VERSION:-}" ]]; then
  ./scripts/ci/install-bun.sh &
  bun_pid=$!
else
  bun_pid=""
fi

if [[ -n "${MAESTRO_VERSION:-}" ]]; then
  ./scripts/ci/install-maestro.sh &
  maestro_pid=$!
else
  maestro_pid=""
fi

./scripts/ci/install-node22.sh &
node_pid=$!

wait "$web_pid"
wait "$ios_pid"
if [[ -n "$bun_pid" ]]; then
  wait "$bun_pid"
fi
if [[ -n "$maestro_pid" ]]; then
  wait "$maestro_pid"
fi
wait "$node_pid"
wait "$boot_pid"
