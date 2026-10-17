#!/usr/bin/env bun
// Writes the seed corpus shared by the Rust (core/fuzz) and C (core-c/fuzz) fuzz targets:
// fuzz/corpus/<target>/<name>. Deterministic: rerun after changing a seed and commit the result.
//
//   bun scripts/generate-fuzz-corpus.mjs
import { createHash, createCipheriv, createPublicKey } from 'node:crypto';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { brotliCompressSync, deflateRawSync, gzipSync, crc32 } from 'node:zlib';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const corpus = join(root, 'fuzz', 'corpus');
const cli = JSON.parse(readFileSync(join(root, 'native-contract-tests', 'cli', 'cli-crypto.json'), 'utf8'));

const seeds = new Map();
const add = (target, name, data) => {
  if (!seeds.has(target)) seeds.set(target, []);
  seeds.get(target).push([name, typeof data === 'string' ? Buffer.from(data, 'utf8') : Buffer.from(data)]);
};

// ---- zip: a small writer (stored / deflated entries, directories, symlinks, comments)
const u16 = (value) => {
  const buffer = Buffer.alloc(2);
  buffer.writeUInt16LE(value);
  return buffer;
};
const u32 = (value) => {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32LE(value >>> 0);
  return buffer;
};
function zip(entries, comment = '') {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name, 'utf8');
    const data = Buffer.from(entry.data ?? '');
    const deflate = entry.deflate ?? false;
    const body = deflate ? deflateRawSync(data) : data;
    const crc = crc32(data);
    const mode = entry.symlink ? 0o120777 : entry.name.endsWith('/') ? 0o40755 : 0o100644;
    const local = Buffer.concat([
      u32(0x04034b50),
      u16(20),
      u16(0x0800),
      u16(deflate ? 8 : 0),
      u16(0),
      u16(0x21),
      u32(crc),
      u32(body.length),
      u32(data.length),
      u16(name.length),
      u16(0),
      name,
      body,
    ]);
    const central = Buffer.concat([
      u32(0x02014b50),
      u16(0x0314),
      u16(20),
      u16(0x0800),
      u16(deflate ? 8 : 0),
      u16(0),
      u16(0x21),
      u32(crc),
      u32(body.length),
      u32(data.length),
      u16(name.length),
      u16(0),
      u16(0),
      u16(0),
      u16(0),
      u32((mode << 16) >>> 0),
      u32(offset),
      name,
    ]);
    locals.push(local);
    centrals.push(central);
    offset += local.length;
  }
  const directory = Buffer.concat(centrals);
  const note = Buffer.from(comment, 'utf8');
  const end = Buffer.concat([
    u32(0x06054b50),
    u16(0),
    u16(0),
    u16(entries.length),
    u16(entries.length),
    u32(directory.length),
    u32(offset),
    u16(note.length),
    note,
  ]);
  return Buffer.concat([...locals, directory, end]);
}

for (const bundle of cli.bundles) {
  if (bundle.zipSize < 64 * 1024) add('zip', `cli-${bundle.id}.zip`, readFileSync(join(root, 'native-contract-tests', 'cli', bundle.zip)));
}
add('zip', 'stored.zip', zip([{ name: 'index.html', data: '<html></html>' }]));
add(
  'zip',
  'deflated.zip',
  zip([
    { name: 'index.html', data: '<html><body>'.repeat(20), deflate: true },
    { name: 'js/', data: '' },
    { name: 'js/app.js', data: 'console.log(1);'.repeat(10), deflate: true },
  ]),
);
add(
  'zip',
  'wrapped.zip',
  zip([
    { name: 'dist/', data: '' },
    { name: 'dist/index.html', data: 'x' },
    { name: '__MACOSX/._index.html', data: 'y' },
  ]),
);
add(
  'zip',
  'symlink.zip',
  zip([
    { name: 'index.html', data: 'x' },
    { name: 'link', data: 'index.html', symlink: true },
  ]),
);
add('zip', 'escape.zip', zip([{ name: '../escape.txt', data: 'x' }]));
add('zip', 'windows.zip', zip([{ name: 'a\\b.txt', data: 'x' }]));
add('zip', 'comment.zip', zip([{ name: 'a.txt', data: 'abc' }], 'a comment'));
add('zip', 'empty.zip', zip([]));

