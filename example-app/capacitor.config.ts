import type { CapacitorConfig } from '@capacitor/cli';

const autoUpdate = process.env.CAPGO_AUTO_UPDATE === 'true';
const directUpdateEnv = process.env.CAPGO_DIRECT_UPDATE ?? 'false';
const directUpdate =
  directUpdateEnv === 'true' || directUpdateEnv === 'false' ? directUpdateEnv === 'true' : directUpdateEnv;
const parsedAppReadyTimeout = Number.parseInt(process.env.CAPGO_APP_READY_TIMEOUT ?? '20000', 10);
const appReadyTimeout = Number.isFinite(parsedAppReadyTimeout) && parsedAppReadyTimeout >= 1000 ? parsedAppReadyTimeout : 20000;

function readBooleanEnv(name: string, fallback = false): boolean {
  const rawValue = process.env[name];

  if (rawValue == null) {
    return fallback;
  }

  return rawValue === 'true';
}

const config: CapacitorConfig = {
  appId: 'app.capgo.updater',
  appName: 'Updater Example',
  webDir: 'dist',
  plugins: {
    SplashScreen: {
      launchAutoHide: true,
    },
    CapacitorUpdater: {
      autoUpdate,
      allowModifyUrl: readBooleanEnv('CAPGO_ALLOW_MODIFY_URL', true),
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
    },
  },
};

export default config;
