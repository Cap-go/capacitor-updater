#!/usr/bin/env bash

# Source this helper so SERVER_PID belongs to the runner that will kill and wait for it.
start_fake_capgo_server() {
  local log_file="$1"

  if command -v bun >/dev/null 2>&1 && [[ "${CAPGO_MAESTRO_PREFER_BUN_JS:-0}" == "1" ]]; then
    bun "$ROOT_DIR/scripts/maestro/fake-capgo-server.mjs" >"$log_file" 2>&1 &
  else
    node "$ROOT_DIR/scripts/maestro/fake-capgo-server.mjs" >"$log_file" 2>&1 &
  fi
  SERVER_PID=$!
}
