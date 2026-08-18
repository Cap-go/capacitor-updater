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

// Test-only RSA key so regenerate:rsa-contract is reproducible. Not used in production.
const privateKey = `-----BEGIN RSA PRIVATE KEY-----
MIIEpQIBAAKCAQEAsv0A3reP1v+pBU0ZD/ZlXAGckXJ6LFzXQuXzOkN8vDptsPiB
kJBdORet953EtayZpx8lzAH7BhU+eByN2PCfzFUTpiD/jFh3lv1S3JUP/JUGAixT
MF4D6J2rtxUOKyWjRPa/A0fM/M8IbPqeSfOtEEZaWjyBVajAIYIXO9XeaxfV5U9t
D6g/mbH0SArDvbgwOOXUARW3UQ30u9qB5cC08dVC4DZywRdn885AyPSjefQ8t7if
qUtcOZ4iUmrhrOPBh0UH1OcOCC+M9Gso7wTKRt7E03ZKhY+4SKuTxCsINgOd3YSi
JPYlrUEpSpdjYfxnbsGe1hI8oPHAgJMihZX+AwIDAQABAoIBAFL6pl+afC3xortZ
begPlBgeiyaHCwrsE8Po9WUqinZ9JANqgi6yLvXb+4QTeXG8ThPDhfNZa7X7PVXT
7xMHIx5Ixu462B6JmQ+/651l4d54fCufvwVqYKeECWq8cTAhp9q+BfoQXIFLvh0/
5whj1vT3mMXCzTcYH9KpC/pqgU3mHWKp8Kb5i5olZFunrfSx8lpO5nW5N5QqWWpd
yDMgw/aqyQhzalXUh1JE1xgrG6PA1emTtRG+WuksQvhyYccT+5vbHAYxzFk7xaTz
7+DQy3Z/MGwyWylGNQ6B5n5cEVhhmtEn1hTjnv3W1mxq88IXNafnk1Y1YG8K4XpJ
7Gp3fHECgYEA3cD1pp0Be32MUwYP0waFDOJEpUtrH0aSd85rZ9e2s6rdck+cmpXz
MIKSlq3DkWwqpfan20CzydW2C9tA0BrY94zGDdVYE62XqiLgJNFp38/C4xJL505M
FFIHC4p5gDp+JL/Sh143XyF2aWdmeDvHskzm0GaeQnMGxNN8xRq3qakCgYEAzqFP
eerX4iaAlxiKwShO28A+k+OupOdjwZMXXjHbd/4aqGOJQ6mQEtE1p2J2qRhkOKkB
NTNSIS1fo8ScaazA+18nDgHEfmtGejCQXAPq8QJ3LyIug18oOGK8uPUyGjdeuKpG
KyZhUWg+wNZheYkvAWSTjlv3dt5klFDbBlV57csCgYEAiGJr8xwvVDckPc/FncEt
xX3IQG1BJgwuexbuggBu8tOMvQhvxbehyV0VMS0P0fnXxRkNpdCGgwU4oNQpaZSJ
ir7+9HUZZYjndZFbj+loF2ndb/DJ1CoYqorEoHl7Pr065flAT1dH8O9Qt4ULxbjm
mien8dabUT0TlayI2WUUPnkCgYEAvQiuYOcMIYT/1ztIlXV+z2OM3FdLiul1Rb5/
flk2YwxA7xRAm3ogqFZlM4DM9d2usndK95S/6kJMYNKaFcNJua5PWG0dilox289a
AhRDd8G9r40h6GXBsfQCm2MWNw24xlBgaVFvbr5jyp9WBY4PRsLwiyhvuHu0oEto
VN8V8QkCgYEAoXVod6XM+kc9tbqx4CcuGBSXiqB32NLllv9X1HZGxyLxSKBbA7zM
DeRpsaHpS11Mdxh8Rqx/gFbfvlT0C0i45CJU7rZtFdlvN7xhIEJMCb2ymdxmX7qo
yWP9MBFaiO4ZfWNJ0QIqBNnUUCEUBz4XLBrk6Vp4vdpxjjL1YOxPeQU=
-----END RSA PRIVATE KEY-----
`;

const publicKey = crypto.createPublicKey(privateKey).export({ type: 'pkcs1', format: 'pem' });

function privateEncrypt(plaintext) {
  return crypto.privateEncrypt({ key: privateKey, padding: crypto.constants.RSA_PKCS1_PADDING }, plaintext);
}

function toHex(buffer) {
  return buffer.toString('hex');
}

const sessionKeyPlaintext = Buffer.alloc(16, 0xab);
const checksumPlaintext = Buffer.from('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'hex');

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
