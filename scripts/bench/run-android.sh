#!/usr/bin/env bash
# Live-update benchmark on the Android emulator (release APK signed with the debug key).
#   scripts/bench/run-android.sh <label> <plugin-checkout-dir> [options]   (see lib.sh for options)
# Uses the running emulator, or starts AVD $BENCH_AVD (default capgo_mem_api36) and stops it at the end.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
bench_caffeinate "$@"
bench_parse_args "$@"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="${ADB:-$SDK/platform-tools/adb}"
BUILD_TOOLS="$(ls -1d "$SDK"/build-tools/* | sort -V | tail -1)"
APP_ID="app.capgo.updater"
ACTIVITY="$APP_ID/.MainActivity"

bench_prepare_fixtures

apk_path() { echo "$BENCH_DIR/apps/$LABEL-android-$1.apk"; }

if [[ "$SKIP_BUILD" != "1" ]]; then
  bench_build_core android
  first=1
  for variant in "${VARIANT_LIST[@]}"; do
    prep_args=(--label "$LABEL" --checkout "$CHECKOUT" --platform android --variant "$variant")
    [[ "$first" == "0" ]] && prep_args+=(--no-install)
    (cd "$BENCH_ROOT" && bun scripts/bench/prepare-app.mjs "${prep_args[@]}") >"$BENCH_LOG_DIR/prepare-$LABEL-android-$variant.log" 2>&1 || {
      echo "[bench] prepare failed, see $BENCH_LOG_DIR/prepare-$LABEL-android-$variant.log" >&2
      exit 1
    }
    first=0
    echo "[bench] gradle assembleRelease $LABEL ($variant)"
    (cd "$BENCH_DIR/apps/$LABEL/android" && ./gradlew assembleRelease) >"$BENCH_LOG_DIR/build-$LABEL-android-$variant.log" 2>&1 || {
      echo "[bench] gradle failed, see $BENCH_LOG_DIR/build-$LABEL-android-$variant.log" >&2
      exit 1
    }
    unsigned="$BENCH_DIR/apps/$LABEL/android/app/build/outputs/apk/release/app-release-unsigned.apk"
    aligned="$BENCH_DIR/apps/$LABEL-android-$variant-aligned.apk"
    "$BUILD_TOOLS/zipalign" -f -p 4 "$unsigned" "$aligned"
    "$BUILD_TOOLS/apksigner" sign --ks "$HOME/.android/debug.keystore" --ks-pass pass:android --key-pass pass:android \
      --ks-key-alias androiddebugkey --out "$(apk_path "$variant")" "$aligned"
    rm -f "$aligned"
  done
fi

bench_acquire_lock
STARTED_EMULATOR=0
if ! "$ADB" devices | grep -q "device$"; then
  echo "[bench] starting emulator ${BENCH_AVD:-capgo_mem_api36}"
  nohup "$SDK/emulator/emulator" -avd "${BENCH_AVD:-capgo_mem_api36}" -no-window -no-audio -no-snapshot-save \
    >"$BENCH_LOG_DIR/emulator.log" 2>&1 &
  STARTED_EMULATOR=1
fi
bench_platform_cleanup() {
  "$ADB" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  "$ADB" reverse --remove "tcp:$BENCH_PORT" >/dev/null 2>&1 || true
  if [[ "$STARTED_EMULATOR" == "1" ]]; then
    "$ADB" emu kill >/dev/null 2>&1 || true
    # emu kill returns before the emulator is gone: wait so the next run does not see a dying device.
    for _ in $(seq 1 60); do "$ADB" devices | grep -q "device$" || break; sleep 1; done
  fi
}
booted=0
for _ in $(seq 1 120); do
  if [[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then booted=1; break; fi
  sleep 2
done
if [[ "$booted" != "1" ]]; then
  echo "[bench] emulator did not boot within 240s" >&2
  exit 1
fi
# Root is needed to clear the app's delta cache between cases on a release (non-debuggable) build.
if [[ "$("$ADB" shell whoami | tr -d '\r')" != "root" ]]; then
  "$ADB" root >/dev/null
  sleep 2
  "$ADB" wait-for-device
fi

reverse_port() {
  "$ADB" reverse "tcp:$BENCH_PORT" "tcp:$BENCH_PORT" >/dev/null
}

restart_app() {
  "$ADB" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  reverse_port || true
  sleep 1
  "$ADB" shell am start -n "$ACTIVITY" >/dev/null 2>&1 || true
}

for variant in "${VARIANT_LIST[@]}"; do
  echo "[bench] === $LABEL android $variant ==="
  "$ADB" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  "$ADB" uninstall "$APP_ID" >/dev/null 2>&1 || true
  "$ADB" install -r "$(apk_path "$variant")" >/dev/null
  reverse_port
  bench_start_server android "$variant" "$ADB shell rm -rf /data/data/$APP_ID/cache/capgo_downloads"
  "$ADB" shell am start -n "$ACTIVITY" >/dev/null
  bench_monitor restart_app
  bench_stop_server
  "$ADB" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
done

echo "[bench] results: $BENCH_DIR/results-$LABEL-android.jsonl"
