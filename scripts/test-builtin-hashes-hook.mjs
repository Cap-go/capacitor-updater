#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
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
const hookScript = path.join(root, 'scripts/capacitor-builtin-hashes-hook.mjs');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'capgo-builtin-hook-'));

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function runHook(envExtra) {
  const result = spawnSync(process.execPath, [hookScript], {
    env: { ...process.env, ...envExtra },
    encoding: 'utf8',
  });
  return result;
}

function assertManifestKeysUnderNode(manifestPath) {
  const parsed = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  assert(parsed.files && typeof parsed.files === 'object', 'manifest must have files object');
  for (const [rel, entry] of Object.entries(parsed.files)) {
    assert(entry && typeof entry === 'object', `entry for ${rel} must be an object`);
    assert(typeof entry.sha256 === 'string' && entry.sha256.length === 64, `sha256 for ${rel}`);
    assert(typeof entry.size === 'number' && entry.size >= 0, `size for ${rel}`);
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
  assert(files['index.html'].sha256 === sha256File(indexPath), 'index.html hash mismatch');
  assert(files['index.html'].size === fs.statSync(indexPath).size, 'index.html size mismatch');
  assert(files['assets/app.js'].sha256 === sha256File(jsPath), 'assets/app.js hash mismatch');

  writeBuiltinHashesManifest(outputFile, files);
  assert(fs.existsSync(outputFile), 'manifest file must be written');
  const parsed = JSON.parse(fs.readFileSync(outputFile, 'utf8'));
  assert(parsed.files['index.html'].sha256 === files['index.html'].sha256, 'written manifest must match collected hashes');
  assert(parsed.files['index.html'].size === files['index.html'].size, 'written manifest size must match');

  fs.writeFileSync(path.join(webDir, BUILTIN_HASHES_FILE_NAME), '{"files":{}}\n', 'utf8');
  const withoutSelf = collectWebBundleHashes(webDir, { outputFileAbs: outputFile });
  assert(!Object.hasOwn(withoutSelf, BUILTIN_HASHES_FILE_NAME), 'must skip manifest in web dir');

  const linkTarget = path.join(tmp, 'outside.js');
  fs.writeFileSync(linkTarget, 'linked\n', 'utf8');
  if (process.platform === 'win32') {
    try {
      fs.symlinkSync(linkTarget, path.join(webDir, 'link.js'), 'file');
    } catch {
      // Symlinks may require elevation on Windows; skip symlink assertion when unavailable.
    }
  } else {
    fs.symlinkSync(linkTarget, path.join(webDir, 'link.js'));
  }
  const withLink = collectWebBundleHashes(webDir, { outputFileAbs: outputFile });
  if (process.platform !== 'win32') {
    assert(!Object.hasOwn(withLink, 'link.js'), 'must not follow symlinks');
  }

  const resolvedAndroid = resolveNativePublicDir(tmp, 'android', {});
  assert(resolvedAndroid === androidPublic, 'android public dir resolution');

  const absAndroidRoot = path.join(tmp, 'external-android');
  const absAndroidPublic = path.join(absAndroidRoot, 'app', 'src', 'main', 'assets', 'public');
  fs.mkdirSync(absAndroidPublic, { recursive: true });
  const resolvedAbsAndroid = resolveNativePublicDir(tmp, 'android', {
    android: { path: absAndroidRoot },
  });
  assert(resolvedAbsAndroid === absAndroidPublic, 'absolute android.path public dir resolution');

  const hookAndroidRoot = path.join(tmp, 'hook-android-root');
  const hookAndroidPublic = path.join(hookAndroidRoot, 'android', 'app', 'src', 'main', 'assets', 'public');
  fs.mkdirSync(hookAndroidPublic, { recursive: true });
  fs.writeFileSync(path.join(hookAndroidPublic, 'index.html'), '<html>hook</html>\n', 'utf8');
  const androidHook = runHook({
    CAPACITOR_PLATFORM_NAME: 'android',
    CAPACITOR_ROOT_DIR: hookAndroidRoot,
    CAPACITOR_CONFIG: JSON.stringify({ android: { path: 'android' } }),
  });
  assert(androidHook.status === 0, `android hook must exit 0, got ${androidHook.status} stderr=${androidHook.stderr}`);
  const androidManifest = path.join(hookAndroidPublic, BUILTIN_HASHES_FILE_NAME);
  assert(fs.existsSync(androidManifest), 'android hook must write manifest');
  assertManifestKeysUnderNode(androidManifest);

  const hookIosRoot = path.join(tmp, 'hook-ios-root');
  const iosPublic = path.join(hookIosRoot, 'ios', 'App', 'public');
  const pbxprojDir = path.join(hookIosRoot, 'ios', 'App', 'App.xcodeproj');
  fs.mkdirSync(iosPublic, { recursive: true });
  fs.mkdirSync(pbxprojDir, { recursive: true });
  fs.writeFileSync(
    path.join(pbxprojDir, 'project.pbxproj'),
    '/* fixture */ path = public; sourceTree = SOURCE_ROOT;\n',
    'utf8',
  );
  fs.writeFileSync(path.join(iosPublic, 'index.html'), '<html>ios hook</html>\n', 'utf8');
  const iosHook = runHook({
    CAPACITOR_PLATFORM_NAME: 'ios',
    CAPACITOR_ROOT_DIR: hookIosRoot,
    CAPACITOR_CONFIG: JSON.stringify({ ios: { path: 'ios' } }),
  });
  assert(iosHook.status === 0, `ios hook must exit 0, got ${iosHook.status} stderr=${iosHook.stderr}`);
  const iosManifest = path.join(iosPublic, BUILTIN_HASHES_FILE_NAME);
  assert(fs.existsSync(iosManifest), 'ios hook must write manifest');
  assertManifestKeysUnderNode(iosManifest);

  const badRoot = path.join(tmp, 'hook-fail-root');
  fs.mkdirSync(badRoot, { recursive: true });
  const failHook = runHook({
    CAPACITOR_PLATFORM_NAME: 'android',
    CAPACITOR_ROOT_DIR: badRoot,
    CAPACITOR_CONFIG: '{}',
  });
  assert(failHook.status === 0, 'hook must exit 0 even when native public dir is missing');

  console.log('builtin-hashes hook ok');
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
