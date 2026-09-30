// Fixture helpers: RSA keys, Capgo-CLI-compatible encryption, random bundles and manifests.
//
// Encryption format (matches what the native code verifies, see
// native-contract-tests/crypto.json and scripts/generate-core-contract-fixtures.mjs):
// - AES-128-CBC + PKCS#7 with a random 16-byte key and IV.
// - sessionKey = base64(iv) + ':' + base64(RSA-2048 PKCS#1 v1.5 privateEncrypt(aesKey)).
// - Zip checksum = sha256 of the DECRYPTED zip; with a public key it is sent as
//   hex(privateEncrypt(raw sha256 bytes)).
// - Manifest: every file is AES-encrypted with the version's session key and its
//   file_hash is hex(privateEncrypt(raw sha256 of the plaintext file)).
import crypto from 'node:crypto';
import { createReadStream, createWriteStream, existsSync } from 'node:fs';
import { copyFile, mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { benchJs, indexHtml } from './app-template.mjs';
import {
  builtinPadDir,
  builtinPadFileBytes,
  builtinPadFiles,
  builtinPadIndex,
  deviceBaseUrl,
  keysDir,
  manifestTmpDir,
} from './config.mjs';

export async function ensureKeys() {
  const privPath = path.join(keysDir, 'private.pem');
  const pubPath = path.join(keysDir, 'public.pem');
  if (!existsSync(privPath) || !existsSync(pubPath)) {
    await mkdir(keysDir, { recursive: true });
    const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', {
      modulusLength: 2048,
      publicKeyEncoding: { type: 'pkcs1', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs1', format: 'pem' },
    });
    await writeFile(privPath, privateKey);
    await writeFile(pubPath, publicKey);
  }
  return {
    privateKey: (await readFile(privPath, 'utf8')).trim(),
    publicKey: (await readFile(pubPath, 'utf8')).trim(),
  };
}

export function rsaPrivateEncrypt(privateKey, buf) {
  return crypto.privateEncrypt({ key: privateKey, padding: crypto.constants.RSA_PKCS1_PADDING }, buf);
}

export function newSession(privateKey) {
  const key = crypto.randomBytes(16);
  const iv = crypto.randomBytes(16);
  const sessionKey = `${iv.toString('base64')}:${rsaPrivateEncrypt(privateKey, key).toString('base64')}`;
  return { key, iv, sessionKey };
}

export function encryptBuffer(session, buf) {
  // Capgo CLI bundle format (AES-128-CBC); test fixture only.
  const cipher = crypto.createCipheriv('aes-128-cbc', session.key, session.iv); // NOSONAR
  return Buffer.concat([cipher.update(buf), cipher.final()]);
}

export async function encryptFileTo(session, src, dest) {
  // Capgo CLI bundle format (AES-128-CBC); test fixture only.
  const cipher = crypto.createCipheriv('aes-128-cbc', session.key, session.iv); // NOSONAR
  await pipeline(createReadStream(src, { highWaterMark: 1024 * 1024 }), cipher, createWriteStream(dest));
}

export function encryptedChecksum(privateKey, sha256Hex) {
  return rsaPrivateEncrypt(privateKey, Buffer.from(sha256Hex, 'hex')).toString('hex');
}

export async function sha256File(file) {
  const hash = crypto.createHash('sha256');
  await pipeline(createReadStream(file, { highWaterMark: 1024 * 1024 }), hash);
  return hash.digest('hex');
}

/** Write `bytes` of random data to `file` and return its sha256. */
export async function writeRandomFile(file, bytes) {
  await mkdir(path.dirname(file), { recursive: true });
  const hash = crypto.createHash('sha256');
  const out = createWriteStream(file);
  let left = bytes;
  const chunkSize = 4 * 1024 * 1024;
  while (left > 0) {
    const n = Math.min(chunkSize, left);
    const chunk = crypto.randomBytes(n);
    hash.update(chunk);
    if (!out.write(chunk)) {
      await new Promise((resolve) => out.once('drain', resolve));
    }
    left -= n;
  }
  await new Promise((resolve, reject) => out.end((err) => (err ? reject(err) : resolve())));
  return hash.digest('hex');
}

/** Split `bytes` into `count` near-equal file sizes. */
export function splitSizes(bytes, count) {
  const base = Math.floor(bytes / count);
  const sizes = Array.from({ length: count }, () => base);
  sizes[sizes.length - 1] += bytes - base * count;
  return sizes;
}

export function padFileName(i, prefix = 'pad') {
  const dir = String(Math.floor(i / 100)).padStart(2, '0');
  return `${prefix}/d${dir}/f${String(i).padStart(4, '0')}.bin`;
}

