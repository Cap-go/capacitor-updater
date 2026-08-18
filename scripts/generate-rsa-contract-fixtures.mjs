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
};

fs.writeFileSync(outputPath, `${JSON.stringify(fixture, null, 2)}\n`);
console.log(`Wrote ${outputPath}`);
