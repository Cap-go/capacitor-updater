import './style.css';
import { Capacitor } from '@capacitor/core';
import { CapacitorUpdater } from '@capgo/capacitor-updater';

if (window.__capgoProbe) {
  window.__capgoProbe.moduleLoadedAt = new Date().toISOString();
}
console.log('[Harness] module boot', window.__capgoProbe ?? null);

const plugin = CapacitorUpdater;
const platform = Capacitor.getPlatform();
const buildLabel = import.meta.env.VITE_CAPGO_APP_LABEL ?? 'manual-build';
const scenarioId = import.meta.env.VITE_CAPGO_SCENARIO ?? 'manual';
const directUpdateMode = import.meta.env.VITE_CAPGO_DIRECT_UPDATE ?? 'false';
const serverUrl = import.meta.env.VITE_CAPGO_SERVER_URL ?? 'not-configured';
const allowManualBundleError = import.meta.env.VITE_CAPGO_ALLOW_MANUAL_BUNDLE_ERROR === 'true';
const allowModifyAppId = import.meta.env.VITE_CAPGO_ALLOW_MODIFY_APP_ID === 'true';
const allowModifyUrl = import.meta.env.VITE_CAPGO_ALLOW_MODIFY_URL === 'true';
const allowSetDefaultChannel = import.meta.env.VITE_CAPGO_ALLOW_SET_DEFAULT_CHANNEL !== 'false';
const persistCustomId = import.meta.env.VITE_CAPGO_PERSIST_CUSTOM_ID === 'true';
const persistModifyUrl = import.meta.env.VITE_CAPGO_PERSIST_MODIFY_URL === 'true';
const skipNotifyAppReady = import.meta.env.VITE_CAPGO_SKIP_NOTIFY_APP_READY === 'true';
const bootStorageKey = '__capgo_maestro_boot_count';
const lastActionStorageKey = '__capgo_maestro_last_action';
const lastActionResultStorageKey = '__capgo_maestro_last_action_result';
const pendingReloadActionStorageKey = '__capgo_maestro_pending_reload_action';
const fallbackUpdateUrl = 'https://example.com/api/auto_update';
const maxEvents = 10;
const runtimeSmokeAppId = 'app.capgo.updater.e2e';
const runtimeSmokeCustomId = 'qa-user-42';
const lastActionFromStorage = window.localStorage.getItem(lastActionStorageKey) ?? 'none';
const lastActionResultFromStorage = window.localStorage.getItem(lastActionResultStorageKey) ?? 'idle';
const reloadActionFromStorage = window.localStorage.getItem(pendingReloadActionStorageKey) ?? 'none';

window.localStorage.removeItem(pendingReloadActionStorageKey);

function requireElement(id) {
  const element = document.getElementById(id);
  if (!element) {
    throw new Error(`Expected #${id} in index.html`);
  }
  return element;
}

const elements = {
  actionStatus: requireElement('action-status'),
  appIdState: requireElement('app-id-state'),
  appLabel: requireElement('app-label'),
  appReadyEvent: requireElement('app-ready-event'),
  autoUpdateAvailable: requireElement('auto-update-available'),
  autoUpdateEnabled: requireElement('auto-update-enabled'),
  bootCount: requireElement('boot-count'),
  breakingEvent: requireElement('breaking-event'),
  bundleCount: requireElement('bundle-count'),
  channelPrivateEvent: requireElement('channel-private-event'),
  currentBundle: requireElement('current-bundle'),
  currentBundleSource: requireElement('current-bundle-source'),
  debugOutput: requireElement('debug-output'),
  downloadCompleteEventState: requireElement('download-complete-event-state'),
  downloadCompleteEvent: requireElement('download-complete-event'),
  directUpdateMode: requireElement('direct-update-mode'),
  downloadEventState: requireElement('download-event-state'),
  downloadEvent: requireElement('download-event'),
  downloadFailedEvent: requireElement('download-failed-event'),
  e2eSummary: requireElement('e2e-summary'),
  eventLog: requireElement('event-log'),
  failedUpdateState: requireElement('failed-update-state'),
  flexibleUpdateEvent: requireElement('flexible-update-event'),
  getChannelState: requireElement('get-channel-state'),
  getChannelReadState: requireElement('get-channel-read-state'),
  harnessReady: requireElement('harness-ready'),
  lastGetLatestCheckState: requireElement('last-get-latest-check-state'),
  lastListChannelsCheckState: requireElement('last-list-channels-check-state'),
  lastPrivateChannelCheckState: requireElement('last-private-channel-check-state'),
  lastSetChannelBetaCheckState: requireElement('last-set-channel-beta-check-state'),
  lastUnsetChannelCheckState: requireElement('last-unset-channel-check-state'),
  lastAction: requireElement('last-action'),
  lastActionResult: requireElement('last-action-result'),
  lastDownload: requireElement('last-download'),
  lastError: requireElement('last-error'),
  latestVersionState: requireElement('latest-version-state'),
  listChannelsState: requireElement('list-channels-state'),
  majorEvent: requireElement('major-event'),
  nextBundle: requireElement('next-bundle'),
  noNeedUpdateEventState: requireElement('no-need-update-event-state'),
  noNeedUpdateEvent: requireElement('no-need-update-event'),
  notifyStatus: requireElement('notify-status'),
  output: requireElement('plugin-output'),
  quickActions: requireElement('quick-actions'),
  quickRunSmokeSequenceButton: requireElement('quick-run-smoke-sequence'),
  refreshButton: requireElement('refresh-state'),
  reloadMarker: requireElement('reload-marker'),
  resultMarker: requireElement('result-marker'),
  runSmokeSequenceButton: requireElement('run-smoke-sequence'),
  scenarioId: requireElement('scenario-id'),
  sequenceStatus: requireElement('sequence-status'),
  setNextEventState: requireElement('set-next-event-state'),
  serverActiveRelease: requireElement('server-active-release'),
  serverLastAppId: requireElement('server-last-app-id'),
  serverLastChannel: requireElement('server-last-channel'),
  serverLastCustomId: requireElement('server-last-custom-id'),
  serverLastDefaultChannel: requireElement('server-last-default-channel'),
  serverChannelUrl: requireElement('server-channel-url'),
  serverLastVersion: requireElement('server-last-version'),
  serverStatsUrl: requireElement('server-stats-url'),
  serverStatsActions: requireElement('server-stats-actions'),
  serverUpdateUrl: requireElement('server-update-url'),
  serverUrl: requireElement('server-url'),
  setEvent: requireElement('set-event'),
  setNextEvent: requireElement('set-next-event'),
  shakeChannelSelectorState: requireElement('shake-channel-selector-state'),
  shakeMenuState: requireElement('shake-menu-state'),
  smokeActions: requireElement('smoke-actions'),
  updateAvailableEventState: requireElement('update-available-event-state'),
  updateAvailableEvent: requireElement('update-available-event'),
  updateFailedEventState: requireElement('update-failed-event-state'),
  updateFailedEvent: requireElement('update-failed-event'),
};

const actionCards = new Map();
const actionMarkers = new Map();
let listenersAttached = false;
let smokeSequencePromise = null;
let refreshStatePromise = null;
let refreshStateQueued = false;
let actionInProgress = false;
let sequenceInProgress = false;
const quickActionIds = [
  'set-runtime-urls',
  'verify-persisted-config',
  'get-app-update-info',
  'perform-immediate-update',
  'start-flexible-update',
  'complete-flexible-update',
  'get-latest',
  'open-app-store',
  'reset-server-release',
  'advance-server-release',
  'download-latest-bundle',
  'set-last-downloaded-bundle',
  'queue-last-downloaded-bundle',
  'get-next-bundle',
  'get-latest-no-update',
  'set-multi-delay',
  'cancel-delay',
  'reload-app',
  'get-failed-update',
  'set-bundle-error',
  'delete-inactive-bundle',
  'reset-to-builtin',
];
const smokeSequenceDefaultDelayMs = 150;
const smokeSequenceMutationDelayMs = 300;
const smokeSequenceExtendedSettleActionIds = new Set([
  'set-app-id',
  'set-custom-id',
  'set-update-url',
  'set-stats-url',
  'set-channel-url',
  'set-channel-beta',
  'unset-channel',
  'remove-all-listeners',
]);
const manualZipStoreContractSmokeActionIds =
  platform === 'ios'
    ? []
    : ['get-app-update-info', 'perform-immediate-update', 'start-flexible-update', 'complete-flexible-update', 'get-latest'];
const smokeSequenceActionIdsByScenario = {
  'manual-zip': [
    'notify-app-ready',
    'current-bundle',
    'list-bundles',
    'get-plugin-version',
    'get-builtin-version',
    'get-device-id',
    'is-auto-update-enabled',
    'is-auto-update-available',
    'get-app-id',
    'set-app-id',
    'set-custom-id',
    'set-update-url',
    'set-stats-url',
    'set-channel-url',
    'set-channel-beta',
    'get-channel',
    'unset-channel',
    'get-next-bundle',
    'get-failed-update',
    'set-shake-menu',
    'is-shake-menu-enabled',
    'set-shake-channel-selector',
    'is-shake-channel-selector-enabled',
    'remove-all-listeners',
    ...manualZipStoreContractSmokeActionIds,
  ],
  'manual-zip-no-persist': [
    'set-custom-id',
    'set-app-id',
    'set-update-url',
    'set-stats-url',
    'set-channel-url',
    'set-channel-beta',
    'get-channel',
    'unset-channel',
  ],
  'manual-zip-config-guards': [
    'set-custom-id',
    'set-app-id',
    'set-update-url',
    'set-stats-url',
    'set-channel-url',
    'set-channel-beta',
    'get-channel',
    'set-channel-private',
    'unset-channel',
  ],
};

const state = {
  autoUpdateAvailable: 'loading',
  autoUpdateEnabled: 'loading',
  bootCount: incrementBootCount(),
  bundles: [],
  currentBundle: null,
  eventMarkers: {
    appReady: 'none',
    appReloaded: 'none',
    breakingAvailable: 'none',
    channelPrivate: 'none',
    download: 'none',
    downloadComplete: 'none',
    downloadFailed: 'none',
    flexibleUpdate: 'none',
    majorAvailable: 'none',
    noNeedUpdate: 'none',
    set: 'none',
    setNext: 'none',
    updateAvailable: 'none',
    updateFailed: 'none',
  },
  events: [],
  failedUpdate: null,
  getChannelResult: null,
  getChannelReadMarker: 'not-run',
  harnessReady: false,
  lastGetLatestCheck: 'not-run',
  lastListChannelsCheck: 'not-run',
  lastPrivateChannelCheck: 'not-run',
  lastSetChannelBetaCheck: 'not-run',
  lastUnsetChannelCheck: 'not-run',
  listChannelsResult: null,
  lastAction: lastActionFromStorage,
  lastActionMarker: 'none',
  lastActionResult: lastActionResultFromStorage,
  lastDownload: 'none',
  lastDownloadedBundleId: null,
  lastDownloadedBundleVersion: 'none',
  lastError: null,
  lastHarnessSnapshot: '',
  lastPhase: 'idle',
  lastLatest: null,
  nextBundle: null,
  notifyStatus: skipNotifyAppReady ? 'skipped by build' : 'pending',
  reloadMarkerAction: reloadActionFromStorage,
  serverDebug: null,
  sequenceRuns: 0,
  shakeChannelSelectorEnabled: 'loading',
  shakeMenuEnabled: 'loading',
};

