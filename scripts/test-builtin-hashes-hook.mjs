#!/usr/bin/env bun
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  BUILTIN_HASHES_FILE_NAME,
  collectWebBundleHashes,
  resolveNativePublicDir,
  sha256File,
  writeBuiltinHashesManifest,
} from './builtin-hashes-lib.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'capgo-builtin-hook-'));

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

try {
  const webDir = path.join(tmp, 'www');
  const androidPublic = path.join(tmp, 'android', 'app', 'src', 'main', 'assets', 'public');
  fs.mkdirSync(webDir, { recursive: true });
  fs.mkdirSync(androidPublic, { recursive: true });

  const indexPath = path.join(webDir, 'index.html');
  fs.writeFileSync(indexPath, '<html></html>\n', 'utf8');
  const nestedDir = path.join(webDir, 'assets');
  fs.mkdirSync(nestedDir, { recursive: true });
  const jsPath = path.join(nestedDir, 'app.js');
  fs.writeFileSync(jsPath, 'console.log("ok");\n', 'utf8');

  const outputFile = path.join(androidPublic, BUILTIN_HASHES_FILE_NAME);
  const files = collectWebBundleHashes(webDir, { outputFileAbs: outputFile });
  assert(Object.keys(files).length === 2, 'expected two hashed web files');
  assert(files['index.html'] === sha256File(indexPath), 'index.html hash mismatch');
  assert(files['assets/app.js'] === sha256File(jsPath), 'assets/app.js hash mismatch');

  writeBuiltinHashesManifest(outputFile, files);
  assert(fs.existsSync(outputFile), 'manifest file must be written');
  const parsed = JSON.parse(fs.readFileSync(outputFile, 'utf8'));
  assert(parsed.files['index.html'] === files['index.html'], 'written manifest must match collected hashes');

  fs.writeFileSync(path.join(webDir, BUILTIN_HASHES_FILE_NAME), '{"files":{}}\n', 'utf8');
  const withoutSelf = collectWebBundleHashes(webDir, { outputFileAbs: outputFile });
  assert(!Object.hasOwn(withoutSelf, BUILTIN_HASHES_FILE_NAME), 'must skip manifest in web dir');

  const linkTarget = path.join(tmp, 'outside.js');
  fs.writeFileSync(linkTarget, 'linked\n', 'utf8');
  fs.symlinkSync(linkTarget, path.join(webDir, 'link.js'));
  const withLink = collectWebBundleHashes(webDir, { outputFileAbs: outputFile });
  assert(!Object.hasOwn(withLink, 'link.js'), 'must not follow symlinks');

  const resolvedAndroid = resolveNativePublicDir(tmp, 'android', {});
  assert(resolvedAndroid === androidPublic, 'android public dir resolution');

  const absAndroidRoot = path.join(tmp, 'external-android');
  const absAndroidPublic = path.join(absAndroidRoot, 'app', 'src', 'main', 'assets', 'public');
  fs.mkdirSync(absAndroidPublic, { recursive: true });
  const resolvedAbsAndroid = resolveNativePublicDir(tmp, 'android', {
    android: { path: absAndroidRoot },
  });
  assert(resolvedAbsAndroid === absAndroidPublic, 'absolute android.path public dir resolution');

  console.log('builtin-hashes hook ok');
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
