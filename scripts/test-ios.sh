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

# After the last test, xcodebuild normally exits within seconds. On CI it sometimes hangs in
# its own tooling afterwards: stop it instead of burning the job cap (the summary decides).
TEARDOWN_LIMIT_SECONDS="${CAPGO_IOS_TEST_TEARDOWN_LIMIT_SECONDS:-20}"
LOG_FILE="$(mktemp -t capgo-ios-test)"
START_MARKER="$(mktemp -t capgo-ios-test-start)"
trap 'kill "${TAIL_PID:-}" 2>/dev/null || true; rm -f "$LOG_FILE" "$START_MARKER"' EXIT

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
    echo "::warning::iOS tests finished but xcodebuild did not exit within ${TEARDOWN_LIMIT_SECONDS}s; stopping it (the test summary decides the result)."
    ps -axo pid,ppid,etime,command | grep -iE "xctest|xcodebuild|testmanagerd" | grep -v grep || true
    # A test process that crashed while exiting leaves a report.
    for report in $(find "$HOME/Library/Logs/DiagnosticReports" -name 'xctest*' -newer "$START_MARKER" 2>/dev/null | head -3); do
      echo "---- crash report $report"
      head -c 12000 "$report"
      echo
    done
    # Seen on CI: xcodebuild waiting on a hung `xcodebuild -version -sdk` child after the tests.
    # Capture the children first: once xcodebuild exits they are reparented and -P misses them.
    children="$(pgrep -P "$XCODEBUILD_PID" || true)"
    kill -TERM "$XCODEBUILD_PID" $children 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$XCODEBUILD_PID" 2>/dev/null || break
      sleep 2
    done
    kill -KILL "$XCODEBUILD_PID" $children 2>/dev/null || true
    stopped_by_watchdog=1
    break
  fi
  sleep 2
done
status=0
wait "$XCODEBUILD_PID" 2>/dev/null || status=$?
sleep 1
kill "$TAIL_PID" 2>/dev/null || true

# xcodebuild's own status decides, unless the watchdog stopped it after the tests finished.
if [[ -z "${stopped_by_watchdog:-}" ]]; then
  exit "$status"
fi
if grep -q "^Test Suite 'All tests' passed" "$LOG_FILE" && grep -q "with 0 failures" "$LOG_FILE"; then
  exit 0
fi
echo "iOS tests failed" >&2
exit 1
