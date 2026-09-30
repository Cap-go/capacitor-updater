#!/usr/bin/env bash
# Shared helpers for run-ios.sh / run-android.sh. Sourced, not executed.

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BENCH_DIR="${BENCH_DIR:-$BENCH_ROOT/.context/bench}"
BENCH_PORT="${BENCH_PORT:-3193}"
BENCH_LOG_DIR="$BENCH_DIR/logs"
SERVER_PID=""
mkdir -p "$BENCH_LOG_DIR"

bench_usage() {
  cat >&2 <<EOF
usage: $0 <label> <plugin-checkout-dir> [--variants plain,enc] [--only <regex>] [--runs N]
                                        [--skip-build] [--retry-failed] [--no-core]
  label           results label, e.g. before / after
  checkout        plugin checkout to benchmark (its example-app native projects are copied)
  --variants      encryption variants to run (default plain,enc)
  --only          regex filter on case ids (e.g. 'zip-3MB|manifest-2f')
  --runs          runs per cell (default 3)
  --skip-build    reuse the previously built app for this label
  --retry-failed  re-run cases whose final attempt failed
  --no-core       do not run <checkout>/scripts/build-core.sh before building
EOF
  exit 2
}

bench_parse_args() {
  [[ $# -ge 2 ]] || bench_usage
  LABEL="$1"
  CHECKOUT="$(cd "$2" && pwd)"
  shift 2
  VARIANTS="plain,enc"
  ONLY=""
  RUNS="3"
  SKIP_BUILD=0
  RETRY_FAILED=0
  BUILD_CORE=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --variants) VARIANTS="$2"; shift 2 ;;
      --only) ONLY="$2"; shift 2 ;;
      --runs) RUNS="$2"; shift 2 ;;
      --skip-build) SKIP_BUILD=1; shift ;;
      --retry-failed) RETRY_FAILED=1; shift ;;
      --no-core) BUILD_CORE=0; shift ;;
      *) bench_usage ;;
    esac
  done
  IFS=',' read -r -a VARIANT_LIST <<<"$VARIANTS"
}

bench_prepare_fixtures() {
  (cd "$BENCH_ROOT" && bun scripts/bench/gen-fixtures.mjs)
}

bench_build_core() {
  local platform="$1"
  if [[ "$BUILD_CORE" == "1" && -x "$CHECKOUT/scripts/build-core.sh" && -d "$CHECKOUT/core" ]]; then
    echo "[bench] building Rust core ($platform) in $CHECKOUT"
    "$CHECKOUT/scripts/build-core.sh" "$platform" >"$BENCH_LOG_DIR/build-core-$LABEL-$platform.log" 2>&1 || {
      echo "[bench] build-core failed, see $BENCH_LOG_DIR/build-core-$LABEL-$platform.log" >&2
      exit 1
    }
  fi
}

bench_kill_port() {
  local pids
  pids="$(lsof -ti "tcp:$BENCH_PORT" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
}

bench_start_server() {
  local platform="$1" variant="$2" clean_cmd="$3"
  local results="$BENCH_DIR/results-$LABEL-$platform.jsonl"
  local log="$BENCH_LOG_DIR/server-$LABEL-$platform-$variant.log"
  bench_kill_port
  local extra=()
  [[ -n "$ONLY" ]] && extra+=(--only "$ONLY")
  [[ "$RETRY_FAILED" == "1" ]] && extra+=(--retry-failed)
  (cd "$BENCH_ROOT" && exec bun scripts/bench/server.mjs --platform "$platform" --label "$LABEL" --variant "$variant" \
    --results "$results" --runs "$RUNS" --port "$BENCH_PORT" --clean-cmd "$clean_cmd" ${extra[@]+"${extra[@]}"}) >>"$log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$BENCH_PORT/bench/status" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  echo "[bench] server did not start, see $log" >&2
  exit 1
}

bench_stop_server() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

# bench_monitor <restart-function> : poll the server until every case is done,
# restarting the app whenever the server reports a timeout/hang.
bench_monitor() {
  local restart_fn="$1"
  local last=""
  while true; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "[bench] server exited unexpectedly" >&2
      return 1
    fi
    local status
    status="$(curl -sf "http://127.0.0.1:$BENCH_PORT/bench/status" || echo '{}')"
    if [[ "$status" == *'"done":true'* ]]; then
      echo "[bench] all cases done"
      return 0
    fi
    if [[ "$status" == *'"needsRestart":true'* ]]; then
      echo "[bench] restarting app"
      "$restart_fn"
      curl -sf -X POST "http://127.0.0.1:$BENCH_PORT/bench/restarted" >/dev/null || true
    fi
    local cur
    cur="$(printf '%s' "$status" | sed -n 's/.*"remaining":\([0-9]*\).*/\1/p')"
    if [[ "$cur" != "$last" ]]; then
      echo "[bench] remaining: $cur"
      last="$cur"
    fi
    sleep 3
  done
}

trap bench_stop_server EXIT
