import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
export const repoRoot = path.resolve(scriptDir, '..', '..');
export const exampleAppDir = path.join(repoRoot, 'example-app');
export const maestroDir = path.join(repoRoot, '.maestro');
export const artifactDir = path.join(repoRoot, '.maestro-artifacts');
export const bundleArtifactDir = path.join(artifactDir, 'bundles');
export const defaultPort = Number(process.env.CAPGO_MAESTRO_PORT ?? '3192');
export const defaultHostBaseUrl = process.env.CAPGO_MAESTRO_HOST_BASE_URL ?? `http://127.0.0.1:${defaultPort}`;
export const defaultDeviceBaseUrl = process.env.CAPGO_MAESTRO_DEVICE_BASE_URL ?? `http://10.0.2.2:${defaultPort}`;
export const exampleAppId = 'app.capgo.updater';
export const exampleApkPath = path.join(exampleAppDir, 'android', 'app', 'build', 'outputs', 'apk', 'debug', 'app-debug.apk');

export const scenarios = {
  deferred: {
    id: 'deferred',
    directUpdate: 'false',
    builtinLabel: 'deferred-builtin',
    releases: [{ version: 'deferred-v1', label: 'deferred-v1' }],
  },
  always: {
    id: 'always',
    directUpdate: 'always',
    builtinLabel: 'always-builtin',
    releases: [
      { version: 'always-v1', label: 'always-v1' },
      { version: 'always-v2', label: 'always-v2' },
    ],
  },
  'at-install': {
    id: 'at-install',
    directUpdate: 'atInstall',
    builtinLabel: 'at-install-builtin',
    releases: [
      { version: 'at-install-v1', label: 'at-install-v1' },
      { version: 'at-install-v2', label: 'at-install-v2' },
    ],
  },
  'on-launch': {
    id: 'on-launch',
    directUpdate: 'onLaunch',
    builtinLabel: 'on-launch-builtin',
    releases: [
      { version: 'on-launch-v1', label: 'on-launch-v1' },
      { version: 'on-launch-v2', label: 'on-launch-v2' },
      { version: 'on-launch-v3', label: 'on-launch-v3' },
    ],
  },
};

export function getScenario(id) {
  const scenario = scenarios[id];

  if (!scenario) {
    throw new Error(`Unknown Maestro scenario: ${id}`);
  }

  return scenario;
}

export function getBundleZipPath(version) {
  return path.join(bundleArtifactDir, `${version}.zip`);
}
