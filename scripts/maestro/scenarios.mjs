import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
export const repoRoot = path.resolve(scriptDir, '..', '..');
export const exampleAppDir = path.join(repoRoot, 'example-app');
export const maestroDir = path.join(repoRoot, '.maestro');
export const artifactDir = path.join(repoRoot, '.maestro-artifacts');
export const bundleArtifactDir = path.join(artifactDir, 'bundles');
export const manifestArtifactDir = path.join(artifactDir, 'manifest');
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

const sharedMutableConfig = {
  CAPGO_APP_READY_TIMEOUT: '60000',
  CAPGO_ALLOW_MANUAL_BUNDLE_ERROR: 'true',
  CAPGO_ALLOW_MODIFY_APP_ID: 'true',
  CAPGO_ALLOW_MODIFY_URL: 'true',
  CAPGO_ALLOW_SET_DEFAULT_CHANNEL: 'true',
  CAPGO_PERSIST_CUSTOM_ID: 'true',
  CAPGO_PERSIST_MODIFY_URL: 'true',
};

export const scenarios = {
  deferred: {
    id: 'deferred',
    mode: 'auto',
    delivery: 'zip',
    autoUpdate: true,
    directUpdate: 'false',
    builtinLabel: 'deferred-builtin',
    releases: [{ version: 'deferred-v1', label: 'deferred-v1' }],
  },
  always: {
    id: 'always',
    mode: 'auto',
    delivery: 'zip',
    autoUpdate: true,
    directUpdate: 'always',
    builtinLabel: 'always-builtin',
    releases: [
      { version: 'always-v1', label: 'always-v1' },
      { version: 'always-v2', label: 'always-v2' },
    ],
  },
  'legacy-true': {
    id: 'legacy-true',
    mode: 'auto',
    delivery: 'zip',
    autoUpdate: true,
    directUpdate: 'true',
    builtinLabel: 'legacy-true-builtin',
    releases: [
      { version: 'legacy-true-v1', label: 'legacy-true-v1' },
      { version: 'legacy-true-v2', label: 'legacy-true-v2' },
    ],
  },
  'at-install': {
    id: 'at-install',
    mode: 'auto',
    delivery: 'zip',
    autoUpdate: true,
    directUpdate: 'atInstall',
    builtinLabel: 'at-install-builtin',
    releases: [
      { version: 'at-install-v1', label: 'at-install-v1' },
      { version: 'at-install-v2', label: 'at-install-v2' },
    ],
  },
  'on-launch': {
    id: 'on-launch',
    mode: 'auto',
    delivery: 'zip',
    autoUpdate: true,
    directUpdate: 'onLaunch',
    builtinLabel: 'on-launch-builtin',
    releases: [
      { version: 'on-launch-v1', label: 'on-launch-v1' },
      { version: 'on-launch-v2', label: 'on-launch-v2' },
      { version: 'on-launch-v3', label: 'on-launch-v3' },
    ],
  },
  'manual-zip': {
    id: 'manual-zip',
    mode: 'manual',
    delivery: 'zip',
    autoUpdate: false,
    directUpdate: 'false',
    builtinLabel: 'manual-zip-builtin',
    env: {
      ...sharedMutableConfig,
    },
    releases: [
      { version: 'manual-zip-v1', label: 'manual-zip-v1' },
      { version: 'manual-zip-v2', label: 'manual-zip-v2' },
      {
        version: 'manual-zip-v3-broken',
        label: 'manual-zip-v3-broken',
        env: {
          CAPGO_APP_READY_TIMEOUT: '5000',
          VITE_CAPGO_SKIP_NOTIFY_APP_READY: 'true',
        },
      },
      { version: 'manual-zip-v4', label: 'manual-zip-v4' },
    ],
  },
  'manual-manifest': {
    id: 'manual-manifest',
    mode: 'manual',
    delivery: 'manifest',
    autoUpdate: false,
    directUpdate: 'false',
    builtinLabel: 'manual-manifest-builtin',
    env: {
      ...sharedMutableConfig,
    },
    releases: [
      { version: 'manual-manifest-v1', label: 'manual-manifest-v1' },
      { version: 'manual-manifest-v2', label: 'manual-manifest-v2' },
    ],
  },
  'manual-zip-no-persist': {
    id: 'manual-zip-no-persist',
    mode: 'manual',
    delivery: 'zip',
    autoUpdate: false,
    directUpdate: 'false',
    builtinLabel: 'manual-zip-no-persist-builtin',
    env: {
      ...sharedMutableConfig,
      CAPGO_PERSIST_CUSTOM_ID: 'false',
      CAPGO_PERSIST_MODIFY_URL: 'false',
    },
    releases: [{ version: 'manual-zip-no-persist-v1', label: 'manual-zip-no-persist-v1' }],
  },
  'manual-zip-config-guards': {
    id: 'manual-zip-config-guards',
    mode: 'manual',
    delivery: 'zip',
    autoUpdate: false,
    directUpdate: 'false',
    builtinLabel: 'manual-zip-config-guards-builtin',
    env: {
      ...sharedMutableConfig,
      CAPGO_ALLOW_MANUAL_BUNDLE_ERROR: 'false',
      CAPGO_ALLOW_MODIFY_APP_ID: 'false',
      CAPGO_ALLOW_MODIFY_URL: 'false',
      CAPGO_ALLOW_SET_DEFAULT_CHANNEL: 'false',
    },
    releases: [{ version: 'manual-zip-config-guards-v1', label: 'manual-zip-config-guards-v1' }],
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

export function getManifestDirectoryPath(version) {
  return path.join(manifestArtifactDir, version);
}

export function getManifestMetadataPath(version) {
  return path.join(manifestArtifactDir, `${version}.json`);
}

export function createBuildEnv({
  scenarioId,
  directUpdate,
  appLabel,
  autoUpdate = false,
  extraEnv = {},
  env = process.env,
}) {
  const rawEnvPort = env.CAPGO_MAESTRO_PORT?.trim() || String(defaultPort);
  const envPort = Number.parseInt(rawEnvPort, 10);

  if (!Number.isInteger(envPort) || envPort <= 0 || envPort > 65535) {
    throw new Error(`Invalid CAPGO_MAESTRO_PORT: ${rawEnvPort}`);
  }

  const deviceBaseUrl = env.CAPGO_MAESTRO_DEVICE_BASE_URL ?? `http://10.0.2.2:${envPort}`;
  const updateUrl = `${deviceBaseUrl}/api/updates/${scenarioId}`;

  const mergedEnv = {
    ...env,
    ...extraEnv,
  };

  return {
    ...mergedEnv,
    CAPGO_AUTO_UPDATE: String(autoUpdate),
    VITE_CAPGO_APP_LABEL: appLabel,
    VITE_CAPGO_SCENARIO: scenarioId,
    VITE_CAPGO_DIRECT_UPDATE: directUpdate,
    VITE_CAPGO_SERVER_URL: updateUrl,
    VITE_CAPGO_ALLOW_MANUAL_BUNDLE_ERROR: mergedEnv.CAPGO_ALLOW_MANUAL_BUNDLE_ERROR ?? 'false',
    VITE_CAPGO_ALLOW_MODIFY_APP_ID: mergedEnv.CAPGO_ALLOW_MODIFY_APP_ID ?? 'false',
    VITE_CAPGO_ALLOW_MODIFY_URL: mergedEnv.CAPGO_ALLOW_MODIFY_URL ?? 'false',
    VITE_CAPGO_ALLOW_SET_DEFAULT_CHANNEL: mergedEnv.CAPGO_ALLOW_SET_DEFAULT_CHANNEL ?? 'true',
    VITE_CAPGO_PERSIST_CUSTOM_ID: mergedEnv.CAPGO_PERSIST_CUSTOM_ID ?? 'false',
    VITE_CAPGO_PERSIST_MODIFY_URL: mergedEnv.CAPGO_PERSIST_MODIFY_URL ?? 'false',
    CAPGO_UPDATE_URL: updateUrl,
    CAPGO_STATS_URL: `${deviceBaseUrl}/api/stats?scenario=${scenarioId}`,
    CAPGO_CHANNEL_URL: `${deviceBaseUrl}/api/channel?scenario=${scenarioId}`,
  };
}