function incrementBootCount() {
  const stored = Number(window.localStorage.getItem(bootStorageKey) ?? '0');
  const previous = Number.isFinite(stored) ? stored : 0;
  const next = previous + 1;
  window.localStorage.setItem(bootStorageKey, String(next));
  return next;
}

function getServerBaseUrl() {
  if (!serverUrl.startsWith('http')) {
    return null;
  }

  try {
    const parsed = new URL(serverUrl);
    return `${parsed.protocol}//${parsed.host}`;
  } catch {
    return null;
  }
}

function pause(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function getSmokeSequenceDelayMs(actionId) {
  if (smokeSequenceExtendedSettleActionIds.has(actionId)) {
    return smokeSequenceMutationDelayMs;
  }

  return smokeSequenceDefaultDelayMs;
}

function createServerEndpoint(pathname) {
  const baseUrl = getServerBaseUrl();

  if (!baseUrl) {
    return null;
  }

  const url = new URL(pathname, `${baseUrl}/`);
  url.searchParams.set('scenario', scenarioId);
  return url.toString();
}

function appendQueryParam(urlString, key, value) {
  try {
    const url = new URL(urlString);
    url.searchParams.set(key, value);
    return url.toString();
  } catch {
    return urlString;
  }
}

function getDefaultUpdateUrl() {
  return serverUrl.startsWith('http') ? serverUrl : fallbackUpdateUrl;
}

function getDefaultStatsUrl() {
  return createServerEndpoint('/api/stats') ?? 'https://example.com/api/stats';
}

function getDefaultChannelUrl() {
  return createServerEndpoint('/api/channel') ?? 'https://example.com/api/channel';
}

function getRuntimeUpdateUrl() {
  return appendQueryParam(getDefaultUpdateUrl(), 'source', 'runtime-update');
}

function getRuntimeStatsUrl() {
  return appendQueryParam(getDefaultStatsUrl(), 'source', 'runtime-stats');
}

function getRuntimeChannelUrl() {
  return appendQueryParam(getDefaultChannelUrl(), 'source', 'runtime-channel');
}

function formatObservedRequestUrl(value, allowedKeys = []) {
  if (!value) {
    return 'none';
  }

  try {
    const url = new URL(value, window.location.origin);
    if (allowedKeys.length) {
      const search = new URLSearchParams();
      allowedKeys.forEach((key) => {
        const nextValue = url.searchParams.get(key);
        if (nextValue !== null) {
          search.set(key, nextValue);
        }
      });
      const normalizedSearch = search.toString();
      return normalizedSearch ? `${url.pathname}?${normalizedSearch}` : url.pathname;
    }
    return `${url.pathname}${url.search}`;
  } catch {
    return String(value);
  }
}

function getBundleVersion(bundle) {
  if (typeof bundle === 'string') {
    const parsedVersion =
      bundle.match(/versionName=([^,}]+)/)?.[1] ??
      bundle.match(/version_name=([^,}]+)/)?.[1] ??
      bundle.match(/version=([^,}]+)/)?.[1];
    return parsedVersion?.trim() || bundle;
  }

  if (!bundle) {
    return 'none';
  }

  return bundle.versionName ?? bundle.version_name ?? bundle.version ?? bundle.id ?? 'unknown';
}

function getBundleSource(bundle) {
  if (!bundle) {
    return 'none';
  }

  return bundle.id === 'builtin' ? 'builtin' : 'downloaded';
}

function getBundleStatus(bundle) {
  return bundle?.status ?? 'unknown';
}

function getTimestamp(bundle) {
  if (!bundle?.downloaded) {
    return Number.NEGATIVE_INFINITY;
  }

  const parsed = Date.parse(bundle.downloaded);
  return Number.isNaN(parsed) ? Number.NEGATIVE_INFINITY : parsed;
}

function sortBundlesByDownloadDate(left, right) {
  return getTimestamp(right) - getTimestamp(left);
}

function getLastDownloadedBundle(bundles) {
  return [...bundles]
    .filter((bundle) => bundle?.id !== 'builtin')
    .sort(sortBundlesByDownloadDate)[0] ?? null;
}

function getLatestInactiveBundle(bundles) {
  const currentId = state.currentBundle?.id;
  const nextId = state.nextBundle?.id;

  return [...bundles]
    .filter((bundle) => bundle?.id !== 'builtin' && bundle?.id !== currentId && bundle?.id !== nextId)
    .sort(sortBundlesByDownloadDate)[0] ?? null;
}

function formatAvailableChannels(result) {
  const channels = Array.isArray(result?.channels) ? result.channels : [];

  if (!channels.length) {
    return 'none';
  }

  return channels
    .map((channel) => channel?.name ?? channel?.id ?? 'unknown')
    .filter(Boolean)
    .join(', ');
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
    const detail =
      bundle ||
      entry.payload?.version ||
      entry.payload?.message ||
      entry.payload?.status ||
      entry.payload?.installStatus ||
      '';
    const detailSuffix = detail ? `: ${detail}` : '';
    item.textContent = `${entry.label}${detailSuffix}`;
    elements.eventLog.appendChild(item);
  });
}

function formatEventMarkerValue(eventName, payload) {
  if (eventName === 'appReloaded') {
    return 'observed';
  }

  if (eventName === 'onFlexibleUpdateStateChange') {
    return `${payload?.installStatus ?? 'unknown'}:${payload?.bytesDownloaded ?? 0}/${payload?.totalBytesToDownload ?? 0}`;
  }

  if (eventName === 'download') {
    return `${payload?.percent ?? 0}%:${getBundleVersion(payload?.bundle ?? payload)}`;
  }

  if (payload?.bundle) {
    return getBundleVersion(payload.bundle);
  }

  return (
    payload?.channel ??
    payload?.version ??
    payload?.message ??
    payload?.status ??
    payload?.error ??
    'observed'
  );
}

function recordEventMarker(eventName, payload) {
  const markerValue = formatEventMarkerValue(eventName, payload);

  if (eventName === 'breakingAvailable') {
    state.eventMarkers.breakingAvailable = markerValue;
    return;
  }

  if (eventName === 'majorAvailable') {
    state.eventMarkers.majorAvailable = markerValue;
    return;
  }

  if (eventName === 'onFlexibleUpdateStateChange') {
    state.eventMarkers.flexibleUpdate = markerValue;
    return;
  }

  state.eventMarkers[eventName] = markerValue;
}

function createHarnessSnapshot() {
  return {
    appId: elements.appIdState.textContent,
    allowManualBundleError,
    allowModifyAppId,
    allowModifyUrl,
    allowSetDefaultChannel,
    autoUpdateAvailable: state.autoUpdateAvailable,
    autoUpdateEnabled: state.autoUpdateEnabled,
    bootCount: state.bootCount,
    buildLabel,
    currentBundleSource: getBundleSource(state.currentBundle),
    currentBundleVersion: getBundleVersion(state.currentBundle),
    directUpdateMode,
    failedUpdateVersion: getBundleVersion(state.failedUpdate?.bundle ?? state.failedUpdate),
    harnessReady: state.harnessReady,
    lastDownload: state.lastDownload,
    lastPhase: state.lastPhase,
    lastActionMarker: state.lastActionMarker,
    lastActionResult: state.lastActionResult,
    latestVersion: state.lastLatest?.version ?? 'none',
    nextBundleVersion: getBundleVersion(state.nextBundle),
    notifyStatus: state.notifyStatus,
    platform,
    persistCustomId,
    persistModifyUrl,
    reloadMarkerAction: state.reloadMarkerAction,
    scenarioId,
    serverActiveRelease: state.serverDebug?.activeRelease ?? 'none',
    serverLastAppId: state.serverDebug?.debug?.lastUpdateRequest?.payload?.app_id ?? 'none',
    serverLastCustomId:
      state.serverDebug?.debug?.lastUpdateRequest?.payload?.custom_id ??
      state.serverDebug?.debug?.lastChannelRequest?.payload?.custom_id ??
      'none',
    downloadCompleteEventVersion: state.eventMarkers.downloadComplete,
    updateAvailableEventVersion: state.eventMarkers.updateAvailable,
    setEventVersion: state.eventMarkers.set,
    setNextEventVersion: state.eventMarkers.setNext,
  };
}

function logHarnessState(snapshot) {
  const serializedSnapshot = JSON.stringify(snapshot);

  if (serializedSnapshot === state.lastHarnessSnapshot) {
    return;
  }

  state.lastHarnessSnapshot = serializedSnapshot;
  console.log({ harnessState: sanitizeLogValue(snapshot) });
}

function sanitizeLogValue(value) {
  if (typeof value === 'string') {
    return value.replace(/[\r\n]+/g, ' ');
  }

  if (Array.isArray(value)) {
    return value.map((entry) => sanitizeLogValue(entry));
  }

  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, entry]) => [key, sanitizeLogValue(entry)]),
    );
  }

  return value;
}

async function refreshServerState() {
  const controlStateUrl = createServerEndpoint('/api/control/state');

  if (!controlStateUrl) {
    state.serverDebug = null;
    return;
  }

  try {
    const response = await withTimeout(
      'refreshServerState()',
      () => fetch(controlStateUrl),
      15000,
    );

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    state.serverDebug = await response.json();
  } catch (error) {
    state.serverDebug = {
      debug: null,
      error: error?.message ?? String(error),
    };
  }
}

async function performRefreshState() {
  try {
    state.lastPhase = 'refresh-state:core';
    renderState();
    const [currentResult, nextBundle, listResult] = await Promise.all([
      withTimeout('refreshState current()', () => plugin.current()),
      withTimeout('refreshState getNextBundle()', () => plugin.getNextBundle()),
      withTimeout('refreshState list()', () => plugin.list()),
    ]);

    state.currentBundle = currentResult?.bundle ?? currentResult;
    state.nextBundle = nextBundle?.bundle ?? nextBundle;
    state.bundles = listResult?.bundles ?? [];
    state.lastDownload = getBundleVersion(getLastDownloadedBundle(state.bundles));

    const lastDownloadedBundle = getLastDownloadedBundle(state.bundles);
    if (lastDownloadedBundle) {
      state.lastDownloadedBundleId = lastDownloadedBundle.id ?? null;
      state.lastDownloadedBundleVersion = getBundleVersion(lastDownloadedBundle);
    }

    state.lastPhase = 'refresh-state:probes';
    renderState();
    const [autoUpdateEnabled, autoUpdateAvailable, shakeMenu, shakeChannelSelector] = await Promise.allSettled([
      withTimeout('refreshState isAutoUpdateEnabled()', () => plugin.isAutoUpdateEnabled()),
      withTimeout('refreshState isAutoUpdateAvailable()', () => plugin.isAutoUpdateAvailable()),
      withTimeout('refreshState isShakeMenuEnabled()', () => plugin.isShakeMenuEnabled()),
      withTimeout('refreshState isShakeChannelSelectorEnabled()', () => plugin.isShakeChannelSelectorEnabled()),
    ]);

    if (autoUpdateEnabled.status === 'fulfilled') {
      state.autoUpdateEnabled = String(autoUpdateEnabled.value?.enabled ?? 'unknown');
    }

    if (autoUpdateAvailable.status === 'fulfilled') {
      state.autoUpdateAvailable = String(autoUpdateAvailable.value?.available ?? 'unknown');
    }

    if (shakeMenu.status === 'fulfilled') {
      state.shakeMenuEnabled = String(shakeMenu.value?.enabled ?? 'unknown');
    }

    if (shakeChannelSelector.status === 'fulfilled') {
      state.shakeChannelSelectorEnabled = String(shakeChannelSelector.value?.enabled ?? 'unknown');
    }

    state.lastError = null;
  } catch (error) {
    state.lastError = error?.message ?? String(error);
    addEvent('Refresh error', { message: state.lastError });
  }

  await refreshServerState();
  renderState();
}

