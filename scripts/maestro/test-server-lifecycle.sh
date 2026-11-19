#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/scripts/maestro/start-fake-server.sh"
TEST_DIR="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

CAPGO_MAESTRO_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    print(listener.getsockname()[1])
PY
)"
export CAPGO_MAESTRO_PORT

for preference in 0 1; do
  export CAPGO_MAESTRO_PREFER_BUN_JS="$preference"
  for attempt in 1 2; do
    start_fake_capgo_server "$TEST_DIR/server.log"
    ready=0
    for _ in {1..50}; do
      if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        cat "$TEST_DIR/server.log" >&2
        exit 1
      fi
      if curl --silent --fail --max-time 1 "http://127.0.0.1:$CAPGO_MAESTRO_PORT/health" >/dev/null; then
        ready=1
        break
      fi
      sleep 0.1
    done
    if [[ "$ready" != 1 ]]; then
      cat "$TEST_DIR/server.log" >&2
      exit 1
    fi
    # Waiting for this PID must wait for the actual server, not a shell wrapper.
    kill "$SERVER_PID"
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
    python3 - <<'PY'
import os
import socket
with socket.socket() as listener:
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('0.0.0.0', int(os.environ['CAPGO_MAESTRO_PORT'])))
PY
    echo "Server lifecycle passed: prefer_bun=$preference, run=$attempt, port released."
  done
done
