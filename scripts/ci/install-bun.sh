#!/usr/bin/env bash

set -euo pipefail

BUN_VERSION="${BUN_VERSION:-1.3.12}"
NORMALIZED_VERSION="${BUN_VERSION#bun-v}"
PLATFORM="$(uname -s)"
ARCH="$(uname -m)"

case "${PLATFORM}-${ARCH}" in
  Linux-x86_64)
    BUN_ARCHIVE="bun-linux-x64.zip"
    ;;
  Linux-aarch64 | Linux-arm64)
    BUN_ARCHIVE="bun-linux-aarch64.zip"
    ;;
  Darwin-arm64)
    BUN_ARCHIVE="bun-darwin-aarch64.zip"
    ;;
  Darwin-x86_64)
    BUN_ARCHIVE="bun-darwin-x64.zip"
    ;;
  *)
    echo "Unsupported Bun platform: ${PLATFORM}-${ARCH}" >&2
    exit 1
    ;;
esac

BASE_URL="https://github.com/oven-sh/bun/releases/download/bun-v${NORMALIZED_VERSION}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl --retry 5 --retry-all-errors --retry-delay 5 -fsSL \
  -o "$TMP_DIR/bun.zip" \
  "${BASE_URL}/${BUN_ARCHIVE}"
unzip -q "$TMP_DIR/bun.zip" -d "$TMP_DIR/bun"

INSTALL_PATH="$(find "$TMP_DIR/bun" -type f -name bun | head -n 1)"
if [[ -z "$INSTALL_PATH" ]]; then
  echo "Unable to locate Bun binary after extracting ${NORMALIZED_VERSION}" >&2
  exit 1
fi

rm -rf "$HOME/.bun"
mkdir -p "$HOME/.bun/bin"
cp "$INSTALL_PATH" "$HOME/.bun/bin/bun"
chmod 0755 "$HOME/.bun/bin/bun"
echo "$HOME/.bun/bin" >> "$GITHUB_PATH"
"$HOME/.bun/bin/bun" --revision
