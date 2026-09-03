#!/usr/bin/env node
/**
 * Restore Capacitor-major pins after merging main into an LTS branch.
 * Config: .github/lts-backport.json
 *
 * Usage:
 *   node restore-lts-constraints.mjs --target v7
 *   node restore-lts-constraints.mjs --self-test
 */
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(SCRIPT_DIR, '..', '..');

export function resolveConfigPath(scriptDir = SCRIPT_DIR) {
  const candidates = [join(scriptDir, 'lts-backport.json'), join(scriptDir, '..', 'lts-backport.json')];
  const found = candidates.find((path) => existsSync(path));
  if (!found) {
    throw new Error(`lts-backport.json not found. Looked in: ${candidates.join(', ')}`);
  }
  return found;
}

const CAPACITOR_DEP_PREFIX = '@capacitor/';
const NATIVE_PLUGIN_VERSION_FILES = [
  'android/src/main/java/ee/forgr/capacitor_updater/CapacitorUpdaterPlugin.java',
  'ios/Sources/CapacitorUpdaterPlugin/CapacitorUpdaterPlugin.swift',
];

export function loadConfig(configPath = resolveConfigPath()) {
  return JSON.parse(readFileSync(configPath, 'utf8'));
}

export function ltsVersionFromMain(mainVersion, targetMajor) {
  const parts = String(mainVersion).split('.');
  if (parts.length < 3 || parts.some((part) => !/^\d+$/.test(part))) {
    throw new Error(`Unexpected version "${mainVersion}"`);
  }
  return `${targetMajor}.${parts[1]}.${parts[2]}`;
}

function pinCapacitorDeps(deps, range, extra = {}) {
  if (!deps) {
    return deps;
  }
  const next = { ...deps };
  for (const key of Object.keys(next)) {
    if (key === '@capacitor/docgen') {
      if (extra.docgen) {
        next[key] = extra.docgen;
      }
      continue;
    }
    if (key.startsWith(CAPACITOR_DEP_PREFIX)) {
      next[key] = range;
    }
  }
  return next;
}

export function rewritePackageJson(pkg, target, nextVersion) {
  const extra = target.docgen ? { docgen: target.docgen } : {};
  return {
    ...pkg,
    version: nextVersion,
    devDependencies: pinCapacitorDeps(pkg.devDependencies, target.capacitorRange, extra),
    dependencies: pinCapacitorDeps(pkg.dependencies, target.capacitorRange, extra),
    peerDependencies: pinCapacitorDeps(pkg.peerDependencies, target.capacitorRange, extra),
  };
}

export function rewriteExamplePackageJson(pkg, target) {
  const extra = {};
  const range = target.exampleCapacitorRange || target.capacitorRange;
  return {
    ...pkg,
    dependencies: pinCapacitorDeps(pkg.dependencies, range, extra),
    devDependencies: pinCapacitorDeps(pkg.devDependencies, range, extra),
  };
}

export function patchAndroidBuildGradle(src, android) {
  let out = src;
  out = out.replace(
    /compileSdk(?:Version)?(?:\s*=)?\s*project\.hasProperty\('compileSdkVersion'\) \? rootProject\.ext\.compileSdkVersion : \d+/,
    (match) => match.replace(/: \d+$/, `: ${android.compileSdk}`),
  );
  out = out.replace(
    /minSdkVersion(?:\s*=)?\s*project\.hasProperty\('minSdkVersion'\) \? rootProject\.ext\.minSdkVersion : \d+/,
    (match) => match.replace(/: \d+$/, `: ${android.minSdk}`),
  );
  out = out.replace(
    /targetSdkVersion(?:\s*=)?\s*project\.hasProperty\('targetSdkVersion'\) \? rootProject\.ext\.targetSdkVersion : \d+/,
    (match) => match.replace(/: \d+$/, `: ${android.targetSdk}`),
  );
  out = out.replace(/sourceCompatibility JavaVersion\.VERSION_\d+/, `sourceCompatibility JavaVersion.VERSION_${android.java}`);
  out = out.replace(/targetCompatibility JavaVersion\.VERSION_\d+/, `targetCompatibility JavaVersion.VERSION_${android.java}`);
  out = out.replace(
    /implementation 'com\.squareup\.okhttp3:okhttp:[^']+'/,
    `implementation 'com.squareup.okhttp3:okhttp:${android.okhttp}'`,
  );
  out = out.replace(
    /classpath 'com\.android\.tools\.build:gradle:[^']+'/,
    `classpath 'com.android.tools.build:gradle:${android.agp}'`,
  );
  return out;
}

export function patchExampleVariablesGradle(src, android) {
  let out = src;
  out = out.replace(/minSdkVersion = \d+/, `minSdkVersion = ${android.minSdk}`);
  out = out.replace(/compileSdkVersion = \d+/, `compileSdkVersion = ${android.compileSdk}`);
  out = out.replace(/targetSdkVersion = \d+/, `targetSdkVersion = ${android.targetSdk}`);
  return out;
}

