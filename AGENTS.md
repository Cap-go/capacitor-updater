# AGENTS.md

This file provides guidance to AI agents and contributors working on this Capacitor plugin.

## Quick Start

```bash
# Install dependencies
bun install

# Build the shared Rust core for Android and iOS (needed before native builds)
bun run core:build

# Build the plugin (TypeScript + Rollup + docgen)
bun run build

# Full verification (iOS, Android, Web)
bun run verify

# Format code (ESLint + Prettier + SwiftLint)
bun run fmt

# Lint without fixing
bun run lint
```

## Development Workflow

1. **Install** - `bun install` (never use npm)
2. **Build** - `bun run build` compiles TypeScript, generates docs, and bundles with Rollup
3. **Verify** - `bun run verify` builds for iOS, Android, and Web. Always run this before submitting work
4. **Format** - `bun run fmt` auto-fixes ESLint, Prettier, and SwiftLint issues
5. **Lint** - `bun run lint` checks code quality without modifying files

### Individual Platform Verification

```bash
bun run verify:ios
bun run verify:android
bun run verify:web
```

### Example App

If an `example-app/` directory exists, you can test the plugin locally:

```bash
cd example-app
bun install
bun run start
```

The example app references the plugin via `file:..`. Use `bunx cap sync <platform>` to sync native platforms.

## Rust Core

The whole updater (update cycle, downloads, bundle store, rollback, delays, previews, channels, stats, crypto and path guards) lives in one Rust crate, `core/`, used by both Android (JNI) and iOS (xcframework). The Java/Swift plugins only keep Capacitor glue and platform work (WebView, lifecycle, UI, app store APIs), reached through engine hooks. See `core/README.md`.

- Requires rustup (`rustup` adds cross targets automatically), `cargo-ndk` + an Android NDK for Android, Xcode for iOS.
- `bun run core:test` runs the Rust unit tests and every shared fixture in `native-contract-tests/` (`core/tests/contract.rs`).
- `bun run core:build:android` / `bun run core:build:ios` produce the prebuilt binaries (git-ignored, shipped in the npm package by CI). `scripts/test-ios.sh` rebuilds the xcframework automatically; Android JVM tests build a host library through Gradle.
- Change behavior in `core/` with a Rust test (`core/tests/plugin.rs` for plugin flows; fixture-first via `scripts/generate-core-contract-fixtures.mjs` for pure rules). Rust runs the fixtures; the Android and iOS tests only smoke-test the binding (`CoreBindingTest.java`, `CoreBindingTests.swift`). Do not reimplement engine logic in Swift/Java; call the engine.

## Project Structure

- `src/definitions.ts` - TypeScript interfaces and types (source of truth for API docs)
- `src/index.ts` - Plugin registration
- `src/web.ts` - Web implementation
- `ios/Sources/` - iOS native code (Swift)
- `android/src/main/` - Android native code (Java/Kotlin)
- `core/` - Shared Rust updater core (C ABI + JNI)
- `native-contract-tests/` - Language-neutral fixtures for the core rules, run by `core/tests/contract.rs`
- `dist/` - Generated output (do not edit manually)
- `Package.swift` - SwiftPM definition
- `*.podspec` - CocoaPods spec

## iOS Package Management

We always support both **CocoaPods** and **Swift Package Manager (SPM)**. Every plugin must ship a valid `*.podspec` and `Package.swift`. Do not remove or break either integration — users depend on both.

## API Documentation

API docs in the README are auto-generated from JSDoc in `src/definitions.ts`. **Never edit the `<docgen-index>` or `<docgen-api>` sections in README.md directly.** Instead, update `src/definitions.ts` and run `bun run docgen` (also runs as part of `bun run build`). Document any important default or future-major default candidate in `src/definitions.ts` so the next Capacitor major upgrade can change it deliberately.

## Versioning

The plugin major version must always follow the Capacitor major version (e.g., plugin v8 for Capacitor 8). **Do not introduce breaking changes in `src/definitions.ts` unless explicitly asked or the current definition is broken or unusable.** Breaking changes belong to the matching Capacitor major migration, and all other changes must stay backward compatible.

## Changelog

`CHANGELOG.md` is managed automatically by CI/CD. Do not edit it manually.

## Pull Request Guidelines

We welcome contributions, including AI-generated pull requests. Every PR must include:

### Required Sections

1. **What** - What does this PR change?
2. **Why** - What is the reason for this change?
3. **How** - How did you approach the implementation?
4. **Testing** - What did you test? How did you verify it works?
5. **Not Tested** - What is not yet tested or needs further validation?

### Rules

- **No breaking changes** unless aligned with a new Capacitor major release.
- Run `bun run verify` and `bun run fmt` before opening a PR. CI will catch failures, but catching them locally saves time.
- If you are an AI agent, that is perfectly fine. Just be transparent about it. We care that the code is correct and helpful, not who wrote it.
- We review PRs on a best-effort basis. We may request changes — you are expected to address them for the PR to be merged.
- We use automated code review tools (CodeRabbit, and others). You will need to respond to their feedback and resolve any issues they raise.
- We have automatic releases. Once merged, your change will ship in the next release cycle.

### PR Template

```
## What
- [Brief description of the change]

## Why
- [Motivation for this change]

## How
- [Implementation approach]

## Testing
- [What was tested and how]

## Not Tested
- [What still needs testing, if anything]
```

## Common Pitfalls

- Always rename Swift/Java classes and package IDs when creating a new plugin from a template — leftover names cause registration conflicts.
- We only use Java 21 for Android builds.
- Keep temporary files clean: delete or mark with `deleteOnExit` after use.
- `dist/` is fully regenerated on every build — never edit generated files.
- Use Bun for everything. Do not use npm or npx. Use `bunx` if you need to run a package binary.
- Production and PR beta publishes use `npm stage publish`. Plugin CI only has the org `NPM_TOKEN`.
- Maestro can sometimes fail for timeout, WE ENFORCE ` timeout-minutes: 10` if your test fail for timeout make better test augment the timeout is NEVER allowed

## Timeout Policy

- Keep CI, script, and runtime timeouts at 10 minutes or less. Use `timeout-minutes: 10` or lower in GitHub Actions and cap timeout values at `600000` ms, `600` seconds, or `10m` unless explicitly requested.

## Security (do not regress)

Canonical researcher policy: https://github.com/Cap-go/.github/blob/main/SECURITY.md and https://capgo.app/security/.

- Do **not** put GHSA ids or unpublished advisory/PoC text in public PRs, issues, or changelogs.
- When `publicKey` is set, do not accept manifest updates with empty / missing `sessionKey` as encrypted delivery.
- Manifest `file_name` (and equivalent install paths) must reject `..`, absolute paths, and escapes outside the bundle install root on **both** iOS and Android.
- Bundle `id` values used by `delete` / `set` / `next` must stay constrained to the updater sandbox. No path traversal via id.
- Signature / checksum / encryption gates are security boundaries. Do not weaken them for convenience without an explicit product decision and tests.
- Report plugin security issues via private advisories: https://github.com/Cap-go/capacitor-updater/security/advisories/new
