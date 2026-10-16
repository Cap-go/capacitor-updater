#!/usr/bin/env bun
/**
 * Generates native-contract-tests/crypto-rsa.json using Node.js crypto.privateEncrypt,
 * matching Capgo bundle encryption (RSA PKCS#1 + public decrypt on device).
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const outputPath = path.join(root, 'native-contract-tests', 'crypto-rsa.json');

const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'pkcs1', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs1', format: 'pem' },
});

function privateEncrypt(plaintext) {
  return crypto.privateEncrypt(
    { key: privateKey, padding: crypto.constants.RSA_PKCS1_PADDING },
    plaintext,
  );
}

function toHex(buffer) {
  return buffer.toString('hex');
}

const sessionKeyPlaintext = Buffer.alloc(16, 0xab);
const checksumPlaintext = Buffer.from(
  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  'hex',
);

const sessionKeyCiphertext = privateEncrypt(sessionKeyPlaintext);
const checksumCiphertext = privateEncrypt(checksumPlaintext);

if (sessionKeyCiphertext.length !== 256 || checksumCiphertext.length !== 256) {
  throw new Error(`Expected 256-byte RSA ciphertext, got ${sessionKeyCiphertext.length}`);
}

const cleanedKey = publicKey
  .replace(/-----BEGIN RSA PUBLIC KEY-----/g, '')
  .replace(/-----END RSA PUBLIC KEY-----/g, '')
  .replace(/\s+/g, '');

// Signed bundle metadata (Capgo CLI >= 8.53.0): sha256(payload) signed with privateEncrypt, hex encoded.
function sha256(text) {
  return crypto.createHash('sha256').update(Buffer.from(text, 'utf8')).digest();
}

function buildBundleSignaturePayload(version, checksumHex) {
  return `capgo-bundle-v1\nversion:${version}\nchecksum:${checksumHex.toLowerCase()}\n`;
}

function buildManifestSignaturePayload(version, entries) {
  const sorted = [...entries].sort((a, b) => Buffer.compare(Buffer.from(a.file_name, 'utf8'), Buffer.from(b.file_name, 'utf8')));
  let payload = `capgo-manifest-v1\nversion:${version}\n`;
  for (const entry of sorted) {
    payload += `${entry.file_name}:${entry.hashHex.toLowerCase()}\n`;
  }
  return payload;
}

function sign(payload) {
  return toHex(privateEncrypt(sha256(payload)));
}

const bundleVersion = '1.2.3';
const bundleChecksumHex = toHex(checksumPlaintext);
const bundlePayload = buildBundleSignaturePayload(bundleVersion, bundleChecksumHex);
const bundleSignatureHex = sign(bundlePayload);
// Unsorted on purpose: the plugin must sort by UTF-8 bytes (uppercase before lowercase, 'é' after ASCII).
const manifestEntries = [
  { file_name: 'index.html', hashHex: 'a'.repeat(64) },
  { file_name: 'Assets/logo.png', hashHex: 'b'.repeat(64) },
  { file_name: 'assets/app.js.br', hashHex: 'c'.repeat(64) },
  { file_name: 'assets/\u00e9t\u00e9.js', hashHex: 'd'.repeat(64) },
];
const manifestPayload = buildManifestSignaturePayload(bundleVersion, manifestEntries);
const manifestSignatureHex = sign(manifestPayload);
const manifestEntriesEncrypted = manifestEntries.map((entry) => ({
  file_name: entry.file_name,
  file_hash: toHex(privateEncrypt(Buffer.from(entry.hashHex, 'hex'))),
}));

const bundleSignatureCases = [
  {
    id: 'valid',
    input: { version: bundleVersion, checksumHex: bundleChecksumHex, encryptedChecksumHex: toHex(checksumCiphertext), signatureHex: bundleSignatureHex },
    expect: { payload: bundlePayload, valid: true },
  },
  {
    id: 'tampered-version',
    input: { version: '1.2.4', checksumHex: bundleChecksumHex, encryptedChecksumHex: toHex(checksumCiphertext), signatureHex: bundleSignatureHex },
    expect: { payload: buildBundleSignaturePayload('1.2.4', bundleChecksumHex), valid: false },
  },
  {
    id: 'wrong-length-signature',
    input: { version: bundleVersion, checksumHex: bundleChecksumHex, encryptedChecksumHex: toHex(checksumCiphertext), signatureHex: bundleSignatureHex.slice(0, 510) },
    expect: { payload: bundlePayload, valid: false },
  },
];

const manifestSignatureCases = [
  {
    id: 'valid-unsorted-input',
    input: { version: bundleVersion, entries: manifestEntries, encryptedEntries: manifestEntriesEncrypted, signatureHex: manifestSignatureHex },
    expect: { payload: manifestPayload, valid: true },
  },
  {
    id: 'dropped-entry',
    input: { version: bundleVersion, entries: manifestEntries.slice(1), encryptedEntries: manifestEntriesEncrypted.slice(1), signatureHex: manifestSignatureHex },
    expect: { payload: buildManifestSignaturePayload(bundleVersion, manifestEntries.slice(1)), valid: false },
  },
  {
    id: 'renamed-entry',
    input: {
      version: bundleVersion,
      entries: [{ ...manifestEntries[0], file_name: 'index2.html' }, ...manifestEntries.slice(1)],
      encryptedEntries: [{ ...manifestEntriesEncrypted[0], file_name: 'index2.html' }, ...manifestEntriesEncrypted.slice(1)],
      signatureHex: manifestSignatureHex,
    },
    expect: { payload: buildManifestSignaturePayload(bundleVersion, [{ ...manifestEntries[0], file_name: 'index2.html' }, ...manifestEntries.slice(1)]), valid: false },
  },
];

const fixture = {
  version: 1,
  description:
    'RSA public-decrypt contract vectors generated with crypto.privateEncrypt (PKCS#1), matching Capgo CLI encryption.',
  publicKeyPem: publicKey.trim(),
  rsaPublicDecrypt: [
    {
      id: 'session-key-16-bytes',
      input: { ciphertextHex: toHex(sessionKeyCiphertext) },
      expect: { plaintextHex: toHex(sessionKeyPlaintext) },
    },
    {
      id: 'checksum-sha256-32-bytes',
      input: { ciphertextHex: toHex(checksumCiphertext) },
      expect: { plaintextHex: toHex(checksumPlaintext) },
    },
  ],
  decryptChecksum: [
    {
      id: 'hex-encoded-rsa-ciphertext',
      input: { checksumHex: toHex(checksumCiphertext) },
      expect: { decryptedHex: toHex(checksumPlaintext) },
    },
  ],
  calcKeyId: [
    {
      id: 'fixture-public-key',
      input: { publicKeyPem: publicKey.trim() },
      expect: { keyId: cleanedKey.slice(0, 20) },
    },
  ],
  rsaPublicKeyLoad: [
    {
      id: 'valid-pkcs1-pem',
      input: { publicKeyPem: publicKey.trim() },
      expect: { loads: true },
    },
    {
      id: 'invalid-pem',
      input: { publicKeyPem: 'not-a-key' },
      expect: { loads: false },
    },
  ],
  decryptChecksumInvalid: [
    {
      id: 'wrong-size-255-bytes',
      input: { checksumHex: '00'.repeat(255) },
      expect: { throws: true },
    },
  ],
  bundleSignature: bundleSignatureCases,
  manifestSignature: manifestSignatureCases,
};

fs.writeFileSync(outputPath, `${JSON.stringify(fixture, null, 2)}\n`);
console.log(`Wrote ${outputPath}`);
