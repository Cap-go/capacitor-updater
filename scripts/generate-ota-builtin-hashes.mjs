#!/usr/bin/env bun
/**
 * Writes `ota-builtin-hashes.json` for faster manifest (delta) updates.
 *
 * Keys are paths relative to the web root with `/` separators. Values are lowercase
 * SHA-256 hex of the file bytes, matching manifest `file_hash` computation.
 *
 * Place the output in your web assets directory (for example `public/`) before
 * `bunx cap sync` so it ships inside the native app bundle.
 *
 * Usage:
 *   bun scripts/generate-ota-builtin-hashes.mjs [webDir] [outputFile]
 *
 * Defaults: webDir = ./www, outputFile = <webDir>/ota-builtin-hashes.json
 */
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { pathContains, resolveRealPath } from './cli-crypto-fixture-output.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const resolvedRoot = fs.realpathSync(root);
const resolvedCwd = fs.realpathSync(process.cwd());

function assertAllowedRoot(label, target) {
  const resolved = resolveRealPath(target);
  if (!pathContains(resolvedRoot, resolved) && !pathContains(resolvedCwd, resolved)) {
    console.error(`Refusing ${label} outside the project or current working directory: ${target}`);
    process.exit(1);
  }
  return resolved;
}

function assertWebDirectory(dir) {
  const resolved = assertAllowedRoot('web directory', dir); // NOSONAR CLI path validated against project root and cwd
  if (!fs.existsSync(resolved) || !fs.statSync(resolved).isDirectory()) { // NOSONAR path validated by assertAllowedRoot
    console.error(`Web directory not found: ${dir}`);
    process.exit(1);
  }
  return resolved;
}

const rawWebDir = process.argv[2] ?? path.join(root, 'www');
const webDir = assertWebDirectory(rawWebDir);
const rawOutputFile = process.argv[3] ?? path.join(webDir, 'ota-builtin-hashes.json');
const outputFile = assertAllowedRoot('output file', rawOutputFile);
const defaultOutputFile = path.join(webDir, 'ota-builtin-hashes.json');

if (!pathContains(webDir, outputFile)) {
  console.error('Output file must be inside the web directory');
  process.exit(1);
}

try {
  if (fs.lstatSync(outputFile).isSymbolicLink()) {
    console.error(`Refusing to write through symbolic link: ${rawOutputFile}`);
    process.exit(1);
  }
} catch (err) {
  if (err?.code !== 'ENOENT') {
    throw err;
  }
}

if (fs.existsSync(outputFile) && outputFile !== defaultOutputFile) {
  console.error(`Refusing to overwrite existing file: ${rawOutputFile}`);
  console.error('Use the default output name ota-builtin-hashes.json or remove the file first.');
  process.exit(1);
}

const skipNames = new Set(['ota-builtin-hashes.json']);

function sha256File(file) {
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

function walk(dir, base, out, ancestors = new Set()) {
  const realDir = fs.realpathSync(dir);
  if (ancestors.has(realDir)) {
    return;
  }
  ancestors.add(realDir);
  try {
    for (const name of fs.readdirSync(dir)) {
      if (skipNames.has(name)) {
        continue;
      }
      const full = path.join(dir, name);
      const resolvedFull = fs.realpathSync(full);
      if (resolvedFull === outputFile) {
        continue;
      }
      if (!pathContains(base, resolvedFull)) {
        continue;
      }
      const stat = fs.statSync(resolvedFull);
      if (stat.isDirectory()) {
        walk(resolvedFull, base, out, ancestors);
        continue;
      }
      if (!stat.isFile()) {
        continue;
      }
      const rel = path.relative(base, resolvedFull).split(path.sep).join('/');
      out[rel] = sha256File(resolvedFull);
    }
  } finally {
    ancestors.delete(realDir);
  }
}

const files = {};
walk(webDir, webDir, files);
fs.mkdirSync(path.dirname(outputFile), { recursive: true }); // NOSONAR output path constrained to webDir via pathContains
fs.writeFileSync(outputFile, `${JSON.stringify({ files }, null, 2)}\n`, 'utf8'); // NOSONAR output path constrained to webDir via pathContains
console.log(`Wrote ${Object.keys(files).length} entries to ${outputFile}`);