async function refreshState() {
  if (refreshStatePromise) {
    refreshStateQueued = true;
    return refreshStatePromise;
  }

  refreshStatePromise = (async () => {
    do {
      refreshStateQueued = false;
      await performRefreshState();
    } while (refreshStateQueued);
  })();

  try {
    return await refreshStatePromise;
  } finally {
    refreshStatePromise = null;
  }
}

function renderState() {
  const serverDebug = state.serverDebug?.debug ?? null;
  const lastUpdatePayload = serverDebug?.lastUpdateRequest?.payload ?? {};
  const lastChannelPayload = serverDebug?.lastChannelRequest?.payload ?? {};
  const serverStatsActions = serverDebug?.statsActions ?? [];
  const serverUpdateUrl = formatObservedRequestUrl(serverDebug?.lastUpdateRequest?.url);
  const serverChannelUrl = formatObservedRequestUrl(serverDebug?.lastChannelRequest?.url, ['scenario', 'source']);
  const serverStatsUrl = formatObservedRequestUrl(serverDebug?.lastStatsRequest?.url);
  const harnessSnapshot = createHarnessSnapshot();

  elements.appLabel.textContent = `Build label: ${buildLabel}`;
  elements.lastAction.textContent = `Last action: ${state.lastAction}`;
  elements.lastActionResult.textContent = `Last action result: ${state.lastActionResult}`;
  elements.resultMarker.textContent = `M:${state.lastActionResult}`;
  elements.lastError.textContent = `Last error: ${state.lastError ?? 'none'}`;
  elements.downloadEventState.textContent = `Download event: ${state.eventMarkers.download}`;
  elements.downloadCompleteEventState.textContent = `Download complete event: ${state.eventMarkers.downloadComplete}`;
  elements.updateAvailableEventState.textContent = `Update available event: ${state.eventMarkers.updateAvailable}`;
  elements.setNextEventState.textContent = `Set next event: ${state.eventMarkers.setNext}`;
  elements.noNeedUpdateEventState.textContent = `No need update event: ${state.eventMarkers.noNeedUpdate}`;
  elements.updateFailedEventState.textContent = `Update failed event: ${state.eventMarkers.updateFailed}`;
  elements.actionStatus.textContent = `Status: ${state.lastPhase}`;
  elements.harnessReady.textContent = `Harness ready: ${state.harnessReady ? 'yes' : 'no'}`;
  elements.scenarioId.textContent = `Scenario: ${scenarioId}`;
  elements.directUpdateMode.textContent = `Direct update mode: ${directUpdateMode}`;
  elements.serverUrl.textContent = `Server URL: ${serverUrl}`;
  elements.bootCount.textContent = `Boot count: ${state.bootCount}`;
  elements.notifyStatus.textContent = `Notify app ready: ${state.notifyStatus}`;
  elements.autoUpdateEnabled.textContent = `Auto update enabled: ${state.autoUpdateEnabled}`;
  elements.autoUpdateAvailable.textContent = `Auto update available: ${state.autoUpdateAvailable}`;
  elements.currentBundleSource.textContent = `Current bundle source: ${getBundleSource(state.currentBundle)}`;
  elements.currentBundle.textContent = `Current bundle version: ${getBundleVersion(state.currentBundle)}`;
  elements.nextBundle.textContent = `Next bundle version: ${getBundleVersion(state.nextBundle)}`;
  elements.bundleCount.textContent = `Downloaded bundle count: ${state.bundles.length}`;
  elements.lastDownload.textContent = `Last completed download: ${state.lastDownload}`;
  elements.latestVersionState.textContent = `Latest available version: ${state.lastLatest?.version ?? 'none'}`;
  elements.lastGetLatestCheckState.textContent = `Last getLatest check: ${state.lastGetLatestCheck}`;
  elements.failedUpdateState.textContent = `Failed update: ${getBundleVersion(state.failedUpdate?.bundle ?? state.failedUpdate)}`;
  elements.getChannelState.textContent = `Current channel: ${state.getChannelResult?.channel ?? 'none'}`;
  elements.lastListChannelsCheckState.textContent = `Last listChannels check: ${state.lastListChannelsCheck}`;
  elements.lastSetChannelBetaCheckState.textContent = `Last setChannel beta check: ${state.lastSetChannelBetaCheck}`;
  elements.getChannelReadState.textContent = `Last getChannel check: ${state.getChannelReadMarker}`;
  elements.lastPrivateChannelCheckState.textContent = `Last private channel check: ${state.lastPrivateChannelCheck}`;
  elements.lastUnsetChannelCheckState.textContent = `Last unsetChannel check: ${state.lastUnsetChannelCheck}`;
  elements.listChannelsState.textContent = `Available channels: ${formatAvailableChannels(state.listChannelsResult)}`;
  elements.shakeMenuState.textContent = `Shake menu enabled: ${state.shakeMenuEnabled}`;
  elements.shakeChannelSelectorState.textContent = `Shake channel selector enabled: ${state.shakeChannelSelectorEnabled}`;
  elements.appIdState.textContent = `App ID: ${lastUpdatePayload.app_id ?? lastChannelPayload.app_id ?? 'not-yet-observed'}`;
  elements.reloadMarker.textContent =
    state.reloadMarkerAction === 'none'
      ? 'Reload marker: none'
      : `Reload marker: ${state.reloadMarkerAction}:${getBundleVersion(state.currentBundle)}`;
  elements.serverActiveRelease.textContent = `Server active release: ${state.serverDebug?.activeRelease ?? 'none'}`;
  elements.serverLastVersion.textContent = `Server saw version_name: ${lastUpdatePayload.version_name ?? 'none'}`;
  elements.serverLastAppId.textContent = `Server saw app_id: ${lastUpdatePayload.app_id ?? lastChannelPayload.app_id ?? 'none'}`;
  elements.serverLastCustomId.textContent =
    `Server saw custom_id: ${lastUpdatePayload.custom_id ?? lastChannelPayload.custom_id ?? 'none'}`;
  elements.serverLastChannel.textContent = `Server saw channel request: ${lastChannelPayload.channel ?? 'none'}`;
  elements.serverLastDefaultChannel.textContent =
    `Server saw defaultChannel: ${lastUpdatePayload.defaultChannel ?? lastChannelPayload.defaultChannel ?? 'none'}`;
  elements.serverUpdateUrl.textContent = `Server update URL: ${serverUpdateUrl}`;
  elements.serverChannelUrl.textContent = `Server channel URL: ${serverChannelUrl}`;
  elements.serverStatsUrl.textContent = `Server stats URL: ${serverStatsUrl}`;
  elements.serverStatsActions.textContent =
    `Server stats actions: ${serverStatsActions.length ? serverStatsActions.join(', ') : 'none'}`;
  elements.appReadyEvent.textContent = `appReady event: ${state.eventMarkers.appReady}`;
  elements.setEvent.textContent = `set event: ${state.eventMarkers.set}`;
  elements.setNextEvent.textContent = `setNext event: ${state.eventMarkers.setNext}`;
  elements.updateAvailableEvent.textContent = `updateAvailable event: ${state.eventMarkers.updateAvailable}`;
  elements.updateFailedEvent.textContent = `updateFailed event: ${state.eventMarkers.updateFailed}`;
  elements.channelPrivateEvent.textContent = `channelPrivate event: ${state.eventMarkers.channelPrivate}`;
  elements.downloadEvent.textContent = `download event: ${state.eventMarkers.download}`;
  elements.downloadCompleteEvent.textContent = `downloadComplete event: ${state.eventMarkers.downloadComplete}`;
  elements.downloadFailedEvent.textContent = `downloadFailed event: ${state.eventMarkers.downloadFailed}`;
  elements.noNeedUpdateEvent.textContent = `noNeedUpdate event: ${state.eventMarkers.noNeedUpdate}`;
  elements.breakingEvent.textContent = `breakingAvailable event: ${state.eventMarkers.breakingAvailable}`;
  elements.majorEvent.textContent = `majorAvailable event: ${state.eventMarkers.majorAvailable}`;
  elements.flexibleUpdateEvent.textContent = `flexible update event: ${state.eventMarkers.flexibleUpdate}`;
  elements.e2eSummary.textContent =
    `M:${state.lastActionMarker} | ` +
    `Harness: ${state.harnessReady ? 'ready' : 'pending'} | ` +
    `Build label: ${buildLabel} | ` +
    `Scenario: ${scenarioId} | ` +
    `Direct update mode: ${directUpdateMode} | ` +
    `Auto update enabled: ${state.autoUpdateEnabled} | ` +
    `Auto update available: ${state.autoUpdateAvailable} | ` +
    `Notify app ready: ${state.notifyStatus} | ` +
    `Current bundle source: ${getBundleSource(state.currentBundle)} | ` +
    `Current bundle version: ${getBundleVersion(state.currentBundle)} | ` +
    `Next bundle version: ${getBundleVersion(state.nextBundle)} | ` +
    `Last completed download: ${state.lastDownload} | ` +
    `Download event: ${state.eventMarkers.download} | ` +
    `Download complete event: ${state.eventMarkers.downloadComplete} | ` +
    `Update available event: ${state.eventMarkers.updateAvailable} | ` +
    `Set next event: ${state.eventMarkers.setNext} | ` +
    `No need update event: ${state.eventMarkers.noNeedUpdate} | ` +
    `Update failed event: ${state.eventMarkers.updateFailed} | ` +
    `Failed update: ${getBundleVersion(state.failedUpdate?.bundle ?? state.failedUpdate)} | ` +
    `Last error: ${state.lastError ?? 'none'}`;
  elements.debugOutput.textContent = JSON.stringify(
    {
      ...harnessSnapshot,
      bundles: state.bundles,
      currentBundle: state.currentBundle,
      failedUpdate: state.failedUpdate,
      getChannelResult: state.getChannelResult,
      lastError: state.lastError,
      lastLatest: state.lastLatest,
      nextBundle: state.nextBundle,
      probe: window.__capgoProbe ?? null,
      recentEvents: state.events,
      serverDebug: state.serverDebug,
      skipNotifyAppReady,
    },
    null,
    2,
  );

  logHarnessState(harnessSnapshot);
}

function resetScrollPosition() {
  const scrollToTop = () => {
    window.scrollTo({
      top: 0,
      left: 0,
      behavior: 'auto',
    });
  };

  scrollToTop();
  window.requestAnimationFrame(scrollToTop);
  window.setTimeout(scrollToTop, 100);
  window.setTimeout(scrollToTop, 500);
}

