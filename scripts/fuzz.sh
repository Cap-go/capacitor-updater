#!/usr/bin/env bash
# libFuzzer targets of both updater cores: the same targets, the same input formats and the
# same seed corpus (fuzz/corpus/<target>, regenerate with scripts/generate-fuzz-corpus.mjs).
#
#   scripts/fuzz.sh list                          -> the target names
#   scripts/fuzz.sh build rust|c|all              -> core/fuzz (cargo-fuzz, nightly, ASan, release + overflow checks)
#                                                    core-c/build-fuzz (clang, ASan + UBSan)
#   scripts/fuzz.sh run rust|c <target> <seconds> [libFuzzer flags...]
#   scripts/fuzz.sh smoke rust|c <seconds> [targets...] -> each target (default: all) for <seconds> (CI)
#
# New inputs go to fuzz/work/<core>/<target> and crashes to fuzz/artifacts/<core>/<target>
# (both git-ignored); the committed seeds are only read. A crash, leak, sanitizer report or
# timeout exits non-zero.
#
# Rust needs rustup with a nightly toolchain (CAPGO_FUZZ_TOOLCHAIN, default nightly) and
# cargo-fuzz. CAPGO_FUZZ_RUST_PROFILE=dev builds unoptimized (much faster to build: the CI
# smoke run), still without debug assertions and with overflow checks. C needs a clang with libFuzzer (CAPGO_FUZZ_CC; on macOS Homebrew's llvm, since
# Apple clang ships without it).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS_DIR="$ROOT_DIR/fuzz/corpus"
TOOLCHAIN="${CAPGO_FUZZ_TOOLCHAIN:-nightly}"
RUST_PROFILE="${CAPGO_FUZZ_RUST_PROFILE:-release}"
C_BUILD_DIR="$ROOT_DIR/core-c/build-fuzz"

if [[ -d "$HOME/.cargo/bin" ]]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

targets() {
  ls -1 "$CORPUS_DIR"
}

fuzz_cc() {
  if [[ -n "${CAPGO_FUZZ_CC:-}" ]]; then
    echo "$CAPGO_FUZZ_CC"
  elif [[ "$(uname)" == "Darwin" && -x /opt/homebrew/opt/llvm/bin/clang ]]; then
    echo /opt/homebrew/opt/llvm/bin/clang
  else
    echo clang
  fi
}

rust_target_dir() {
  local triple
  triple="$(rustc +"$TOOLCHAIN" -vV | sed -n 's/^host: //p')"
  if [[ "$RUST_PROFILE" == "dev" ]]; then
    echo "$ROOT_DIR/core/fuzz/target/$triple/debug"
  else
    echo "$ROOT_DIR/core/fuzz/target/$triple/release"
  fi
}

# Release code as it ships (overflow checks on, debug assertions off: dependencies keep
# debug_assert!s that are not checks of untrusted input).
build_rust() {
  if [[ "$RUST_PROFILE" == "dev" ]]; then
    (cd "$ROOT_DIR/core/fuzz" &&
      RUSTFLAGS="${RUSTFLAGS:-} -C overflow-checks=on -C debug-assertions=off" cargo +"$TOOLCHAIN" fuzz build --dev)
  else
    (cd "$ROOT_DIR/core/fuzz" && RUSTFLAGS="${RUSTFLAGS:-} -C overflow-checks=on" cargo +"$TOOLCHAIN" fuzz build -O)
  fi
}

build_c() {
  CC="$(fuzz_cc)" cmake -S "$ROOT_DIR/core-c" -B "$C_BUILD_DIR" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCAPGO_FUZZ=ON -DCAPGO_SHARED=OFF -DCAPGO_TEST_SUPPORT=ON >/dev/null
  cmake --build "$C_BUILD_DIR" -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" >/dev/null
}

binary() {
  local core="$1" target="$2"
  case "$core" in
    rust) echo "$(rust_target_dir)/$target" ;;
    c) echo "$C_BUILD_DIR/fuzz_$target" ;;
    *)
      echo "core must be rust or c, got: $core" >&2
      exit 2
      ;;
  esac
}

run() {
  local core="$1" target="$2" seconds="$3"
  shift 3
  local bin work artifacts
  bin="$(binary "$core" "$target")"
  work="$ROOT_DIR/fuzz/work/$core/$target"
  artifacts="$ROOT_DIR/fuzz/artifacts/$core/$target"
  mkdir -p "$work" "$artifacts"
  # LeakSanitizer in Rust's macOS ASan runtime deadlocks at exit (seen with nightly 1.9x):
  # Rust leaks are checked on Linux (CI) only.
  local leaks=1
  if [[ "$core" == "rust" && "$(uname)" == "Darwin" ]]; then
    leaks=0
  fi
  # Network targets talk to their own loopback server: never through a proxy from the environment.
  env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy \
    ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=$leaks:abort_on_error=1}" \
    UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}" \
    LSAN_OPTIONS="${LSAN_OPTIONS:-suppressions=$ROOT_DIR/fuzz/lsan.supp:print_suppressions=0}" \
    "$bin" "$work" "$CORPUS_DIR/$target" \
    -max_total_time="$seconds" -timeout=25 -rss_limit_mb=4096 -max_len=65536 \
    -artifact_prefix="$artifacts/" -print_final_stats=1 "$@"
}

case "${1:-}" in
  list) targets ;;
  build)
    case "${2:-all}" in
      rust) build_rust ;;
      c) build_c ;;
      all)
        build_rust
        build_c
        ;;
      *)
        echo "Usage: $0 build rust|c|all" >&2
        exit 2
        ;;
    esac
    ;;
  run)
    if [[ $# -lt 4 ]]; then
      echo "Usage: $0 run rust|c <target> <seconds> [libFuzzer flags...]" >&2
      exit 2
    fi
    shift
    run "$@"
    ;;
  smoke)
    if [[ $# -lt 3 ]]; then
      echo "Usage: $0 smoke rust|c <seconds> [targets...]" >&2
      exit 2
    fi
    core="$2"
    seconds="$3"
    shift 3
    selected="${*:-$(targets)}"
    failed=0
    for target in $selected; do
      echo "::group::$core $target"
      if ! run "$core" "$target" "$seconds" 2>&1 | tail -n 40; then
        failed=1
      fi
      echo "::endgroup::"
      if [[ $failed -ne 0 ]]; then
        echo "Fuzz target $target ($core core) failed: see fuzz/artifacts/$core/$target" >&2
        exit 1
      fi
    done
    ;;
  *)
    sed -n '2,21p' "$0" >&2
    exit 2
    ;;
esac
