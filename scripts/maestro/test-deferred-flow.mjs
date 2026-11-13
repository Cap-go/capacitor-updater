import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const flowDir = new URL('../../.maestro/ios/', import.meta.url);
const [, deferred] = Bun.YAML.parse(await readFile(new URL('live-update-deferred.yaml', flowDir), 'utf8'));
const [, core] = Bun.YAML.parse(await readFile(new URL('assert-live-update-core.yaml', flowDir), 'utf8'));
const call = deferred.find((step) => step.runFlow?.file === 'assert-live-update-core.yaml')?.runFlow;
assert.ok(call?.env, 'Deferred relaunch must supply the core assertion parameters');

const fields = {
  FIRST_BUILD_LABEL: 'Build label: 1.2.3+deferred',
  SCENARIO_LINE: 'Scenario: deferred',
  DIRECT_UPDATE_LINE: 'Direct update mode: false',
  AUTO_UPDATE_ENABLED_LINE: 'Auto update enabled: true',
  AUTO_UPDATE_AVAILABLE_LINE: 'Auto update available: true',
  FIRST_NOTIFY_READY_LINE: 'Notify app ready: ok (1.2.3+deferred)',
  DOWNLOADED_SOURCE_LINE: 'Current bundle source: downloaded',
  FIRST_CURRENT_VERSION_LINE: 'Current bundle version: 1.2.3+deferred',
};
const parameters = Object.fromEntries(
  Object.entries(call.env).map(([name, reference]) => {
    const source = /^\$\{(\w+)\}$/.exec(reference)?.[1];
    assert.ok(Object.hasOwn(fields, source), `Missing deferred fixture for ${source}`);
    return [name, `.*${fields[source].replace(/[.*+?^${}()|[\]\\]/g, String.raw`\$&`)}.*`];
  }),
);
const template = core.find((step) => step.extendedWaitUntil?.visible.includes('${'))?.extendedWaitUntil.visible;
assert.ok(template, 'Core assertion must wait for the pinned state summary');
const pattern = template.replace(/\$\{(\w+)\}/g, (_, name) => {
  assert.ok(Object.hasOwn(parameters, name), `Deferred flow does not supply ${name}`);
  return parameters[name];
});
const matcher = new RegExp(`^${pattern}$`);
const summary = `Harness: ready | ${Object.values(fields).join(' | ')} | Next bundle version: none`;
assert.match(summary, matcher);
assert.doesNotMatch(summary.replace('Harness: ready', 'Harness: booting'), matcher);
for (const field of Object.values(fields)) {
  assert.doesNotMatch(summary.replace(field, 'incorrect state'), matcher, `Must check ${field}`);
}
console.log('Deferred flow checks passed (all helper parameters supplied, ready state and every field required).');
