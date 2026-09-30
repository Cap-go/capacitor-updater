// Bench server: serves bundles/manifests, drives the app case by case and
// appends one JSON line per finished attempt to the results file.
//
// Usage:
//   bun scripts/bench/server.mjs --platform ios --label before --variant plain \
//     --results .context/bench/results-before-ios.jsonl [--runs 3] [--only <regex>] \
//     [--clean-cmd "<shell command clearing the app delta cache>"] [--retry-failed] [--max-attempts 2]
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import { appendFileSync, existsSync, readFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import {
  benchPort,
  buildCases,
  builtinPadDir,
  reuseRatio,
  suites as allSuites,
  defaultRuns,
  deviceBaseUrl,
  manifestTmpDir,
  zipDir,
  zipFixtureBase,
} from './config.mjs';
import {
  createManifestVersion,
  ensureBuiltinPad,
  ensureKeys,
  padFileName,
  removeManifestVersion,
} from './fixtures.mjs';

function arg(name, fallback = undefined) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return fallback;
  const v = process.argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
}

const platform = arg('platform');
const label = arg('label');
const variant = arg('variant');
const resultsFile = arg('results');
const runs = Number.parseInt(arg('runs', String(defaultRuns)), 10);
const only = arg('only') ? new RegExp(arg('only')) : null;
const cleanCmd = arg('clean-cmd', process.env.BENCH_CLEAN_CMD ?? '');
const retryFailed = Boolean(arg('retry-failed', false));
const maxAttempts = Number.parseInt(arg('max-attempts', '2'), 10);
const port = Number.parseInt(arg('port', String(benchPort)), 10);
const idleRestartSec = Number.parseInt(arg('idle-restart', '150'), 10);
const enabledSuites = String(arg('suites', allSuites.join(','))).split(',');

if (!platform || !label || !['plain', 'enc'].includes(variant) || !resultsFile) {
  console.error(
    'usage: server.mjs --platform <ios|android> --label <before|after> --variant <plain|enc> --results <file>',
  );
  process.exit(2);
}

const keys = await ensureKeys();
const builtinPad = await ensureBuiltinPad();
const allCases = buildCases(variant, runs, enabledSuites).filter((c) => !only || only.test(c.id));

// ---- resume support --------------------------------------------------------
const finished = new Set();
if (existsSync(resultsFile)) {
  for (const line of readFileSync(resultsFile, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      const r = JSON.parse(line);
      if (r.label !== label || r.platform !== platform) continue;
      if (r.ok || (r.final && !retryFailed)) finished.add(r.caseId);
    } catch {
      // ignore torn lines
    }
  }
}
// Warm-up cases (always run first, excluded from the report): the first download
// and the first WebView reload of a fresh app process are noticeably slower.
const warmups = arg('no-warmup', false)
  ? []
  : ['background', 'direct'].map((mode) => ({
      id: `warmup-zip-3MB-${variant}-${mode}`,
      kind: 'zip',
      sizeKey: '3MB',
      bytes: 3 * 1024 * 1024,
      files: 10,
      variant,
      mode,
      run: 0,
      timeoutSec: 120,
      warmup: true,
    }));
const queue = [...warmups, ...allCases.filter((c) => !finished.has(c.id))];
const attempts = new Map();
console.log(`[bench-server] ${label}/${platform}/${variant}: ${allCases.length} cases, ${queue.length} to run`);

let current = null; // { case, attempt, version, startedAt, phase, meta }
// Per-version request accounting (proves every manifest file was fetched).
const served = new Map();
function countServed(version, bytes) {
  const s = served.get(version) ?? { requests: 0, bytes: 0 };
  s.requests += 1;
  s.bytes += bytes;
  served.set(version, s);
}
let needsRestart = false;
let lastSeen = Date.now();
let preparing = false;
let lastFinishedBytes = 0;
let lastFinishedVersions = [];

function log(msg) {
  console.log(`[bench-server ${new Date().toISOString().slice(11, 19)}] ${msg}`);
}

