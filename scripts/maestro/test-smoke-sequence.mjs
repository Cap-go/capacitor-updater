import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(new URL('../../example-app/src/main.js', import.meta.url), 'utf8');
const start = source.indexOf('async function runSmokeSequence()');
const end = source.indexOf('\nfunction getSmokeSequenceActions()', start);
const sequence = source.slice(start, end);

function harness(overrides = {}) {
  const context = vm.createContext({
    smokeSequencePromise: null,
    sequenceInProgress: false,
    smokeSequenceStatus: 'idle',
    actionInProgress: false,
    isMaestroE2E: true,
    suppressNonSequenceActionsUntil: 0,
    elements: Object.fromEntries(
      ['sequenceStatus', 'resultMarker', 'output', 'runSmokeSequenceButton', 'quickRunSmokeSequenceButton'].map(
        (key) => [key, {}],
      ),
    ),
    state: { sequenceRuns: 0, lastActionMarker: 'smoke-sequence:success' },
    window: { localStorage: { setItem() {} } },
    lastActionStorageKey: 'action',
    lastActionMarkerStorageKey: 'marker',
    lastActionResultStorageKey: 'result',
    getSmokeSequenceActions: () => [{ id: 'test-action' }],
    actionCards: new Map(),
    renderState() {},
    renderDemoActionButtons() {},
    waitForPendingRefresh: async () => {},
    waitForCondition: async (check) => {
      assert.equal(await check(), true);
    },
    runAction: async () => {},
    withTimeout: async (_, operation) => operation(),
    pause: async () => {},
    getSmokeSequenceDelayMs: () => 0,
    refreshState: async () => {},
    console: { error() {} },
    ...overrides,
  });
  // The executed source is only the fixed, checked-in example-app function above, never CLI or network input.
  vm.runInContext(sequence, context); // NOSONAR trusted repository code executed in this isolated test harness
  return context;
}

const failed = harness({
  waitForPendingRefresh: async () => {
    throw new Error('refresh timed out');
  },
});
await assert.rejects(failed.runSmokeSequence(), /refresh timed out/);
assert.equal(failed.sequenceInProgress, false);
assert.equal(failed.smokeSequencePromise, null);
assert.equal(failed.elements.runSmokeSequenceButton.disabled, false);
assert.equal(failed.elements.quickRunSmokeSequenceButton.disabled, false);
assert.equal(failed.smokeSequenceStatus, 'error');
assert.match(failed.state.lastActionMarker, /^smoke-sequence:error:/);

let releaseAction;
const actionDone = new Promise((resolve) => {
  releaseAction = resolve;
});
let runs = 0;
const queued = harness({
  actionInProgress: true,
  waitForCondition: async (check) => {
    await actionDone;
    assert.equal(await check(), true);
  },
  runAction: async () => {
    runs++;
  },
});
const first = queued.runSmokeSequence();
const duplicate = queued.runSmokeSequence();
assert.equal(queued.smokeSequenceStatus, 'running');
assert.equal(queued.state.lastActionMarker, 'smoke-sequence:running');
assert.equal(runs, 0);
queued.actionInProgress = false;
releaseAction();
await Promise.all([first, duplicate]);
assert.equal(runs, 1);
assert.equal(queued.state.sequenceRuns, 1);
assert.equal(queued.smokeSequenceStatus, 'success');
assert.equal(queued.sequenceInProgress, false);
console.log(
  'Smoke sequence checks passed (refresh failure cleanup, stale marker reset, action serialization, duplicate suppression).',
);
