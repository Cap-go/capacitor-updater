import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { copyFile, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

assert.equal(process.versions.bun, undefined, 'Run this regression with Node, not Bun');

const dir = path.dirname(fileURLToPath(import.meta.url));
const temp = await mkdtemp(path.join(os.tmpdir(), 'capgo-maestro-test-'));
let server;
try {
  const scripts = path.join(temp, 'scripts/maestro');
  const bundles = path.join(temp, '.maestro-artifacts/bundles');
  const manifest = path.join(temp, '.maestro-artifacts/manifest');
  await mkdir(scripts, { recursive: true });
  await mkdir(bundles, { recursive: true });
  await mkdir(path.join(manifest, 'manual-manifest-v1'), { recursive: true });
  for (const file of ['fake-capgo-server.mjs', 'scenarios.mjs']) {
    await copyFile(path.join(dir, file), path.join(scripts, file));
  }
  const bytes = Buffer.alloc(16384, 42);
  await writeFile(path.join(bundles, 'edge-deferred-v1.zip'), bytes);
  await writeFile(path.join(bundles, 'edge-deferred-v1.checksum'), 'test-checksum\n');
  await writeFile(
    path.join(manifest, 'manual-manifest-v1.json'),
    JSON.stringify({ files: [{ file_name: 'index.html', file_hash: 'test-hash' }] }),
  );
  await writeFile(path.join(manifest, 'manual-manifest-v1/index.html'), 'manifest fixture');
  const listener = net.createServer();
  listener.listen(0, '127.0.0.1');
  await once(listener, 'listening');
  const port = listener.address().port;
  await new Promise((resolve) => listener.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  let logs = '';
  // Explicitly use Node: running this fixture under Bun would conceal the original CI bug.
  server = spawn(process.execPath, [path.join(scripts, 'fake-capgo-server.mjs')], {
    env: { ...process.env, CAPGO_MAESTRO_PORT: String(port), CAPGO_MAESTRO_DEVICE_BASE_URL: base },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  server.stdout.on('data', (chunk) => {
    logs += chunk;
  });
  server.stderr.on('data', (chunk) => {
    logs += chunk;
  });
  async function request(route, options = {}) {
    const response = await fetch(base + route, { ...options, signal: AbortSignal.timeout(3000) });
    assert.equal(response.ok, true, `${route}: ${response.status}\n${logs}`);
    return response;
  }
  for (let attempt = 0; ; attempt++) {
    try {
      await request('/health');
      break;
    } catch (error) {
      if (attempt === 50) throw error;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }
  const update = await (
    await request('/api/updates/edge-deferred', { method: 'POST', body: JSON.stringify({ version_name: '1.0' }) })
  ).json();
  assert.equal(update.checksum, 'test-checksum');
  assert.deepEqual(Buffer.from(await (await request('/bundles/edge-deferred-v1.zip')).arrayBuffer()), bytes);
  const ranged = await request('/bundles/edge-deferred-v1.zip', { headers: { range: 'bytes=100-' } });
  assert.equal(ranged.status, 206);
  assert.equal(ranged.headers.get('content-range'), 'bytes 100-16383/16384');
  assert.deepEqual(Buffer.from(await ranged.arrayBuffer()), bytes.subarray(100));
  await request('/api/control/fault?scenario=edge-deferred&target=bundle&mode=corrupt', { method: 'POST' });
  const corrupt = Buffer.from(await (await request('/bundles/edge-deferred-v1.zip')).arrayBuffer());
  assert.equal(corrupt.length, bytes.length);
  assert.notDeepEqual(corrupt, bytes);
  const manifestUpdate = await (
    await request('/api/updates/manual-manifest', { method: 'POST', body: JSON.stringify({ version_name: '1.0' }) })
  ).json();
  assert.equal(manifestUpdate.manifest[0].file_name, 'index.html');
  assert.equal(await (await request('/manifest/manual-manifest-v1/index.html')).text(), 'manifest fixture');
  const conditions = new Map([
    ['downloads.aborted >= 1', { bundleDownloads: { aborted: 1 } }],
    ['downloads.ranged >= 1', { bundleDownloads: { ranged: 1 } }],
    ['downloads.dropped >= 1', { bundleDownloads: { dropped: 1 } }],
    ['downloads.inFlight >= 1', { bundleDownloads: { inFlight: 1 } }],
    ['downloads.faulted >= 1', { bundleDownloads: { faulted: 1 } }],
    ['downloads.served >= 1', { bundleDownloads: { served: 1 } }],
    ['downloads.started === 0', { bundleDownloads: { started: 0 } }],
    ['debug.updateFaults >= 1', { updateFaults: 1 }],
    ['(stats.checksum_fail ?? 0) >= 1', { statsActionCounts: { checksum_fail: 1 } }],
    ['(stats.update_check_error ?? 0) >= 1', { statsActionCounts: { update_check_error: 1 } }],
  ]);
  const conditionScript = path.join(dir, 'server-condition.mjs');
  for (const [condition, debug] of conditions) {
    assert.equal(spawnSync(process.execPath, [conditionScript, JSON.stringify({ debug }), condition]).status, 0, condition);
    assert.equal(spawnSync(process.execPath, [conditionScript, '{}', condition]).status, 1, condition);
  }
  assert.equal(spawnSync(process.execPath, [conditionScript, '{}', 'process.exit(0)']).status, 2);
  console.log(
    'Maestro helper regression checks passed (Node server, ZIP, Range, corruption, manifest, condition allowlist).',
  );
} finally {
  if (server && server.exitCode === null) {
    server.kill();
    await once(server, 'exit');
  }
  await rm(temp, { recursive: true, force: true });
}
