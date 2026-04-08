import { spawn } from 'node:child_process';
import { defaultDeviceBaseUrl, exampleAppDir, getScenario } from './scenarios.mjs';

const scenarioId = process.argv[2];

if (!scenarioId) {
  throw new Error('Usage: bun scripts/maestro/prepare-android-scenario.mjs <scenario-id>');
}

const scenario = getScenario(scenarioId);

function runCommand(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: 'inherit',
    });

    child.on('exit', (code) => {
      if (code === 0) {
        resolve();
        return;
      }

      reject(new Error(`${command} ${args.join(' ')} failed with exit code ${code}`));
    });
  });
}

const env = {
  ...process.env,
  CAPGO_AUTO_UPDATE: 'true',
  CAPGO_DIRECT_UPDATE: scenario.directUpdate,
  CAPGO_UPDATE_URL: `${defaultDeviceBaseUrl}/api/updates/${scenario.id}`,
  CAPGO_STATS_URL: `${defaultDeviceBaseUrl}/api/stats`,
  CAPGO_CHANNEL_URL: `${defaultDeviceBaseUrl}/api/channel`,
  VITE_CAPGO_APP_LABEL: scenario.builtinLabel,
  VITE_CAPGO_SCENARIO: scenario.id,
  VITE_CAPGO_DIRECT_UPDATE: scenario.directUpdate,
  VITE_CAPGO_SERVER_URL: `${defaultDeviceBaseUrl}/api/updates/${scenario.id}`,
};

await runCommand('bun', ['run', 'build'], {
  cwd: exampleAppDir,
  env,
});

await runCommand('bunx', ['cap', 'sync', 'android'], {
  cwd: exampleAppDir,
  env,
});

await runCommand('./gradlew', ['assembleDebug'], {
  cwd: `${exampleAppDir}/android`,
  env,
});
