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
// Random files shipped inside the bench app's builtin public/ (under bpad/), used by the
// builtin-reuse manifest cases. Generated once; hashes in builtin-pad.json.
export const builtinPadDir = path.join(fixturesDir, 'builtin-pad');
export const builtinPadIndex = path.join(fixturesDir, 'builtin-pad.json');
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

// Manifest reuse cases (background only): the new version ships `reuseRatio` of its
// files already available on the device, either in the delta cache (from a version A
// installed untimed just before) or in the app's builtin public/ folder.
export const reuseRatio = 0.9;
export const reuseSizes = [
  { key: '200f-20MB', files: 200, bytes: 20 * MB, timeoutSec: 300 },
  { key: '2000f-200MB', files: 2000, bytes: 200 * MB, timeoutSec: 600 },
];
export const reuseKinds = ['reuse-cache', 'reuse-builtin'];
// Builtin pad: enough 100 KiB files for 90% of the largest reuse case.
export const builtinPadFiles = Math.round(2000 * reuseRatio);
export const builtinPadFileBytes = Math.floor((200 * MB) / 2000);

// Network-shaped cases (plain, background): every payload response waits
// `latencyMs` before its headers, and all payload bytes share one token bucket.
export const shape = {
  latencyMs: Number.parseInt(process.env.BENCH_SHAPE_LATENCY_MS ?? '80', 10),
  mbit: Number.parseFloat(process.env.BENCH_SHAPE_MBIT ?? '40'),
};
export const shapedSizes = [
  { kind: 'shaped-zip', key: '30MB', bytes: 30 * MB, files: 30, timeoutSec: 300 },
  { kind: 'shaped-manifest', key: '200f-20MB', files: 200, bytes: 20 * MB, timeoutSec: 600 },
  { kind: 'shaped-manifest', key: '2000f-20MB', files: 2000, bytes: 20 * MB, timeoutSec: 600 },
];

export const suites = ['main', 'reuse', 'shaped'];
export const modes = ['background', 'direct'];
export const variants = ['plain', 'enc'];
export const defaultRuns = Number.parseInt(process.env.BENCH_RUNS ?? '3', 10);

export function zipFixtureBase(sizeKey, variant) {
  return path.join(zipDir, `${sizeKey}-${variant}`);
}

/** Every case of one app variant (encryption off/on), in execution order. */
export function buildCases(variant, runs = defaultRuns, enabledSuites = suites) {
  const cases = [];
  for (let run = 1; run <= runs; run += 1) {
    if (enabledSuites.includes('main')) {
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
    if (enabledSuites.includes('reuse')) {
      for (const kind of reuseKinds) {
        for (const size of reuseSizes) {
          cases.push({
            id: `${kind}-${size.key}-${variant}-background-r${run}`,
            kind,
            sizeKey: size.key,
            bytes: size.bytes,
            files: size.files,
            variant,
            mode: 'background',
            run,
            timeoutSec: size.timeoutSec,
          });
        }
      }
    }
    if (enabledSuites.includes('shaped') && variant === 'plain') {
      for (const size of shapedSizes) {
        cases.push({
          id: `${size.kind}-${size.key}-${variant}-background-r${run}`,
          kind: size.kind,
          sizeKey: size.key,
          bytes: size.bytes,
          files: size.files,
          variant,
          mode: 'background',
          run,
          timeoutSec: size.timeoutSec,
          shape,
        });
      }
    }
  }
  return cases;
}
