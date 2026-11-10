#!/usr/bin/env bash

# Maestro may print [Passed] markers before teardown; only the final summary counts.
maestro_cli_reported_pass() {
  local output_file="$1"
  local tail_chunk=""

  if [[ ! -f "$output_file" ]]; then
    return 1
  fi

  tail_chunk="$(tail -n 40 "$output_file")"
  grep -qE '\[Passed\][[:space:]]*$|/[0-9]+ Flow Passed' <<<"$tail_chunk"
}
