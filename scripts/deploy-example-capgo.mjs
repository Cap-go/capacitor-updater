#!/usr/bin/env node
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..');
const appDir = resolve(repoRoot, 'example-app');
const rootPackageJson = JSON.parse(readFileSync(resolve(repoRoot, 'package.json'), 'utf8'));
const examplePackageJson = JSON.parse(readFileSync(resolve(appDir, 'package.json'), 'utf8'));
const tsConfigPath = resolve(appDir, 'capacitor.config.ts');
const jsonConfigPath = resolve(appDir, 'capacitor.config.json');
const configPath = existsSync(tsConfigPath)
  ? tsConfigPath
  : existsSync(jsonConfigPath)
    ? jsonConfigPath
    : null;

if (!configPath) {
  console.error('Missing Capacitor config. Expected example-app/capacitor.config.ts or example-app/capacitor.config.json.');
  process.exit(1);
}

const configText = readFileSync(configPath, 'utf8');

function readConfigString(key, fallback) {
  const patterns = {
    appId: /['"]?appId['"]?\s*[:=]\s*['"]([^'"]+)['"]/,
    appName: /['"]?appName['"]?\s*[:=]\s*['"]([^'"]+)['"]/,
    webDir: /['"]?webDir['"]?\s*[:=]\s*['"]([^'"]+)['"]/,
  };
  const match = patterns[key]?.exec(configText);
  return match?.[1] ?? fallback;
}

function runCapgo(args, allowFailure = false) {
  const token = process.env.CAPGO_TOKEN;
  const fullArgs = ['x', '@capgo/cli@8.5.3', ...args];
  if (token) {
    fullArgs.push('--apikey', token);
  }
  const result = spawnSync(process.execPath, fullArgs, {
    cwd: appDir,
    stdio: 'inherit',
    env: process.env,
  });
  if (!allowFailure && result.status !== 0) {
    process.exit(result.status ?? 1);
  }
  return result.status ?? 1;
}

const appId = process.env.CAPGO_APP_ID || readConfigString('appId');
const appName = process.env.CAPGO_APP_NAME || readConfigString('appName', rootPackageJson.name);
const webDir = process.env.CAPGO_WEB_DIR || readConfigString('webDir', 'dist');
const distDir = resolve(appDir, webDir);
const channel = process.env.CAPGO_CHANNEL || process.argv[2] || 'production';
function usableVersion(version) {
  return version && version !== '0.0.0' ? version : undefined;
}

const bundle =
  process.env.CAPGO_BUNDLE || usableVersion(examplePackageJson.version) || usableVersion(rootPackageJson.version);
const comment =
  process.env.CAPGO_COMMENT ||
  (process.env.GITHUB_RUN_NUMBER
    ? `${appName} run ${process.env.GITHUB_RUN_NUMBER}`
    : `${appName} ${bundle}`);
const iconPath = process.env.CAPGO_ICON || resolve(appDir, 'assets', 'capgo-icon.png');

if (!appId) {
  console.error('Missing Capgo app id. Set CAPGO_APP_ID or example-app/capacitor.config.* appId.');
  process.exit(1);
}

if (!existsSync(distDir)) {
  console.error(`Missing example app bundle at ${distDir}. Run bun run example:build first.`);
  process.exit(1);
}

if (!bundle) {
  console.error('Missing Capgo bundle version. Set CAPGO_BUNDLE or add a version to example-app/package.json or package.json.');
  process.exit(1);
}

const appArgs = [appId, '--name', appName];
if (existsSync(iconPath)) {
  appArgs.push('--icon', iconPath);
}

const setStatus = runCapgo(['app', 'set', ...appArgs], true);
if (setStatus !== 0) {
  runCapgo(['app', 'add', ...appArgs]);
}

console.log(`Deploying ${appId} to Capgo channel "${channel}"`);
const channelArgs = ['channel', 'add', channel, appId];
if (channel === 'production') {
  channelArgs.push('--default');
}
runCapgo(channelArgs, true);


runCapgo([
  'bundle',
  'upload',
  appId,
  '--bundle',
  bundle,
  '--path',
  webDir,
  '--channel',
  channel,
  '--package-json',
  'package.json,../package.json',
  '--node-modules',
  'node_modules,../node_modules',
  '--delta',
  '--no-key',
  '--ignore-checksum-check',
  '--version-exists-ok',
  '--comment',
  comment,
]);
