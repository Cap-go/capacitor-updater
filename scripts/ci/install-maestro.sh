#!/usr/bin/env bash

set -euo pipefail

MAESTRO_VERSION="${MAESTRO_VERSION:-cli-2.4.0}"
BASE_URL="https://github.com/mobile-dev-inc/Maestro/releases/download/${MAESTRO_VERSION}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

download_maestro_asset() {
  local asset_name="$1"
  local output_path="$2"

  if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
    if gh release download "$MAESTRO_VERSION" --repo mobile-dev-inc/Maestro --pattern "$asset_name" --dir "$TMP_DIR" --clobber; then
      mv "$TMP_DIR/$asset_name" "$output_path"
      return 0
    fi

    echo "Authenticated Maestro release download failed for ${asset_name}; falling back to direct curl." >&2
  fi

  curl --retry 5 --retry-all-errors --retry-delay 5 -fsSL \
    -o "$output_path" \
    "${BASE_URL}/${asset_name}"
}

download_maestro_asset maestro.zip "$TMP_DIR/maestro.zip"
download_maestro_asset checksums_sha256.txt "$TMP_DIR/checksums_sha256.txt"

(
  cd "$TMP_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    grep ' maestro.zip$' checksums_sha256.txt | sha256sum -c -
  else
    grep ' maestro.zip$' checksums_sha256.txt | shasum -a 256 -c -
  fi
)

unzip -q "$TMP_DIR/maestro.zip" -d "$TMP_DIR/maestro"
INSTALL_PATH="$(find "$TMP_DIR/maestro" -type f -name maestro | head -n 1)"
if [[ -z "$INSTALL_PATH" ]]; then
  echo "Unable to locate Maestro binary after extracting ${MAESTRO_VERSION}" >&2
  exit 1
fi

INSTALL_ROOT="$(dirname "$(dirname "$INSTALL_PATH")")"
rm -rf "$HOME/.maestro"
mkdir -p "$HOME/.maestro"
cp -R "$INSTALL_ROOT"/. "$HOME/.maestro/"

if [[ ! -f "$HOME/.maestro/bin/maestro" || ! -d "$HOME/.maestro/lib" ]]; then
  echo "Incomplete Maestro installation for ${MAESTRO_VERSION}" >&2
  exit 1
fi

chmod 0755 "$HOME/.maestro/bin/maestro"
echo "$HOME/.maestro/bin" >> "$GITHUB_PATH"