function record(c, fields) {
  const rec = {
    ts: new Date().toISOString(),
    label,
    platform,
    variant: c.case.variant,
    caseId: c.case.id,
    kind: c.case.kind,
    sizeKey: c.case.sizeKey,
    mode: c.case.mode,
    run: c.case.run,
    attempt: c.attempt,
    version: c.version,
    servedBytes: c.meta?.servedBytes,
    fileCount: c.meta?.fileCount,
    expectedDownloads: c.meta?.expectedDownloads,
    requests: served.get(c.version)?.requests ?? 0,
    requestBytes: served.get(c.version)?.bytes ?? 0,
    ...(c.case.shape ? { shape: c.case.shape, peakInFlight: c.peakInFlight ?? 0 } : {}),
    ...(c.case.warmup ? { warmup: true } : {}),
    ...fields,
  };
  if (!rec.ok) {
    rec.final = c.attempt >= maxAttempts;
    if (!rec.final) queue.unshift(c.case);
  }
  appendFileSync(resultsFile, `${JSON.stringify(rec)}\n`);
  served.delete(c.version);
  for (const v of c.versions) served.delete(v);
  log(
    `${rec.ok ? 'OK  ' : 'FAIL'} ${rec.caseId} a${rec.attempt}` +
      (rec.ok
        ? ` total=${rec.totalMs}ms dl=${rec.downloadMs}ms${rec.applyMs != null ? ` apply=${rec.applyMs}ms` : ''}`
        : ` ${rec.error}`),
  );
  lastFinishedBytes = c.case.bytes;
  lastFinishedVersions = c.versions;
  current = null;
}

function randomSuffix() {
  return crypto.randomBytes(3).toString('hex').slice(0, 4);
}

async function zipDownload(c, version) {
  const fixture = JSON.parse(await readFile(`${zipFixtureBase(c.sizeKey, c.variant)}.json`, 'utf8'));
  const download = { url: `${deviceBaseUrl}/z/${fixture.file}`, version, checksum: fixture.checksum };
  if (fixture.sessionKey) download.sessionKey = fixture.sessionKey;
  return { download, meta: { servedBytes: fixture.size, fileCount: c.files + 2, expectedDownloads: 1 } };
}

async function manifestDownload(version, options) {
  const t = Date.now();
  const m = await createManifestVersion({ version, keys, ...options });
  log(`generated manifest ${version} (${m.fileCount} files, ${m.expectedDownloads} to fetch) in ${Date.now() - t}ms`);
  const download = { url: `${deviceBaseUrl}/z/unused.zip`, version, manifest: m.manifest };
  if (m.sessionKey) download.sessionKey = m.sessionKey;
  return {
    download,
    plainRoot: m.plainRoot,
    meta: { servedBytes: m.servedBytes, fileCount: m.fileCount, expectedDownloads: m.expectedDownloads },
  };
}

async function prepareCase(c) {
  const attempt = (attempts.get(c.id) ?? 0) + 1;
  attempts.set(c.id, attempt);
  const version = `${label}-${c.id}-a${attempt}-${randomSuffix()}`;
  const base = { files: c.files, bytes: c.bytes, variant: c.variant };
  const reused = Math.round(c.files * reuseRatio);
  let prepared;
  let pre = null;
  // Generated manifest versions to delete from disk once the case is over.
  const versions = [];
  if (c.kind === 'zip' || c.kind === 'shaped-zip') {
    prepared = await zipDownload(c, version);
  } else if (c.kind === 'reuse-cache') {
    // Version A: installed untimed right before B, so its files land in the delta cache.
    const versionA = `${version}-A`;
    const a = await manifestDownload(versionA, { ...base, keepPlain: true });
    pre = a.download;
    versions.push(versionA);
    const names = Array.from({ length: reused }, (_, i) => padFileName(i));
    prepared = await manifestDownload(version, { ...base, reuse: { srcDir: a.plainRoot, names, newStart: reused } });
    versions.push(version);
  } else if (c.kind === 'reuse-builtin') {
    const names = builtinPad.files.slice(0, reused).map((f) => f.name);
    if (names.length < reused) throw new Error(`builtin pad too small for ${c.id}`);
    prepared = await manifestDownload(version, { ...base, reuse: { srcDir: builtinPadDir, names, newStart: 0 } });
    versions.push(version);
  } else {
    prepared = await manifestDownload(version, base);
    versions.push(version);
  }
  return {
    case: c,
    attempt,
    version,
    versions,
    download: prepared.download,
    pre,
    preSettleMs: pre ? 2000 + Math.round((c.bytes / (100 * 1024 * 1024)) * 2000) : 0,
    meta: prepared.meta,
  };
}

function runCleanCmd() {
  if (!cleanCmd) return;
  const r = spawnSync('/bin/sh', ['-c', cleanCmd], { timeout: 60000, encoding: 'utf8' });
  if (r.status !== 0) log(`clean cmd failed (${r.status}): ${(r.stderr || '').trim().slice(0, 200)}`);
}

