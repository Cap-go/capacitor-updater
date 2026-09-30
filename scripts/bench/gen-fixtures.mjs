// Generate bench fixtures: RSA key pair, builtin web assets, and zip bundles
// (3 MB / 30 MB / 300 MB of random content, plain + encrypted).
// Manifest versions are generated lazily by the server (fresh content per case).
//
// Usage: bun scripts/bench/gen-fixtures.mjs [--force]
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { builtinWwwDir, fixturesDir, zipDir, zipFixtureBase, zipSizes } from './config.mjs';
import { encryptedChecksum, encryptFileTo, ensureKeys, newSession, sha256File, writeBundleTree } from './fixtures.mjs';

const force = process.argv.includes('--force');
const keys = await ensureKeys();

await writeBundleTree(builtinWwwDir, { marker: 'builtin' });
console.log(`[bench] builtin www -> ${builtinWwwDir}`);

await mkdir(zipDir, { recursive: true });

for (const size of zipSizes) {
  const plainBase = zipFixtureBase(size.key, 'plain');
  const encBase = zipFixtureBase(size.key, 'enc');
  if (!force && existsSync(`${plainBase}.json`) && existsSync(`${encBase}.json`)) {
    console.log(`[bench] zip ${size.key} already generated`);
    continue;
  }
  const tree = path.join(fixturesDir, `tree-${size.key}`);
  console.log(`[bench] generating zip ${size.key} (${size.files} random files)`);
  await writeBundleTree(tree, { marker: `zip-${size.key}`, bytes: size.bytes, files: size.files });
  const plainZip = `${plainBase}.zip`;
  await rm(plainZip, { force: true });
  const zip = spawnSync('/usr/bin/zip', ['-q', '-r', plainZip, '.'], { cwd: tree, stdio: 'inherit' });
  if (zip.status !== 0) throw new Error(`zip failed for ${size.key}`);
  await rm(tree, { recursive: true, force: true });

  const sha = await sha256File(plainZip);
  const plainSize = (await stat(plainZip)).size;
  await writeFile(
    `${plainBase}.json`,
    JSON.stringify({ file: path.basename(plainZip), checksum: sha, sha256: sha, size: plainSize }, null, 2),
  );

  const session = newSession(keys.privateKey);
  const encZip = `${encBase}.zip`;
  await encryptFileTo(session, plainZip, encZip);
  await writeFile(
    `${encBase}.json`,
    JSON.stringify(
      {
        file: path.basename(encZip),
        checksum: encryptedChecksum(keys.privateKey, sha),
        sessionKey: session.sessionKey,
        sha256: sha,
        size: (await stat(encZip)).size,
      },
      null,
      2,
    ),
  );
  console.log(`[bench] zip ${size.key}: ${(plainSize / 1024 / 1024).toFixed(1)} MB`);
}

// Sanity: decrypt round-trip of the smallest encrypted zip with the public key flow.
const probe = JSON.parse(await readFile(`${zipFixtureBase(zipSizes[0].key, 'enc')}.json`, 'utf8'));
console.log(`[bench] fixtures ready (enc sample sessionKey length ${probe.sessionKey.length})`);
