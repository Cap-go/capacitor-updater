#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SIMULATOR_ID=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/{print $2; exit}')

if [[ -z "${SIMULATOR_ID:-}" ]]; then
  echo "No available iPhone simulator found. Please install one via Xcode." >&2
  exit 1
fi

# CAPGO_IOS_TEST_ACTION lets CI split the work: build-for-testing once, then
# test-without-building per shard. Defaults to a plain "test" for local runs.
ACTION="${CAPGO_IOS_TEST_ACTION:-test}"
case "$ACTION" in
  test | build-for-testing | test-without-building) ;;
  *)
    echo "Unsupported CAPGO_IOS_TEST_ACTION: $ACTION" >&2
    exit 1
    ;;
esac

# A shared build artifact can run directly without resolving the package or compiling on each shard.
BUILD_SELECTION=(-scheme CapgoCapacitorUpdater)
if [[ -n "${CAPGO_IOS_XCTESTRUN:-}" ]]; then
  if [[ "$ACTION" != "test-without-building" ]]; then
    echo "CAPGO_IOS_XCTESTRUN requires CAPGO_IOS_TEST_ACTION=test-without-building" >&2
    exit 1
  fi
  if [[ ! -f "$CAPGO_IOS_XCTESTRUN" ]]; then
    echo "iOS test configuration not found: $CAPGO_IOS_XCTESTRUN" >&2
    exit 1
  fi
  BUILD_SELECTION=(-xctestrun "$CAPGO_IOS_XCTESTRUN")
fi

EXTRA_ARGS=()
# A stable DerivedData path lets CI cache the compiled test bundle between runs.
if [[ -n "${CAPGO_IOS_DERIVED_DATA:-}" ]]; then
  EXTRA_ARGS+=(-derivedDataPath "$CAPGO_IOS_DERIVED_DATA")
fi
# Post-test diagnostics collection only adds idle time in CI, so skip it.
if [[ "$ACTION" != "build-for-testing" && -n "${CI:-}" ]]; then
  EXTRA_ARGS+=(-collect-test-diagnostics never)
fi

# Parallel testing clones the simulator once per worker, and on 3-core CI
# runners the clone and boot cost (about 70s) outweighs the test time it saves.
if [[ "$ACTION" != "build-for-testing" && -n "${CI:-}" ]]; then
  EXTRA_ARGS+=(-parallel-testing-enabled NO)
fi

# InstallPerfTests is a timing benchmark (about 80s on CI runners), not a
# correctness gate, and it pushes the native test shard past its 5 minute cap.
# CI skips it by default; set CAPGO_IOS_RUN_PERF=1 to run it anyway.
if [[ "$ACTION" != "build-for-testing" && -n "${CI:-}" && "${CAPGO_IOS_RUN_PERF:-0}" != "1" ]]; then
  EXTRA_ARGS+=(-skip-testing:CapacitorUpdaterPluginTests/InstallPerfTests)
fi

xcodebuild "$ACTION" \
  "${BUILD_SELECTION[@]}" \
  -destination "id=${SIMULATOR_ID}" \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  "$@"
