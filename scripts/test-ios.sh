#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Always rebuild the Rust core so tests never run against a stale xcframework.
"$ROOT_DIR/scripts/build-core.sh" ios

SIMULATOR_ID=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/{print $2; exit}')

if [[ -z "${SIMULATOR_ID:-}" ]]; then
  echo "No available iPhone simulator found. Please install one via Xcode." >&2
  exit 1
fi

# After the last test, xcodebuild normally exits within seconds. If the test process lingers,
# print its stacks (to find what keeps it alive) and stop it instead of burning the CI job cap.
TEARDOWN_LIMIT_SECONDS="${CAPGO_IOS_TEST_TEARDOWN_LIMIT_SECONDS:-45}"
LOG_FILE="$(mktemp -t capgo-ios-test)"
trap 'kill "${TAIL_PID:-}" 2>/dev/null || true; rm -f "$LOG_FILE"' EXIT

xcodebuild test -scheme CapgoCapacitorUpdater -destination "id=${SIMULATOR_ID}" "$@" > "$LOG_FILE" 2>&1 &
XCODEBUILD_PID=$!
tail -n +1 -f "$LOG_FILE" &
TAIL_PID=$!

finished_at=""
while kill -0 "$XCODEBUILD_PID" 2>/dev/null; do
  if [[ -z "$finished_at" ]] && grep -q "^Test Suite 'All tests' \(passed\|failed\)" "$LOG_FILE"; then
    finished_at=$SECONDS
  fi
  if [[ -n "$finished_at" ]] && (( SECONDS - finished_at > TEARDOWN_LIMIT_SECONDS )); then
    echo "::warning::iOS tests finished but xcodebuild did not exit within ${TEARDOWN_LIMIT_SECONDS}s; test process stacks:"
    for pid in $(pgrep -f "xctest" || true); do
      echo "---- sample of $pid ($(ps -o comm= -p "$pid" 2>/dev/null || true))"
      sample "$pid" 3 2>/dev/null | sed -n '/Call graph:/,/Total number in stack/p' | head -400 || true
    done
    pkill -P "$XCODEBUILD_PID" 2>/dev/null || true
    kill "$XCODEBUILD_PID" 2>/dev/null || true
    break
  fi
  sleep 2
done
wait "$XCODEBUILD_PID" 2>/dev/null || true
sleep 1
kill "$TAIL_PID" 2>/dev/null || true

if grep -q "^Test Suite 'All tests' passed" "$LOG_FILE" && grep -q "with 0 failures" "$LOG_FILE"; then
  exit 0
fi
echo "iOS tests failed" >&2
exit 1
