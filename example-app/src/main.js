import './style.css';
import { Capacitor } from '@capacitor/core';
import { CapacitorUpdater } from '@capgo/capacitor-updater';

if (window.__capgoProbe) {
  window.__capgoProbe.moduleLoadedAt = new Date().toISOString();
}
console.log('[Harness] module boot', window.__capgoProbe ?? null);

const plugin = CapacitorUpdater;
const buildLabel = import.meta.env.VITE_CAPGO_APP_LABEL ?? 'manual-build';
const scenarioId = import.meta.env.VITE_CAPGO_SCENARIO ?? 'manual';
const directUpdateMode = import.meta.env.VITE_CAPGO_DIRECT_UPDATE ?? 'false';
const serverUrl = import.meta.env.VITE_CAPGO_SERVER_URL ?? 'not-configured';
const bootStorageKey = '__capgo_maestro_boot_count';
const maxEvents = 8;
const fallbackUpdateUrl = 'https://example.com/api/auto_update';
const defaultUpdateUrl = serverUrl.startsWith('http') ? serverUrl : fallbackUpdateUrl;
const isSmokeMode = scenarioId === 'manual' && serverUrl === 'not-configured';
const shouldAutoRunSmokeSequence = isSmokeMode && Capacitor.getPlatform() === 'android';

function requireElement(id) {
  const element = document.getElementById(id);
  if (!element) {
    throw new Error(`Expected #${id} in index.html`);
  }
  return element;
}

const elements = {
  appLabel: requireElement('app-label'),
  scenarioId: requireElement('scenario-id'),
  directUpdateMode: requireElement('direct-update-mode'),
  serverUrl: requireElement('server-url'),
  bootCount: requireElement('boot-count'),
  notifyStatus: requireElement('notify-status'),
  autoUpdateEnabled: requireElement('auto-update-enabled'),
  autoUpdateAvailable: requireElement('auto-update-available'),
  e2eSummary: requireElement('e2e-summary'),
  currentBundleSource: requireElement('current-bundle-source'),
  currentBundle: requireElement('current-bundle'),
  nextBundle: requireElement('next-bundle'),
  bundleCount: requireElement('bundle-count'),
  lastDownload: requireElement('last-download'),
  eventLog: requireElement('event-log'),
  smokeActions: requireElement('smoke-actions'),
  runSmokeSequenceButton: requireElement('run-smoke-sequence'),
  lastAction: requireElement('last-action'),
  actionStatus: requireElement('action-status'),
  resultMarker: requireElement('result-marker'),
  sequenceStatus: requireElement('sequence-status'),
  output: requireElement('plugin-output'),
  debugOutput: requireElement('debug-output'),
  refreshButton: requireElement('refresh-state'),
};

const actionCards = new Map();
const actionMarkers = new Map();
let smokeSequencePromise = null;
const state = {
  bootCount: incrementBootCount(),
  notifyStatus: 'pending',
  autoUpdateEnabled: 'loading',
  autoUpdateAvailable: 'loading',
  currentBundle: null,
  nextBundle: null,
  bundles: [],
  lastDownload: 'none',
  events: [],
  lastError: null,
  lastHarnessSnapshot: '',
};

const actions = [
  {
    id: 'notify-app-ready',
    label: 'Notify app ready',
    buttonLabel: 'Run notifyAppReady',
    description: 'Confirm that the current bundle booted successfully.',
    inputs: [],
    run: async () => {
      const result = await performNotifyAppReady();
      return result ?? 'notifyAppReady() resolved.';
    },
  },
  {
    id: 'current-bundle',
    label: 'Get current bundle',
    buttonLabel: 'Run get current bundle',
    description: 'Read the active bundle and builtin native version.',
    inputs: [],
    run: async () => plugin.current(),
  },
  {
    id: 'list-bundles',
    label: 'List downloaded bundles',
    buttonLabel: 'Run list downloaded bundles',
    description: 'Inspect bundles currently stored on the device.',
    inputs: [],
    run: async () => plugin.list(),
  },
  {
    id: 'get-plugin-version',
    label: 'Get plugin version',
    buttonLabel: 'Run get plugin version',
    description: 'Return the installed native plugin version.',
    inputs: [],
    run: async () => plugin.getPluginVersion(),
  },
  {
    id: 'set-update-url',
    label: 'Set update URL',
    buttonLabel: 'Apply update URL',
    description: 'Point the example app at a custom update endpoint.',
    inputs: [
      {
        name: 'updateUrl',
        label: 'Update URL',
        type: 'text',
        value: defaultUpdateUrl,
        placeholder: fallbackUpdateUrl,
      },
    ],
    run: async (values) => {
      if (!values.updateUrl) {
        throw new Error('Provide an update URL.');
      }
      await plugin.setUpdateUrl({ url: values.updateUrl });
      addEvent('Update URL set', { url: values.updateUrl });
      return {
        message: 'Update URL set.',
        url: values.updateUrl,
      };
    },
  },
];

