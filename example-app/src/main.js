import './style.css';
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

const elements = {
  appLabel: document.getElementById('app-label'),
  scenarioId: document.getElementById('scenario-id'),
  directUpdateMode: document.getElementById('direct-update-mode'),
  serverUrl: document.getElementById('server-url'),
  bootCount: document.getElementById('boot-count'),
  notifyStatus: document.getElementById('notify-status'),
  currentBundleSource: document.getElementById('current-bundle-source'),
  currentBundle: document.getElementById('current-bundle'),
  nextBundle: document.getElementById('next-bundle'),
  bundleCount: document.getElementById('bundle-count'),
  lastDownload: document.getElementById('last-download'),
  eventLog: document.getElementById('event-log'),
  output: document.getElementById('plugin-output'),
  refreshButton: document.getElementById('refresh-state'),
};

const state = {
  bootCount: incrementBootCount(),
  notifyStatus: 'pending',
  currentBundle: null,
  nextBundle: null,
  bundles: [],
  lastDownload: 'none',
  events: [],
  lastError: null,
};

function incrementBootCount() {
  const previous = Number(window.localStorage.getItem(bootStorageKey) ?? '0');
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
    item.textContent = `${entry.label}${detail ? `: ${detail}` : ''}`;
    elements.eventLog.appendChild(item);
  });
}

function renderState() {
  elements.appLabel.textContent = `Build label: ${buildLabel}`;
  elements.scenarioId.textContent = `Scenario: ${scenarioId}`;
  elements.directUpdateMode.textContent = `Direct update mode: ${directUpdateMode}`;
  elements.serverUrl.textContent = `Server URL: ${serverUrl}`;
  elements.bootCount.textContent = `Boot count: ${state.bootCount}`;
  elements.notifyStatus.textContent = `Notify app ready: ${state.notifyStatus}`;
  elements.currentBundleSource.textContent = `Current bundle source: ${getBundleSource(state.currentBundle)}`;
  elements.currentBundle.textContent = `Current bundle version: ${getBundleVersion(state.currentBundle)}`;
  elements.nextBundle.textContent = `Next bundle version: ${getBundleVersion(state.nextBundle)}`;
  elements.bundleCount.textContent = `Downloaded bundle count: ${state.bundles.length}`;
  elements.lastDownload.textContent = `Last completed download: ${state.lastDownload}`;
  elements.output.textContent = JSON.stringify(
    {
      buildLabel,
      scenarioId,
      directUpdateMode,
      serverUrl,
      bootCount: state.bootCount,
      probe: window.__capgoProbe ?? null,
      notifyStatus: state.notifyStatus,
      currentBundle: state.currentBundle,
      nextBundle: state.nextBundle,
      downloadedBundles: state.bundles,
      lastDownload: state.lastDownload,
      lastError: state.lastError,
      recentEvents: state.events,
    },
    null,
    2,
  );
}

async function refreshState() {
  try {
    const [currentResult, nextBundle, listResult] = await Promise.all([
      plugin.current(),
      plugin.getNextBundle(),
      plugin.list(),
    ]);

    state.currentBundle = currentResult?.bundle ?? currentResult;
    state.nextBundle = nextBundle;
    state.bundles = listResult?.bundles ?? [];
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
      renderState();
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

async function notifyAppReady() {
  try {
    const result = await plugin.notifyAppReady();
    state.notifyStatus = result?.bundle
      ? `ok (${getBundleVersion(result.bundle)})`
      : result?.message ?? 'ok';
    addEvent('notifyAppReady()', result ?? { status: 'ok' });
  } catch (error) {
    state.notifyStatus = `error: ${error?.message ?? error}`;
    state.lastError = error?.message ?? String(error);
    addEvent('notifyAppReady() failed', { message: state.lastError });
  }

  renderState();
}

async function bootstrap() {
  attachListeners();
  renderState();
  await notifyAppReady();
  await refreshState();

  window.setInterval(() => {
    void refreshState();
  }, 1000);

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) {
      void refreshState();
    }
  });
}

elements.refreshButton.addEventListener('click', () => {
  void refreshState();
});

void bootstrap();