/** Random files for the app's builtin public/bpad (generated once, reused by every build). */
export async function ensureBuiltinPad() {
  if (existsSync(builtinPadIndex)) {
    const index = JSON.parse(await readFile(builtinPadIndex, 'utf8'));
    if (index.files?.length === builtinPadFiles && index.fileBytes === builtinPadFileBytes) return index;
  }
  await rm(builtinPadDir, { recursive: true, force: true });
  const files = [];
  for (let i = 0; i < builtinPadFiles; i += 1) {
    const name = padFileName(i, 'bpad');
    const hash = await writeRandomFile(path.join(builtinPadDir, name), builtinPadFileBytes);
    files.push({ name, hash, size: builtinPadFileBytes });
  }
  const index = { fileBytes: builtinPadFileBytes, files };
  await writeFile(builtinPadIndex, JSON.stringify(index));
  return index;
}

/** Write index.html + bench.js (+ random padding) into `dir`. */
export async function writeBundleTree(dir, { marker, bytes = 0, files = 0 }) {
  await rm(dir, { recursive: true, force: true });
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, 'index.html'), indexHtml(marker));
  await writeFile(path.join(dir, 'bench.js'), benchJs(marker));
  const entries = [];
  if (files > 0) {
    const sizes = splitSizes(bytes, files);
    for (let i = 0; i < files; i += 1) {
      const name = padFileName(i);
      const hash = await writeRandomFile(path.join(dir, name), sizes[i]);
      entries.push({ name, hash, size: sizes[i] });
    }
  }
  return entries;
}

export function encodePath(rel) {
  return rel
    .split('/')
    .map((s) => encodeURIComponent(s))
    .join('/');
}

/**
 * Generate a manifest version on disk (served under /m/<version>/...).
 * index.html, bench.js and `files - reuse.names.length` padding files get fresh
 * random content. `reuse` copies files (same name, same bytes) from `reuse.srcDir`
 * so the device can take them from its delta cache or builtin assets instead of
 * downloading them. `keepPlain` keeps a plaintext copy (returned as plainRoot) so a
 * later version can reuse its files.
 */
export async function createManifestVersion({ version, files, bytes, variant, keys, reuse = null, keepPlain = false }) {
  const plainDir = path.join(manifestTmpDir, `${version}.plain`);
  const serveDir = path.join(manifestTmpDir, version);
  const reusedNames = reuse?.names ?? [];
  const newCount = files - reusedNames.length;
  const newStart = reuse?.newStart ?? 0;
  await writeBundleTree(plainDir, { marker: version });
  const sizes = splitSizes(Math.round((bytes * newCount) / files), Math.max(newCount, 1));
  const newNames = [];
  for (let i = 0; i < newCount; i += 1) {
    const name = padFileName(newStart + i);
    await writeRandomFile(path.join(plainDir, name), sizes[i]);
    newNames.push(name);
  }
  if (reuse) {
    for (const name of reusedNames) {
      await mkdir(path.dirname(path.join(plainDir, name)), { recursive: true });
      await copyFile(path.join(reuse.srcDir, name), path.join(plainDir, name));
    }
  }
  const names = ['index.html', 'bench.js', ...reusedNames, ...newNames];
  const session = variant === 'enc' ? newSession(keys.privateKey) : null;
  const manifest = [];
  let servedBytes = 0;
  if (session) {
    await rm(serveDir, { recursive: true, force: true });
  }
  for (const name of names) {
    const src = path.join(plainDir, name);
    const hash = await sha256File(src);
    if (session) {
      const dest = path.join(serveDir, name);
      await mkdir(path.dirname(dest), { recursive: true });
      await writeFile(dest, encryptBuffer(session, await readFile(src)));
      servedBytes += (await stat(dest)).size;
    } else {
      servedBytes += (await stat(src)).size;
    }
    manifest.push({
      file_name: name,
      file_hash: session ? encryptedChecksum(keys.privateKey, hash) : hash,
      download_url: `${deviceBaseUrl}/m/${encodePath(version)}/${encodePath(name)}`,
    });
  }
  let plainRoot = null;
  if (session) {
    if (keepPlain) plainRoot = plainDir;
    else await rm(plainDir, { recursive: true, force: true });
  } else {
    await rm(serveDir, { recursive: true, force: true });
    await rename(plainDir, serveDir);
    plainRoot = keepPlain ? serveDir : null;
  }
  return {
    manifest,
    sessionKey: session?.sessionKey,
    servedBytes,
    fileCount: names.length,
    expectedDownloads: names.length - reusedNames.length,
    plainRoot,
  };
}

export async function removeManifestVersion(version) {
  await rm(path.join(manifestTmpDir, version), { recursive: true, force: true });
  await rm(path.join(manifestTmpDir, `${version}.plain`), { recursive: true, force: true });
}