export function iosPlatformExpr(value) {
  const raw = String(value);
  if (raw.startsWith('.')) {
    return raw;
  }
  return `"${raw}"`;
}

export function patchPackageSwift(src, target) {
  let out = src;
  out = out.replace(/platforms:\s*\[\.iOS\([^)]+\)\]/, `platforms: [.iOS(${iosPlatformExpr(target.iosPlatform)})]`);
  out = out.replace(
    /ionic-team\/capacitor-swift-pm\.git",\s*(?:from|exact):\s*"[^"]+"/,
    `ionic-team/capacitor-swift-pm.git", from: "${target.swiftPm}"`,
  );
  if (target.bigIntExact) {
    out = out.replace(
      /\.package\(url: "https:\/\/github\.com\/attaswift\/BigInt\.git", [^)]+\)/,
      `.package(url: "https://github.com/attaswift/BigInt.git", exact: "${target.bigIntExact}")`,
    );
  }
  return out;
}

export function patchPodspec(src, target) {
  return src.replace(/s\.ios\.deployment_target = '[^']+'/, `s.ios.deployment_target = '${target.iosDeployment}'`);
}

export function patchPluginVersion(src, fromVersion, toVersion) {
  if (!fromVersion || fromVersion === toVersion) {
    return src;
  }
  return src.split(fromVersion).join(toVersion);
}

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function readText(path) {
  return readFileSync(path, 'utf8');
}

function writeText(path, value) {
  writeFileSync(path, value);
}

export function applyConstraints(repoRoot, target) {
  const pkgPath = join(repoRoot, 'package.json');
  const pkg = JSON.parse(readText(pkgPath));
  const fromVersion = pkg.version;
  const toVersion = ltsVersionFromMain(fromVersion, target.major);
  writeJson(pkgPath, rewritePackageJson(pkg, target, toVersion));

  const examplePkgPath = join(repoRoot, 'example-app/package.json');
  const pinExampleApp = target.pinExampleApp !== false;
  if (existsSync(examplePkgPath) && pinExampleApp) {
    writeJson(examplePkgPath, rewriteExamplePackageJson(JSON.parse(readText(examplePkgPath)), target));
  }

  const gradlePath = join(repoRoot, 'android/build.gradle');
  writeText(gradlePath, patchAndroidBuildGradle(readText(gradlePath), target.android));

  const exampleGradlePath = join(repoRoot, 'example-app/android/build.gradle');
  if (existsSync(exampleGradlePath)) {
    writeText(
      exampleGradlePath,
      readText(exampleGradlePath).replace(
        /classpath 'com\.android\.tools\.build:gradle:[^']+'/,
        `classpath 'com.android.tools.build:gradle:${target.android.agp}'`,
      ),
    );
  }

  const exampleVarsPath = join(repoRoot, 'example-app/android/variables.gradle');
  if (existsSync(exampleVarsPath)) {
    writeText(exampleVarsPath, patchExampleVariablesGradle(readText(exampleVarsPath), target.android));
  }

  const swiftPath = join(repoRoot, 'Package.swift');
  writeText(swiftPath, patchPackageSwift(readText(swiftPath), target));

  const exampleSpmPath = join(repoRoot, 'example-app/ios/App/CapApp-SPM/Package.swift');
  if (existsSync(exampleSpmPath) && pinExampleApp) {
    writeText(exampleSpmPath, patchPackageSwift(readText(exampleSpmPath), target));
  }

  const podspecPath = join(repoRoot, 'CapgoCapacitorUpdater.podspec');
  writeText(podspecPath, patchPodspec(readText(podspecPath), target));

  for (const relative of NATIVE_PLUGIN_VERSION_FILES) {
    const nativePath = join(repoRoot, relative);
    if (existsSync(nativePath)) {
      writeText(nativePath, patchPluginVersion(readText(nativePath), fromVersion, toVersion));
    }
  }

  return { fromVersion, toVersion };
}

