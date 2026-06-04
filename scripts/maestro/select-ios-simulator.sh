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

preferred_device_types=(
  'com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation'
  'com.apple.CoreSimulator.SimDeviceType.iPhone-SE--2nd-generation-'
  'com.apple.CoreSimulator.SimDeviceType.iPhone-16e'
  'com.apple.CoreSimulator.SimDeviceType.iPhone-15'
  'com.apple.CoreSimulator.SimDeviceType.iPhone-14'
  'com.apple.CoreSimulator.SimDeviceType.iPhone-17e'
  'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
  'com.apple.CoreSimulator.SimDeviceType.iPhone-16'
  'com.apple.CoreSimulator.SimDeviceType.iPhone-13'
  'com.apple.CoreSimulator.SimDeviceType.iPhone-12'
)

available_devices="$(xcrun simctl list devices available)"
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

device_type_exists() {
  local device_type="$1"

  xcrun simctl list devicetypes | grep -Fq "($device_type)"
}

create_lightweight_device() {
  local runtime_id=""
  local device_type=""
  local simulator_id=""

  runtime_id="$(latest_ios_runtime)"
  if [[ -z "$runtime_id" ]]; then
    return 1
  fi

  for device_type in "${preferred_device_types[@]}"; do
    if device_type_exists "$device_type"; then
      if simulator_id="$(xcrun simctl create "Capgo Maestro iPhone" "$device_type" "$runtime_id" 2>/dev/null)"; then
        printf '%s\n' "$simulator_id"
        return 0
      fi
    fi
  done

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
  if [[ -n "$simulator_id" ]]; then
    printf '%s\n' "$simulator_id"
    exit 0
  fi
fi

simulator_id="$(find_first_iphone)"
if [[ -n "$simulator_id" ]]; then
  printf '%s\n' "$simulator_id"
  exit 0
fi

echo "No available iPhone simulator found." >&2
exit 1
