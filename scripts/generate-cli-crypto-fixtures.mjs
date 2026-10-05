#!/usr/bin/env bun
/**
 * Writes native-contract-tests/cli/ with bundles zipped and encrypted by the real Capgo CLI.
 *
 * The CLI (`@capgo/cli/sdk`, pinned in devDependencies) is the source of truth: keys come from
 * generateEncryptionKeys, zips and checksums from zipBundle, and the encrypted zip, checksum and
 * ivSessionKey from encryptBundle. Nothing here encrypts on its own, so the plugin tests decrypt
 * exactly what `capgo bundle upload` produces. Keys, IVs and session keys are random per run;
 * bundle contents and zip timestamps are fixed.
 *
 * Usage: bun scripts/generate-cli-crypto-fixtures.mjs [outputDir]
 */
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

// The CLI must not send analytics for fixture generation.
process.env.CAPGO_DISABLE_TELEMETRY = '1';
// Zip entry times are local time: pin the zone so the zip bytes do not depend on the machine.
process.env.TZ = 'UTC';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outputDir = path.resolve(process.argv[2] ?? path.join(root, 'native-contract-tests', 'cli'));
const require = (await import('node:module')).createRequire(import.meta.url);
const cliPackage = JSON.parse(fs.readFileSync(require.resolve('@capgo/cli/package.json'), 'utf8'));
const updaterVersion = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version;
const { CapgoSDK } = await import('@capgo/cli/sdk');
// zipBundle looks up a saved Capgo API key before zipping although it never calls the network:
// pass a placeholder so the generator runs offline and in CI (no login).
const sdk = new CapgoSDK({ apikey: process.env.CAPGO_TOKEN || 'offline-fixture-generation' });

const appId = 'app.capgo.clifixtures';
const fixedTime = new Date('2024-01-01T00:00:00Z');

