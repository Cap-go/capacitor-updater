#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${ANDROID_HOME:-}" ]]; then
  echo "ANDROID_HOME is not set; skipping Android SDK temp cleanup." >&2
  exit 0
fi

rm -rf "${ANDROID_HOME}/.temp" 2>/dev/null || true
echo "Cleared Android SDK temp cache under ${ANDROID_HOME}/.temp."
