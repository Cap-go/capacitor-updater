// App size of the release bench builds (plain variant) for one label.
// Web assets (public/, which carries the 180 MB bench builtin pad) are reported
// separately so the native footprint is visible.
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, rmSync, statSync } from 'node:fs';
import path from 'node:path';
import { gzipSync } from 'node:zlib';
import { appsDir } from './config.mjs';

function sh(cmd, args, options = {}) {
  const r = spawnSync(cmd, args, { encoding: options.encoding ?? 'utf8', maxBuffer: 1 << 30, ...options });
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(' ')} failed: ${r.stderr}`);
  return r.stdout;
}

function gzip9Size(buffer) {
  return gzipSync(buffer, { level: 9 }).length;
}

/** Android: entries of the signed release APK. */
export function androidSize(label) {
  const apk = path.join(appsDir, `${label}-android-plain.apk`);
  if (!existsSync(apk)) return null;
  // unzip -v: Length Method Size Cmpr Date Time CRC-32 Name
  const entries = sh('unzip', ['-v', apk])
    .split('\n')
    .map((l) => l.trim().split(/\s+/))
    .filter((c) => c.length >= 8 && /^\d+$/.test(c[0]) && /^\d+$/.test(c[2]))
    .map((c) => ({ size: Number(c[0]), compressed: Number(c[2]), name: c.slice(7).join(' ') }));
  const sum = (list, key) => list.reduce((n, e) => n + e[key], 0);
  const web = entries.filter((e) => e.name.startsWith('assets/public/'));
  const libs = entries
    .filter((e) => /^lib\/[^/]+\/libcapgo_updater_core\.so$/.test(e.name))
    .map((e) => ({ abi: e.name.split('/')[1], size: e.size, compressed: e.compressed }));
  const dex = entries.filter((e) => /^classes\d*\.dex$/.test(e.name));
  const arm64 = libs.find((l) => l.abi === 'arm64-v8a');
  const arm64Gzip = arm64
    ? gzip9Size(sh('unzip', ['-p', apk, 'lib/arm64-v8a/libcapgo_updater_core.so'], { encoding: 'buffer' }))
    : 0;
  return {
    apkBytes: statSync(apk).size,
    webCompressed: sum(web, 'compressed'),
    libs,
    dexBytes: sum(dex, 'size'),
    dexFiles: dex.length,
    arm64Gzip,
  };
}

function dirSize(dir) {
  let total = 0;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) total += dirSize(p);
    else if (entry.isFile()) total += statSync(p).size;
  }
  return total;
}

/** iOS: Release simulator .app (sizes of the arm64 slice are given too). */
export function iosSize(label) {
  const app = path.join(appsDir, `${label}-ios-plain.app`);
  if (!existsSync(app)) return null;
  const exe = path.join(app, 'App');
  const archs = sh('lipo', ['-archs', exe]).trim();
  let arm64Bytes = statSync(exe).size;
  if (archs.split(' ').length > 1) {
    const tmp = path.join(appsDir, `.${label}-App-arm64`);
    sh('lipo', [exe, '-thin', 'arm64', '-output', tmp]);
    arm64Bytes = statSync(tmp).size;
    rmSync(tmp, { force: true });
  }
  const fwDir = path.join(app, 'Frameworks');
  const frameworks = existsSync(fwDir)
    ? readdirSync(fwDir).map((name) => ({ name, bytes: dirSize(path.join(fwDir, name)) }))
    : [];
  const publicDir = path.join(app, 'public');
  return {
    appBytes: dirSize(app),
    webBytes: existsSync(publicDir) ? dirSize(publicDir) : 0,
    exeBytes: statSync(exe).size,
    exeArchs: archs,
    exeArm64Bytes: arm64Bytes,
    frameworks,
  };
}
