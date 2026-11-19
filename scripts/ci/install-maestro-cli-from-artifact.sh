#!/usr/bin/env bash
set -euo pipefail

artifact_archive="${1:-}"
if [[ -z "$artifact_archive" || ! -f "$artifact_archive" ]]; then
  echo "Usage: install-maestro-cli-from-artifact.sh <path-to-maestro-cli.tgz>" >&2
  exit 1
fi

rm -rf "$HOME/.maestro"
mkdir -p "$HOME"
tar -xzf "$artifact_archive" -C "$HOME"

if [[ ! -x "$HOME/.maestro/bin/maestro" ]]; then
  echo "Maestro CLI missing after extracting ${artifact_archive}" >&2
  exit 1
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$HOME/.maestro/bin" >>"$GITHUB_PATH"
fi

export PATH="$HOME/.maestro/bin:$PATH"
maestro --version