function incrementBootCount() {
  const stored = Number(window.localStorage.getItem(bootStorageKey) ?? '0');
  const previous = Number.isFinite(stored) ? stored : 0;
  const next = previous + 1;
  window.localStorage.setItem(bootStorageKey, String(next));
  return next;
}

function getBundleVersion(bundle) {
  if (!bundle) {
    return 'none';
  }

  return bundle.versionName ?? bundle.version ?? bundle.id ?? 'unknown';
}

function getBundleSource(bundle) {
  if (!bundle) {
    return 'none';
  }

  return bundle.id === 'builtin' ? 'builtin' : 'downloaded';
}

function getTimestamp(bundle) {
  if (!bundle?.downloaded) {
    return Number.NEGATIVE_INFINITY;
  }

  const parsed = Date.parse(bundle.downloaded);
  return Number.isNaN(parsed) ? Number.NEGATIVE_INFINITY : parsed;
}

function getLastDownloadedBundleVersion(bundles) {
  const latestDownloadedBundle = [...bundles]
    .filter((bundle) => bundle?.id !== 'builtin' && getTimestamp(bundle) !== Number.NEGATIVE_INFINITY)
    .sort((left, right) => getTimestamp(right) - getTimestamp(left))[0];

  return latestDownloadedBundle ? getBundleVersion(latestDownloadedBundle) : 'none';
}

function addEvent(label, payload) {
  const entry = {
    label,
    payload,
    timestamp: new Date().toISOString(),
  };

  state.events.unshift(entry);
  state.events = state.events.slice(0, maxEvents);
  renderEventLog();
}

function renderEventLog() {
  elements.eventLog.innerHTML = '';

  if (!state.events.length) {
    const item = document.createElement('li');
    item.textContent = 'No updater events captured yet.';
    elements.eventLog.appendChild(item);
    return;
  }

  state.events.forEach((entry) => {
    const item = document.createElement('li');
    const bundle = entry.payload?.bundle ? getBundleVersion(entry.payload.bundle) : '';
    const detail = bundle || entry.payload?.version || entry.payload?.message || entry.payload?.status || '';
    const detailSuffix = detail ? `: ${detail}` : '';
    item.textContent = `${entry.label}${detailSuffix}`;
    elements.eventLog.appendChild(item);
  });
}

function renderState() {
  const harnessSnapshot = createHarnessSnapshot();

  elements.appLabel.textContent = `Build label: ${buildLabel}`;
  elements.scenarioId.textContent = `Scenario: ${scenarioId}`;
  elements.directUpdateMode.textContent = `Direct update mode: ${directUpdateMode}`;
  elements.serverUrl.textContent = `Server URL: ${serverUrl}`;
  elements.bootCount.textContent = `Boot count: ${state.bootCount}`;
  elements.notifyStatus.textContent = `Notify app ready: ${state.notifyStatus}`;
  elements.autoUpdateEnabled.textContent = `Auto update enabled: ${state.autoUpdateEnabled}`;
  elements.autoUpdateAvailable.textContent = `Auto update available: ${state.autoUpdateAvailable}`;
  elements.e2eSummary.textContent =
    `Build label: ${buildLabel} | ` +
    `Scenario: ${scenarioId} | ` +
    `Direct update mode: ${directUpdateMode} | ` +
    `Auto update enabled: ${state.autoUpdateEnabled} | ` +
    `Auto update available: ${state.autoUpdateAvailable} | ` +
    `Notify app ready: ${state.notifyStatus} | ` +
    `Current bundle source: ${getBundleSource(state.currentBundle)} | ` +
    `Current bundle version: ${getBundleVersion(state.currentBundle)} | ` +
    `Next bundle version: ${getBundleVersion(state.nextBundle)} | ` +
    `Last completed download: ${state.lastDownload}`;
  elements.currentBundleSource.textContent = `Current bundle source: ${getBundleSource(state.currentBundle)}`;
  elements.currentBundle.textContent = `Current bundle version: ${getBundleVersion(state.currentBundle)}`;
  elements.nextBundle.textContent = `Next bundle version: ${getBundleVersion(state.nextBundle)}`;
  elements.bundleCount.textContent = `Downloaded bundle count: ${state.bundles.length}`;
  elements.lastDownload.textContent = `Last completed download: ${state.lastDownload}`;
  elements.debugOutput.textContent = JSON.stringify(
    {
      ...harnessSnapshot,
      serverUrl,
      probe: window.__capgoProbe ?? null,
      currentBundle: state.currentBundle,
      nextBundle: state.nextBundle,
      downloadedBundles: state.bundles,
      autoUpdateEnabled: state.autoUpdateEnabled,
      autoUpdateAvailable: state.autoUpdateAvailable,
      lastError: state.lastError,
      recentEvents: state.events,
    },
    null,
    2,
  );

  logHarnessState(harnessSnapshot);
}

