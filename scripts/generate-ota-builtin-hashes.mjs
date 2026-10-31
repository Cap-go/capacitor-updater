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
  if (!fs.existsSync(resolved) || !fs.statSync(resolved).isDirectory()) {
    console.error(`Web directory not found: ${dir}`);
    process.exit(1);
  }
  return resolved;
}

const rawWebDir = process.argv[2] ?? path.join(root, 'www');
const webDir = assertWebDirectory(rawWebDir);
const rawOutputFile = process.argv[3] ?? path.join(webDir, 'ota-builtin-hashes.json');
const outputFile = assertAllowedRoot('output file', rawOutputFile);

if (!pathContains(webDir, outputFile)) {
  console.error('Output file must be inside the web directory');
  process.exit(1);
}

const skipNames = new Set(['ota-builtin-hashes.json']);

function sha256File(file) {
  const hash = createHash('sha256');
  hash.update(fs.readFileSync(file));
  return hash.digest('hex');
}

function walk(dir, base, out) {
  for (const name of fs.readdirSync(dir)) {
    if (skipNames.has(name)) {
      continue;
    }
    const full = path.join(dir, name);
    const resolvedFull = fs.realpathSync(full);
    if (!pathContains(base, resolvedFull)) {
      continue;
    }
    const stat = fs.statSync(resolvedFull);
    if (stat.isDirectory()) {
      walk(resolvedFull, base, out);
      continue;
    }
    if (!stat.isFile()) {
      continue;
    }
    const rel = path.relative(base, resolvedFull).split(path.sep).join('/');
    out[rel] = sha256File(resolvedFull);
  }
}

const files = {};
walk(webDir, webDir, files);
fs.mkdirSync(path.dirname(outputFile), { recursive: true }); // NOSONAR output path constrained to webDir via pathContains
fs.writeFileSync(outputFile, `${JSON.stringify({ files }, null, 2)}\n`, 'utf8'); // NOSONAR output path constrained to webDir via pathContains
console.log(`Wrote ${Object.keys(files).length} entries to ${outputFile}`);
