#!/bin/bash
# Cargo target runner for the C core's sanitizer jobs on macOS: preloads the sanitizer runtime
# (CAPGO_SANITIZER_RUNTIME, e.g. `clang -print-file-name=libclang_rt.asan_osx_dynamic.dylib`)
# into each test binary, which loads the instrumented C library with dlopen (CAPGO_CORE_LIB).
# Exported here because System Integrity Protection drops DYLD_* variables when a protected
# binary (/bin/sh, /usr/bin/env) starts.
#
#   cargo test --config 'target."cfg(all())".runner="../scripts/ci/sanitizer-runner.sh"'
export DYLD_INSERT_LIBRARIES="${CAPGO_SANITIZER_RUNTIME:?set CAPGO_SANITIZER_RUNTIME}"
exec "$@"