function createHarnessSnapshot() {
  return {
    buildLabel,
    scenarioId,
    directUpdateMode,
    bootCount: state.bootCount,
    notifyStatus: state.notifyStatus,
    autoUpdateEnabled: state.autoUpdateEnabled,
    autoUpdateAvailable: state.autoUpdateAvailable,
    currentBundleSource: getBundleSource(state.currentBundle),
    currentBundleVersion: getBundleVersion(state.currentBundle),
    nextBundleVersion: getBundleVersion(state.nextBundle),
    downloadedBundleCount: state.bundles.length,
    lastDownload: state.lastDownload,
  };
}

function logHarnessState(snapshot) {
  const serializedSnapshot = JSON.stringify(snapshot);
  if (serializedSnapshot === state.lastHarnessSnapshot) {
    return;
  }

  state.lastHarnessSnapshot = serializedSnapshot;
  console.log(`[HarnessState] ${serializedSnapshot}`);
}

async function refreshState() {
  try {
    const [currentResult, nextBundle, listResult] = await Promise.all([
      plugin.current(),
      plugin.getNextBundle(),
      plugin.list(),
    ]);
    const [autoUpdateEnabled, autoUpdateAvailable] = await Promise.allSettled([
      plugin.isAutoUpdateEnabled(),
      plugin.isAutoUpdateAvailable(),
    ]);

    state.currentBundle = currentResult?.bundle ?? currentResult;
    state.nextBundle = nextBundle?.bundle ?? nextBundle;
    state.bundles = listResult?.bundles ?? [];
    if (autoUpdateEnabled.status === 'fulfilled') {
      state.autoUpdateEnabled = String(autoUpdateEnabled.value?.enabled ?? 'unknown');
    }
    if (autoUpdateAvailable.status === 'fulfilled') {
      state.autoUpdateAvailable = String(autoUpdateAvailable.value?.available ?? 'unknown');
    }
    state.lastDownload = getLastDownloadedBundleVersion(state.bundles);
    state.lastError = null;
  } catch (error) {
    state.lastError = error?.message ?? String(error);
    addEvent('Refresh error', { message: state.lastError });
  }

  renderState();
}

function attachListeners() {
  const listeners = [
    ['appReady', (payload) => addEvent('App ready event', payload)],
    ['updateAvailable', (payload) => addEvent('Update available', payload)],
    ['downloadComplete', (payload) => {
      state.lastDownload = getBundleVersion(payload?.bundle ?? payload);
      addEvent('Download complete', payload);
    }],
    ['downloadFailed', (payload) => addEvent('Download failed', payload)],
    ['download', (payload) => addEvent('Download progress', payload)],
  ];

  listeners.forEach(([eventName, handler]) => {
    plugin.addListener(eventName, async (payload) => {
      handler(payload);
      await refreshState();
    });
  });
}

async function performNotifyAppReady() {
  try {
    const result = await plugin.notifyAppReady();
    state.notifyStatus = result?.bundle
      ? `ok (${getBundleVersion(result.bundle)})`
      : result?.message ?? 'ok';
    addEvent('notifyAppReady()', result ?? { status: 'ok' });
    state.lastError = null;
    return result;
  } catch (error) {
    state.notifyStatus = `error: ${error?.message ?? error}`;
    state.lastError = error?.message ?? String(error);
    addEvent('notifyAppReady() failed', { message: state.lastError });
    throw error;
  }
}

function formatResult(result) {
  if (result === undefined) {
    return 'Action completed.';
  }

  if (typeof result === 'string') {
    return result;
  }

  try {
    return JSON.stringify(result, null, 2);
  } catch (error) {
    console.warn('Unable to serialize plugin result for display', error);
    return String(result);
  }
}

function getCardValues(card, action) {
  const values = {};

  (action.inputs || []).forEach((input) => {
    const field = card.querySelector(`[name="${input.name}"]`);
    if (!field) {
      return;
    }

    values[input.name] = field.value;
  });

  return values;
}