async function nextAction() {
  if (current) {
    // A case is already assigned (e.g. duplicate request): let it time out instead.
    return { action: 'wait', ms: 3000 };
  }
  if (preparing) return { action: 'wait', ms: 2000 };
  for (const v of lastFinishedVersions) await removeManifestVersion(v);
  lastFinishedVersions = [];
  if (!queue.length) return { action: 'done' };
  preparing = true;
  try {
    // Let async work of the previous case settle (delta cache population, deletes).
    const settleMs = 2000 + Math.round((lastFinishedBytes / (100 * 1024 * 1024)) * 2000);
    await Bun.sleep(settleMs);
    runCleanCmd();
    const c = queue.shift();
    const prepared = await prepareCase(c);
    current = { ...prepared, startedAt: Date.now(), phase: 'running' };
    log(`start ${c.id} a${prepared.attempt} (${c.mode})`);
    return {
      action: 'run',
      case: {
        id: c.id,
        attempt: prepared.attempt,
        mode: c.mode,
        download: prepared.download,
        pre: prepared.pre,
        preSettleMs: prepared.preSettleMs,
      },
    };
  } finally {
    preparing = false;
  }
}

function matches(body) {
  return current && body.caseId === current.case.id && body.attempt === current.attempt;
}

const cors = {
  'access-control-allow-headers': '*',
  'access-control-allow-methods': 'GET,HEAD,POST,OPTIONS',
  'access-control-allow-origin': '*',
  'access-control-allow-private-network': 'true',
  'cache-control': 'no-store',
};

const json = (payload, status = 200) => Response.json(payload, { status, headers: cors });

function safeJoin(root, rel) {
  const target = path.resolve(root, rel);
  if (target !== root && !target.startsWith(root + path.sep)) return null;
  return target;
}

// ---- network shaping (per case) ---------------------------------------------
// One token bucket shared by every payload connection (total bandwidth cap), plus a
// fixed delay before the response headers of every payload request (latency/TTFB).
const SHAPE_CHUNK = 16 * 1024;
const bucket = { tokens: 0, last: performance.now(), rateBytesPerSec: 0 };
async function takeTokens(n) {
  const capacity = 4 * SHAPE_CHUNK;
  for (;;) {
    const now = performance.now();
    bucket.tokens = Math.min(capacity, bucket.tokens + ((now - bucket.last) / 1000) * bucket.rateBytesPerSec);
    bucket.last = now;
    if (bucket.tokens >= n) {
      bucket.tokens -= n;
      return;
    }
    await Bun.sleep(Math.max(1, Math.ceil(((n - bucket.tokens) / bucket.rateBytesPerSec) * 1000)));
  }
}

// Parallelism seen by the server during a shaped case (requests between arrival and last byte).
let inFlight = 0;
function requestDone(state) {
  if (!state.done) {
    state.done = true;
    inFlight -= 1;
  }
}

function shapedBody(file, state) {
  let data = null;
  let offset = 0;
  return new ReadableStream({
    cancel() {
      requestDone(state);
    },
    async pull(controller) {
      data ??= new Uint8Array(await Bun.file(file).arrayBuffer());
      if (offset >= data.length) {
        controller.close();
        requestDone(state);
        return;
      }
      const n = Math.min(SHAPE_CHUNK, data.length - offset);
      await takeTokens(n);
      controller.enqueue(data.subarray(offset, offset + n));
      offset += n;
    },
  });
}

async function serveFile(file, method) {
  if (!file || !existsSync(file)) return new Response('not found', { status: 404, headers: cors });
  const f = Bun.file(file);
  const headers = { ...cors, 'content-type': 'application/octet-stream', 'content-length': String(f.size) };
  const shape = current?.case.shape;
  if (shape) {
    bucket.rateBytesPerSec = (shape.mbit * 1_000_000) / 8;
    const state = { done: false };
    inFlight += 1;
    if (current) current.peakInFlight = Math.max(current.peakInFlight ?? 0, inFlight);
    await Bun.sleep(shape.latencyMs);
    if (method === 'HEAD') {
      requestDone(state);
      return new Response(null, { headers });
    }
    return new Response(shapedBody(file, state), { headers });
  }
  return new Response(method === 'HEAD' ? null : f, { headers });
}

async function body(req) {
  try {
    return await req.json();
  } catch {
    return {};
  }
}

