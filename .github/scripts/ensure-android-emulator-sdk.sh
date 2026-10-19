#!/usr/bin/env bash
set -euo pipefail

CHANNEL="${1:-0}"
MAX_ATTEMPTS="${2:-3}"
RETRY_DELAY_SECONDS="${3:-15}"

if [[ -z "${ANDROID_HOME:-}" ]]; then
  echo "ANDROID_HOME is not set" >&2
  exit 1
fi

SDKMANAGER="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"
if [[ ! -x "$SDKMANAGER" ]]; then
  SDKMANAGER="$(command -v sdkmanager || true)"
fi
if [[ -z "$SDKMANAGER" || ! -x "$SDKMANAGER" ]]; then
  echo "sdkmanager was not found under ANDROID_HOME or PATH" >&2
  exit 1
fi

yes | "$SDKMANAGER" --licenses >/dev/null || true

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  rm -rf "${ANDROID_HOME}/.temp" 2>/dev/null || true
  if yes | "$SDKMANAGER" --install "emulator" --channel="$CHANNEL" >/dev/null; then
    echo "Android emulator package is installed (attempt ${attempt})."
    exit 0
  fi
  echo "sdkmanager emulator install failed on attempt ${attempt}/${MAX_ATTEMPTS}; retrying after ${RETRY_DELAY_SECONDS}s..." >&2
  sleep "$RETRY_DELAY_SECONDS"
done

echo "sdkmanager could not install the Android emulator package after ${MAX_ATTEMPTS} attempts." >&2
exit 1
