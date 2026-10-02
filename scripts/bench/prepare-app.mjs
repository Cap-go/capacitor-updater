// Prepare an isolated bench app for one plugin checkout.
// Copies <checkout>/example-app native projects into .context/bench/apps/<label>,
// points @capgo/capacitor-updater at file:<checkout>, installs the bench web
// assets (www/) and writes a bench-only capacitor.config.json.
// The checkout's own example-app is never modified.
//
// Usage: bun scripts/bench/prepare-app.mjs --label before --checkout <dir> --platform ios|android --variant plain|enc [--no-install]
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { appsDir, builtinPadDir, builtinWwwDir, deviceBaseUrl } from './config.mjs';
import { ensureBuiltinPad, ensureKeys } from './fixtures.mjs';

function arg(name, fallback = undefined) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return fallback;
  const v = process.argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
}

const label = arg('label');
const checkout = path.resolve(arg('checkout'));
const platform = arg('platform');
const variant = arg('variant');
const skipInstall = Boolean(arg('no-install', false));
if (!label || !checkout || !['ios', 'android'].includes(platform) || !['plain', 'enc'].includes(variant)) {
  console.error('usage: prepare-app.mjs --label <l> --checkout <dir> --platform <ios|android> --variant <plain|enc>');
  process.exit(2);
}

function run(cmd, args, cwd) {
  console.log(`[bench-prepare] (${path.relative(process.cwd(), cwd) || '.'}) ${cmd} ${args.join(' ')}`);
  const r = spawnSync(cmd, args, { cwd, stdio: 'inherit', env: process.env });
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(' ')} failed with ${r.status}`);
}

const appDir = path.resolve(appsDir, label);
// The label names a folder that rsync --delete rewrites: it must stay a direct child of appsDir.
if (path.dirname(appDir) !== path.resolve(appsDir)) {
  console.error(`label must be a plain folder name: ${label}`);
  process.exit(2);
}
const src = path.join(checkout, 'example-app');

if (!skipInstall) {
  run(
    'rsync',
    [
      '-a',
      '--delete',
      '--exclude',
      'node_modules',
      '--exclude',
      'dist',
      '--exclude',
      'www',
      '--exclude',
      '/src',
      '--exclude',
      '/index.html',
      '--exclude',
      'capacitor.config.ts',
      '--exclude',
      'capacitor.config.json',
      '--exclude',
      'ios/App/App/public',
      '--exclude',
      'android/app/src/main/assets/public',
      '--exclude',
      'android/app/build',
      '--exclude',
      'android/build',
      '--exclude',
      'android/.gradle',
      '--exclude',
      'ios/App/build',
      '--exclude',
      'ios/DerivedData',
      `${src}/`,
      `${appDir}/`,
    ],
    process.cwd(),
  );

  const pkgPath = path.join(appDir, 'package.json');
  const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
  pkg.name = `capgo-bench-${label}`;
  pkg.dependencies['@capgo/capacitor-updater'] = `file:${checkout}`;
  pkg.scripts = {};
  writeFileSync(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`);
  rmSync(path.join(appDir, 'bun.lock'), { force: true });

  // Bun keeps file: deps as copies; drop them so the current checkout is re-copied.
  const bunStore = path.join(appDir, 'node_modules', '.bun');
  if (existsSync(bunStore)) {
    for (const entry of readdirSync(bunStore)) {
      if (entry.startsWith('@capgo+capacitor-updater@'))
        rmSync(path.join(bunStore, entry), { recursive: true, force: true });
    }
  }
  rmSync(path.join(appDir, 'node_modules', '@capgo', 'capacitor-updater'), { recursive: true, force: true });
  // The npm registry occasionally 404s a freshly published tarball: retry a few times.
  for (let attempt = 1; ; attempt += 1) {
    try {
      run('bun', ['install'], appDir);
      break;
    } catch (error) {
      if (attempt >= 3) throw error;
      console.warn(`[bench-prepare] bun install failed (attempt ${attempt}), retrying in 20s`);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20_000);
    }
  }
}

// The bench uses release builds (optimized Java/Swift). Give the release variant the
// same loopback-only cleartext network security config the example app uses in debug.
const debugSrc = path.join(appDir, 'android', 'app', 'src', 'debug');
const releaseSrc = path.join(appDir, 'android', 'app', 'src', 'release');
if (existsSync(debugSrc)) {
  rmSync(releaseSrc, { recursive: true, force: true });
  cpSync(debugSrc, releaseSrc, { recursive: true });
}
// The plugin refuses cleartext HTTP unless NetworkSecurityPolicy allows it for the host, so the
// bench server host (10.0.2.2 or 127.0.0.1) must be listed in the release network security config.
if (platform === 'android') {
  const host = new URL(deviceBaseUrl).hostname;
  const xmlDir = path.join(releaseSrc, 'res', 'xml');
  const configs = existsSync(xmlDir)
    ? readdirSync(xmlDir)
        .filter((f) => f.endsWith('.xml'))
        .map((f) => readFileSync(path.join(xmlDir, f), 'utf8'))
    : [];
  if (!configs.some((xml) => /cleartextTrafficPermitted="true"/.test(xml) && xml.includes(`>${host}<`))) {
    throw new Error(`release network security config does not allow cleartext to ${host} (${xmlDir})`);
  }
}

rmSync(path.join(appDir, 'www'), { recursive: true, force: true });
cpSync(builtinWwwDir, path.join(appDir, 'www'), { recursive: true });
// Builtin files for the builtin-reuse manifest cases (www/bpad/...).
await ensureBuiltinPad();
cpSync(builtinPadDir, path.join(appDir, 'www'), { recursive: true });

const keys = await ensureKeys();
const updater = {
  autoUpdate: false,
  directUpdate: false,
  appReadyTimeout: 60000,
  responseTimeout: 600,
  updateUrl: `${deviceBaseUrl}/api/updates`,
  statsUrl: `${deviceBaseUrl}/api/stats`,
  channelUrl: `${deviceBaseUrl}/api/channel`,
};
if (variant === 'enc') updater.publicKey = keys.publicKey;

const config = {
  appId: 'app.capgo.updater',
  appName: 'capgo-bench',
  webDir: 'www',
  android: { allowMixedContent: true },
  plugins: {
    SplashScreen: { launchAutoHide: true, launchShowDuration: 0 },
    CapacitorUpdater: updater,
  },
};
writeFileSync(path.join(appDir, 'capacitor.config.json'), `${JSON.stringify(config, null, 2)}\n`);

run('bunx', ['cap', 'sync', platform], appDir);
console.log(`[bench-prepare] ${label}/${platform}/${variant} ready in ${appDir}`);