async function waitForCondition(check, timeoutMs = 45000, intervalMs = 500) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const result = await check();

    if (result) {
      return result;
    }

    await new Promise((resolve) => window.setTimeout(resolve, intervalMs));
  }

  throw new Error(`Condition timed out after ${timeoutMs}ms`);
}

async function withTimeout(label, operation, timeoutMs = 30000) {
  let timeoutId = null;

  try {
    return await Promise.race([
      operation(),
      new Promise((_, reject) => {
        timeoutId = window.setTimeout(() => {
          reject(new Error(`${label} timed out after ${timeoutMs}ms`));
        }, timeoutMs);
      }),
    ]);
  } finally {
    if (timeoutId !== null) {
      window.clearTimeout(timeoutId);
    }
  }
}

async function waitForBundleVersion(version, timeoutMs = 45000) {
  return waitForCondition(async () => {
    const result = await plugin.list();
    const bundle = (result?.bundles ?? []).find(
      (candidate) => getBundleVersion(candidate) === version && getBundleStatus(candidate) !== 'downloading',
    );

    if (!bundle) {
      return null;
    }

    state.bundles = result?.bundles ?? [];
    state.lastDownloadedBundleId = bundle.id ?? null;
    state.lastDownloadedBundleVersion = getBundleVersion(bundle);
    renderState();
    return bundle;
  }, timeoutMs);
}

async function waitForEventMarker(markerKey, expectedFragment, timeoutMs = 8000) {
  return waitForCondition(async () => {
    const value = state.eventMarkers[markerKey];
    return value && value.includes(expectedFragment) ? value : null;
  }, timeoutMs, 250);
}

async function getBundleByVersion(version) {
  if (!version || version === 'none') {
    return null;
  }

  if (state.bundles.length) {
    const existingMatch = state.bundles.find((bundle) => getBundleVersion(bundle) === version);
    if (existingMatch && getBundleStatus(existingMatch) !== 'downloading') {
      return existingMatch;
    }
  }

  return waitForBundleVersion(version);
}

async function getLastDownloadedBundleOrThrow() {
  const version = state.lastDownloadedBundleVersion;
  const bundle = await getBundleByVersion(version);

  if (!bundle) {
    throw new Error('No downloaded bundle is available.');
  }

  return bundle;
}

