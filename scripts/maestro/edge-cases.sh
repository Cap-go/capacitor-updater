#!/usr/bin/env bash
# Shared helpers for the edge case Maestro scenarios (network drop, app kill, corrupt bundle, ...).
# Sourced by run-android-live-update.sh and run-ios-live-update.sh after HOST_SERVER_URL is set.
# Failures are injected by fake-capgo-server.mjs because the device reaches the server through
# adb reverse / the host loopback, so toggling the emulator or simulator radio would not cut it.

EDGE_CASE_SERVER_TIMEOUT_SECONDS="${CAPGO_MAESTRO_EDGE_SERVER_TIMEOUT_SECONDS:-180}"
# edgeCases in scenarios.mjs is the single source of truth for case ids and their app scenario.
read -r -a EDGE_CASE_IDS <<<"$(bun --eval "
import { edgeCases } from '${ROOT_DIR}/scripts/maestro/scenarios.mjs';
console.log(Object.keys(edgeCases).join(' '));
")"

is_edge_case() {
  local candidate="$1"
  local edge_case_id

  for edge_case_id in "${EDGE_CASE_IDS[@]}"; do
    if [[ "$edge_case_id" == "$candidate" ]]; then
      return 0
    fi
  done

  return 1
}

edge_case_app_scenario() {
  local edge_case_id="$1"

  bun --eval "
import { edgeCases } from '${ROOT_DIR}/scripts/maestro/scenarios.mjs';

const app = edgeCases[process.argv[1]]?.app;
if (!app) {
  console.error('Unknown edge case: ' + process.argv[1]);
  process.exit(1);
}
console.log(app);
" "$edge_case_id"
  return $?
}

set_server_fault() {
  local scenario="$1"
  local target="$2"
  local mode="$3"

  curl --silent --show-error --fail -X POST \
    "$HOST_SERVER_URL/api/control/fault?scenario=$scenario&target=$target&mode=$mode" >/dev/null
  echo "Fake Capgo server fault for ${scenario}: ${target}=${mode}"
  return 0
}

# Polls the fake server until a JS condition over its debug state holds. The condition can use
# `state`, `debug`, `downloads` (bundle download counters) and `stats` (stats action counts).
wait_for_server_condition() {
  local scenario="$1"
  local description="$2"
  local condition="$3"
  local timeout_seconds="${4:-$EDGE_CASE_SERVER_TIMEOUT_SECONDS}"
  local deadline=$((SECONDS + timeout_seconds))
  local server_state=""

  echo "Waiting for fake server state: ${description}"

  while ((SECONDS < deadline)); do
    server_state="$(curl --silent --show-error --fail "$HOST_SERVER_URL/api/control/state?scenario=$scenario" || true)"

    if [[ -n "$server_state" ]] && bun --eval "
const state = JSON.parse(process.argv[1]);
const debug = state.debug ?? {};
const downloads = debug.bundleDownloads ?? {};
const stats = debug.statsActionCounts ?? {};
process.exit((${condition}) ? 0 : 1);
" "$server_state" >/dev/null 2>&1; then
      echo "Verified fake server state: ${description}"
      return 0
    fi

    sleep 1
  done

  echo "Timed out waiting for fake server state: ${description}" >&2
  echo "Last fake server state: ${server_state}" >&2
  return 1
}

# Fault to inject for each edge case before the app first launches.
apply_edge_case_fault() {
  local edge_case_id="$1"
  local app_scenario="$2"

  case "$edge_case_id" in
    edge-network-drop|edge-direct-network-drop)
      set_server_fault "$app_scenario" bundle drop
      ;;
    edge-kill-download)
      set_server_fault "$app_scenario" bundle stall
      ;;
    edge-corrupt-bundle)
      set_server_fault "$app_scenario" bundle corrupt
      ;;
    edge-offline-check)
      set_server_fault "$app_scenario" update drop
      ;;
    *)
      echo "Unknown edge case: $edge_case_id" >&2
      return 1
      ;;
  esac
}

# Waits until the injected fault has actually hit the running app.
wait_for_edge_case_fault_hit() {
  local edge_case_id="$1"
  local app_scenario="$2"

  case "$edge_case_id" in
    edge-network-drop|edge-direct-network-drop)
      wait_for_server_condition "$app_scenario" 'bundle download dropped midway' 'downloads.dropped >= 1'
      ;;
    edge-kill-download)
      wait_for_server_condition "$app_scenario" 'bundle download is stalled in flight' 'downloads.inFlight >= 1'
      ;;
    edge-corrupt-bundle)
      wait_for_server_condition "$app_scenario" 'corrupted bundle was served' 'downloads.faulted >= 1'
      ;;
    edge-offline-check)
      wait_for_server_condition "$app_scenario" 'update check hit the dropped connection' 'debug.updateFaults >= 1'
      ;;
    *)
      echo "Unknown edge case: $edge_case_id" >&2
      return 1
      ;;
  esac
  return $?
}

# Server-side proof that the app recovered with a full, clean download after the fault cleared.
assert_edge_case_recovered() {
  local edge_case_id="$1"
  local app_scenario="$2"

  wait_for_server_condition "$app_scenario" 'a full bundle download was served after the fault cleared' 'downloads.served >= 1' 30 || return 1

  case "$edge_case_id" in
    edge-kill-download)
      wait_for_server_condition "$app_scenario" 'the killed download was seen as aborted' 'downloads.aborted >= 1' 5
      ;;
    edge-corrupt-bundle)
      wait_for_server_condition "$app_scenario" 'the checksum mismatch was reported' '(stats.checksum_fail ?? 0) >= 1' 5
      ;;
    edge-offline-check)
      wait_for_server_condition "$app_scenario" 'the failed update check was reported' '(stats.download_fail ?? 0) >= 1' 5
      ;;
    *)
      return 0
      ;;
  esac
  return $?
}

# Server-side proof that the failure stayed contained; call it before the fault is cleared.
assert_edge_case_failure_contained() {
  local edge_case_id="$1"
  local app_scenario="$2"

  if [[ "$edge_case_id" == "edge-offline-check" ]]; then
    wait_for_server_condition "$app_scenario" 'no bundle was requested while the update check failed' 'downloads.started === 0' 5
    return $?
  fi

  return 0
}
