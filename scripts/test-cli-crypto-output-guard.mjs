#!/usr/bin/env bun
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { assertSafeFixtureOutputDir, resolveRealPath } from './cli-crypto-fixture-output.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'cli-crypto-guard-'));

function expectRefusal(outputDir, cwd) {
  try {
    assertSafeFixtureOutputDir(outputDir, { root, cwd });
    console.error(`expected refusal for ${outputDir}`);
    process.exit(1);
  } catch (err) {
    if (!String(err.message).includes('Refusing to write fixtures')) {
      throw err;
    }
  }
}

const repoLink = path.join(tmp, 'repo-link');
fs.symlinkSync(root, repoLink, 'dir');
expectRefusal(repoLink, tmp);

const nested = path.join(tmp, 'nested', 'out');
const resolvedNested = resolveRealPath(nested);
if (resolvedNested !== path.join(tmp, 'nested', 'out')) {
  console.error(`unexpected resolveRealPath for missing nested dir: ${resolvedNested}`);
  process.exit(1);
}
assertSafeFixtureOutputDir(nested, { root, cwd: tmp });

fs.rmSync(tmp, { recursive: true, force: true });
console.log('cli-crypto output guard ok');
