#!/usr/bin/env bun
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  assertSafeFixtureOutputDir,
  pathContains,
  resolveRealPath,
} from './cli-crypto-fixture-output.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'cli-crypto-guard-'));
const realTmp = fs.realpathSync(tmp);

function expectRefusal(outputDir, cwd, fixtureRoot = root) {
  try {
    assertSafeFixtureOutputDir(outputDir, { root: fixtureRoot, cwd });
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

const checkoutLike = path.join(tmp, '..checkout');
fs.mkdirSync(checkoutLike, { recursive: true });
if (!pathContains(realTmp, fs.realpathSync(checkoutLike))) {
  console.error('pathContains must treat a ..checkout child as inside its parent directory');
  process.exit(1);
}
expectRefusal(realTmp, tmp, checkoutLike);

const nested = path.join(tmp, 'nested', 'out');
const resolvedNested = resolveRealPath(nested);
const expectedNested = path.join(realTmp, 'nested', 'out');
if (resolvedNested !== expectedNested) {
  console.error(`unexpected resolveRealPath for missing nested dir: ${resolvedNested} (expected ${expectedNested})`);
  process.exit(1);
}
assertSafeFixtureOutputDir(nested, { root, cwd: tmp });

fs.rmSync(tmp, { recursive: true, force: true });
console.log('cli-crypto output guard ok');
