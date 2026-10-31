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

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const webDir = path.resolve(process.argv[2] ?? path.join(root, 'www'));
const outputFile = path.resolve(process.argv[3] ?? path.join(webDir, 'ota-builtin-hashes.json'));

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
    const stat = fs.statSync(full);
    if (stat.isDirectory()) {
      walk(full, base, out);
      continue;
    }
    if (!stat.isFile()) {
      continue;
    }
    const rel = path.relative(base, full).split(path.sep).join('/');
    out[rel] = sha256File(full);
  }
}

if (!fs.existsSync(webDir) || !fs.statSync(webDir).isDirectory()) {
  console.error(`Web directory not found: ${webDir}`);
  process.exit(1);
}

const files = {};
walk(webDir, webDir, files);
fs.mkdirSync(path.dirname(outputFile), { recursive: true });
fs.writeFileSync(outputFile, `${JSON.stringify({ files }, null, 2)}\n`, 'utf8');
console.log(`Wrote ${Object.keys(files).length} entries to ${outputFile}`);
