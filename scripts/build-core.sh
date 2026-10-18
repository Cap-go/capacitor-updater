#!/usr/bin/env bash
# Builds the updater core for the plugin hosts.
#
#   scripts/build-core.sh android   -> android/src/main/jniLibs/<abi>/libcapgo_updater_core.so
#   scripts/build-core.sh ios       -> ios/Frameworks/CapgoUpdaterCore.xcframework
#   scripts/build-core.sh host      -> core/target/host/release (JVM unit tests)
#   scripts/build-core.sh all       -> android + ios (ios skipped when not on macOS)
#
# CAPGO_CORE_IMPL=rust (default) builds the Rust core (core/); CAPGO_CORE_IMPL=c builds the
# C implementation of the same header (core-c/) into the same outputs (host: core-c/build-host).
#
# Requirements: rustup (targets are added automatically), cargo-ndk + Android NDK
# for android, Xcode for ios. The C core needs CMake and the same NDK / Xcode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/core"
C_CORE_DIR="$ROOT_DIR/core-c"
CORE_IMPL="${CAPGO_CORE_IMPL:-rust}"
LIB_NAME="capgo_updater_core"
FRAMEWORK_NAME="CapgoUpdaterCore"
ANDROID_MIN_SDK="${ANDROID_MIN_SDK:-24}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-15.0}"

# Prefer rustup's cargo over a system cargo so cross targets resolve.
if [[ -d "$HOME/.cargo/bin" ]]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

ensure_targets() {
  if command -v rustup >/dev/null 2>&1; then
    rustup target add "$@" >/dev/null
  fi
}

find_ndk() {
  if [[ -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]]; then
    return
  fi
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  if [[ -d "$sdk/ndk" ]]; then
    local latest
    latest="$(ls -1 "$sdk/ndk" | sort -V | tail -1)"
    if [[ -n "$latest" ]]; then
      export ANDROID_NDK_HOME="$sdk/ndk/$latest"
    fi
  fi
  if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    echo "Android NDK not found: set ANDROID_NDK_HOME or install one with sdkmanager \"ndk;<version>\"" >&2
    exit 1
  fi
}

build_android() {
  find_ndk
  if ! command -v cargo-ndk >/dev/null 2>&1; then
    cargo install cargo-ndk --locked
  fi
  ensure_targets aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
  local out="$ROOT_DIR/android/src/main/jniLibs"
  rm -rf "$out"
  (
    cd "$CORE_DIR"
    cargo ndk \
      -t arm64-v8a -t armeabi-v7a -t x86 -t x86_64 \
      --platform "$ANDROID_MIN_SDK" \
      -o "$out" \
      build --release --features jni --locked
  )
  # cargo-ndk keeps the symbol table (~1.3 MB per ABI): strip it.
  local strip_tool
  strip_tool="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-strip 2>/dev/null | head -1)"
  if [[ -n "$strip_tool" ]]; then
    find "$out" -name "lib$LIB_NAME.so" -exec "$strip_tool" --strip-all {} \;
  else
    echo "llvm-strip not found in the NDK; Android libraries are not stripped" >&2
  fi
  echo "Android core libraries written to $out"
}

make_framework() {
  local lib="$1"
  local dest="$2"
  rm -rf "$dest"
  mkdir -p "$dest/Headers" "$dest/Modules"
  cp "$lib" "$dest/$FRAMEWORK_NAME"
  cp "$CORE_DIR/include/capgo_updater_core.h" "$dest/Headers/"
  cat >"$dest/Modules/module.modulemap" <<EOF
framework module $FRAMEWORK_NAME {
  umbrella header "capgo_updater_core.h"
  export *
}
EOF
  cat >"$dest/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$FRAMEWORK_NAME</string>
  <key>CFBundleIdentifier</key><string>app.capgo.$FRAMEWORK_NAME</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$FRAMEWORK_NAME</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$IOS_DEPLOYMENT_TARGET</string>
</dict>
</plist>
EOF
}

build_ios() {
  if [[ "$(uname)" != "Darwin" ]]; then
    echo "Skipping iOS core build: requires macOS" >&2
    return
  fi
  if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]] && ! xcodebuild -version >/dev/null 2>&1; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  # CAPGO_CORE_IOS_SIMULATOR_ONLY=1 builds only the arm64 simulator slice (simulator tests on
  # Apple silicon): the shipped xcframework always has the device and both simulator slices.
  local targets="aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios"
  if [[ "${CAPGO_CORE_IOS_SIMULATOR_ONLY:-}" == "1" ]]; then
    targets="aarch64-apple-ios-sim"
  fi
  # shellcheck disable=SC2086
  ensure_targets $targets
  local target_dir="$CORE_DIR/target"
  (
    cd "$CORE_DIR"
    export IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"
    for target in $targets; do
      cargo build --release --locked --target "$target"
    done
  )

  local work="$target_dir/xcframework"
  rm -rf "$work"
  mkdir -p "$work/ios" "$work/simulator"
  # rustc does not strip static libraries; drop debug info (~20 MB -> ~3 MB per slice).
  for target in $targets; do
    mkdir -p "$work/$target"
    cp "$target_dir/$target/release/lib$LIB_NAME.a" "$work/$target/lib$LIB_NAME.a"
    xcrun strip -S "$work/$target/lib$LIB_NAME.a"
  done

  local out="$ROOT_DIR/ios/Frameworks/$FRAMEWORK_NAME.xcframework"
  rm -rf "$out"
  mkdir -p "$(dirname "$out")"
  if [[ "${CAPGO_CORE_IOS_SIMULATOR_ONLY:-}" == "1" ]]; then
    make_framework "$work/aarch64-apple-ios-sim/lib$LIB_NAME.a" "$work/simulator/$FRAMEWORK_NAME.framework"
    xcodebuild -create-xcframework \
      -framework "$work/simulator/$FRAMEWORK_NAME.framework" \
      -output "$out" >/dev/null
  else
    lipo -create \
      "$work/aarch64-apple-ios-sim/lib$LIB_NAME.a" \
      "$work/x86_64-apple-ios/lib$LIB_NAME.a" \
      -output "$work/simulator/lib$LIB_NAME.a"
    make_framework "$work/aarch64-apple-ios/lib$LIB_NAME.a" "$work/ios/$FRAMEWORK_NAME.framework"
    make_framework "$work/simulator/lib$LIB_NAME.a" "$work/simulator/$FRAMEWORK_NAME.framework"
    xcodebuild -create-xcframework \
      -framework "$work/ios/$FRAMEWORK_NAME.framework" \
      -framework "$work/simulator/$FRAMEWORK_NAME.framework" \
      -output "$out" >/dev/null
  fi
  echo "iOS core xcframework written to $out"
}