async function getLatestInactiveBundleOrThrow() {
  const candidate = getLatestInactiveBundle(state.bundles);

  if (candidate) {
    return candidate;
  }

  await refreshState();
  const latestInactive = getLatestInactiveBundle(state.bundles);

  if (!latestInactive) {
    throw new Error('No inactive bundle is available.');
  }

  return latestInactive;
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

function markPendingReloadAction(actionId) {
  window.localStorage.setItem(pendingReloadActionStorageKey, actionId);
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

function normalizeError(error) {
  return {
    code: error?.code ?? error?.error ?? error?.data?.error ?? null,
    message: error?.message ?? String(error),
  };
}

function errorMatches(error, fragments) {
  const normalized = normalizeError(error);
  const haystack = `${normalized.code ?? ''} ${normalized.message}`.toLowerCase();
  return fragments.some((fragment) => haystack.includes(fragment.toLowerCase()));
}

async function expectConfiguredRejection(label, operation, fragments) {
  try {
    await operation();
  } catch (error) {
    invariant(errorMatches(error, fragments), `${label} rejected unexpectedly: ${normalizeError(error).message}`);
    return {
      outcome: 'expected-rejection',
      ...normalizeError(error),
    };
  }

  throw new Error(`${label} unexpectedly resolved`);
}

function invariant(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function expectBoolean(value, message) {
  invariant(typeof value === 'boolean', message);
}

function expectNumber(value, message) {
  invariant(typeof value === 'number' && !Number.isNaN(value), message);
}

function expectString(value, message) {
  invariant(typeof value === 'string' && value.trim().length > 0, message);
}

function expectBundle(bundle, label) {
  invariant(bundle && typeof bundle === 'object', `${label} did not return a bundle`);
  expectString(bundle.id ?? '', `${label} did not return a bundle id`);
  expectString(getBundleVersion(bundle), `${label} did not return a bundle version`);
  return bundle;
}

function expectCurrentBundleResult(result) {
  expectBundle(result?.bundle, 'current()');
  expectString(String(result?.native ?? ''), 'current() did not return the native version');
  return result;
}

function expectBundleListResult(result) {
  invariant(Array.isArray(result?.bundles), 'list() did not return a bundles array');
  return result;
}

function expectStringFieldResult(result, fieldName, label) {
  expectString(result?.[fieldName] ?? '', `${label} did not return ${fieldName}`);
  return result;
}

function expectBooleanFieldResult(result, fieldName, label) {
  expectBoolean(result?.[fieldName], `${label} did not return ${fieldName}`);
  return result;
}

function expectOptionalBundleResult(result, label) {
  if (result == null) {
    return result;
  }

  if (result?.bundle) {
    expectBundle(result.bundle, label);
    return result;
  }

  expectBundle(result, label);
  return result;
}

function expectListChannelsResult(result) {
  invariant(Array.isArray(result?.channels), 'listChannels() did not return a channels array');
  invariant(
    result.channels.some((channel) => channel?.name === 'beta'),
    'listChannels() did not include the beta channel',
  );
  return result;
}

function expectChannel(channelResult, expectedChannel, label) {
  invariant(channelResult && typeof channelResult === 'object', `${label} did not return a channel result`);
  invariant(
    (channelResult.channel ?? '') === expectedChannel,
    `${label} expected channel ${expectedChannel || 'none'}, received ${channelResult.channel || 'none'}`,
  );
  return channelResult;
}

function expectEnabledResult(result, label) {
  expectBoolean(result?.enabled, `${label} did not return enabled`);
  invariant(result.enabled === true, `${label} expected enabled=true`);
  return result;
}

function expectGetLatestResult(result) {
  expectString(result?.version ?? '', 'getLatest() did not return version');
  invariant(
    Array.isArray(result?.manifest) || (typeof result?.url === 'string' && result.url.trim().length > 0),
    'getLatest() did not return a download target',
  );
  return result;
}

function expectResolvedContract(contractResult, methodName) {
  invariant(
    contractResult.outcome === 'resolved',
    `${methodName} unexpectedly rejected: ${contractResult.code ?? contractResult.message ?? 'unknown error'}`,
  );
  return contractResult.result;
}

function expectNotSupportedContract(contractResult, methodName) {
  invariant(contractResult.outcome === 'rejected', `${methodName} unexpectedly resolved`);
  const errorText = `${contractResult.code ?? ''} ${contractResult.message ?? ''}`.toLowerCase();
  invariant(
    errorText.includes('not_supported') || errorText.includes('not supported'),
    `${methodName} did not reject with NOT_SUPPORTED`,
  );
}

function validateGetAppUpdateInfoContract(contractResult) {
  if (contractResult.outcome === 'rejected' && platform === 'android') {
    invariant(
      errorMatches(contractResult, [
        'install error',
        'play store',
        'store information is unavailable',
        'app update info',
        'not allowed',
        'not available',
      ]),
      `getAppUpdateInfo() rejected unexpectedly: ${contractResult.message ?? 'unknown error'}`,
    );
    return contractResult;
  }

  if (contractResult.outcome === 'rejected' && platform === 'ios') {
    invariant(
      errorMatches(contractResult, [
        'app store lookup failed',
        'failed to parse app store response',
        'invalid response from app store',
        'no data received from app store',
        'timed out',
        'network',
        'offline',
      ]),
      `getAppUpdateInfo() rejected unexpectedly: ${contractResult.message ?? 'unknown error'}`,
    );
    return contractResult;
  }

  const result = expectResolvedContract(contractResult, 'getAppUpdateInfo()');
  expectString(result?.currentVersionName ?? '', 'getAppUpdateInfo() did not return currentVersionName');
  expectString(result?.currentVersionCode ?? '', 'getAppUpdateInfo() did not return currentVersionCode');
  expectNumber(result?.updateAvailability, 'getAppUpdateInfo() did not return updateAvailability');

  if (platform === 'ios') {
    if (result.immediateUpdateAllowed !== undefined) {
      expectBoolean(result.immediateUpdateAllowed, 'getAppUpdateInfo() returned an invalid immediateUpdateAllowed');
      invariant(result.immediateUpdateAllowed === false, 'getAppUpdateInfo() reported iOS immediate updates as allowed');
    }

    if (result.flexibleUpdateAllowed !== undefined) {
      expectBoolean(result.flexibleUpdateAllowed, 'getAppUpdateInfo() returned an invalid flexibleUpdateAllowed');
      invariant(result.flexibleUpdateAllowed === false, 'getAppUpdateInfo() reported iOS flexible updates as allowed');
    }

    return contractResult;
  }

  expectBoolean(result?.immediateUpdateAllowed, 'getAppUpdateInfo() did not return immediateUpdateAllowed');
  expectBoolean(result?.flexibleUpdateAllowed, 'getAppUpdateInfo() did not return flexibleUpdateAllowed');

  return contractResult;
}

function validateOpenAppStoreContract(contractResult) {
  expectResolvedContract(contractResult, 'openAppStore()');
  return contractResult;
}

function validateImmediateUpdateContract(contractResult) {
  if (platform === 'ios') {
    expectNotSupportedContract(contractResult, 'performImmediateUpdate()');
    return contractResult;
  }

  const result = expectResolvedContract(contractResult, 'performImmediateUpdate()');
  expectNumber(result?.code, 'performImmediateUpdate() did not return a result code');
  return contractResult;
}

function validateFlexibleUpdateContract(contractResult) {
  if (platform === 'ios') {
    expectNotSupportedContract(contractResult, 'startFlexibleUpdate()');
    return contractResult;
  }

  const result = expectResolvedContract(contractResult, 'startFlexibleUpdate()');
  expectNumber(result?.code, 'startFlexibleUpdate() did not return a result code');
  return contractResult;
}

function validateCompleteFlexibleUpdateContract(contractResult) {
  if (platform === 'ios') {
    expectNotSupportedContract(contractResult, 'completeFlexibleUpdate()');
    return contractResult;
  }

  if (contractResult.outcome === 'resolved') {
    return contractResult;
  }

  expectString(contractResult.message ?? '', 'completeFlexibleUpdate() rejected without an error message');
  return contractResult;
}

async function invokeContractMethod(methodName, runner, validator) {
  try {
    const contractResult = {
      method: methodName,
      outcome: 'resolved',
      result: await runner(),
    };
    validator?.(contractResult);
    return contractResult;
  } catch (error) {
    const contractResult = {
      method: methodName,
      outcome: 'rejected',
      ...normalizeError(error),
    };
    validator?.(contractResult);
    return contractResult;
  }
}

async function fetchJson(url, options = {}) {
  const method = options.method ?? 'GET';

  try {
    const response = await withTimeout(
      `${method} ${url}`,
      () => fetch(url, options),
      15000,
    );

    if (!response.ok) {
      throw new Error(`${method} ${url} returned HTTP ${response.status}`);
    }

    return response.json();
  } catch (error) {
    const message = `${method} ${url} failed: ${error?.message ?? String(error)}`;
    console.error('[Harness] fetchJson failed', message, error);
    throw new Error(message);
  }
}

async function resetServerRelease() {
  const endpoint = createServerEndpoint('/api/control/reset');

  if (!endpoint) {
    throw new Error('Server control endpoint is not available.');
  }

  try {
    console.log('[Harness] resetServerRelease', endpoint);
    await fetchJson(endpoint);
    await refreshServerState();
    renderState();
    return state.serverDebug;
  } catch (error) {
    const message = error?.message ?? String(error);
    addEvent('resetServerRelease() failed', { endpoint, message });
    throw error;
  }
}

async function advanceServerRelease() {
  const endpoint = createServerEndpoint('/api/control/advance');

  if (!endpoint) {
    throw new Error('Server control endpoint is not available.');
  }

  try {
    console.log('[Harness] advanceServerRelease', endpoint);
    await fetchJson(endpoint);
    await refreshServerState();
    renderState();
    return state.serverDebug;
  } catch (error) {
    const message = error?.message ?? String(error);
    addEvent('advanceServerRelease() failed', { endpoint, message });
    throw error;
  }
}

const actions = [
  {
    id: 'notify-app-ready',
    label: 'Notify app ready',
    buttonLabel: 'Run notifyAppReady',
    description: 'Confirm that the current bundle booted successfully.',
    includeInSmokeSequence: true,
    run: async () => {
      const result = await performNotifyAppReady();
      expectBundle(result?.bundle, 'notifyAppReady()');
      return result;
    },
  },
  {
    id: 'current-bundle',
    label: 'Get current bundle',
    buttonLabel: 'Run current()',
    description: 'Read the active bundle and builtin native version.',
    includeInSmokeSequence: true,
    run: async () => expectCurrentBundleResult(await plugin.current()),
  },
  {
    id: 'list-bundles',
    label: 'List downloaded bundles',
    buttonLabel: 'Run list()',
    description: 'Inspect bundles currently stored on the device.',
    includeInSmokeSequence: true,
    run: async () => expectBundleListResult(await plugin.list()),
  },
  {
    id: 'get-plugin-version',
    label: 'Get plugin version',
    buttonLabel: 'Run getPluginVersion()',
    description: 'Return the installed native plugin version.',
    includeInSmokeSequence: true,
    run: async () => expectStringFieldResult(await plugin.getPluginVersion(), 'version', 'getPluginVersion()'),
  },
  {
    id: 'get-builtin-version',
    label: 'Get builtin version',
    buttonLabel: 'Run getBuiltinVersion()',
    description: 'Return the builtin bundle version shipped with the native app.',
    includeInSmokeSequence: true,
    run: async () => expectStringFieldResult(await plugin.getBuiltinVersion(), 'version', 'getBuiltinVersion()'),
  },
  {
    id: 'get-device-id',
    label: 'Get device ID',
    buttonLabel: 'Run getDeviceId()',
    description: 'Return the secure device identifier used by the updater.',
    includeInSmokeSequence: true,
    run: async () => expectStringFieldResult(await plugin.getDeviceId(), 'deviceId', 'getDeviceId()'),
  },
  {
    id: 'is-auto-update-enabled',
    label: 'Check auto update mode',
    buttonLabel: 'Run isAutoUpdateEnabled()',
    description: 'Read whether the native plugin is in automatic update mode.',
    includeInSmokeSequence: true,
    run: async () => expectBooleanFieldResult(await plugin.isAutoUpdateEnabled(), 'enabled', 'isAutoUpdateEnabled()'),
  },
  {
    id: 'is-auto-update-available',
    label: 'Check auto update availability',
    buttonLabel: 'Run isAutoUpdateAvailable()',
    description: 'Read whether the current configuration still supports auto update.',
    includeInSmokeSequence: true,
    run: async () =>
      expectBooleanFieldResult(await plugin.isAutoUpdateAvailable(), 'available', 'isAutoUpdateAvailable()'),
  },
  {
    id: 'get-app-id',
    label: 'Get app ID',
    buttonLabel: 'Run getAppId()',
    description: 'Read the current updater app ID.',
    includeInSmokeSequence: true,
    run: async () => expectStringFieldResult(await plugin.getAppId(), 'appId', 'getAppId()'),
  },
  {
    id: 'set-app-id',
    label: 'Set app ID',
    buttonLabel: 'Apply app ID',
    description: 'Change the updater app ID at runtime.',
    includeInSmokeSequence: true,
    successMarker: (result) =>
      result?.outcome === 'expected-rejection'
        ? 'Action marker: set-app-id:expected-rejection'
        : 'Action marker: set-app-id:success',
    inputs: [
      {
        label: 'App ID',
        name: 'appId',
        type: 'text',
        value: runtimeSmokeAppId,
      },
    ],
    run: async (values) => {
      if (!allowModifyAppId) {
        return expectConfiguredRejection('setAppId()', () => plugin.setAppId({ appId: values.appId }), [
          'allowmodifyappid',
          'not allowed',
        ]);
      }

      await plugin.setAppId({ appId: values.appId });
      const result = await plugin.getAppId();
      expectStringFieldResult(result, 'appId', 'setAppId()');
      invariant(result.appId === values.appId, `setAppId() expected ${values.appId}, received ${result.appId}`);
      return result;
    },
  },
  {
    id: 'set-custom-id',
    label: 'Set custom ID',
    buttonLabel: 'Apply custom ID',
    description: 'Persist a custom identifier that the fake server can observe.',
    includeInSmokeSequence: true,
    inputs: [
      {
        label: 'Custom ID',
        name: 'customId',
        type: 'text',
        value: runtimeSmokeCustomId,
      },
    ],
    run: async (values) => {
      await plugin.setCustomId({ customId: values.customId });
      return {
        customId: values.customId,
        message: 'customId stored',
      };
    },
  },
  {
    id: 'set-runtime-urls',
    label: 'Apply runtime URLs',
    buttonLabel: 'Apply runtime URLs',
    quickButtonLabel: 'Quick apply runtime URLs',
    description: 'Point update, stats, and channel methods at the fake OTA server.',
    showWhen: () => serverUrl.startsWith('http'),
    run: async () => {
      if (!allowModifyUrl) {
        return expectConfiguredRejection(
          'runtime URL update',
          () => plugin.setUpdateUrl({ url: getRuntimeUpdateUrl() }),
          ['allowmodifyurl', 'not allowed'],
        );
      }

      const updateUrl = getRuntimeUpdateUrl();
      const statsUrl = getRuntimeStatsUrl();
      const channelUrl = getRuntimeChannelUrl();

      await plugin.setUpdateUrl({ url: updateUrl });
      await plugin.setStatsUrl({ url: statsUrl });
      await plugin.setChannelUrl({ url: channelUrl });

      return {
        channelUrl,
        statsUrl,
        updateUrl,
      };
    },
  },
  {
    id: 'set-update-url',
    label: 'Set update URL',
    buttonLabel: 'Apply update URL',
    description: 'Point the example app at a custom update endpoint.',
    includeInSmokeSequence: true,
    successMarker: (result) =>
      result?.outcome === 'expected-rejection'
        ? 'Action marker: set-update-url:expected-rejection'
        : 'Action marker: set-update-url:success',
    inputs: [
      {
        label: 'Update URL',
        name: 'updateUrl',
        type: 'text',
        value: getRuntimeUpdateUrl(),
      },
    ],
    run: async (values) => {
      if (!allowModifyUrl) {
        return expectConfiguredRejection('setUpdateUrl()', () => plugin.setUpdateUrl({ url: values.updateUrl }), [
          'allowmodifyurl',
          'not allowed',
        ]);
      }

      await plugin.setUpdateUrl({ url: values.updateUrl });
      return {
        message: 'Update URL set.',
        url: values.updateUrl,
      };
    },
  },
  {
    id: 'set-stats-url',
    label: 'Set stats URL',
    buttonLabel: 'Apply stats URL',
    description: 'Point updater statistics at the fake server.',
    includeInSmokeSequence: true,
    successMarker: (result) =>
      result?.outcome === 'expected-rejection'
        ? 'Action marker: set-stats-url:expected-rejection'
        : 'Action marker: set-stats-url:success',
    inputs: [
      {
        label: 'Stats URL',
        name: 'statsUrl',
        type: 'text',
        value: getRuntimeStatsUrl(),
      },
    ],
    run: async (values) => {
      if (!allowModifyUrl) {
        return expectConfiguredRejection('setStatsUrl()', () => plugin.setStatsUrl({ url: values.statsUrl }), [
          'allowmodifyurl',
          'not allowed',
        ]);
      }

      await plugin.setStatsUrl({ url: values.statsUrl });
      return {
        message: 'Stats URL set.',
        url: values.statsUrl,
      };
    },
  },
  {
    id: 'set-channel-url',
    label: 'Set channel URL',
    buttonLabel: 'Apply channel URL',
    description: 'Point channel operations at the fake server.',
    includeInSmokeSequence: true,
    successMarker: (result) =>
      result?.outcome === 'expected-rejection'
        ? 'Action marker: set-channel-url:expected-rejection'
        : 'Action marker: set-channel-url:success',
    inputs: [
      {
        label: 'Channel URL',
        name: 'channelUrl',
        type: 'text',
        value: getRuntimeChannelUrl(),
      },
    ],
    run: async (values) => {
      if (!allowModifyUrl) {
        return expectConfiguredRejection('setChannelUrl()', () => plugin.setChannelUrl({ url: values.channelUrl }), [
          'allowmodifyurl',
          'not allowed',
        ]);
      }

      await plugin.setChannelUrl({ url: values.channelUrl });
      return {
        message: 'Channel URL set.',
        url: values.channelUrl,
      };
    },
  },
  {
    id: 'list-channels',
    label: 'List channels',
    buttonLabel: 'Run listChannels()',
    description: 'Read the channels that the device is allowed to self-assign to.',
    includeInSmokeSequence: true,
    smokeTimeoutMs: 90000,
    showWhen: () => serverUrl.startsWith('http'),
    run: async () => {
      const result = expectListChannelsResult(await plugin.listChannels());
      state.listChannelsResult = result;
      state.lastListChannelsCheck = formatAvailableChannels(result);
      return result;
    },
  },
  {
    id: 'set-channel-beta',
    label: 'Set public channel',
    buttonLabel: 'Set channel beta',
    description: 'Persist a real channel override the server can observe.',
    includeInSmokeSequence: true,
    smokeTimeoutMs: 90000,
    showWhen: () => serverUrl.startsWith('http'),
    successMarker: (result) =>
      result?.outcome === 'expected-rejection'
        ? 'Action marker: set-channel-beta:expected-rejection'
        : 'Action marker: set-channel-beta:success',
    run: async () => {
      if (!allowSetDefaultChannel) {
        const result = await expectConfiguredRejection('setChannel(beta)', () => plugin.setChannel({ channel: 'beta' }), [
          'disabled_by_config',
          'configuration',
        ]);
        state.lastSetChannelBetaCheck = 'expected-rejection';
        return result;
      }

      await plugin.setChannel({ channel: 'beta' });
      const result = expectChannel(await plugin.getChannel(), 'beta', 'setChannel(beta)');
      state.getChannelResult = result;
      state.lastSetChannelBetaCheck = 'success';
      return result;
    },
  },
  {
    id: 'get-channel',
    label: 'Get channel',
    buttonLabel: 'Run getChannel()',
    description: 'Read the currently active channel override.',
    includeInSmokeSequence: true,
    smokeTimeoutMs: 90000,
    showWhen: () => serverUrl.startsWith('http'),
    successMarker: (result) => `Action marker: get-channel:${result?.channel || 'none'}`,
    run: async () => {
      const result = expectChannel(await plugin.getChannel(), allowSetDefaultChannel ? 'beta' : '', 'getChannel()');
      state.getChannelResult = result;
      state.getChannelReadMarker = result?.channel || 'none';
      return result;
    },
  },
  {
    id: 'set-channel-private',
    label: 'Reject private channel',
    buttonLabel: 'Set channel private-alpha',
    description: 'Assert the private-channel event and rejection contract.',
    includeInSmokeSequence: true,
    smokeTimeoutMs: 90000,
    showWhen: () => serverUrl.startsWith('http'),
    successMarker: (result) =>
      result?.outcome === 'expected-rejection'
        ? 'Action marker: set-channel-private:expected-rejection'
        : 'Action marker: set-channel-private:success',
    run: async () => {
      state.eventMarkers.channelPrivate = 'none';
      renderState();

      if (!allowSetDefaultChannel) {
        const result = await expectConfiguredRejection(
          'setChannel(private-alpha)',
          () => plugin.setChannel({ channel: 'private-alpha' }),
          [
          'disabled_by_config',
          'configuration',
          ],
        );
        state.lastPrivateChannelCheck = 'expected-rejection';
        return result;
      }

      try {
        await plugin.setChannel({ channel: 'private-alpha' });
        throw new Error('setChannel(private-alpha) unexpectedly resolved');
      } catch (error) {
        await waitForEventMarker('channelPrivate', 'private-alpha');
        state.lastPrivateChannelCheck = 'expected-rejection';
        return {
          outcome: 'expected-rejection',
          ...normalizeError(error),
        };
      }
    },
  },
  {
    id: 'unset-channel',
    label: 'Unset channel',
    buttonLabel: 'Run unsetChannel()',
    description: 'Clear the local channel override and fall back to default behaviour.',
    includeInSmokeSequence: true,
    smokeTimeoutMs: 90000,
    showWhen: () => serverUrl.startsWith('http'),
    run: async () => {
      await plugin.unsetChannel();
      const result = expectChannel(await plugin.getChannel(), '', 'unsetChannel()');
      state.getChannelResult = result;
      state.lastUnsetChannelCheck = 'success';
      return result;
    },
  },
  {
    id: 'get-next-bundle',
    label: 'Get next bundle',
    buttonLabel: 'Run getNextBundle()',
    quickButtonLabel: 'Quick read next bundle',
    description: 'Read the queued bundle that would be applied on the next reload.',
    includeInSmokeSequence: true,
    markerId: 'next',
    run: async () => expectOptionalBundleResult(await plugin.getNextBundle(), 'getNextBundle()'),
  },
  {
    id: 'get-failed-update',
    label: 'Get failed update',
    buttonLabel: 'Run getFailedUpdate()',
    quickButtonLabel: 'Quick read failed update',
    description: 'Read the last failed bundle if a rollback occurred.',
    includeInSmokeSequence: true,
    markerId: 'failed',
    run: async () => {
      const result = expectOptionalBundleResult(await plugin.getFailedUpdate(), 'getFailedUpdate()');
      state.failedUpdate = result;
      return result;
    },
  },
  {
    id: 'set-shake-menu',
    label: 'Enable shake menu',
    buttonLabel: 'Run setShakeMenu(true)',
    description: 'Toggle the debug shake menu at runtime.',
    includeInSmokeSequence: true,
    run: async () => {
      await plugin.setShakeMenu({ enabled: true });
      return expectEnabledResult(await plugin.isShakeMenuEnabled(), 'setShakeMenu(true)');
    },
  },
  {
    id: 'is-shake-menu-enabled',
    label: 'Check shake menu',
    buttonLabel: 'Run isShakeMenuEnabled()',
    description: 'Read the current shake menu state.',
    includeInSmokeSequence: true,
    run: async () => expectEnabledResult(await plugin.isShakeMenuEnabled(), 'isShakeMenuEnabled()'),
  },
  {
    id: 'set-shake-channel-selector',
    label: 'Enable shake channel selector',
    buttonLabel: 'Run setShakeChannelSelector(true)',
    description: 'Toggle the shake-driven channel selector at runtime.',
    includeInSmokeSequence: true,
    run: async () => {
      await plugin.setShakeChannelSelector({ enabled: true });
      return expectEnabledResult(
        await plugin.isShakeChannelSelectorEnabled(),
        'setShakeChannelSelector(true)',
      );
    },
  },
  {
    id: 'is-shake-channel-selector-enabled',
    label: 'Check shake channel selector',
    buttonLabel: 'Run isShakeChannelSelectorEnabled()',
    description: 'Read the current shake channel selector state.',
    includeInSmokeSequence: true,
    run: async () =>
      expectEnabledResult(await plugin.isShakeChannelSelectorEnabled(), 'isShakeChannelSelectorEnabled()'),
  },
  {
    id: 'remove-all-listeners',
    label: 'Reset listeners',
    buttonLabel: 'Run removeAllListeners()',
    description: 'Exercise the listener cleanup path, then re-attach the harness listeners.',
    includeInSmokeSequence: true,
    run: async () => {
      await plugin.removeAllListeners();
      listenersAttached = false;
      await attachListeners();
      return {
        message: 'Listeners removed and reattached.',
      };
    },
  },
  {
    id: 'get-app-update-info',
    label: 'Get store update info',
    buttonLabel: 'Run getAppUpdateInfo()',
    quickButtonLabel: 'Quick get store info',
    description: 'Read the App Store or Play Store update contract for the example app.',
    includeInSmokeSequence: true,
    run: async () => invokeContractMethod('getAppUpdateInfo', () => plugin.getAppUpdateInfo(), validateGetAppUpdateInfoContract),
  },
  {
    id: 'open-app-store',
    label: 'Open store page',
    buttonLabel: 'Run openAppStore()',
    quickButtonLabel: 'Quick open store page',
    description: 'Exercise the store-opening contract used as the fallback for native app updates.',
    run: async () => invokeContractMethod('openAppStore', () => plugin.openAppStore(), validateOpenAppStoreContract),
  },
  {
    id: 'perform-immediate-update',
    label: 'Try immediate update',
    buttonLabel: 'Run performImmediateUpdate()',
    quickButtonLabel: 'Quick immediate update',
    description: 'Exercise the platform contract for immediate store updates.',
    includeInSmokeSequence: true,
    run: async () =>
      invokeContractMethod('performImmediateUpdate', () => plugin.performImmediateUpdate(), validateImmediateUpdateContract),
  },
  {
    id: 'start-flexible-update',
    label: 'Try flexible update',
    buttonLabel: 'Run startFlexibleUpdate()',
    quickButtonLabel: 'Quick flexible update',
    description: 'Exercise the platform contract for flexible store updates.',
    includeInSmokeSequence: true,
    run: async () =>
      invokeContractMethod('startFlexibleUpdate', () => plugin.startFlexibleUpdate(), validateFlexibleUpdateContract),
  },
  {
    id: 'complete-flexible-update',
    label: 'Complete flexible update',
    buttonLabel: 'Run completeFlexibleUpdate()',
    quickButtonLabel: 'Quick complete update',
    description: 'Exercise the platform contract for completing a downloaded flexible update.',
    includeInSmokeSequence: true,
    run: async () =>
      invokeContractMethod(
        'completeFlexibleUpdate',
        () => plugin.completeFlexibleUpdate(),
        validateCompleteFlexibleUpdateContract,
      ),
  },
  {
    id: 'verify-persisted-config',
    label: 'Verify persisted runtime config',
    buttonLabel: 'Verify persisted runtime config',
    quickButtonLabel: 'Quick verify persisted config',
    description: 'Re-run persisted routing checks after a cold launch, reusing getLatest() when it already ran.',
    showWhen: () => serverUrl.startsWith('http'),
    markerId: 'persisted',
    run: async () => {
      const channels = expectListChannelsResult(await plugin.listChannels());
      const latest =
        state.lastLatest != null
          ? expectGetLatestResult(state.lastLatest)
          : expectGetLatestResult(await plugin.getLatest());
      const appIdResult = expectStringFieldResult(await plugin.getAppId(), 'appId', 'verify persisted getAppId()');
      state.listChannelsResult = channels;
      state.lastLatest = latest;
      await refreshServerState();
      renderState();

      const serverDebug = state.serverDebug?.debug ?? {};
      const lastUpdateRequest = serverDebug.lastUpdateRequest ?? {};
      const lastChannelRequest = serverDebug.lastChannelRequest ?? {};
      const lastStatsRequest = serverDebug.lastStatsRequest ?? {};
      const observedUpdateUrl = formatObservedRequestUrl(lastUpdateRequest.url);
      const observedChannelUrl = formatObservedRequestUrl(lastChannelRequest.url, ['scenario', 'source']);
      const observedStatsUrl = formatObservedRequestUrl(lastStatsRequest.url);
      const expectedUsesRuntimeUrls = allowModifyUrl && persistModifyUrl;
      const expectedUpdateUrl = formatObservedRequestUrl(
        expectedUsesRuntimeUrls ? getRuntimeUpdateUrl() : getDefaultUpdateUrl(),
      );
      const expectedChannelUrl = formatObservedRequestUrl(
        expectedUsesRuntimeUrls ? getRuntimeChannelUrl() : getDefaultChannelUrl(),
        ['scenario', 'source'],
      );
      const expectedStatsUrl = formatObservedRequestUrl(
        expectedUsesRuntimeUrls ? getRuntimeStatsUrl() : getDefaultStatsUrl(),
      );
      const observedAppId = lastUpdateRequest.payload?.app_id || lastChannelRequest.payload?.app_id || 'none';
      const expectedCustomId = persistCustomId ? runtimeSmokeCustomId : 'none';
      const observedUpdateCustomId = lastUpdateRequest.payload?.custom_id || 'none';
      const observedChannelCustomId = lastChannelRequest.payload?.custom_id || 'none';

      invariant(
        observedUpdateUrl === expectedUpdateUrl,
        `verify persisted config expected update URL ${expectedUpdateUrl}, received ${observedUpdateUrl}`,
      );
      invariant(
        observedChannelUrl === expectedChannelUrl,
        `verify persisted config expected channel URL ${expectedChannelUrl}, received ${observedChannelUrl}`,
      );
      invariant(
        observedStatsUrl === expectedStatsUrl,
        `verify persisted config expected stats URL ${expectedStatsUrl}, received ${observedStatsUrl}`,
      );
      invariant(
        appIdResult.appId !== runtimeSmokeAppId,
        `verify persisted getAppId() should not keep the runtime app ID ${runtimeSmokeAppId} after relaunch`,
      );
      invariant(
        observedAppId === appIdResult.appId,
        `verify persisted config expected server app_id ${appIdResult.appId}, received ${observedAppId}`,
      );
      invariant(
        observedAppId !== runtimeSmokeAppId,
        `verify persisted config should not keep the runtime app_id ${runtimeSmokeAppId} after relaunch`,
      );
      invariant(
        observedUpdateCustomId === expectedCustomId,
        `verify persisted config expected update custom_id ${expectedCustomId}, received ${observedUpdateCustomId}`,
      );
      invariant(
        observedChannelCustomId === expectedCustomId,
        `verify persisted config expected channel custom_id ${expectedCustomId}, received ${observedChannelCustomId}`,
      );

      return {
        appId: appIdResult.appId,
        channels: channels.channels,
        customId: expectedCustomId,
        channelUrl: observedChannelUrl,
        statsUrl: observedStatsUrl,
        updateUrl: observedUpdateUrl,
        version: latest.version,
      };
    },
  },
  {
    id: 'refresh-server-state',
    label: 'Read fake server state',
    buttonLabel: 'Refresh fake server state',
    description: 'Pull the fake server debug view used by Maestro assertions.',
    showWhen: () => serverUrl.startsWith('http'),
    markerId: 'server',
    run: async () => {
      await refreshServerState();
      renderState();
      return state.serverDebug;
    },
  },
  {
    id: 'reset-server-release',
    label: 'Reset fake server release',
    buttonLabel: 'Run resetServerRelease()',
    quickButtonLabel: 'Quick reset release',
    description: 'Reset the fake OTA server back to the first release for this scenario.',
    showWhen: () => serverUrl.startsWith('http'),
    markerId: 'reset',
    run: async () => resetServerRelease(),
  },
  {
    id: 'advance-server-release',
    label: 'Advance fake server release',
    buttonLabel: 'Run advanceServerRelease()',
    quickButtonLabel: 'Quick advance release',
    description: 'Move the fake OTA server to the next release in the scenario.',
    showWhen: () => serverUrl.startsWith('http'),
    markerId: 'advance',
    run: async () => advanceServerRelease(),
  },
  {
    id: 'get-latest',
    label: 'Get latest OTA bundle',
    buttonLabel: 'Run getLatest()',
    quickButtonLabel: 'Quick get latest',
    description: 'Fetch the latest bundle metadata from the fake OTA server.',
    includeInSmokeSequence: true,
    smokeTimeoutMs: 90000,
    showWhen: () => serverUrl.startsWith('http'),
    run: async () => {
      const latest = expectGetLatestResult(await plugin.getLatest());
      state.lastLatest = latest;
      state.lastGetLatestCheck = latest.version ?? 'none';
      return latest;
    },
  },
  {
    id: 'get-latest-no-update',
    label: 'Assert no OTA update available',
    buttonLabel: 'Assert no update available',
    quickButtonLabel: 'Quick confirm no update',
    description: 'Call getLatest() when the current bundle already matches the server and assert the expected rejection.',
    showWhen: () => serverUrl.startsWith('http'),
    markerId: 'no-update',
    run: async () => {
      const currentVersion = getBundleVersion(state.currentBundle);
      invariant(
        currentVersion !== 'builtin' && currentVersion !== 'none',
        'No downloaded bundle is active to prove the no-update getLatest() branch.',
      );

      try {
        await plugin.getLatest();
      } catch (error) {
        invariant(
          errorMatches(error, ['no new version available', 'no_new_version_available', 'no_need_update', 'no need update']),
          `getLatest() rejected unexpectedly: ${normalizeError(error).message}`,
        );
        return {
          currentVersion,
          outcome: 'expected-no-update',
          ...normalizeError(error),
        };
      }

      throw new Error('getLatest() unexpectedly resolved when no update should be available.');
    },
  },
  {
    id: 'download-latest-bundle',
    label: 'Download latest OTA bundle',
    buttonLabel: 'Download latest bundle',
    quickButtonLabel: 'Quick download latest bundle',
    description: 'Run getLatest() and then download the returned zip or manifest bundle.',
    showWhen: () => serverUrl.startsWith('http'),
    markerId: 'download',
    run: async () => {
      state.eventMarkers.download = 'none';
      state.eventMarkers.downloadComplete = 'none';
      state.eventMarkers.downloadFailed = 'none';
      state.eventMarkers.updateAvailable = 'none';
      renderState();

      state.lastPhase = 'download-latest-bundle:getLatest:invoke:start';
      renderState();
      const latestPromise = plugin.getLatest();
      state.lastPhase = 'download-latest-bundle:getLatest:invoke:success';
      renderState();
      const latest = await latestPromise;
      state.lastLatest = latest;
      state.lastPhase = 'download-latest-bundle:getLatest:await:success';
      renderState();

      state.lastPhase = 'download-latest-bundle:download:start';
      renderState();
      const downloadResult = await plugin.download({
        checksum: latest.checksum,
        manifest: latest.manifest,
        sessionKey: latest.sessionKey,
        url: latest.url,
        version: latest.version,
      });
      state.lastPhase = 'download-latest-bundle:download:success';
      renderState();

      state.lastPhase = 'download-latest-bundle:list:start';
      renderState();
      const storedBundle = await waitForBundleVersion(latest.version);
      state.lastDownloadedBundleId = storedBundle.id ?? downloadResult?.id ?? null;
      state.lastDownloadedBundleVersion = latest.version;
      state.lastPhase = 'download-latest-bundle:list:success';
      renderState();

      await waitForEventMarker('updateAvailable', latest.version, 30000);
      await waitForEventMarker('downloadComplete', latest.version, 30000);
      invariant(
        state.eventMarkers.downloadFailed === 'none',
        `download() emitted downloadFailed for ${latest.version}: ${state.eventMarkers.downloadFailed}`,
      );

      return {
        downloadResult,
        storedBundle,
      };
    },
  },
  {
    id: 'set-last-downloaded-bundle',
    label: 'Apply downloaded bundle now',
    buttonLabel: 'Apply last downloaded bundle now',
    quickButtonLabel: 'Quick apply bundle now',
    description: 'Call set() on the latest downloaded bundle and reload immediately.',
    showWhen: () => serverUrl.startsWith('http'),
    reloadsApp: true,
    run: async () => {
      const bundle = await getLastDownloadedBundleOrThrow();
      markPendingReloadAction('set-last-downloaded-bundle');
      void plugin.set({ id: bundle.id });
      return {
        bundle,
        message: `Applying ${getBundleVersion(bundle)} with set().`,
      };
    },
  },
  {
    id: 'queue-last-downloaded-bundle',
    label: 'Queue downloaded bundle',
    buttonLabel: 'Queue last downloaded bundle',
    quickButtonLabel: 'Quick queue bundle',
    description: 'Call next() on the latest downloaded bundle.',
    showWhen: () => serverUrl.startsWith('http'),
    markerId: 'queue',
    run: async () => {
      state.eventMarkers.setNext = 'none';
      renderState();

      const bundle = await getLastDownloadedBundleOrThrow();
      const result = await plugin.next({ id: bundle.id });
      await waitForEventMarker('setNext', getBundleVersion(bundle), 30000);
      return result;
    },
  },
  {
    id: 'set-multi-delay',
    label: 'Set background delay',
    buttonLabel: 'Run setMultiDelay()',
    quickButtonLabel: 'Quick set delay',
    description: 'Require one background cycle before a queued bundle applies.',
    showWhen: () => serverUrl.startsWith('http'),
    markerId: 'delay',
    run: async () => {
      await plugin.setMultiDelay({
        delayConditions: [{ kind: 'background' }],
      });
      return {
        message: 'Delay conditions stored.',
      };
    },
  },
  {
    id: 'cancel-delay',
    label: 'Cancel delay',
    buttonLabel: 'Run cancelDelay()',
    quickButtonLabel: 'Quick cancel delay',
    description: 'Clear any queued delay conditions for the pending bundle.',
    showWhen: () => serverUrl.startsWith('http'),
    markerId: 'cancel',
    run: async () => {
      await plugin.cancelDelay();
      return {
        message: 'Delay cancelled.',
      };
    },
  },
  {
    id: 'reload-app',
    label: 'Reload app',
    buttonLabel: 'Run reload()',
    quickButtonLabel: 'Quick reload app',
    description: 'Reload the current web bundle or apply the queued next bundle immediately.',
    showWhen: () => serverUrl.startsWith('http'),
    reloadsApp: true,
    run: async () => {
      markPendingReloadAction('reload-app');
      void plugin.reload();
      return {
        message: 'Reload requested.',
      };
    },
  },
  {
    id: 'set-bundle-error',
    label: 'Mark inactive bundle as error',
    buttonLabel: 'Run setBundleError()',
    quickButtonLabel: 'Quick mark bundle error',
    description: 'Mark the newest inactive bundle as failed in manual mode.',
    showWhen: () => serverUrl.startsWith('http'),
    markerId: 'bundle',
    successMarker: (result) =>
      result?.outcome === 'expected-rejection'
        ? 'Action marker: bundle:expected-rejection'
        : 'Action marker: bundle:success',
    run: async () => {
      const bundle = await getLatestInactiveBundleOrThrow();

      if (!allowManualBundleError) {
        return expectConfiguredRejection('setBundleError()', () => plugin.setBundleError({ id: bundle.id }), [
          'allowmanualbundleerror',
          'not allowed',
        ]);
      }

      return plugin.setBundleError({ id: bundle.id });
    },
  },
  {
    id: 'delete-inactive-bundle',
    label: 'Delete inactive bundle',
    buttonLabel: 'Run delete() on inactive bundle',
    quickButtonLabel: 'Quick delete inactive bundle',
    description: 'Delete the newest bundle that is neither current nor pending.',
    showWhen: () => serverUrl.startsWith('http'),
    markerId: 'delete',
    run: async () => {
      const bundle = await getLatestInactiveBundleOrThrow();
      await plugin.delete({ id: bundle.id });
      await refreshState();
      return {
        deletedBundle: bundle,
      };
    },
  },
  {
    id: 'reset-to-builtin',
    label: 'Reset to builtin bundle',
    buttonLabel: 'Run reset() to builtin',
    quickButtonLabel: 'Quick reset to builtin',
    description: 'Reset back to the builtin bundle and reload immediately.',
    showWhen: () => serverUrl.startsWith('http'),
    reloadsApp: true,
    run: async () => {
      markPendingReloadAction('reset-to-builtin');
      void plugin.reset();
      return {
        message: 'Reset to builtin requested.',
      };
    },
  },
];

function getVisibleActions() {
  return actions.filter((action) => !action.showWhen || action.showWhen());
}

function getActionById(id) {
  const action = actions.find((candidate) => candidate.id === id);

  if (!action) {
    throw new Error(`Unknown action ${id}`);
  }

  return action;
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

function getActionMarkerId(action) {
  return action.markerId ?? action.id;
}

async function runAction(action, values, options = {}) {
  const { skipRefresh = false } = options;
  const actionMarker = actionMarkers.get(action.id);
  const actionMarkerId = getActionMarkerId(action);
  actionInProgress = true;
  state.lastAction = action.label;
  state.lastActionMarker = `${actionMarkerId}:${action.reloadsApp ? 'reloading' : 'running'}`;
  state.lastActionResult = `${action.id}:running`;
  state.lastPhase = `${action.id}:start`;
  window.localStorage.setItem(lastActionStorageKey, action.label);
  window.localStorage.setItem(lastActionResultStorageKey, state.lastActionResult);
  elements.lastAction.textContent = `Last action: ${state.lastAction}`;
  elements.lastActionResult.textContent = `Last action result: ${state.lastActionResult}`;
  elements.resultMarker.textContent = `M:${action.id}:${action.reloadsApp ? 'reloading' : 'running'}`;
  elements.output.textContent = `Running ${action.label}...`;

  if (actionMarker) {
    actionMarker.textContent = `Action marker: ${actionMarkerId}:${action.reloadsApp ? 'reloading' : 'running'}`;
  }

  try {
    const result = await action.run(values ?? {});
    elements.output.textContent = formatResult(result);

    if (action.reloadsApp) {
      state.lastActionMarker = `${actionMarkerId}:reloading`;
      state.lastActionResult = `${action.id}:reloading`;
      state.lastPhase = `${action.id}:reloading`;
      window.localStorage.setItem(lastActionResultStorageKey, state.lastActionResult);
      elements.lastActionResult.textContent = `Last action result: ${state.lastActionResult}`;
      elements.resultMarker.textContent = `M:${action.id}:reloading`;
      if (actionMarker) {
        actionMarker.textContent = `Action marker: ${actionMarkerId}:reloading`;
      }
      renderState();
      return result;
    }

    state.lastActionMarker = `${actionMarkerId}:success`;
    state.lastActionResult = `${action.id}:success`;
    state.lastPhase = `${action.id}:success`;
    window.localStorage.setItem(lastActionResultStorageKey, state.lastActionResult);
    elements.lastActionResult.textContent = `Last action result: ${state.lastActionResult}`;
    elements.resultMarker.textContent = `M:${action.id}:success`;
    if (actionMarker) {
      actionMarker.textContent =
        typeof action.successMarker === 'function'
          ? action.successMarker(result)
          : `Action marker: ${actionMarkerId}:success`;
    }
    if (!skipRefresh) {
      await refreshState();
    }
    return result;
  } catch (error) {
    const message = error?.message ?? String(error);
    state.lastError = message;
    state.lastActionMarker = `${actionMarkerId}:error`;
    state.lastActionResult = `${action.id}:error`;
    state.lastPhase = `${action.id}:error`;
    window.localStorage.setItem(lastActionResultStorageKey, state.lastActionResult);
    elements.lastActionResult.textContent = `Last action result: ${state.lastActionResult}`;
    elements.resultMarker.textContent = `M:${action.id}:error`;
    elements.output.textContent = `Error: ${message}`;
    if (actionMarker) {
      actionMarker.textContent = `Action marker: ${actionMarkerId}:error`;
    }
    renderState();
    throw error;
  } finally {
    actionInProgress = false;
  }
}

async function runSmokeSequence() {
  if (smokeSequencePromise) {
    return smokeSequencePromise;
  }

  const sequenceActions = getSmokeSequenceActions();

  smokeSequencePromise = (async () => {
    elements.sequenceStatus.textContent = 'Sequence: running';
    elements.resultMarker.textContent = 'M:smoke-sequence:running';
    elements.output.textContent = 'Running smoke test sequence...';
    elements.runSmokeSequenceButton.disabled = true;
    state.sequenceRuns += 1;
    sequenceInProgress = true;

    if (refreshStatePromise) {
      try {
        await withTimeout(
          'pending refreshState before smoke sequence',
          () => refreshStatePromise,
          10000,
        );
      } catch (error) {
        console.warn('Continuing smoke sequence after refresh wait timeout', error);
      }
    }

    state.lastAction = 'Smoke test sequence';
    state.lastActionMarker = 'smoke-sequence:running';
    state.lastActionResult = 'smoke-sequence:running';
    state.lastError = null;
    state.lastPhase = 'smoke-sequence:running';
    window.localStorage.setItem(lastActionStorageKey, state.lastAction);
    window.localStorage.setItem(lastActionResultStorageKey, state.lastActionResult);
    renderState();

    try {
      for (const action of sequenceActions) {
        state.lastPhase = `smoke-sequence:next:${action.id}`;
        renderState();
        const card = actionCards.get(action.id);
        const values = card ? getCardValues(card, action) : {};
        await withTimeout(
          `smoke action ${action.id}`,
          () => runAction(action, values, { skipRefresh: true }),
          action.smokeTimeoutMs ?? 45000,
        );
        await pause(getSmokeSequenceDelayMs(action.id));
      }

      state.lastAction = 'Smoke test sequence';
      state.lastActionMarker = 'smoke-sequence:success';
      state.lastActionResult = 'smoke-sequence:success';
      state.lastError = null;
      state.lastPhase = 'smoke-sequence:success';
      window.localStorage.setItem(lastActionStorageKey, state.lastAction);
      window.localStorage.setItem(lastActionResultStorageKey, state.lastActionResult);
      elements.sequenceStatus.textContent = 'Sequence: success';
      elements.resultMarker.textContent = 'M:smoke-sequence:success';
      renderState();
      void refreshState().catch((error) => {
        console.error('Smoke sequence refresh failed', error);
      });
    } catch (error) {
      const failedPhase = state.lastPhase;
      const rawMessage = error?.message ?? String(error);
      const message = rawMessage && rawMessage !== '[object Object]' ? rawMessage : 'unknown';
      const failureSummary = `${failedPhase}: ${message}`;
      state.lastAction = 'Smoke test sequence';
      state.lastActionMarker = `smoke-sequence:error:${failedPhase}`;
      state.lastActionResult = `smoke-sequence:error:${failedPhase}`;
      state.lastError = failureSummary;
      state.lastPhase = `smoke-sequence:error:${failedPhase}`;
      window.localStorage.setItem(lastActionStorageKey, state.lastAction);
      window.localStorage.setItem(lastActionResultStorageKey, state.lastActionResult);
      elements.sequenceStatus.textContent = 'Sequence: error';
      elements.resultMarker.textContent = `M:${state.lastActionResult}`;
      elements.output.textContent = `Error: ${failureSummary}`;
      renderState();
      console.error('Smoke sequence failed', error);
      throw error;
    } finally {
      sequenceInProgress = false;
      elements.runSmokeSequenceButton.disabled = false;
      smokeSequencePromise = null;
    }
  })();

  return smokeSequencePromise;
}

function getSmokeSequenceActions() {
  const visibleActions = getVisibleActions();
  const overrideIds = smokeSequenceActionIdsByScenario[scenarioId];

  if (!overrideIds) {
    return visibleActions.filter((action) => action.includeInSmokeSequence);
  }

  const visibleActionsById = new Map(visibleActions.map((action) => [action.id, action]));
  return overrideIds.map((id) => visibleActionsById.get(id)).filter(Boolean);
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

  const actionMarker = document.createElement('p');
  actionMarker.className = 'status-line action-marker';
  actionMarker.textContent = `Action marker: ${getActionMarkerId(action)}:idle`;
  card.appendChild(actionMarker);
  actionMarkers.set(action.id, actionMarker);

  return card;
}

function renderActions() {
  elements.smokeActions.innerHTML = '';
  actionCards.clear();
  actionMarkers.clear();

  getVisibleActions().forEach((action) => {
    const card = createActionCard(action);
    actionCards.set(action.id, card);
    elements.smokeActions.appendChild(card);
  });
}

function getVisibleQuickActions() {
  return quickActionIds.map((id) => getActionById(id)).filter((action) => !action.showWhen || action.showWhen());
}

function createQuickActionButton(action) {
  const button = document.createElement('button');
  const quickActionId = `quick-action-${action.id}`;
  button.type = 'button';
  button.id = quickActionId;
  button.setAttribute('data-testid', quickActionId);
  button.textContent = action.quickButtonLabel ?? action.buttonLabel;
  button.addEventListener('click', () => {
    void runAction(action, {}).catch((error) => {
      console.error(`Quick action ${action.id} failed`, error);
    });
  });
  return button;
}

function renderQuickActions() {
  elements.quickActions.innerHTML = '';

  getVisibleQuickActions().forEach((action) => {
    elements.quickActions.appendChild(createQuickActionButton(action));
  });
}

async function attachListeners() {
  if (listenersAttached) {
    return;
  }

  const listenerDefinitions = [
    { eventName: 'appReady', label: 'App ready event', refreshAfter: true },
    { eventName: 'appReloaded', label: 'App reloaded event', refreshAfter: true },
    { eventName: 'breakingAvailable', label: 'Breaking update event', refreshAfter: false },
    { eventName: 'channelPrivate', label: 'Channel private event', refreshAfter: false },
    { eventName: 'download', label: 'Download progress', refreshAfter: false },
    { eventName: 'downloadComplete', label: 'Download complete', refreshAfter: true },
    { eventName: 'downloadFailed', label: 'Download failed', refreshAfter: true },
    { eventName: 'majorAvailable', label: 'Major update event', refreshAfter: false },
    { eventName: 'noNeedUpdate', label: 'No need update event', refreshAfter: false },
    { eventName: 'onFlexibleUpdateStateChange', label: 'Flexible update event', refreshAfter: false },
    { eventName: 'set', label: 'Set event', refreshAfter: true },
    { eventName: 'setNext', label: 'Set next event', refreshAfter: true },
    { eventName: 'updateAvailable', label: 'Update available event', refreshAfter: false },
    { eventName: 'updateFailed', label: 'Update failed event', refreshAfter: true },
  ];

  await Promise.all(
    listenerDefinitions.map(({ eventName, label, refreshAfter }) =>
      plugin.addListener(eventName, async (payload) => {
        recordEventMarker(eventName, payload);

        if (eventName === 'downloadComplete') {
          state.lastDownload = getBundleVersion(payload?.bundle ?? payload);
        }

        if (eventName === 'updateFailed') {
          state.failedUpdate = payload;
        }

        addEvent(label, payload);
        renderState();

        if (refreshAfter) {
          await refreshState();
        }
      }),
    ),
  );

  listenersAttached = true;
}

function startStateRefreshWatchers() {
  const pollState = async () => {
    if (!document.hidden && !actionInProgress && !sequenceInProgress) {
      await refreshState();
    }

    window.setTimeout(() => {
      void pollState();
    }, 5000);
  };

  window.setTimeout(() => {
    void pollState();
  }, 5000);

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && !actionInProgress && !sequenceInProgress) {
      resetScrollPosition();
      void refreshState();
    }
  });

  window.addEventListener('focus', () => {
    resetScrollPosition();
  });

  window.addEventListener('pageshow', () => {
    resetScrollPosition();
  });
}

async function bootstrap() {
  if ('scrollRestoration' in window.history) {
    window.history.scrollRestoration = 'manual';
  }
  resetScrollPosition();
  renderQuickActions();
  renderActions();
  renderState();
  await attachListeners();

  if (!skipNotifyAppReady) {
    try {
      await performNotifyAppReady();
    } catch (error) {
      console.error('notifyAppReady() bootstrap failed', error);
    }
    } else {
      addEvent('notifyAppReady skipped', { message: 'disabled by VITE_CAPGO_SKIP_NOTIFY_APP_READY' });
    }

  await refreshState();
  startStateRefreshWatchers();
  state.harnessReady = true;
  renderState();
}

elements.refreshButton.addEventListener('click', () => {
  void refreshState();
});

elements.runSmokeSequenceButton.addEventListener('click', () => {
  void runSmokeSequence().catch((error) => {
    console.error('Smoke sequence failed', error);
  });
});

elements.quickRunSmokeSequenceButton.addEventListener('click', () => {
  void runSmokeSequence().catch((error) => {
    console.error('Quick smoke sequence failed', error);
  });
});

void bootstrap();