/** Deterministic pseudo-random bytes (SHA-256 counter mode). */
function seededBytes(seed, length) {
  const chunks = [];
  let total = 0;
  for (let counter = 0; total < length; counter++) {
    const block = createHash('sha256').update(`${seed}:${counter}`).digest();
    chunks.push(block);
    total += block.length;
  }
  return Buffer.concat(chunks).subarray(0, length);
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function unwrap(result, step) {
  if (!result?.success) {
    throw new Error(`${step} failed: ${result?.error ?? JSON.stringify(result)}`);
  }
  return result.data;
}

function writeTree(dir, files) {
  fs.rmSync(dir, { recursive: true, force: true });
  for (const [name, content] of Object.entries(files)) {
    const file = path.join(dir, name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content);
  }
  // Fixed timestamps keep the CLI's zip bytes stable across runs.
  const stamp = (target) => {
    for (const entry of fs.readdirSync(target, { withFileTypes: true })) {
      const child = path.join(target, entry.name);
      if (entry.isDirectory()) {
        stamp(child);
      }
      fs.utimesSync(child, fixedTime, fixedTime);
    }
  };
  stamp(dir);
}

async function zipWithCli(id, files) {
  const webDir = path.join(project, `www-${id}`);
  writeTree(webDir, files);
  const zipped = unwrap(
    await sdk.zipBundle({ appId, path: webDir, bundle: '1.0.0', name: `${id}.zip`, codeCheck: false, json: true }),
    `zipBundle(${id})`,
  );
  const zip = fs.readFileSync(path.join(project, zipped.filename));
  if (zipped.checksum !== sha256(zip)) {
    throw new Error(`${id}: CLI checksum ${zipped.checksum} is not the SHA-256 of its zip`);
  }
  const entries = Object.entries(files)
    .map(([name, content]) => ({ path: name, sha256: sha256(Buffer.from(content)) }))
    .sort((a, b) => a.path.localeCompare(b.path));
  return { zip, checksum: zipped.checksum, zipPath: path.join(project, zipped.filename), files: entries };
}

/** Grows a filler file until the CLI's zip length satisfies `accept`. */
async function zipUntil(id, files, filler, accept) {
  for (let extra = 0; extra < 64; extra++) {
    const result = await zipWithCli(id, { ...files, [filler]: seededBytes(`${id}-filler`, 8 + extra).toString('hex') });
    if (accept(result.zip.length)) {
      return result;
    }
  }
  throw new Error(`${id}: no zip length matched`);
}

const indexHtml = (title) =>
  `<!doctype html><html><head><title>${title}</title></head><body><script src="app.js"></script></body></html>\n`;

const cases = [
  {
    id: 'tiny',
    description: 'Smallest real bundle; zip length is not a multiple of 16.',
    build: () => zipUntil('tiny', { 'index.html': '<html>tiny</html>' }, 'pad.txt', (n) => n % 16 !== 0),
  },
  {
    id: 'block-aligned',
    description: 'Zip length is an exact multiple of 16, so PKCS#7 adds a whole padding block.',
    build: () =>
      zipUntil(
        'block-aligned',
        { 'index.html': indexHtml('aligned'), 'app.js': 'console.log("aligned")\n' },
        'pad.txt',
        (n) => n % 16 === 0,
      ),
  },
  {
    id: 'large-random',
    description: 'About 1 MiB of incompressible content; spans several 256 KiB decrypt buffers.',
    build: () =>
      zipUntil(
        'large-random',
        { 'index.html': indexHtml('large'), 'assets/blob.bin': seededBytes('large-random', 1024 * 1024) },
        'pad.txt',
        (n) => n % 16 !== 0,
      ),
  },
  {
    id: 'nested',
    description: 'Nested folders, as a typical web build produces.',
    build: () =>
      zipUntil(
        'nested',
        {
          'index.html': indexHtml('nested'),
          'app.js': 'console.log("nested")\n',
          'assets/css/main.css': 'body { margin: 0; }\n',
          'assets/img/icons/logo.svg': '<svg xmlns="http://www.w3.org/2000/svg"/>\n',
          'assets/js/chunks/vendor/lib.js': `export const data = "${seededBytes('nested', 512).toString('base64')}";\n`,
          'deep/a/b/c/d/e/leaf.txt': 'leaf\n',
        },
        'pad.txt',
        (n) => n % 16 !== 0,
      ),
  },
];

const project = fs.mkdtempSync(path.join(os.tmpdir(), 'capgo-cli-fixtures-'));
const startDir = process.cwd();
try {
  // A minimal Capacitor app with this plugin version installed, as the CLI expects to run in.
  fs.writeFileSync(
    path.join(project, 'package.json'),
    JSON.stringify(
      {
        name: 'capgo-cli-fixtures',
        version: '1.0.0',
        private: true,
        dependencies: { '@capgo/capacitor-updater': updaterVersion },
      },
      null,
      2,
    ),
  );
  const updaterDir = path.join(project, 'node_modules', '@capgo', 'capacitor-updater');
  fs.mkdirSync(updaterDir, { recursive: true });
  fs.writeFileSync(
    path.join(updaterDir, 'package.json'),
    JSON.stringify({ name: '@capgo/capacitor-updater', version: updaterVersion }),
  );
  fs.writeFileSync(
    path.join(project, 'capacitor.config.json'),
    JSON.stringify({ appId, appName: 'CLI fixtures', webDir: 'www' }, null, 2),
  );
  process.chdir(project);

  unwrap(await sdk.generateEncryptionKeys({ force: true }), 'generateEncryptionKeys');
  const capacitorConfig = JSON.parse(fs.readFileSync(path.join(project, 'capacitor.config.json'), 'utf8'));
  const publicKey = capacitorConfig.plugins?.CapacitorUpdater?.publicKey;
  if (!publicKey?.startsWith('-----BEGIN RSA PUBLIC KEY-----')) {
    throw new Error(`Unexpected public key in capacitor.config.json: ${publicKey}`);
  }
  const keyPath = path.join(project, '.capgo_key_v2');

  // Only this script's own files are replaced: never delete the output folder itself, which
  // could be the checkout or hold other files.
  const inside = (parent, child) => {
    const relative = path.relative(parent, child);
    return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
  };
  if (inside(outputDir, root) || inside(outputDir, process.cwd())) {
    throw new Error(`Refusing to write fixtures into ${outputDir}: it contains the repository or the current folder`);
  }
  fs.mkdirSync(outputDir, { recursive: true });
  for (const name of fs.readdirSync(outputDir)) {
    if (name === 'cli-crypto.json' || name.endsWith('.zip') || name.endsWith('.zip.enc')) {
      fs.rmSync(path.join(outputDir, name), { force: true });
    }
  }
  const bundles = [];
  for (const testCase of cases) {
    const { zip, checksum, zipPath, files } = await testCase.build();
    const encrypted = unwrap(
      await sdk.encryptBundle({ zipPath, checksum, keyPath, json: true }),
      `encryptBundle(${testCase.id})`,
    );
    const ciphertext = fs.readFileSync(encrypted.filename);
    if (!/^[0-9a-f]{512}$/.test(encrypted.checksum)) {
      throw new Error(`${testCase.id}: expected a V3 (hex) checksum, got ${encrypted.checksum}`);
    }
    // Round trip through the CLI's own decrypt (public key from the project) as a sanity check.
    const decrypted = unwrap(
      await sdk.decryptBundle({
        zipPath: encrypted.filename,
        ivSessionKey: encrypted.ivSessionKey,
        checksum: encrypted.checksum,
      }),
      `decryptBundle(${testCase.id})`,
    );
    if (decrypted.checksumMatches !== true || !fs.readFileSync(decrypted.outputPath).equals(zip)) {
      throw new Error(`${testCase.id}: CLI decrypt round trip does not give back the zip`);
    }

    fs.writeFileSync(path.join(outputDir, `${testCase.id}.zip`), zip);
    fs.writeFileSync(path.join(outputDir, `${testCase.id}.zip.enc`), ciphertext);
    bundles.push({
      id: testCase.id,
      description: testCase.description,
      zip: `${testCase.id}.zip`,
      encrypted: `${testCase.id}.zip.enc`,
      zipSize: zip.length,
      encryptedSize: ciphertext.length,
      sha256: checksum,
      checksum: encrypted.checksum,
      ivSessionKey: encrypted.ivSessionKey,
      files,
    });
  }

  const fixture = {
    version: 1,
    description:
      'Bundles zipped and encrypted by the Capgo CLI SDK (zipBundle + encryptBundle). The CLI is the source of truth; regenerate with `bun run generate:cli-crypto`.',
    cli: { package: '@capgo/cli', version: cliPackage.version },
    updaterVersion,
    checksumFormat: 'v3-hex',
    publicKey,
    bundles,
  };
  fs.writeFileSync(path.join(outputDir, 'cli-crypto.json'), `${JSON.stringify(fixture, null, 2)}\n`);
  console.log(`Wrote ${bundles.length} bundles from @capgo/cli ${cliPackage.version} to ${outputDir}`);
} finally {
  process.chdir(startDir);
  fs.rmSync(project, { recursive: true, force: true });
}
