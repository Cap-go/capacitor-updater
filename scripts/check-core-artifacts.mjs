#!/usr/bin/env node
/**
 * Fails when the prebuilt Rust core (scripts/build-core.sh) is missing from the
 * package. Run before every publish: without these files the plugin cannot load
 * on Android (UnsatisfiedLinkError) and does not compile on iOS.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const required = [
  ...['arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64'].map(
    (abi) => `android/src/main/jniLibs/${abi}/libcapgo_updater_core.so`,
  ),
  'ios/Frameworks/CapgoUpdaterCore.xcframework/Info.plist',
  ...['ios-arm64', 'ios-arm64_x86_64-simulator'].flatMap((slice) =>
    ['CapgoUpdaterCore', 'Headers/capgo_updater_core.h', 'Modules/module.modulemap'].map(
      (file) => `ios/Frameworks/CapgoUpdaterCore.xcframework/${slice}/CapgoUpdaterCore.framework/${file}`,
    ),
  ),
];

const missing = required.filter((file) => {
  const stat = fs.statSync(path.join(root, file), { throwIfNoEntry: false });
  return !stat?.isFile() || stat.size === 0;
});

if (missing.length > 0) {
  console.error('Missing Rust core artifacts (run `bun run core:build`):');
  for (const file of missing) {
    console.error(`  - ${file}`);
  }
  process.exit(1);
}
console.log('Rust core artifacts present.');