build_host() {
  (
    cd "$CORE_DIR"
    cargo build --release --locked --features jni --target-dir target/host
  )
}

# ---------------------------------------------------------------------------- C core (core-c/)

cmake_build() {
  local build_dir="$1"
  shift
  cmake -S "$C_CORE_DIR" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release "$@" >/dev/null
  cmake --build "$build_dir" --config Release -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" >/dev/null
}

build_android_c() {
  find_ndk
  local out="$ROOT_DIR/android/src/main/jniLibs"
  rm -rf "$out"
  local strip_tool
  strip_tool="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-strip 2>/dev/null | head -1)"
  for abi in arm64-v8a armeabi-v7a x86 x86_64; do
    local build_dir="$C_CORE_DIR/build-android-$abi"
    cmake_build "$build_dir" \
      -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$ANDROID_MIN_SDK" \
      -DCAPGO_JNI=ON -DCAPGO_SHARED=ON
    mkdir -p "$out/$abi"
    cp "$build_dir/lib$LIB_NAME.so" "$out/$abi/lib$LIB_NAME.so"
    if [[ -n "$strip_tool" ]]; then
      "$strip_tool" --strip-all "$out/$abi/lib$LIB_NAME.so"
    fi
  done
  echo "Android C core libraries written to $out"
}

build_ios_c() {
  if [[ "$(uname)" != "Darwin" ]]; then
    echo "Skipping iOS core build: requires macOS" >&2
    return
  fi
  if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]] && ! xcodebuild -version >/dev/null 2>&1; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  local slices="ios-arm64 sim-arm64 sim-x86_64"
  if [[ "${CAPGO_CORE_IOS_SIMULATOR_ONLY:-}" == "1" ]]; then
    slices="sim-arm64"
  fi
  local work="$C_CORE_DIR/build-ios"
  for slice in $slices; do
    local sysroot=iphonesimulator arch="${slice#*-}"
    [[ "$slice" == ios-* ]] && sysroot=iphoneos
    cmake_build "$work/$slice" \
      -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES="$arch" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" -DCAPGO_SHARED=OFF
    xcrun strip -S "$work/$slice/lib$LIB_NAME.a" 2>/dev/null || true
  done
  local out="$ROOT_DIR/ios/Frameworks/$FRAMEWORK_NAME.xcframework"
  rm -rf "$out" "$work/ios" "$work/simulator"
  mkdir -p "$(dirname "$out")" "$work/ios" "$work/simulator"
  if [[ "${CAPGO_CORE_IOS_SIMULATOR_ONLY:-}" == "1" ]]; then
    make_framework "$work/sim-arm64/lib$LIB_NAME.a" "$work/simulator/$FRAMEWORK_NAME.framework"
    xcodebuild -create-xcframework -framework "$work/simulator/$FRAMEWORK_NAME.framework" -output "$out" >/dev/null
  else
    lipo -create "$work/sim-arm64/lib$LIB_NAME.a" "$work/sim-x86_64/lib$LIB_NAME.a" -output "$work/simulator/lib$LIB_NAME.a"
    make_framework "$work/ios-arm64/lib$LIB_NAME.a" "$work/ios/$FRAMEWORK_NAME.framework"
    make_framework "$work/simulator/lib$LIB_NAME.a" "$work/simulator/$FRAMEWORK_NAME.framework"
    xcodebuild -create-xcframework \
      -framework "$work/ios/$FRAMEWORK_NAME.framework" \
      -framework "$work/simulator/$FRAMEWORK_NAME.framework" \
      -output "$out" >/dev/null
  fi
  echo "iOS C core xcframework written to $out"
}

build_host_c() {
  cmake_build "$C_CORE_DIR/build-host" -DCAPGO_JNI=ON -DCAPGO_SHARED=ON
}

if [[ "$CORE_IMPL" == "c" ]]; then
  build_android() { build_android_c; }
  build_ios() { build_ios_c; }
  build_host() { build_host_c; }
elif [[ "$CORE_IMPL" != "rust" ]]; then
  echo "CAPGO_CORE_IMPL must be rust or c, got: $CORE_IMPL" >&2
  exit 2
fi

case "${1:-all}" in
  android) build_android ;;
  ios) build_ios ;;
  host) build_host ;;
  all)
    build_android
    build_ios
    ;;
  *)
    echo "Usage: $0 [android|ios|host|all]" >&2
    exit 2
    ;;
esac
