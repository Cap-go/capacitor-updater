#!/usr/bin/env bun
/**
 * Generates the deterministic parts of the shared updater core contract:
 * - native-contract-tests/policy.json    (update policy + HTTP helper decisions)
 * - native-contract-tests/security.json  (path, cache and bundle-id guards)
 * - native-contract-tests/crypto.json    (session keys, checksums, AES bundle decryption)
 *
 * Every native implementation (Rust core, Android, iOS, and any future host)
 * must return exactly `expect` for each `input`. Expected values are written
 * here by hand from the behavior shipped by the Android and iOS plugins, so a
 * regeneration never silently changes the contract.
 *
 * crypto.json embeds a freshly generated RSA key pair each run, like
 * crypto-rsa.json. Commit the regenerated file together with any change.
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const outDir = path.join(root, 'native-contract-tests');
const only = process.argv.slice(2);

const sha256Hex = (value) => crypto.createHash('sha256').update(value).digest('hex');
const shortPathKey = (value) => sha256Hex(Buffer.from(value, 'utf8')).slice(0, 16);
const EMPTY_SHA256 = sha256Hex(Buffer.alloc(0));
const HASH_A = sha256Hex(Buffer.from('capgo-a'));

function write(name, fixture) {
  if (only.length > 0 && !only.includes(name)) {
    return;
  }
  const outputPath = path.join(outDir, `${name}.json`);
  fs.writeFileSync(outputPath, `${JSON.stringify(fixture, null, 2)}\n`);
  console.log(`Wrote ${outputPath}`);
}

// ---------------------------------------------------------------- policy.json

const NOW_MS = 1_700_000_000_000;
const DAY_MS = 24 * 60 * 60 * 1000;

const policy = {
  version: 1,
  description:
    'Update policy and HTTP helper decisions shared by every updater host. Group names are the core operation names.',
  legacyDirectUpdateAutoMode: [
    ['false', 'atBackground'],
    ['atInstall', 'atInstall'],
    ['onLaunch', 'onLaunch'],
    ['always', 'always'],
    ['onlyDownload', 'atBackground'],
    ['atBackground', 'atBackground'],
    ['garbage', 'atBackground'],
  ].map(([directUpdateMode, mode]) => ({
    id: `legacy-direct-update.${directUpdateMode}`,
    input: { directUpdateMode },
    expect: { mode },
  })),
  isDirectUpdateMode: [
    ['atInstall', true],
    ['onLaunch', true],
    ['always', true],
    ['false', false],
    ['atBackground', false],
    ['onlyDownload', false],
    ['off', false],
    ['', false],
  ].map(([directUpdateMode, direct]) => ({
    id: `direct-update-mode.${directUpdateMode || 'empty'}`,
    input: { directUpdateMode },
    expect: { direct },
  })),
  shakeMenuGesture: [
    ['missing', null, 'shake', true],
    ['empty', '', 'shake', false],
    ['blank', '   ', 'shake', false],
    ['shake', 'shake', 'shake', true],
    ['three-finger-pinch', 'threeFingerPinch', 'threeFingerPinch', true],
    ['three-finger-pinch.padded', '  threeFingerPinch\n', 'threeFingerPinch', true],
    ['unknown', 'pinch', 'shake', false],
    ['case-sensitive', 'Shake', 'shake', false],
  ].map(([id, value, gesture, supported]) => ({
    id: `shake-gesture.${id}`,
    input: { value },
    expect: { gesture, supported },
  })),
  webViewErrorStatsAction: [
    ['unhandled_rejection', 'webview_unhandled_rejection'],
    ['resource_error', 'webview_resource_error'],
    ['security_policy_violation', 'webview_security_policy_violation'],
    ['webview_unclean_restart', 'webview_unclean_restart'],
    ['render_process_gone', 'webview_render_process_gone'],
    ['web_content_process_terminated', 'webview_content_process_terminated'],
    ['webview_dom_content_loaded', 'webview_dom_content_loaded'],
    ['webview_page_loaded', 'webview_page_loaded'],
    ['javascript_error', 'webview_javascript_error'],
    ['something_else', 'webview_javascript_error'],
    ['', 'webview_javascript_error'],
  ].map(([type, action]) => ({
    id: `webview-error.${type || 'empty'}`,
    input: { type },
    expect: { action },
  })),
  launchDownloadReady: [
    ['awaited', true, true, false, false, true, false, 'update downloaded, will install next background'],
    ['awaited-failure', true, false, false, false, true, false, 'Error downloading file'],
    ['failure', false, false, false, false, true, true, 'Error downloading file'],
    ['failure-direct', false, false, true, false, true, true, 'Error downloading file'],
    ['direct-install', false, true, true, false, true, false, 'update downloaded, will install next background'],
    ['preview-session', false, true, false, true, true, false, 'update downloaded, will install next background'],
    ['set-next', false, true, false, false, true, true, 'update downloaded, will install next background'],
    ['only-download', false, true, false, false, false, true, 'update downloaded, autoUpdate onlyDownload'],
  ].map(([id, awaitedByCaller, success, directInstall, previewSession, setNext, notify, status]) => ({
    id: `launch-download-ready.${id}`,
    input: { awaitedByCaller, success, directInstall, previewSession, setNext },
    expect: { notify, status },
  })),
  foreignBundleReset: [
    ['missing-path', null, false, false, false],
    ['empty-path', '', false, false, false],
    ['blank-path', ' \n\t', false, false, false],
    ['builtin', '/data/public', true, false, false],
    ['stored', '/data/versions/abc', false, true, false],
    ['foreign', '/data/versions/abc', false, false, true],
  ].map(([id, bundlePath, isBuiltin, hasStoredBundleInfo, reset]) => ({
    id: `foreign-bundle.${id}`,
    input: { bundlePath, isBuiltin, hasStoredBundleInfo },
    expect: { reset },
  })),
  clearPersistedDefaultChannel: [false, true].flatMap((persistDefaultChannelOnReinstall) =>
    [false, true].flatMap((resetWhenUpdate) =>
      [false, true].flatMap((nativeBuildVersionChanged) =>
        [false, true].map((restoredReinstall) => ({
          id: `clear-default-channel.persist-${persistDefaultChannelOnReinstall}.reset-${resetWhenUpdate}.native-${nativeBuildVersionChanged}.restored-${restoredReinstall}`,
          input: { persistDefaultChannelOnReinstall, resetWhenUpdate, nativeBuildVersionChanged, restoredReinstall },
          expect: {
            clear: !persistDefaultChannelOnReinstall && (restoredReinstall || (resetWhenUpdate && nativeBuildVersionChanged)),
          },
        })),
      ),
    ),
  ),
  manifestConcurrency: [
    [-3, 8],
    [0, 8],
    [1, 8],
    [4, 8],
    [5, 10],
    [8, 16],
    [32, 64],
    [128, 64],
  ].map(([processorCount, maxConcurrentFiles]) => ({
    id: `manifest-concurrency.${processorCount}`,
    input: { processorCount },
    expect: { maxConcurrentFiles },
  })),
  userAgent: [
    ['android', 'app.capgo.demo', '8.1.0', '14', 'android', 'CapacitorUpdater/8.1.0 (app.capgo.demo) android/14'],
    ['ios', 'app.capgo.demo', '8.1.0', '18.2', 'ios', 'CapacitorUpdater/8.1.0 (app.capgo.demo) ios/18.2'],
    ['empty-values', '', '', '', 'android', 'CapacitorUpdater/unknown (unknown) android/unknown'],
    ['trimmed', '  app.id  ', ' 1.0 ', ' 17 ', 'ios', 'CapacitorUpdater/1.0 (app.id) ios/17'],
    ['latin1-kept', 'app.café', '1.0', '17', 'ios', 'CapacitorUpdater/1.0 (app.café) ios/17'],
    ['control-and-emoji-dropped', 'app\u0007.id\u{1F680}', '1.0\n', '17', 'android', 'CapacitorUpdater/1.0 (app.id) android/17'],
    ['only-invalid', '\u{1F680}', '1.0', '17', 'android', 'CapacitorUpdater/1.0 (unknown) android/17'],
  ].map(([id, appId, pluginVersion, versionOs, platform, userAgent]) => ({
    id: `user-agent.${id}`,
    input: { appId, pluginVersion, versionOs, platform },
    expect: { userAgent },
  })),
  retryableHttpStatus: [
    [200, false],
    [404, false],
    [408, true],
    [429, true],
    [499, false],
    [500, true],
    [503, true],
  ].map(([status, retryable]) => ({
    id: `retryable-status.${status}`,
    input: { status },
    expect: { retryable },
  })),
  contentRange: [
    ['full', 'bytes 0-99/100', { start: 0, end: 99, total: 100 }],
    ['unknown-total', 'bytes 100-199/*', { start: 100, end: 199, total: -1 }],
    ['padded', '  bytes 0-9/10  ', { start: 0, end: 9, total: 10 }],
    ['inner-spaces', 'bytes  0 - 9 / 10', { start: 0, end: 9, total: 10 }],
    ['missing', null, null],
    ['empty', '', null],
    ['wrong-unit', 'items 0-1/2', null],
    ['reversed', 'bytes 5-3/10', null],
    ['not-numeric', 'bytes a-b/10', null],
    ['no-total', 'bytes 0-99', null],
  ].map(([id, header, range]) => ({
    id: `content-range.${id}`,
    input: { header },
    expect: { range },
  })),
  zipResumePlan: [
    ['partial-matches', 206, 100, 'bytes 100-199/200', { responseCode: 206, writeOffset: 100 }],
    ['partial-restarts', 206, 100, 'bytes 0-199/200', { responseCode: 200, writeOffset: 0 }],
    ['partial-mismatch', 206, 100, 'bytes 50-199/200', { error: 'invalid_content_range' }],
    ['partial-missing-range', 206, 100, null, { error: 'invalid_content_range' }],
    ['full-after-partial', 200, 100, null, { responseCode: 200, writeOffset: 0 }],
    ['full-fresh', 200, 0, null, { responseCode: 200, writeOffset: 0 }],
    ['other-status', 404, 50, null, { responseCode: 404, writeOffset: 50 }],
  ].map(([id, responseCode, downloadedBytes, contentRange, expect]) => ({
    id: `zip-resume.${id}`,
    input: { responseCode, downloadedBytes, contentRange },
    expect,
  })),
  appendHttpBody: [
    [206, 10, true],
    [206, 0, false],
    [200, 10, false],
    [416, 10, false],
  ].map(([statusCode, existingBytes, append]) => ({
    id: `append-http-body.${statusCode}.${existingBytes}`,
    input: { statusCode, existingBytes },
    expect: { append },
  })),
  rateLimitDeadline: [
    ['header-seconds', '30', null, NOW_MS + 30_000],
    ['header-padded', ' 30 ', null, NOW_MS + 30_000],
    ['header-fraction', '1.5', null, NOW_MS + 1_500],
    ['header-zero', '0', null, 0],
    ['header-negative-no-body', '-5', null, 0],
    ['header-http-date', 'Wed, 21 Oct 2015 07:28:00 GMT', null, 0],
    ['header-invalid-body-more-info', 'abc', JSON.stringify({ moreInfo: { retryAfterSeconds: 10 } }), NOW_MS + 10_000],
    ['body-top-level', null, JSON.stringify({ retryAfterSeconds: 5 }), NOW_MS + 5_000],
    ['body-more-info-wins', null, JSON.stringify({ moreInfo: { retryAfterSeconds: 7 }, retryAfterSeconds: 99 }), NOW_MS + 7_000],
    ['body-reset-at', null, JSON.stringify({ moreInfo: { rateLimitResetAt: NOW_MS + 60_000 } }), NOW_MS + 60_000],
    ['body-top-level-reset-at', null, JSON.stringify({ rateLimitResetAt: NOW_MS + 45_000 }), NOW_MS + 45_000],
    ['body-reset-in-past', null, JSON.stringify({ rateLimitResetAt: NOW_MS - 1_000 }), 0],
    ['body-negative-retry-uses-reset', null, JSON.stringify({ moreInfo: { retryAfterSeconds: -1 }, rateLimitResetAt: NOW_MS + 5_000 }), NOW_MS + 5_000],
    ['capped-at-one-day', null, JSON.stringify({ retryAfterSeconds: 999_999 }), NOW_MS + DAY_MS],
    ['body-not-json', null, 'not json', 0],
    ['no-hint', null, null, 0],
  ].map(([id, retryAfter, body, blockedUntilMs]) => ({
    id: `rate-limit.${id}`,
    input: { retryAfter, body, nowMs: NOW_MS },
    expect: { blockedUntilMs },
  })),
  remoteError: [
    ['both', JSON.stringify({ error: 'too_many_requests', message: 'Slow down' }), 'too_many_requests', 'Slow down'],
    ['message-only', JSON.stringify({ message: 'm' }), '', 'm'],
    ['error-only', JSON.stringify({ error: 'e' }), 'e', ''],
    ['missing', null, '', ''],
    ['empty', '', '', ''],
    ['not-json', 'garbage', '', ''],
    ['array', '[]', '', ''],
  ].map(([id, body, error, message]) => ({
    id: `remote-error.${id}`,
    input: { body },
    expect: { error, message },
  })),
  bundleStatus: [
    ['success', 'success', 'success'],
    ['error', 'error', 'error'],
    ['pending', 'pending', 'pending'],
    ['deleted', 'deleted', 'deleted'],
    ['deleting', 'deleting', 'deleting'],
    ['downloading', 'downloading', 'downloading'],
    ['unknown', 'installed', null],
    ['padded', ' success ', 'success'],
    ['uppercase', 'SUCCESS', 'success'],
    ['empty', '', 'pending'],
  ].map(([id, value, status]) => ({
    id: `bundle-status.${id}`,
    input: { value },
    expect: { status },
  })),
};

// -------------------------------------------------------------- security.json

const BASE = '/capgo-contract/base';

const security = {
  version: 1,
  description:
    'Path, cache and bundle-id guards. These are security boundaries: manifest file_name, zip entries and bundle ids must never escape their root.',
  pathTraversalSegment: [
    ['a/b', false],
    ['../a', true],
    ['a/../b', true],
    ['a/..', true],
    ['..', true],
    ['..a/b', false],
    ['a..b', false],
    ['...', false],
    ['a//b', false],
    ['./a', false],
    ['a\\..\\b', false],
  ].map(([pathValue, traversal]) => ({
    id: `traversal.${pathValue}`,
    input: { path: pathValue },
    expect: { traversal },
  })),
  resolvePathInside: [
    ['file', 'index.html', { path: `${BASE}/index.html` }],
    ['nested', 'assets/app.js', { path: `${BASE}/assets/app.js` }],
    ['dot-prefix', './index.html', { path: `${BASE}/index.html` }],
    ['dot-segment', 'a/./b.js', { path: `${BASE}/a/b.js` }],
    ['trailing-slash', 'a/', { path: `${BASE}/a` }],
    ['triple-dot-name', '...', { path: `${BASE}/...` }],
    ['dotdot-prefix-name', '..hidden', { path: `${BASE}/..hidden` }],
    ['empty', '', { error: 'empty_path' }],
    ['backslash', 'a\\b', { error: 'invalid_separator' }],
    ['nul', 'a\u0000b', { error: 'invalid_separator' }],
    ['parent', '../x', { error: 'path_traversal' }],
    ['nested-parent', 'a/../../x', { error: 'path_traversal' }],
    ['inner-parent', 'a/../b', { error: 'path_traversal' }],
    ['absolute', '/etc/passwd', { error: 'absolute_path' }],
    ['tilde', '~/x', { error: 'absolute_path' }],
    ['self', '.', { error: 'escapes_base' }],
  ].map(([id, relativePath, expect]) => ({
    id: `resolve.${id}`,
    input: { base: BASE, path: relativePath },
    expect,
  })),
  manifestTargetPath: [
    ['brotli', 'a.js.br', { path: `${BASE}/a.js` }],
    ['plain', 'a.js', { path: `${BASE}/a.js` }],
    ['nested-brotli', 'dir/b.css.br', { path: `${BASE}/dir/b.css` }],
    ['only-extension', '.br', { error: 'empty_path' }],
    ['traversal', '../x.js.br', { error: 'path_traversal' }],
    ['absolute', '/x.js', { error: 'absolute_path' }],
  ].map(([id, fileName, expect]) => ({
    id: `manifest-target.${id}`,
    input: { base: BASE, fileName },
    expect,
  })),
  builtinAssetPath: [
    ['file', 'index.html', { assetPath: 'public/index.html' }],
    ['brotli', 'js/app.js.br', { assetPath: 'public/js/app.js' }],
    ['dot-prefix', './a.js', { assetPath: 'public/a.js' }],
    ['traversal', '../secret', { error: 'path_traversal' }],
    ['absolute', '/etc/hosts', { error: 'absolute_path' }],
  ].map(([id, fileName, expect]) => ({
    id: `builtin-asset.${id}`,
    input: { fileName },
    expect,
  })),
  safeCacheHash: [
    ['sha256', HASH_A, true],
    ['sha256-upper', HASH_A.toUpperCase(), true],
    ['crc32', 'deadbeef', true],
    ['too-short', HASH_A.slice(1), false],
    ['too-long', `${HASH_A}0`, false],
    ['md5-length', HASH_A.slice(0, 32), false],
    ['non-hex', 'g'.repeat(64), false],
    ['path-chars', '../../../../../../../../../../../../../../../../../../../../../..', false],
    ['empty', '', false],
    ['missing', null, false],
  ].map(([id, hash, safe]) => ({
    id: `safe-cache-hash.${id}`,
    input: { hash },
    expect: { safe },
  })),
  reusableCacheFile: [
    ['sha256-non-empty', HASH_A, 10, true],
    ['sha256-empty-file', HASH_A, 0, false],
    ['empty-sha256-empty-file', EMPTY_SHA256, 0, true],
    ['empty-sha256-upper-empty-file', EMPTY_SHA256.toUpperCase(), 0, true],
    ['crc32-never-trusted', 'deadbeef', 10, false],
    ['missing-file', HASH_A, null, false],
    ['unsafe-hash', 'g'.repeat(64), 10, false],
  ].map(([id, hash, size, reusable]) => ({
    id: `reusable-cache.${id}`,
    input: { hash, size },
    expect: { reusable },
  })),
  manifestPartialName: [
    ['sha256', HASH_A, 'assets/app.js', `partial_${HASH_A}_${shortPathKey('assets/app.js')}.tmp`],
    ['crc32', 'deadbeef', 'assets/app.js', `partial_${shortPathKey('deadbeef\u0000assets/app.js')}_${shortPathKey('assets/app.js')}.tmp`],
    ['unsafe-hash', '../../x', 'a.js', `partial_${shortPathKey('../../x\u0000a.js')}_${shortPathKey('a.js')}.tmp`],
  ].map(([id, hash, fileName, name]) => ({
    id: `partial-name.${id}`,
    input: { hash, fileName },
    expect: { name },
  })),
  shortPathKey: ['index.html', '', 'a/b/c.js', 'café/é.js'].map((value) => ({
    id: `short-path-key.${value || 'empty'}`,
    input: { value },
    expect: { key: shortPathKey(value) },
  })),
};

// ---------------------------------------------------------------- crypto.json

function buildCrypto() {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'pkcs1', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs1', format: 'pem' },
  });
  const publicKeyPem = publicKey.trim();
  const privateEncrypt = (plaintext) =>
    crypto.privateEncrypt({ key: privateKey, padding: crypto.constants.RSA_PKCS1_PADDING }, plaintext);

  const aesKey = Buffer.from('000102030405060708090a0b0c0d0e0f', 'hex');
  const iv = Buffer.from('f0e0d0c0b0a090807060504030201000', 'hex');
  const encryptedKey = privateEncrypt(aesKey);
  const sessionKey = `${iv.toString('base64')}:${encryptedKey.toString('base64')}`;
  const aesEncrypt = (plaintext) => {
    // Capgo CLI bundle format (AES-128-CBC); fixture generation only.
    const cipher = crypto.createCipheriv('aes-128-cbc', aesKey, iv); // NOSONAR
    return Buffer.concat([cipher.update(plaintext), cipher.final()]);
  };

  const small = Buffer.from('hello capgo', 'utf8');
  const multiBlock = Buffer.from(Array.from({ length: 1000 }, (_, i) => i % 251));
  const smallCipher = aesEncrypt(small);
  const multiCipher = aesEncrypt(multiBlock);
  const corrupted = Buffer.from(smallCipher);
  corrupted[corrupted.length - 1] ^= 0xff;
  const longKeySession = `${iv.toString('base64')}:${privateEncrypt(Buffer.alloc(32, 7)).toString('base64')}`;
  const shortIvSession = `${Buffer.alloc(8, 1).toString('base64')}:${encryptedKey.toString('base64')}`;
  const garbageKeySession = `${iv.toString('base64')}:${crypto.randomBytes(256).toString('base64')}`;

  const checksumPlain = Buffer.from(HASH_A, 'hex');
  const checksumCipher = privateEncrypt(checksumPlain);
  const crcCipher = privateEncrypt(Buffer.from('deadbeef', 'hex'));

  const hex = (buffer) => buffer.toString('hex');

  return {
    version: 1,
    description:
      'Session-key, checksum and AES-128-CBC bundle decryption vectors. Ciphertexts are produced like the Capgo CLI: AES key RSA privateEncrypt (PKCS#1 v1.5), bundle AES-128-CBC with PKCS#7 padding. `publicKeyPem: null` in an input means "use the fixture key".',
    publicKeyPem,
    sessionKeyValid: [
      ['valid', 'aXY=:a2V5', true],
      ['empty', '', false],
      ['colon-only', ':', false],
      ['missing-key', 'aXY=:', false],
      ['missing-iv', ':a2V5', false],
      ['three-parts', 'a:b:c', false],
      ['no-separator', 'abc', false],
    ].map(([id, value, valid]) => ({
      id: `session-key.${id}`,
      input: { sessionKey: value },
      expect: { valid },
    })),
    keyId: [
      ['fixture', publicKeyPem, publicKeyPem.replace(/-----(BEGIN|END) RSA PUBLIC KEY-----/g, '').replace(/\s+/g, '').slice(0, 20)],
      ['empty', '', ''],
      ['short', 'abc', 'abc'],
      ['crlf-and-spaces', '-----BEGIN RSA PUBLIC KEY-----\r\nMIIB CgKC\r\nAQEAqJikYizowR4jGct5\r\n-----END RSA PUBLIC KEY-----', 'MIIBCgKCAQEAqJikYizo'],
    ].map(([id, publicKeyValue, keyIdValue]) => ({
      id: `key-id.${id}`,
      input: { publicKey: publicKeyValue },
      expect: { keyId: keyIdValue },
    })),
    publicKeyValid: [
      ['fixture', null, true],
      ['garbage', '-----BEGIN RSA PUBLIC KEY-----\nnot-base64!!\n-----END RSA PUBLIC KEY-----', false],
      ['not-a-key', 'not-a-key', false],
    ].map(([id, publicKeyValue, valid]) => ({
      id: `public-key.${id}`,
      input: { publicKey: publicKeyValue },
      expect: { valid },
    })),
    checksumAlgorithm: [
      ['empty', '', 'empty'],
      ['sha256', HASH_A, 'SHA-256'],
      ['crc32', 'deadbeef', 'CRC32 (deprecated)'],
      ['unknown', '0123456789', 'unknown (10 hex chars)'],
    ].map(([id, checksum, algorithm]) => ({
      id: `checksum-algorithm.${id}`,
      input: { checksum },
      expect: { algorithm },
    })),
    checksumFile: [
      ['empty', '', 1, EMPTY_SHA256],
      ['abc', '616263', 1, sha256Hex(Buffer.from('abc'))],
      ['one-mebibyte-plus-one', '61', 1024 * 1024 + 1, sha256Hex(Buffer.alloc(1024 * 1024 + 1, 0x61))],
    ].map(([id, contentHex, repeat, checksum]) => ({
      id: `checksum-file.${id}`,
      input: { contentHex, repeat },
      expect: { checksum },
    })),
    decryptChecksum: [
      ['hex-sha256', null, hex(checksumCipher), { checksum: HASH_A }],
      ['base64-legacy', null, checksumCipher.toString('base64'), { checksum: HASH_A }],
      ['crc32-payload', null, hex(crcCipher), { checksum: 'deadbeef' }],
      ['no-public-key-passthrough', '', 'not-encrypted', { checksum: 'not-encrypted' }],
      ['wrong-size', null, '00'.repeat(255), { error: 'checksum_not_encrypted' }],
      ['not-rsa-block', null, 'ff'.repeat(256), { error: 'decrypt_failed' }],
    ].map(([id, publicKeyValue, checksum, expect]) => ({
      id: `decrypt-checksum.${id}`,
      input: { publicKey: publicKeyValue, checksum },
      expect,
    })),
    decryptFile: [
      ['small', null, sessionKey, hex(smallCipher), { plaintextHex: hex(small) }],
      ['multi-block', null, sessionKey, hex(multiCipher), { plaintextHex: hex(multiBlock) }],
      ['no-public-key-noop', '', sessionKey, hex(smallCipher), { plaintextHex: hex(smallCipher) }],
      ['no-session-key-noop', null, '', hex(smallCipher), { plaintextHex: hex(smallCipher) }],
      ['invalid-session-key-noop', null, 'nocolon', hex(smallCipher), { plaintextHex: hex(smallCipher) }],
      // Fail closed: an unusable key must never leave the bundle silently undecrypted.
      [
        'invalid-public-key',
        '-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----',
        sessionKey,
        hex(smallCipher),
        { error: 'invalid_public_key' },
      ],
      ['short-iv', null, shortIvSession, hex(smallCipher), { error: 'invalid_iv' }],
      ['garbage-session-key', null, garbageKeySession, hex(smallCipher), { error: 'session_key_decrypt_failed' }],
      ['session-key-too-long', null, longKeySession, hex(smallCipher), { error: 'invalid_session_key' }],
      ['bad-padding', null, sessionKey, hex(corrupted), { error: 'decrypt_failed' }],
      ['not-block-aligned', null, sessionKey, hex(smallCipher.subarray(0, 15)), { error: 'decrypt_failed' }],
      ['empty-ciphertext', null, sessionKey, '', { error: 'empty_input' }],
    ].map(([id, publicKeyValue, sessionKeyValue, ciphertextHex, expect]) => ({
      id: `decrypt-file.${id}`,
      input: { publicKey: publicKeyValue, sessionKey: sessionKeyValue, ciphertextHex },
      expect,
    })),
  };
}

write('policy', policy);
write('security', security);
if (only.length === 0 || only.includes('crypto')) {
  write('crypto', buildCrypto());
}
