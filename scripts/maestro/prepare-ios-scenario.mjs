import { runCommand } from './command.mjs';
import { purgeLocalPluginCopy } from './purge-local-plugin-copy.mjs';
import { createBuildEnv, exampleAppDir, getScenario, resolveAppScenarioId } from './scenarios.mjs';

const scenarioId = process.argv[2];

if (!scenarioId) {
  throw new Error('Usage: bun scripts/maestro/prepare-ios-scenario.mjs <scenario-id>');
}

const scenario = getScenario(resolveAppScenarioId(scenarioId));

const env = {
  ...createBuildEnv({
    scenarioId: scenario.id,
    directUpdate: scenario.directUpdate,
    appLabel: scenario.builtinLabel,
    autoUpdate: scenario.autoUpdate,
    extraEnv: scenario.env ?? {},
  }),
  CAPGO_DIRECT_UPDATE: scenario.directUpdate,
};

purgeLocalPluginCopy();

await runCommand('bun', ['install'], {
  cwd: exampleAppDir,
  env,
});

await runCommand('bun', ['run', 'build'], {
  cwd: exampleAppDir,
  env,
});

await runCommand('bunx', ['cap', 'sync', 'ios'], {
  cwd: exampleAppDir,
  env,
});