function selfTest() {
  const rewritten = rewritePackageJson(
    {
      version: '8.51.15',
      devDependencies: {
        '@capacitor/core': '^8.5.0',
        '@capacitor/docgen': '^0.3.0',
        typescript: '^5.9.2',
      },
      peerDependencies: { '@capacitor/core': '^8.0.0' },
    },
    { major: 7, capacitorRange: '^7.0.0', docgen: '^0.2.1' },
    '7.51.15',
  );
  assert.equal(rewritten.version, '7.51.15');
  assert.equal(rewritten.devDependencies['@capacitor/core'], '^7.0.0');
  assert.equal(rewritten.devDependencies['@capacitor/docgen'], '^0.2.1');
  assert.equal(rewritten.devDependencies.typescript, '^5.9.2');
  assert.equal(rewritten.peerDependencies['@capacitor/core'], '^7.0.0');
  assert.equal(ltsVersionFromMain('8.51.15', 5), '5.51.15');

  const gradle = patchAndroidBuildGradle(
    `
    compileSdk project.hasProperty('compileSdkVersion') ? rootProject.ext.compileSdkVersion : 36
    minSdkVersion project.hasProperty('minSdkVersion') ? rootProject.ext.minSdkVersion : 24
    targetSdkVersion project.hasProperty('targetSdkVersion') ? rootProject.ext.targetSdkVersion : 36
    sourceCompatibility JavaVersion.VERSION_21
    targetCompatibility JavaVersion.VERSION_21
    classpath 'com.android.tools.build:gradle:8.13.0'
    implementation 'com.squareup.okhttp3:okhttp:5.4.0'
    `,
    { minSdk: 22, compileSdk: 34, targetSdk: 34, java: 17, okhttp: '4.12.0', agp: '8.7.2' },
  );
  assert.match(gradle, /: 34/);
  assert.match(gradle, /minSdkVersion[^\n]+: 22/);
  assert.match(gradle, /VERSION_17/);
  assert.match(gradle, /okhttp:4\.12\.0/);
  assert.match(gradle, /gradle:8\.7\.2/);

  const swift = patchPackageSwift(
    `platforms: [.iOS("15.0")],
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.7.0")`,
    { iosPlatform: '.v13', swiftPm: '6.0.0', bigIntExact: '5.2.0' },
  );
  assert.match(swift, /\.iOS\(\.v13\)/);
  assert.match(swift, /from: "6\.0\.0"/);
  assert.match(swift, /exact: "5\.2\.0"/);

  const exampleSpm = patchPackageSwift(
    `platforms: [.iOS(.v15)],
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", exact: "8.5.0")`,
    { iosPlatform: '.v14', swiftPm: '7.0.0' },
  );
  assert.match(exampleSpm, /\.iOS\(\.v14\)/);
  assert.match(exampleSpm, /from: "7\.0\.0"/);

  const podspec = patchPodspec("s.ios.deployment_target = '15.0'", { iosDeployment: '14.0' });
  assert.equal(podspec, "s.ios.deployment_target = '14.0'");

  const swift134 = patchPackageSwift(
    `platforms: [.iOS("15.0")],
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")`,
    { iosPlatform: '13.4', swiftPm: '5.0.0' },
  );
  assert.match(swift134, /\.iOS\("13\.4"\)/);

  const examplePinned = rewriteExamplePackageJson(
    {
      dependencies: { '@capacitor/core': '^8.5.0', '@capacitor/ios': '^8.5.0' },
      devDependencies: { '@capacitor/cli': '^8.5.0', typescript: '^5.9.2' },
    },
    { capacitorRange: '^5.0.0', exampleCapacitorRange: '^8.0.0' },
  );
  assert.equal(examplePinned.dependencies['@capacitor/core'], '^8.0.0');
  assert.equal(examplePinned.devDependencies['@capacitor/cli'], '^8.0.0');
  assert.equal(examplePinned.devDependencies.typescript, '^5.9.2');

  const native = patchPluginVersion('private let pluginVersion: String = "8.51.15"', '8.51.15', '7.51.15');
  assert.equal(native, 'private let pluginVersion: String = "7.51.15"');

  const config = loadConfig();
  assert.ok(config.targets.v5 && config.targets.v6 && config.targets.v7);
  assert.equal(config.targets.v6.android.minSdk, 23);

  const stashDir = join(tmpdir(), `lts-restore-stash-${process.pid}`);
  mkdirSync(stashDir, { recursive: true });
  try {
    copyFileSync(resolveConfigPath(), join(stashDir, 'lts-backport.json'));
    assert.equal(resolveConfigPath(stashDir), join(stashDir, 'lts-backport.json'));
    assert.ok(loadConfig(resolveConfigPath(stashDir)).targets.v7);
  } finally {
    rmSync(stashDir, { recursive: true, force: true });
  }

  console.log('restore-lts-constraints self-test passed');
}

function parseArgs(argv) {
  const args = { target: null, selfTest: false, repoRoot: REPO_ROOT, config: null };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--self-test') {
      args.selfTest = true;
    } else if (arg === '--target') {
      args.target = argv[i + 1];
      i += 1;
    } else if (arg === '--repo-root') {
      args.repoRoot = argv[i + 1];
      i += 1;
    } else if (arg === '--config') {
      args.config = argv[i + 1];
      i += 1;
    }
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
const isDirectRun = Boolean(process.argv[1]) && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (args.selfTest || args.target || isDirectRun) {
  if (args.selfTest) {
    selfTest();
    process.exit(0);
  }
  if (!args.target) {
    console.error('Usage: restore-lts-constraints.mjs --target v5|v6|v7');
    process.exit(1);
  }
  const config = loadConfig(args.config || resolveConfigPath());
  const target = config.targets[args.target];
  if (!target) {
    console.error(`Unknown target "${args.target}". Valid: ${Object.keys(config.targets).join(', ')}`);
    process.exit(1);
  }
  const result = applyConstraints(args.repoRoot, target);
  console.log(`Restored ${args.target} constraints: ${result.fromVersion} -> ${result.toVersion}`);
}
