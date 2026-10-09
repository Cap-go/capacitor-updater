# Porting the Rust core to C: conventions

`core-c/` is a C11 implementation of `core/include/capgo_updater_core.h`, a
line-by-line port of `core/src/` (Rust). Both libraries must pass the same
tests: `core/tests/` drives a core only through the C ABI, and
`CAPGO_CORE_LIB=<path to the C shared library>` selects this one.

## Rule zero: behave exactly like Rust

- Same operations, JSON shapes, error codes, **error messages, log messages,
  event payloads, hook names and payloads, stored keys and values, files and
  their contents**. Tests compare them. Copy Rust strings verbatim.
- Rust `format!("{x:?}")` of a `&str` prints it quoted with Rust escapes
  (`"a\"b"`); reproduce it where it is used.
- Same ordering of side effects (events, hooks, KV writes, HTTP requests),
  same threading behavior (what blocks, what runs on a worker thread).
- Security boundaries (path guards, checksum / signature / session key checks,
  HTTPS rules) are ported exactly, never relaxed.

## Layout

One C file per Rust file, same path: `core/src/engine/store.rs` ->
`core-c/src/engine/store.c` + `store.h`. Shared runtime in `src/rt/`:

| Header | Use |
| --- | --- |
| `rt/json.h` | `cj` values = `serde_json::Value` (sorted keys, u64/i64/f64 numbers, serde printing) |
| `rt/str.h` | `cg_malloc` (aborts on OOM), `cg_strdup`, `cg_fmt`, `cg_buf`, `cg_strs`, trim / UTF-8 helpers |
| `rt/err.h` | `cg_error {code, message}` = `CoreError`; `cg_err_io(err, context, errno)` = `CoreError::io` |
| `rt/sync.h` | mutex, condvar, `cg_spawn` (detached thread `capgo-<name>`), `cg_now_ms`, `cg_mono_ms`, `cg_event` |
| `host.h` | the `Host` trait: log, kv, emit / emit_retained, hook, proxy, TLS verification, method lane |

## Naming

- Public (cross-file) functions: `cg_<module>_<rust_name>`, e.g.
  `paths::resolve_path_inside` -> `cg_paths_resolve_path_inside`. `impl Engine`
  methods take `cg_engine *engine` first: `Engine::set_bundle` in store.rs ->
  `cg_store_set_bundle(engine, ...)`.
- File-local helpers are `static`.
- Types: `cg_<name>` (`cg_bundle_info`, `cg_engine_config`).

## Ownership

- `const char *` parameters are borrowed. `char *` return values are
  `malloc`'d and owned by the caller (document otherwise).
- `Option<&str>` / `Option<String>` = `NULL`.
- `cj *` stored into another value (`cj_set`, `cj_push`, builders) is moved.
  Getters return borrowed pointers.
- Structs get `cg_<type>_free(ptr)` (frees members and the struct) or
  `cg_<type>_clear(&value)` (members only, for stack values).

## Strings with NUL bytes

JSON strings may contain `\u0000`; the `const char *` view (`cj_as_str`) stops at
it. Wherever Rust validates a string from the input (paths, file names, bundle
ids, URLs), check `cj_str_has_nul()` first and fail the way Rust does (paths.rs:
`invalid_separator`). Never let a truncated string pass a security check.

## Errors

`CoreResult<T>` -> return `bool` (or a pointer, NULL on error) and take a
trailing `cg_error *err` (may be NULL). Set it with `cg_err_set(err, "code",
"fmt", ...)`. Callers that ignore an error pass a local and `cg_err_clear` it.

## Concurrency

- `Mutex<T>` -> a `cg_mutex` next to the data. `AtomicBool`/`AtomicU64` ->
  `<stdatomic.h>`. `Condvar` -> `cg_cond`. Threads -> `cg_spawn`.
- Never hold a lock across a host callback, a network call, a file
  extraction or a call that takes another engine lock unless Rust does exactly
  that (the Rust comments explain the lock orders; keep them).
- Thread-locals (`thread_local!`) -> `_Thread_local`.

## Build and test

```bash
cmake -S core-c -B core-c/build -DCAPGO_TEST_SUPPORT=ON && cmake --build core-c/build -j
cd core && CAPGO_CORE_LIB=$PWD/../core-c/build/libcapgo_updater_core.dylib \
  cargo test --features test-support            # or: --test contract, --test engine_archive, ...
```

`cargo test` without `CAPGO_CORE_LIB` runs the same tests on the Rust core.
Test-only operations (`test.<name>`, Rust `src/testing.rs`) are compiled only
with `CAPGO_TEST_SUPPORT`.

Dependencies (fetched by CMake, pinned): Mbed TLS 3.6 (TLS client, AES,
SHA-256, big numbers), the Brotli decoder, and the platform zlib.
