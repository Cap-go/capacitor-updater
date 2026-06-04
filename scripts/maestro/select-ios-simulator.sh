#!/usr/bin/env bash

set -euo pipefail

preferred_names=(
  'Capgo Maestro iPhone'
  'iPhone SE (3rd generation)'
  'iPhone SE (2nd generation)'
  'iPhone 16e'
  'iPhone 15'
  'iPhone 14'
  'iPhone 17e'
  'iPhone 17'
  'iPhone 16'
  'iPhone 13'
  'iPhone 12'
)

available_devices="$(xcrun simctl list devices available)"
available_device_types="$(xcrun simctl list devicetypes)"
device_line_regex='^[[:space:]]*(.*)[[:space:]]\(([0-9A-F-]{36})\)[[:space:]]\([^)]*\)[[:space:]]*$'

find_existing_device() {
  local preferred_name="$1"
  local line=""
  local name=""
  local simulator_id=""

  while IFS= read -r line; do
    if [[ "$line" =~ $device_line_regex ]]; then
      name="${BASH_REMATCH[1]}"
      simulator_id="${BASH_REMATCH[2]}"
      if [[ "$name" == "$preferred_name" ]]; then
        printf '%s\n' "$simulator_id"
        return 0
      fi
    fi
  done <<<"$available_devices"
}

find_first_iphone() {
  local line=""
  local name=""
  local simulator_id=""

  while IFS= read -r line; do
    if [[ "$line" =~ $device_line_regex ]]; then
      name="${BASH_REMATCH[1]}"
      simulator_id="${BASH_REMATCH[2]}"
      if [[ "$name" == iPhone* ]]; then
        printf '%s\n' "$simulator_id"
        return 0
      fi
    fi
  done <<<"$available_devices"
}

latest_ios_runtime() {
  xcrun simctl list runtimes available |
    sed -nE 's/^iOS .* - (com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+)$/\1/p' |
    tail -n 1
}

device_type_identifier_for_name() {
  local device_name="$1"
  local line=""
  local name=""
  local identifier=""

  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    identifier="${line##* (}"
    identifier="${identifier%)}"
    name="${line% ($identifier)}"
    if [[ "$name" == "$device_name" && "$identifier" == com.apple.CoreSimulator.SimDeviceType.* ]]; then
      printf '%s\n' "$identifier"
      return 0
    fi
  done <<<"$available_device_types"
}

create_lightweight_device() {
  local runtime_id=""
  local device_name=""
  local device_type=""
  local simulator_id=""
  local create_error_log=""

  runtime_id="$(latest_ios_runtime)"
  if [[ -z "$runtime_id" ]]; then
    return 1
  fi

  create_error_log="$(mktemp "${TMPDIR:-/tmp}/capgo-simctl-create.XXXXXX")"

  for device_name in "${preferred_names[@]:1}"; do
    device_type="$(device_type_identifier_for_name "$device_name")"
    if [[ -n "$device_type" ]] &&
      simulator_id="$(xcrun simctl create "Capgo Maestro iPhone" "$device_type" "$runtime_id" 2>"$create_error_log")" &&
      [[ -n "$simulator_id" ]]; then
      rm -f "$create_error_log"
      printf '%s\n' "$simulator_id"
      return 0
    fi

    if [[ -s "$create_error_log" ]]; then
      cat "$create_error_log" >&2
      : >"$create_error_log"
    fi
  done

  rm -f "$create_error_log"
  return 1
}

for preferred_name in "${preferred_names[@]}"; do
  simulator_id="$(find_existing_device "$preferred_name")"
  if [[ -n "$simulator_id" ]]; then
    printf '%s\n' "$simulator_id"
    exit 0
  fi
done

if simulator_id="$(create_lightweight_device)"; then
  printf '%s\n' "$simulator_id"
  exit 0
fi

simulator_id="$(find_first_iphone)"
if [[ -n "$simulator_id" ]]; then
  printf '%s\n' "$simulator_id"
  exit 0
fi

echo "No available iPhone simulator found." >&2
exit 1