async function runAction(action, values) {
  const actionMarker = actionMarkers.get(action.id);
  elements.lastAction.textContent = `Last action: ${action.label}`;
  elements.actionStatus.textContent = 'Status: running';
  elements.resultMarker.textContent = `Result marker: ${action.id}:running`;
  elements.output.textContent = `Running ${action.label}...`;
  if (actionMarker) {
    actionMarker.textContent = `Action marker: ${action.id}:running`;
  }

  try {
    const result = await action.run(values);
    elements.actionStatus.textContent = 'Status: success';
    elements.resultMarker.textContent = `Result marker: ${action.id}:success`;
    elements.output.textContent = formatResult(result);
    if (actionMarker) {
      actionMarker.textContent = `Action marker: ${action.id}:success`;
    }
    void refreshState();
    return result;
  } catch (error) {
    const message = error?.message ?? String(error);
    state.lastError = message;
    elements.actionStatus.textContent = 'Status: error';
    elements.resultMarker.textContent = `Result marker: ${action.id}:error`;
    elements.output.textContent = `Error: ${message}`;
    if (actionMarker) {
      actionMarker.textContent = `Action marker: ${action.id}:error`;
    }
    renderState();
    throw error;
  }
}

async function runSmokeSequence() {
  if (smokeSequencePromise) {
    return smokeSequencePromise;
  }

  smokeSequencePromise = (async () => {
    elements.sequenceStatus.textContent = 'Sequence: running';
    elements.resultMarker.textContent = 'Result marker: smoke-sequence:running';
    elements.output.textContent = 'Running smoke test sequence...';
    elements.runSmokeSequenceButton.disabled = true;

    try {
      for (const action of actions) {
        const card = actionCards.get(action.id);
        const values = card ? getCardValues(card, action) : {};
        await runAction(action, values);
      }
      elements.sequenceStatus.textContent = 'Sequence: success';
      elements.resultMarker.textContent = 'Result marker: smoke-sequence:success';
    } catch (error) {
      elements.sequenceStatus.textContent = 'Sequence: error';
      elements.resultMarker.textContent = 'Result marker: smoke-sequence:error';
      console.error('Smoke sequence failed', error);
      throw error;
    } finally {
      elements.runSmokeSequenceButton.disabled = false;
      smokeSequencePromise = null;
    }
  })();

  return smokeSequencePromise;
}

function createInputField(card, input) {
  const fieldWrapper = document.createElement('label');
  fieldWrapper.className = 'action-input';
  fieldWrapper.textContent = input.label;

  const field = document.createElement('input');
  field.type = input.type || 'text';
  field.name = input.name;
  field.value = input.value || '';
  if (input.placeholder) {
    field.placeholder = input.placeholder;
  }

  fieldWrapper.appendChild(field);
  card.appendChild(fieldWrapper);
}

function createActionCard(action) {
  const card = document.createElement('article');
  card.className = 'action-card';

  const title = document.createElement('h3');
  title.textContent = action.label;
  card.appendChild(title);

  const description = document.createElement('p');
  description.className = 'action-copy';
  description.textContent = action.description;
  card.appendChild(description);

  (action.inputs || []).forEach((input) => {
    createInputField(card, input);
  });

  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = action.buttonLabel;
  button.addEventListener('click', () => {
    const values = getCardValues(card, action);
    void runAction(action, values).catch(() => {});
  });

  card.appendChild(button);

  if (isSmokeMode) {
    const actionMarker = document.createElement('p');
    actionMarker.className = 'status-line action-marker';
    actionMarker.textContent = `Action marker: ${action.id}:idle`;
    card.appendChild(actionMarker);
    actionMarkers.set(action.id, actionMarker);
  }

  return card;
}

function renderActions() {
  actions.forEach((action) => {
    const card = createActionCard(action);
    actionCards.set(action.id, card);
    elements.smokeActions.appendChild(card);
  });
}

function startStateRefreshWatchers() {
  window.setInterval(() => {
    void refreshState();
  }, 1000);

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) {
      void refreshState();
    }
  });
}

async function bootstrap() {
  renderActions();
  renderState();

  if (isSmokeMode) {
    attachListeners();
    await refreshState();
    startStateRefreshWatchers();
    if (shouldAutoRunSmokeSequence) {
      window.setTimeout(() => {
        void runSmokeSequence().catch((error) => {
          console.error('Smoke sequence bootstrap failed', error);
        });
      }, 250);
    }
    return;
  }

  attachListeners();

  try {
    await performNotifyAppReady();
  } catch (error) {
    console.error('notifyAppReady() bootstrap failed', error);
  }

  await refreshState();
  startStateRefreshWatchers();
}

elements.refreshButton.addEventListener('click', () => {
  void refreshState();
});

elements.runSmokeSequenceButton.addEventListener('click', () => {
  void runSmokeSequence();
});

void bootstrap();