const server = Bun.serve({
  port,
  hostname: '0.0.0.0',
  idleTimeout: 255,
  async fetch(req) {
    const url = new URL(req.url);
    const p = url.pathname;
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });

    if (p.startsWith('/z/')) {
      const name = decodeURIComponent(p.slice(3));
      if (!/^[\w.-]+$/.test(name)) return new Response('bad name', { status: 400, headers: cors });
      const file = path.join(zipDir, name);
      if (current && req.method === 'GET' && existsSync(file)) countServed(current.version, Bun.file(file).size);
      return serveFile(file, req.method);
    }
    if (p.startsWith('/m/')) {
      const rel = decodeURIComponent(p.slice(3));
      const file = safeJoin(path.resolve(manifestTmpDir), rel);
      if (file && req.method === 'GET' && existsSync(file)) countServed(rel.split('/')[0], Bun.file(file).size);
      return serveFile(file, req.method);
    }
    if (p.startsWith('/api/')) {
      if (p.startsWith('/api/updates')) return json({ error: 'no_new_version_available', message: 'bench' });
      return json({ status: 'ok' });
    }

    if (p === '/bench/status') {
      return json({
        label,
        platform,
        variant,
        total: allCases.length,
        remaining: queue.length + (current || preparing ? 1 : 0),
        current: current ? { id: current.case.id, attempt: current.attempt, phase: current.phase } : null,
        needsRestart,
        done: !queue.length && !current && !preparing && !lastFinishedVersions.length,
        lastSeenAgoSec: Math.round((Date.now() - lastSeen) / 1000),
      });
    }
    if (p === '/bench/restarted') {
      needsRestart = false;
      lastSeen = Date.now();
      return json({ ok: true });
    }

    lastSeen = Date.now();
    const b = req.method === 'POST' ? await body(req) : {};

    if (p === '/bench/log') {
      log(`app: ${JSON.stringify(b).slice(0, 500)}`);
      return json({ ok: true });
    }
    if (p === '/bench/boot') {
      const version = b.bundle?.version ?? '?';
      log(`boot marker=${b.marker} bundle=${version}${b.readyError ? ` readyError=${b.readyError}` : ''}`);
      if (current?.phase === 'awaiting-ready') {
        const ps = b.pendingSet;
        if (ps && ps.caseId === current.case.id && ps.attempt === current.attempt && version === current.version) {
          const downloadMs = current.t1 - current.t0;
          const applyMs = b.tReady - ps.tSet;
          record(current, {
            ok: true,
            downloadMs,
            applyMs,
            totalMs: downloadMs + applyMs,
            wallMs: b.tReady - current.t0,
          });
        } else {
          record(current, {
            ok: false,
            error: `unexpected boot after set(): running ${version}, expected ${current.version}${b.readyError ? ` (${b.readyError})` : ''}`,
          });
        }
      } else if (current?.phase === 'running') {
        record(current, { ok: false, error: `app rebooted during case (bundle ${version})` });
      }
      return json(await nextAction());
    }
    if (p === '/bench/next') return json(await nextAction());
    if (p === '/bench/pre-done') {
      if (matches(b)) {
        // The timed part starts now: give it the full case timeout.
        current.startedAt = Date.now();
        log(`pre-download done for ${current.case.id}`);
      }
      return json({ ok: true });
    }
    if (p === '/bench/downloaded') {
      if (!matches(b)) return json({ ok: false, stale: true });
      current.phase = 'awaiting-ready';
      current.t0 = b.t0;
      current.t1 = b.t1;
      current.bundleId = b.bundleId;
      return json({ ok: true });
    }
    if (p === '/bench/result') {
      if (!matches(b)) {
        log(`stale result ignored: ${b.caseId} a${b.attempt}`);
        return json(await nextAction());
      }
      if (b.ok) {
        const downloadMs = b.t1 - b.t0;
        record(current, { ok: true, downloadMs, totalMs: downloadMs, status: b.status });
      } else {
        record(current, { ok: false, error: String(b.error ?? 'unknown').slice(0, 500) });
      }
      return json(await nextAction());
    }
    return new Response('not found', { status: 404, headers: cors });
  },
});

setInterval(() => {
  if (current) {
    const elapsed = (Date.now() - current.startedAt) / 1000;
    if (elapsed > current.case.timeoutSec) {
      record(current, { ok: false, error: `timeout after ${Math.round(elapsed)}s (phase ${current.phase})` });
      needsRestart = true;
    }
  } else if (!preparing && queue.length && (Date.now() - lastSeen) / 1000 > idleRestartSec) {
    log('app idle, requesting restart');
    needsRestart = true;
    lastSeen = Date.now();
  }
}, 2000);

log(`listening on ${server.hostname}:${server.port} (device url ${deviceBaseUrl})`);
