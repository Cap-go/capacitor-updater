import { runCommand } from './command.mjs';
import { createBuildEnv, exampleAppDir, getScenario } from './scenarios.mjs';

async function runCommandWithRetries(command, args, options, maxAttempts = 3) {
  let attempt = 1;

  while (attempt <= maxAttempts) {
    try {
      await runCommand(command, args, options);
      return;
    } catch (error) {
      if (attempt === maxAttempts) {
        throw error;
      }

      console.warn(
        `[maestro] ${command} ${args.join(' ')} failed on attempt ${attempt}/${maxAttempts}: ${error.message}`,
      );
      console.warn('[maestro] Retrying after a short delay...');
      await Bun.sleep(attempt * 5000);
      attempt += 1;
    }
  }
}

const scenarioId = process.argv[2];

if (!scenarioId) {
  throw new Error('Usage: bun scripts/maestro/prepare-android-scenario.mjs <scenario-id>');
}

const scenario = getScenario(scenarioId);

const env = {
  ...createBuildEnv({
    scenarioId: scenario.id,
    directUpdate: scenario.directUpdate,
    appLabel: scenario.builtinLabel,
  }),
  CAPGO_AUTO_UPDATE: 'true',
  CAPGO_DIRECT_UPDATE: scenario.directUpdate,
};

await runCommand('bun', ['run', 'build'], {
  cwd: exampleAppDir,
  env,
});

await runCommand('bunx', ['cap', 'sync', 'android'], {
  cwd: exampleAppDir,
  env,
});

await runCommandWithRetries('./gradlew', ['assembleDebug'], {
  cwd: `${exampleAppDir}/android`,
  env,
});
