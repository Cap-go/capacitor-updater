#!/usr/bin/env bash
# Live-update benchmark on the iOS simulator.
#   scripts/bench/run-ios.sh <label> <plugin-checkout-dir> [options]   (see lib.sh for options)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
bench_caffeinate "$@"
bench_parse_args "$@"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
UDID="${BENCH_IOS_UDID:-$(xcrun simctl list devices available | awk -F '[()]' '/iPhone 17 Pro \(/ { print $2; exit }')}"
[[ -n "$UDID" ]] || { echo "[bench] no iPhone 17 Pro simulator: set BENCH_IOS_UDID" >&2; exit 1; }
APP_ID="app.capgo.updater"
DERIVED="$BENCH_DIR/derived/$LABEL-ios"

bench_prepare_fixtures

app_path() { echo "$BENCH_DIR/apps/$LABEL-ios-$1.app"; }

if [[ "$SKIP_BUILD" != "1" ]]; then
  bench_build_core ios
  first=1
  for variant in "${VARIANT_LIST[@]}"; do
    prep_args=(--label "$LABEL" --checkout "$CHECKOUT" --platform ios --variant "$variant")
    [[ "$first" == "0" ]] && prep_args+=(--no-install)
    (cd "$BENCH_ROOT" && bun scripts/bench/prepare-app.mjs "${prep_args[@]}") >"$BENCH_LOG_DIR/prepare-$LABEL-ios-$variant.log" 2>&1 || {
      echo "[bench] prepare failed, see $BENCH_LOG_DIR/prepare-$LABEL-ios-$variant.log" >&2
      exit 1
    }
    first=0
    echo "[bench] xcodebuild $LABEL ($variant)"
    xcodebuild -project "$BENCH_DIR/apps/$LABEL/ios/App/App.xcodeproj" -scheme App -configuration Release \
      -destination "id=$UDID" -derivedDataPath "$DERIVED" build >"$BENCH_LOG_DIR/build-$LABEL-ios-$variant.log" 2>&1 || {
      echo "[bench] xcodebuild failed, see $BENCH_LOG_DIR/build-$LABEL-ios-$variant.log" >&2
      exit 1
    }
    rm -rf "$(app_path "$variant")"
    cp -R "$DERIVED/Build/Products/Release-iphonesimulator/App.app" "$(app_path "$variant")"
  done
fi

bench_acquire_lock
BOOTED_BY_BENCH=0
if ! xcrun simctl list devices | grep "$UDID" | grep -q Booted; then
  xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
  BOOTED_BY_BENCH=1
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null
bench_platform_cleanup() {
  xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1 || true
  if [[ "$BOOTED_BY_BENCH" == "1" ]]; then xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true; fi
}

restart_app() {
  xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1 || true
  sleep 1
  xcrun simctl launch "$UDID" "$APP_ID" >/dev/null 2>&1 || true
}

for variant in "${VARIANT_LIST[@]}"; do
  echo "[bench] === $LABEL ios $variant ==="
  xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$UDID" "$APP_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$(app_path "$variant")"
  clean_cmd="D=\$(xcrun simctl get_app_container $UDID $APP_ID data) && rm -rf \"\$D/Library/Caches/capgo_downloads\""
  bench_start_server ios "$variant" "$clean_cmd"
  xcrun simctl launch "$UDID" "$APP_ID" >/dev/null
  bench_monitor restart_app
  bench_stop_server
  xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1 || true
done

echo "[bench] results: $BENCH_DIR/results-$LABEL-ios.jsonl"
