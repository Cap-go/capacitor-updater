#!/usr/bin/env node
/**
 * Capacitor plugin hook: runs on capacitor:sync:after and capacitor:copy:after.
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
  const webDir = process.env.CAPACITOR_WEB_DIR;
  if (!rootDir || !webDir) {
    return;
  }

  if (!fs.existsSync(webDir) || !fs.statSync(webDir).isDirectory()) {
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
  const files = collectWebBundleHashes(webDir, { outputFileAbs: outputFile });
  writeBuiltinHashesManifest(outputFile, files);
}

main();
