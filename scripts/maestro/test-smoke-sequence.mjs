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

const bootstrapStart = source.indexOf('async function bootstrap()');
const bootstrapEnd = source.indexOf('\nbindActionButton(', bootstrapStart);
const verifyStart = source.indexOf('async function verifyPersistedRuntimeConfig(');
const verifyEnd = source.indexOf('\nasync function runGetLatestCheck()', verifyStart);
const bootSource = `${source.slice(verifyStart, verifyEnd)}\n${source.slice(bootstrapStart, bootstrapEnd)}`;

function bootHarness(overrides = {}) {
  const noop = () => {};
  const context = vm.createContext({
    platform: 'android',
    isMaestroE2E: true,
    scenarioId: 'manual-zip',
    buildLabel: 'manual-zip-builtin',
    bootActionFromStorage: 'verify-persisted-config-boot',
    serverUrl: 'http://127.0.0.1:3192',
    skipNotifyAppReady: false,
    persistCustomId: false,
    defaultSmokeAppId: 'app.test',
    state: { bootCount: 1, harnessReady: false },
    window: { history: {} },
    document: { body: { classList: { add: noop } }, documentElement: { classList: { add: noop } } },
    SplashScreen: { hide: noop },
    ...Object.fromEntries(
      [
        'resetScrollPosition',
        'configureQaToolsPanel',
        'renderQuickActions',
        'pinMaestroQuickActions',
        'renderActions',
        'bindDemoActions',
        'renderState',
        'attachListeners',
        'performNotifyAppReady',
        'refreshState',
        'startStateRefreshWatchers',
        'ensureManualManifestRuntimeUrls',
      ].map((name) => [name, noop]),
    ),
    plugin: { listChannels: async () => ({ channels: [{ name: 'production' }] }) },
    expectListChannelsResult: (result) => result,
    refreshServerState: async () => {
      context.state.serverDebug = { debug: null, error: 'WebView fetch unavailable' };
    },
    waitForCondition: async (check) => {
      if (!(await check())) throw new Error('server debug timed out');
    },
    getActionById: (id) => {
      assert.equal(id, 'verify-persisted-config-boot');
      return {
        run: () => context.verifyPersistedRuntimeConfig({ includePluginAppId: false, probeLatest: false }),
      };
    },
    runAction: async (action) => {
      context.bootResult = await action.run();
    },
    attachMaestroDeepLinks: async () => {
      context.deepLinksAttached = true;
    },
    console: {
      error: (_, error) => {
        context.bootError = error;
      },
    },
    ...overrides,
  });
  // Only the two fixed functions read from the checked-in example app are executed.
  vm.runInContext(bootSource, context); // NOSONAR trusted repository code executed in this isolated test harness
  return context;
}

const androidBoot = bootHarness();
await androidBoot.bootstrap();
assert.equal(androidBoot.bootResult.channels[0].name, 'production');
assert.equal(androidBoot.bootResult.note, 'server debug unavailable in Android WebView');
assert.equal(androidBoot.state.harnessReady, true);
assert.equal(androidBoot.deepLinksAttached, true);

const nativeFailure = new Error('native channels failed');
const failedBoot = bootHarness({
  plugin: {
    listChannels: async () => {
      throw nativeFailure;
    },
  },
});
await failedBoot.bootstrap();
assert.equal(failedBoot.bootError, nativeFailure);
assert.equal(failedBoot.bootResult, undefined);

const iosBoot = bootHarness({ platform: 'ios' });
await assert.rejects(iosBoot.bootstrap(), /server debug timed out/);
assert.equal(iosBoot.bootResult, undefined);
assert.equal(iosBoot.state.harnessReady, false);
console.log('Boot checks passed (Android native fallback, native failure, iOS debug gate).');
