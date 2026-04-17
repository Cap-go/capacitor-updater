import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
export const repoRoot = path.resolve(scriptDir, '..', '..');
export const exampleAppDir = path.join(repoRoot, 'example-app');
export const maestroDir = path.join(repoRoot, '.maestro');
export const artifactDir = path.join(repoRoot, '.maestro-artifacts');
export const bundleArtifactDir = path.join(artifactDir, 'bundles');
const rawPort = process.env.CAPGO_MAESTRO_PORT?.trim() || '3192';
export const defaultPort = Number.parseInt(rawPort, 10);

if (!Number.isInteger(defaultPort) || defaultPort <= 0 || defaultPort > 65535) {
  throw new Error(`Invalid CAPGO_MAESTRO_PORT: ${rawPort}`);
}

export const defaultHostBaseUrl = process.env.CAPGO_MAESTRO_HOST_BASE_URL ?? `http://127.0.0.1:${defaultPort}`; // NOSONAR loopback-only fake OTA server for Maestro
export const defaultDeviceBaseUrl = process.env.CAPGO_MAESTRO_DEVICE_BASE_URL ?? `http://10.0.2.2:${defaultPort}`; // NOSONAR emulator alias for the local fake OTA server
export const exampleAppId = 'app.capgo.updater';
export const exampleApkPath = path.join(
  exampleAppDir,
  'android',
  'app',
  'build',
  'outputs',
  'apk',
  'debug',
  'app-debug.apk',
);

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
  'native-reset': {
    id: 'native-reset',
    directUpdate: 'always',
    builtinLabel: 'native-reset-builtin-v1',
    releases: [{ version: 'native-reset-live', label: 'native-reset-live' }],
  },
};

export function findScenario(id) {
  return scenarios[id] ?? null;
}

export function getScenario(id) {
  const scenario = findScenario(id);

  if (!scenario) {
    throw new Error(`Unknown Maestro scenario: ${id}`);
  }

  return scenario;
}

export function getBundleZipPath(version) {
  return path.join(bundleArtifactDir, `${version}.zip`);
}

export function createBuildEnv({ scenarioId, directUpdate, appLabel, env = process.env }) {
  const rawEnvPort = env.CAPGO_MAESTRO_PORT?.trim() || String(defaultPort);
  const envPort = Number.parseInt(rawEnvPort, 10);

  if (!Number.isInteger(envPort) || envPort <= 0 || envPort > 65535) {
    throw new Error(`Invalid CAPGO_MAESTRO_PORT: ${rawEnvPort}`);
  }

  const deviceBaseUrl = env.CAPGO_MAESTRO_DEVICE_BASE_URL ?? `http://10.0.2.2:${envPort}`;
  const updateUrl = `${deviceBaseUrl}/api/updates/${scenarioId}`;

  return {
    ...env,
    VITE_CAPGO_APP_LABEL: appLabel,
    VITE_CAPGO_SCENARIO: scenarioId,
    VITE_CAPGO_DIRECT_UPDATE: directUpdate,
    VITE_CAPGO_SERVER_URL: updateUrl,
    CAPGO_UPDATE_URL: updateUrl,
    CAPGO_STATS_URL: `${deviceBaseUrl}/api/stats`,
    CAPGO_CHANNEL_URL: `${deviceBaseUrl}/api/channel`,
  };
}
