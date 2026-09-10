#!/usr/bin/env bash
# Caps cumulative retry sleep. Callers may pass a shared counter file so multiple
# ladders in one job share a single budget (see maestro_android_example_app).
set -euo pipefail

delay_seconds="${1:?delay seconds required}"
max_total_seconds="${2:?max total seconds required}"
counter_file="${RUNNER_TEMP}/artifact-ladder-sleep-total"
if [[ -n "${3:-}" ]]; then
  counter_file="$3"
fi

current_total=0
if [[ -f "$counter_file" ]]; then
  current_total="$(cat "$counter_file")"
fi

remaining=$((max_total_seconds - current_total))
if [[ "$remaining" -le 0 ]]; then
  echo "Artifact ladder retry delay budget exhausted (${current_total}s / ${max_total_seconds}s)."
  exit 0
fi

sleep_seconds="$delay_seconds"
if [[ "$sleep_seconds" -gt "$remaining" ]]; then
  sleep_seconds="$remaining"
fi

echo "Sleeping ${sleep_seconds}s before artifact download retry (${current_total}s / ${max_total_seconds}s used)."
sleep "$sleep_seconds"
echo "$((current_total + sleep_seconds))" >"$counter_file"