// ---- inflate (raw deflate) and brotli
const text = 'Capgo live update '.repeat(40);
add('inflate', 'text.bin', deflateRawSync(text));
add('inflate', 'stored.bin', deflateRawSync(Buffer.alloc(300, 7), { level: 0 }));
add('inflate', 'empty.bin', deflateRawSync(Buffer.alloc(0)));
add('inflate', 'html.bin', deflateRawSync('<html><head></head><body>' + 'a'.repeat(1000) + '</body></html>'));
add('brotli', 'text.br', brotliCompressSync(text));
add('brotli', 'empty.br', brotliCompressSync(Buffer.alloc(0)));
add('brotli', 'js.br', brotliCompressSync('function f(){return 1}\n'.repeat(50)));
add('brotli', 'stored-wrapper.br', Buffer.concat([Buffer.from([0x1b, 0x00, 0x06]), Buffer.from('raw'), Buffer.from([0x03])]));

// ---- JSON documents
const checksum = cli.bundles[0].checksum;
const sessionKey = cli.bundles[0].ivSessionKey;
const manifest = [
  { file_name: 'index.html', file_hash: '9556388be94d06eb7d263ec726a0ca4154ae82356e2a666a60e1bdedd0ad6d0b', download_url: 'https://cdn.example.com/a' },
  { file_name: 'js/app.js.br', file_hash: checksum, download_url: 'https://cdn.example.com/b' },
  { file_name: '../escape', file_hash: '00000000', download_url: 'https://cdn.example.com/c' },
];
const update = {
  version: '1.0.1',
  url: 'https://cdn.example.com/bundle.zip',
  checksum,
  sessionKey,
  manifest,
  link: 'https://example.com',
  comment: 'release',
};
add('json', 'update.json', JSON.stringify(update));
add('json', 'numbers.json', '[0,-0,1.5,-2.25e-7,1e308,18446744073709551615,-9223372036854775808,3.0,1E2]');
add('json', 'strings.json', '{"a":"\\u0000\\ud83d\\ude00\\n\\t\\"","b":[true,false,null],"c":{}}');
add('json', 'nested.json', '[[[[[[{"k":[{"k":[]}]}]]]]]]');
add('manifest', 'update.json', JSON.stringify(update));
add('manifest', 'array.json', JSON.stringify(manifest));
add(
  'manifest',
  'odd.json',
  JSON.stringify({ version: '2', manifest: [{ file_name: 1 }, { file_name: './a/./b', file_hash: 'x'.repeat(64) }, null, 'x'] }),
);
add('update_response', 'zip.json', JSON.stringify({ version: '1.0.1', url: 'https://cdn.example.com/b.zip', checksum, sessionKey }));
add('update_response', 'manifest.json', JSON.stringify(update));
add('update_response', 'up-to-date.json', JSON.stringify({ error: 'no_new_version_available', message: 'No new version', kind: 'up_to_date' }));
add('update_response', 'blocked.json', JSON.stringify({ error: 'disable_auto_update_to_major', message: 'blocked', kind: 'blocked', version: '2.0.0', breaking: true }));
add('update_response', 'builtin.json', JSON.stringify({ version: 'builtin' }));

