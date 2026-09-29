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

// Version-bound signed checksum (must match the Capgo CLI):
// payload = SHA-256(content) || SHA-256(binding context)
const signedBindingDomain = 'capgo-signed-checksum-v1';

function bundleBindingContext(version) {
  return `${signedBindingDomain}\0bundle\0${version}`;
}

function manifestFileBindingContext(version, fileName) {
  const name = fileName.endsWith('.br') ? fileName.slice(0, -3) : fileName;
  return `${signedBindingDomain}\0file\0${version}\0${name}`;
}

function boundChecksum(bindingContext) {
  const bindingHash = crypto.createHash('sha256').update(bindingContext, 'utf8').digest();
  return privateEncrypt(Buffer.concat([checksumPlaintext, bindingHash]));
}

const signedVersion = '1.0.0';
const signedFileName = 'assets/index.js';
const boundBundleCiphertext = boundChecksum(bundleBindingContext(signedVersion));
const boundFileCiphertext = boundChecksum(manifestFileBindingContext(signedVersion, signedFileName));

const sessionKeyCiphertext = privateEncrypt(sessionKeyPlaintext);
const checksumCiphertext = privateEncrypt(checksumPlaintext);

if (sessionKeyCiphertext.length !== 256 || checksumCiphertext.length !== 256) {
  throw new Error(`Expected 256-byte RSA ciphertext, got ${sessionKeyCiphertext.length}`);
}

const cleanedKey = publicKey
  .replace(/-----BEGIN RSA PUBLIC KEY-----/g, '')
  .replace(/-----END RSA PUBLIC KEY-----/g, '')
  .replace(/\s+/g, '');

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
    {
      id: 'bound-payload-returns-content-hash',
      input: { checksumHex: toHex(boundBundleCiphertext) },
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
  bindingContext: [
    {
      id: 'bundle',
      input: { kind: 'bundle', version: signedVersion },
      expect: { contextHex: toHex(Buffer.from(bundleBindingContext(signedVersion), 'utf8')) },
    },
    {
      id: 'manifest-file',
      input: { kind: 'file', version: signedVersion, fileName: signedFileName },
      expect: { contextHex: toHex(Buffer.from(manifestFileBindingContext(signedVersion, signedFileName), 'utf8')) },
    },
    {
      id: 'manifest-file-brotli-suffix-stripped',
      input: { kind: 'file', version: signedVersion, fileName: `${signedFileName}.br` },
      expect: { contextHex: toHex(Buffer.from(manifestFileBindingContext(signedVersion, signedFileName), 'utf8')) },
    },
  ],
  decryptBoundChecksum: [
    {
      id: 'bundle-bound-matching-version',
      input: { checksumHex: toHex(boundBundleCiphertext), kind: 'bundle', version: signedVersion, requireBinding: true },
      expect: { throws: false, decryptedHex: toHex(checksumPlaintext) },
    },
    {
      id: 'bundle-bound-replayed-under-other-version',
      input: { checksumHex: toHex(boundBundleCiphertext), kind: 'bundle', version: '3.0.0', requireBinding: false },
      expect: { throws: true },
    },
    {
      id: 'bundle-bound-used-as-manifest-file',
      input: {
        checksumHex: toHex(boundBundleCiphertext),
        kind: 'file',
        version: signedVersion,
        fileName: signedFileName,
        requireBinding: false,
      },
      expect: { throws: true },
    },
    {
      id: 'file-bound-matching-version-and-brotli-name',
      input: {
        checksumHex: toHex(boundFileCiphertext),
        kind: 'file',
        version: signedVersion,
        fileName: `${signedFileName}.br`,
        requireBinding: true,
      },
      expect: { throws: false, decryptedHex: toHex(checksumPlaintext) },
    },
    {
      id: 'file-bound-other-file-name',
      input: {
        checksumHex: toHex(boundFileCiphertext),
        kind: 'file',
        version: signedVersion,
        fileName: 'assets/other.js',
        requireBinding: false,
      },
      expect: { throws: true },
    },
    {
      id: 'file-bound-replayed-under-other-version',
      input: {
        checksumHex: toHex(boundFileCiphertext),
        kind: 'file',
        version: '3.0.0',
        fileName: signedFileName,
        requireBinding: false,
      },
      expect: { throws: true },
    },
    {
      id: 'legacy-unbound-accepted-by-default',
      input: { checksumHex: toHex(checksumCiphertext), kind: 'bundle', version: '3.0.0', requireBinding: false },
      expect: { throws: false, decryptedHex: toHex(checksumPlaintext) },
    },
    {
      id: 'legacy-unbound-rejected-when-required',
      input: { checksumHex: toHex(checksumCiphertext), kind: 'bundle', version: '3.0.0', requireBinding: true },
      expect: { throws: true },
    },
  ],
  decryptChecksumInvalid: [
    {
      id: 'wrong-size-255-bytes',
      input: { checksumHex: '00'.repeat(255) },
      expect: { throws: true },
    },
  ],
};

fs.writeFileSync(outputPath, `${JSON.stringify(fixture, null, 2)}\n`);
console.log(`Wrote ${outputPath}`);
