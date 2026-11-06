import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { resolveRealPath } from './resolve-real-path.mjs';

export const BUILTIN_HASHES_FILE_NAME = 'ota-builtin-hashes.json';

/** On Android, sized manifest rows compare against uncompressed asset length (openFd when stored uncompressed, otherwise InputStream). */

export function sha256File(file) {
  const hash = createHash('sha256');
  const fd = fs.openSync(file, 'r');
  try {
    const chunk = Buffer.alloc(1024 * 1024);
    let bytesRead;
    while ((bytesRead = fs.readSync(fd, chunk, 0, chunk.length, null)) > 0) {
      hash.update(chunk.subarray(0, bytesRead));
    }
  } finally {
    fs.closeSync(fd);
  }
  return hash.digest('hex');
}

/**
 * Walk `webDir` and collect relativePath -> sha256 hex. Skips the manifest output file,
 * symlinks (does not follow), and non-regular files.
 */
export function collectWebBundleHashes(webDir, { outputFileAbs = null } = {}) {
  const base = fs.realpathSync(webDir);
  const resolvedOutput = outputFileAbs ? resolveRealPath(outputFileAbs) : null;
  const skipNames = new Set([BUILTIN_HASHES_FILE_NAME]);
  const files = {};

  function recordRegularFile(resolvedFull) {
    if (resolvedOutput && resolvedFull === resolvedOutput) {
      return;
    }
    if (!pathContains(base, resolvedFull)) {
      return;
    }
    const rel = path.relative(base, resolvedFull).split(path.sep).join('/');
    const stat = fs.statSync(resolvedFull);
    files[rel] = { sha256: sha256File(resolvedFull), size: stat.size };
  }

  function visitName(name, realDir, ancestors) {
    if (skipNames.has(name)) {
      return;
    }
    const full = path.join(realDir, name);
    let stat;
    try {
      stat = fs.lstatSync(full);
    } catch {
      return;
    }
    if (stat.isSymbolicLink()) {
      return;
    }
    if (stat.isDirectory()) {
      walk(full, ancestors);
      return;
    }
    if (!stat.isFile()) {
      return;
    }
    recordRegularFile(fs.realpathSync(full));
  }

  function walk(dir, ancestors = new Set()) {
    const realDir = fs.realpathSync(dir);
    if (ancestors.has(realDir)) {
      return;
    }
    ancestors.add(realDir);
    try {
      for (const name of fs.readdirSync(realDir)) {
        visitName(name, realDir, ancestors);
      }
    } finally {
      ancestors.delete(realDir);
    }
  }

  walk(base);
  return files;
}

export function pathContains(parent, descendant) {
  const relative = path.relative(parent, descendant);
  if (relative === '') {
    return true;
  }
  if (path.isAbsolute(relative) || relative === '..' || relative.startsWith(`..${path.sep}`)) {
    return false;
  }
  return true;
}

export function resolveIosPublicDir(rootDir, extConfig = {}) {
  const platformDir = extConfig.ios?.path ?? 'ios';
  const platformDirAbs = path.resolve(rootDir, platformDir);
  const nativeProjectDirAbs = path.join(platformDirAbs, 'App');
  const nativeTargetDirAbs = path.join(platformDirAbs, 'App', 'App');
  const pbxprojPath = path.join(platformDirAbs, 'App', 'App.xcodeproj', 'project.pbxproj');
  try {
    const pbxproj = fs.readFileSync(pbxprojPath, 'utf8');
    const re = /path\s=\spublic[\s\S]+?sourceTree\s=\s([^;]+)/;
    const match = pbxproj.match(re);
    if (match?.[1] === 'SOURCE_ROOT') {
      return path.join(nativeProjectDirAbs, 'public');
    }
  } catch {
    // ignore
  }
  return path.join(nativeTargetDirAbs, 'public');
}

export function resolveAndroidPublicDir(rootDir, extConfig = {}) {
  const platformDir = extConfig.android?.path ?? 'android';
  const platformDirAbs = path.resolve(rootDir, platformDir);
  return path.join(platformDirAbs, 'app', 'src', 'main', 'assets', 'public');
}

export function resolveNativePublicDir(rootDir, platformName, extConfig = {}) {
  if (platformName === 'android') {
    return resolveAndroidPublicDir(rootDir, extConfig);
  }
  if (platformName === 'ios') {
    return resolveIosPublicDir(rootDir, extConfig);
  }
  return null;
}

export function writeBuiltinHashesManifest(outputFile, files) {
  const payload = `${JSON.stringify({ files }, null, 2)}\n`;
  fs.mkdirSync(path.dirname(outputFile), { recursive: true });
  const tmpFile = `${outputFile}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmpFile, payload, 'utf8');
    fs.renameSync(tmpFile, outputFile);
  } catch (err) {
    fs.rmSync(tmpFile, { force: true });
    throw err;
  }
}
