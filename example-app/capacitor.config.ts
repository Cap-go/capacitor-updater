import type { CapacitorConfig } from '@capacitor/cli';

const autoUpdate = process.env.CAPGO_AUTO_UPDATE === 'true';
const directUpdateEnv = process.env.CAPGO_DIRECT_UPDATE ?? 'false';
const directUpdate =
  directUpdateEnv === 'true' || directUpdateEnv === 'false' ? directUpdateEnv === 'true' : directUpdateEnv;

const config: CapacitorConfig = {
  appId: 'app.capgo.updater',
  appName: 'Updater Example',
  webDir: 'dist',
  plugins: {
    SplashScreen: {
      launchAutoHide: false,
    },
    CapacitorUpdater: {
      autoUpdate,
      allowModifyUrl: true,
      directUpdate,
      updateUrl: process.env.CAPGO_UPDATE_URL,
      statsUrl: process.env.CAPGO_STATS_URL,
      channelUrl: process.env.CAPGO_CHANNEL_URL,
      appReadyTimeout: 20000,
    },
  },
};

export default config;