// ---- HTTP responses (first byte: low bit 0 buffered GET, 1 streamed download)
const http = (mode, response) => Buffer.concat([Buffer.from([mode]), Buffer.from(response)]);
add('http_response', 'length.bin', http(0, 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{"ok":true}'));
add('http_response', 'chunked.bin', http(1, 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nTrailer: x\r\n\r\n'));
add('http_response', 'redirect.bin', http(0, 'HTTP/1.1 301 Moved Permanently\r\nLocation: /next?a=b\r\nContent-Length: 0\r\n\r\n'));
add('http_response', 'redirect-absolute.bin', http(1, 'HTTP/1.1 302 Found\r\nLocation: http://cdn.example.com:8080/x\r\n\r\n'));
add('http_response', 'close.bin', http(1, 'HTTP/1.0 200 OK\r\nServer: x\r\n\r\nbody until close'));
add('http_response', 'no-content.bin', http(0, 'HTTP/1.1 204 No Content\r\n\r\n'));
add('http_response', 'continue.bin', http(0, 'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'));
add(
  'http_response',
  'gzip.bin',
  http(0, Buffer.concat([Buffer.from('HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: '), Buffer.from(String(gzipSync('{"a":1}').length)), Buffer.from('\r\n\r\n'), gzipSync('{"a":1}')])),
);
add('http_response', 'rate-limit.bin', http(0, 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 1\r\nContent-Length: 0\r\n\r\n'));

// ---- RSA keys and checksums
const pem = cli.publicKey;
const key = createPublicKey(pem);
add('rsa_key', 'pkcs1.pem', pem);
add('rsa_key', 'spki.pem', key.export({ type: 'spki', format: 'pem' }));
add('rsa_key', 'pkcs1.der', key.export({ type: 'pkcs1', format: 'der' }));
add('rsa_key', 'spki.der', key.export({ type: 'spki', format: 'der' }));
add('rsa_key', 'escaped.pem', pem.replaceAll('\n', '\\n'));
for (const bundle of cli.bundles) {
  add('rsa_checksum', `${bundle.id}.hex`, bundle.checksum);
  add('rsa_checksum', `${bundle.id}.b64`, Buffer.from(bundle.checksum, 'hex').toString('base64'));
}
add('rsa_checksum', 'block.bin', Buffer.concat([Buffer.from([0, 1]), Buffer.alloc(221, 0xff), Buffer.from([0]), Buffer.alloc(32, 0xab)]));

// ---- AES-CBC (key, iv, ciphertext) and session keys
const aes = (seed, plaintext) => {
  const material = createHash('sha256').update(seed).digest();
  const keyBytes = material.subarray(0, 16);
  const iv = material.subarray(16, 32);
  const cipher = createCipheriv('aes-128-cbc', keyBytes, iv);
  return Buffer.concat([keyBytes, iv, cipher.update(plaintext), cipher.final()]);
};
add('aes_cbc', 'short.bin', aes('short', 'hello'));
add('aes_cbc', 'block.bin', aes('block', Buffer.alloc(16, 1)));
add('aes_cbc', 'long.bin', aes('long', Buffer.alloc(100, 2)));
for (const bundle of cli.bundles) add('aes_cbc', `${bundle.id}.session`, bundle.ivSessionKey);

// ---- path guards: `<base> 0xFF <relative>` or a relative path alone
const sep = Buffer.from([0xff]);
for (const [name, relative] of [
  ['plain', 'index.html'],
  ['nested', 'assets/js/app.js'],
  ['brotli', 'assets/app.js.br'],
  ['dots', './a/./b'],
  ['traversal', 'a/../../b'],
  ['absolute', '/etc/passwd'],
  ['tilde', '~/x'],
  ['backslash', 'a\\b'],
  ['nul', 'a\u0000b'],
  ['double-slash', 'a//b/'],
  ['dot', '.'],
]) {
  add('path_guard', `${name}.txt`, relative);
}
add('path_guard', 'with-base.bin', Buffer.concat([Buffer.from('/data/app/'), sep, Buffer.from('x/y')]));
add('path_guard', 'root-base.bin', Buffer.concat([Buffer.from('/'), sep, Buffer.from('x')]));
add('path_guard', 'empty-base.bin', Buffer.concat([sep, Buffer.from('a')]));

rmSync(corpus, { recursive: true, force: true });
for (const [target, files] of seeds) {
  const dir = join(corpus, target);
  mkdirSync(dir, { recursive: true });
  for (const [name, data] of files) writeFileSync(join(dir, name), data);
}
console.log(`Wrote ${[...seeds.values()].reduce((total, files) => total + files.length, 0)} seeds for ${seeds.size} targets to ${corpus}`);
