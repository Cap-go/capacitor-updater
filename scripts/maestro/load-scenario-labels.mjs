import process from 'node:process';
import { getScenario, resolveAppScenarioId } from './scenarios.mjs';

const scenarioId = process.argv[2];
const builtinVersion = process.argv[3];

if (!builtinVersion) {
  throw new Error('Unable to determine example-app iOS MARKETING_VERSION');
}

const scenario = getScenario(resolveAppScenarioId(scenarioId));
console.log(
  [scenario.builtinLabel, builtinVersion.trim(), ...scenario.releases.map((release) => release.version)].join(
    '\t',
  ),
);
