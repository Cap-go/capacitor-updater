#!/usr/bin/env node
/**
 * Capacitor plugin hook: runs on capacitor:copy:after (covers standalone copy and sync, which invokes copy).
 * Writes ota-builtin-hashes.json into the native web public folder for the active platform.
 */
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import {
  BUILTIN_HASHES_FILE_NAME,
  collectWebBundleHashes,
  resolveNativePublicDir,
  writeBuiltinHashesManifest,
} from './builtin-hashes-lib.mjs';

function readExtConfig() {
  const raw = process.env.CAPACITOR_CONFIG;
  if (!raw) {
    return {};
  }
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

function main() {
  const platformName = process.env.CAPACITOR_PLATFORM_NAME;
  if (!platformName || platformName === 'web') {
    return;
  }

  const rootDir = process.env.CAPACITOR_ROOT_DIR;
  if (!rootDir) {
    return;
  }

  const extConfig = readExtConfig();
  const nativePublicDir = resolveNativePublicDir(rootDir, platformName, extConfig);
  if (!nativePublicDir) {
    return;
  }

  if (!fs.existsSync(nativePublicDir)) {
    return;
  }

  const outputFile = path.join(nativePublicDir, BUILTIN_HASHES_FILE_NAME);
  fs.rmSync(outputFile, { force: true });
  try {
    const files = collectWebBundleHashes(nativePublicDir, { outputFileAbs: outputFile });
    writeBuiltinHashesManifest(outputFile, files);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.warn(`[capgo] ${BUILTIN_HASHES_FILE_NAME} not generated: ${message}`);
  }
}

main();
