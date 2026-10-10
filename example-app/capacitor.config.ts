import type { CapacitorConfig } from '@capacitor/cli';

const autoUpdate = process.env.CAPGO_AUTO_UPDATE === 'true';
const directUpdateEnv = process.env.CAPGO_DIRECT_UPDATE ?? 'false';
const directUpdate =
  directUpdateEnv === 'true' || directUpdateEnv === 'false'
    ? directUpdateEnv === 'true'
    : directUpdateEnv;
const usesDirectUpdate = directUpdate !== false;
const parsedAppReadyTimeout = Number.parseInt(process.env.CAPGO_APP_READY_TIMEOUT ?? '20000', 10);
const appReadyTimeout =
  Number.isFinite(parsedAppReadyTimeout) && parsedAppReadyTimeout >= 1000
    ? parsedAppReadyTimeout
    : 20000;

function isLocalHttpUrl(value: string | undefined): boolean {
  if (!value) return false;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.protocol !== 'http:') return false;
  const host = url.hostname;
  return (
    host === 'localhost' ||
    host === '127.0.0.1' ||
    host === '::1' ||
    host === '[::1]' ||
    host === '10.0.2.2' || // NOSONAR Android emulator alias for the host loopback, test-only
    /^10\./.test(host) ||
    /^192\.168\./.test(host) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(host)
  );
}

function readBooleanEnv(name: string, fallback = false): boolean {
  const rawValue = process.env[name];

  if (rawValue == null) {
    return fallback;
  }

  return rawValue === 'true';
}

const config: CapacitorConfig = {
  appId: 'app.capgo.updater',
  appName: '@capgo/capacitor-updater',
  webDir: 'dist',
  plugins: {
    SplashScreen: {
      launchAutoHide: !usesDirectUpdate,
    },
    CapacitorUpdater: {
      autoUpdate,
      allowModifyUrl: readBooleanEnv('CAPGO_ALLOW_MODIFY_URL', true),
      // Maestro runs a plain-http fake server on loopback / the emulator host alias / a LAN IP.
      // Only those hosts relax httpsOnly automatically; any other http URL needs CAPGO_HTTPS_ONLY=false.
      httpsOnly: readBooleanEnv('CAPGO_HTTPS_ONLY', !isLocalHttpUrl(process.env.CAPGO_UPDATE_URL)),
      allowModifyAppId: readBooleanEnv('CAPGO_ALLOW_MODIFY_APP_ID', true),
      allowManualBundleError: readBooleanEnv('CAPGO_ALLOW_MANUAL_BUNDLE_ERROR', true),
      allowSetDefaultChannel: readBooleanEnv('CAPGO_ALLOW_SET_DEFAULT_CHANNEL', true),
      directUpdate,
      persistCustomId: readBooleanEnv('CAPGO_PERSIST_CUSTOM_ID', true),
      persistModifyUrl: readBooleanEnv('CAPGO_PERSIST_MODIFY_URL', true),
      updateUrl: process.env.CAPGO_UPDATE_URL,
      statsUrl: process.env.CAPGO_STATS_URL,
      channelUrl: process.env.CAPGO_CHANNEL_URL,
      appReadyTimeout,
      autoSplashscreen: usesDirectUpdate,
    },
  },
};

export default config;
