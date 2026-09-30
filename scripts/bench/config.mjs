// Shared paths and the benchmark matrix for the live-update performance bench.
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
export const repoRoot = path.resolve(scriptDir, '..', '..');
export const benchDir = process.env.BENCH_DIR ?? path.join(repoRoot, '.context', 'bench');
export const keysDir = path.join(benchDir, 'keys');
export const fixturesDir = path.join(benchDir, 'fixtures');
export const zipDir = path.join(fixturesDir, 'zip');
export const manifestTmpDir = path.join(fixturesDir, 'manifest-tmp');
export const builtinWwwDir = path.join(fixturesDir, 'www');
export const appsDir = path.join(benchDir, 'apps');
export const logsDir = path.join(benchDir, 'logs');

export const benchPort = Number.parseInt(process.env.BENCH_PORT ?? '3193', 10);
// Both the iOS simulator (loopback shared with the host) and the Android emulator
// (through `adb reverse`) reach the bench server at 127.0.0.1.
export const deviceBaseUrl = process.env.BENCH_DEVICE_BASE_URL ?? `http://127.0.0.1:${benchPort}`;

export const MB = 1024 * 1024;
export const KB = 1024;

// Zip bundles: total payload size (random, incompressible).
export const zipSizes = [
  { key: '3MB', bytes: 3 * MB, files: 10, timeoutSec: 120 },
  { key: '30MB', bytes: 30 * MB, files: 30, timeoutSec: 240 },
  { key: '300MB', bytes: 300 * MB, files: 100, timeoutSec: 600 },
];

// Manifest (delta) downloads: N changed payload files totalling `bytes`.
// index.html and bench.js are also unique per version (so also downloaded).
export const manifestSizes = [
  { key: '2f-20KB', files: 2, bytes: 20 * KB, timeoutSec: 120 },
  { key: '20f-2MB', files: 20, bytes: 2 * MB, timeoutSec: 180 },
  { key: '200f-20MB', files: 200, bytes: 20 * MB, timeoutSec: 300 },
  { key: '2000f-200MB', files: 2000, bytes: 200 * MB, timeoutSec: 600 },
];

export const modes = ['background', 'direct'];
export const variants = ['plain', 'enc'];
export const defaultRuns = Number.parseInt(process.env.BENCH_RUNS ?? '3', 10);

export function zipFixtureBase(sizeKey, variant) {
  return path.join(zipDir, `${sizeKey}-${variant}`);
}

/** Every case of one app variant (encryption off/on), in execution order. */
export function buildCases(variant, runs = defaultRuns) {
  const cases = [];
  for (let run = 1; run <= runs; run += 1) {
    for (const mode of modes) {
      for (const size of zipSizes) {
        cases.push({
          id: `zip-${size.key}-${variant}-${mode}-r${run}`,
          kind: 'zip',
          sizeKey: size.key,
          bytes: size.bytes,
          files: size.files,
          variant,
          mode,
          run,
          timeoutSec: size.timeoutSec,
        });
      }
      for (const size of manifestSizes) {
        cases.push({
          id: `manifest-${size.key}-${variant}-${mode}-r${run}`,
          kind: 'manifest',
          sizeKey: size.key,
          bytes: size.bytes,
          files: size.files,
          variant,
          mode,
          run,
          timeoutSec: size.timeoutSec,
        });
      }
    }
  }
  return cases;
}
