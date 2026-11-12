#!/usr/bin/env bash

set -euo pipefail

NODE_VERSION="${NODE_VERSION:-26.11.0}"
MIN_MAJOR=22
NODE_HOME="$HOME/.capgo-node"
NODE_BIN="$NODE_HOME/bin/node"
PLATFORM="$(uname -s)"
ARCH="$(uname -m)"

node_major_ok() {
  local node_cmd="$1"
  "$node_cmd" -e "process.exit(Number(process.versions.node.split('.')[0]) >= ${MIN_MAJOR} ? 0 : 1)"
}

export_path() {
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "$NODE_HOME/bin" >> "$GITHUB_PATH"
  fi
  export PATH="$NODE_HOME/bin:$PATH"
}

if [[ -x "$NODE_BIN" ]] && node_major_ok "$NODE_BIN"; then
  export_path
  "$NODE_BIN" --version
  exit 0
fi

if command -v node >/dev/null 2>&1 && node_major_ok node; then
  node --version
  exit 0
fi

case "${PLATFORM}-${ARCH}" in
  Darwin-arm64)
    NODE_ARCHIVE="node-v${NODE_VERSION}-darwin-arm64.tar.gz"
    ;;
  Darwin-x86_64)
    NODE_ARCHIVE="node-v${NODE_VERSION}-darwin-x64.tar.gz"
    ;;
  Linux-x86_64)
    NODE_ARCHIVE="node-v${NODE_VERSION}-linux-x64.tar.gz"
    ;;
  Linux-aarch64 | Linux-arm64)
    NODE_ARCHIVE="node-v${NODE_VERSION}-linux-arm64.tar.gz"
    ;;
  *)
    echo "Unsupported Node platform: ${PLATFORM}-${ARCH}" >&2
    exit 1
    ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BASE_URL="https://nodejs.org/dist/v${NODE_VERSION}"
curl --retry 5 --retry-all-errors --retry-delay 5 -fsSL \
  -o "$TMP_DIR/node.tar.gz" \
  "${BASE_URL}/${NODE_ARCHIVE}"

tar -xzf "$TMP_DIR/node.tar.gz" -C "$TMP_DIR"
EXTRACTED_DIR="$(find "$TMP_DIR" -maxdepth 1 -type d -name 'node-v*' | head -n 1)"
if [[ -z "$EXTRACTED_DIR" ]]; then
  echo "Unable to locate Node.js after extracting ${NODE_VERSION}" >&2
  exit 1
fi

rm -rf "$NODE_HOME"
mkdir -p "$NODE_HOME"
cp -R "$EXTRACTED_DIR/." "$NODE_HOME/"
chmod 0755 "$NODE_BIN"
export_path
"$NODE_BIN" --version
