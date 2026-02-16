# AGENTS.md

This file provides guidance to AI agents and contributors working on this Capacitor plugin.

## Quick Start

```bash
# Install dependencies
bun install

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

## Project Structure

- `src/definitions.ts` - TypeScript interfaces and types (source of truth for API docs)
- `src/index.ts` - Plugin registration
- `src/web.ts` - Web implementation
- `ios/Sources/` - iOS native code (Swift)
- `android/src/main/` - Android native code (Java/Kotlin)
- `dist/` - Generated output (do not edit manually)
- `Package.swift` - SwiftPM definition
- `*.podspec` - CocoaPods spec

## iOS Package Management

We always support both **CocoaPods** and **Swift Package Manager (SPM)**. Every plugin must ship a valid `*.podspec` and `Package.swift`. Do not remove or break either integration — users depend on both.

## API Documentation

API docs in the README are auto-generated from JSDoc in `src/definitions.ts`. **Never edit the `<docgen-index>` or `<docgen-api>` sections in README.md directly.** Instead, update `src/definitions.ts` and run `bun run docgen` (also runs as part of `bun run build`).

## Versioning

The plugin major version follows the Capacitor major version (e.g., plugin v8 for Capacitor 8). **We only ship breaking changes when a new Capacitor native major version is released.** All other changes must be backward compatible.

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
