#!/usr/bin/env bash
# Fails on unbounded C string calls in the C core (core-c/src, core-c/fuzz): strcpy, strcat,
# sprintf, vsprintf, gets, strncpy (no terminator on truncation), strncat, stpcpy. Use
# cg_strdup / cg_fmt / cg_buf (rt/str.h) or snprintf; memcpy with a checked length is fine.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if grep -rnE '\b(strcpy|strcat|sprintf|vsprintf|gets|strncpy|strncat|stpcpy)[[:space:]]*\(' \
  "$ROOT_DIR/core-c/src" "$ROOT_DIR/core-c/fuzz"; then
  echo "Unbounded string calls found in the C core (see above)." >&2
  exit 1
fi
echo "No unbounded string calls in the C core."
