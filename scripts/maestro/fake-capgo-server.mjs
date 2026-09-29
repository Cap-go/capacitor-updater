import { existsSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import {
  defaultDeviceBaseUrl,
  defaultHostBaseUrl,
  defaultPort,
  findScenario,
  getBundleChecksumPath,
  getBundleZipPath,
  getManifestDirectoryPath,
  getManifestMetadataPath,
  scenarios,
} from './scenarios.mjs';

const baseHeaders = {
  'access-control-allow-headers': '*',
  'access-control-allow-methods': 'GET,HEAD,POST,PUT,OPTIONS',
  'access-control-allow-origin': '*',
  'access-control-allow-private-network': 'true',
  'cache-control': 'no-store',
  connection: 'close',
};

const channelCatalog = [
  {
    id: 1,
    name: 'beta',
    public: false,
    allow_self_set: true,
  },
  {
    id: 2,
    name: 'public-preview',
    public: true,
    allow_self_set: true,
  },
  {
    id: 3,
    name: 'private-alpha',
    public: false,
    allow_self_set: false,
  },
];

// Fault injection lets Maestro flows reproduce real-world network failures deterministically:
// the device reaches this server through adb reverse / the host loopback, so toggling the
// emulator or simulator radio would not cut the connection. Faults are per scenario and are
// cleared on reset.
const faultModes = {
  bundle: new Set(['none', 'drop', 'stall', 'corrupt', 'http-500']),
  update: new Set(['none', 'drop', 'http-500']),
};

function createScenarioFaults() {
  return {
    bundle: 'none',
    update: 'none',
  };
}

function createBundleDownloadState() {
  return {
    aborted: 0,
    dropped: 0,
    faulted: 0,
    inFlight: 0,
    ranged: 0,
    served: 0,
    started: 0,
  };
}

function createScenarioDebugState() {
  return {
    bundleDownloads: createBundleDownloadState(),
    lastBundleRequest: null,
    lastChannelRequest: null,
    lastStatsRequest: null,
    lastUpdateRequest: null,
    requestCounts: {
      channel: 0,
      manifestFile: 0,
      stats: 0,
      update: 0,
    },
    manifestFiles: [],
    statsActionCounts: {},
    statsActions: [],
    updateFaults: 0,
  };
}

const scenarioState = new Map(Object.keys(scenarios).map((scenarioId) => [scenarioId, 0]));
const scenarioDebugState = new Map(Object.keys(scenarios).map((scenarioId) => [scenarioId, createScenarioDebugState()]));
const scenarioFaultState = new Map(Object.keys(scenarios).map((scenarioId) => [scenarioId, createScenarioFaults()]));
const stalledDownloadReleasers = new Map(Object.keys(scenarios).map((scenarioId) => [scenarioId, new Set()]));

function jsonResponse(payload, init = {}) {
  return Response.json(payload, {
    ...init,
    headers: {
      ...baseHeaders,
      ...(init.headers ?? {}),
    },
  });
}

function fileResponse(file, init = {}) {
  return new Response(file, {
    ...init,
    headers: {
      ...baseHeaders,
      ...(init.headers ?? {}),
    },
  });
}

function logRequest(requestUrl, method, details = '') {
  const suffix = details ? ` ${details}` : '';
  console.log(`[fake-capgo] ${method} ${requestUrl.pathname}${requestUrl.search}${suffix}`);
}

function getScenarioId(requestUrl, fallbackScenarioId = null) {
  return requestUrl.searchParams.get('scenario') ?? fallbackScenarioId;
}

function getScenarioFromQuery(requestUrl, fallbackScenarioId = null) {
  const scenarioId = getScenarioId(requestUrl, fallbackScenarioId);

  if (!scenarioId) {
    return null;
  }

  return findScenario(scenarioId);
}

function getScenarioStatePayload(scenario) {
  const activeReleaseIndex = scenarioState.get(scenario.id) ?? 0;

  return {
    activeRelease: scenario.releases[activeReleaseIndex].version,
    activeReleaseIndex,
    delivery: scenario.delivery,
    faults: { ...(scenarioFaultState.get(scenario.id) ?? createScenarioFaults()) },
    mode: scenario.mode,
    scenario: scenario.id,
  };
}

function getScenarioFromRequest(requestUrl, fallbackScenarioId = null) {
  const scenario = getScenarioFromQuery(requestUrl, fallbackScenarioId);

  if (!scenario) {
    return jsonResponse({ error: 'missing_scenario' }, { status: 400 });
  }

  return scenario;
}

async function readJsonPayload(request) {
  const rawBody = await request.text().catch(() => '');

  if (!rawBody) {
    return {};
  }

  try {
    return JSON.parse(rawBody);
  } catch {
    return {};
  }
}

function resetScenarioDebugState(scenarioId) {
  scenarioDebugState.set(scenarioId, createScenarioDebugState());
}

function releaseStalledDownloads(scenarioId) {
  const releasers = stalledDownloadReleasers.get(scenarioId);

  if (!releasers) {
    return;
  }

  for (const release of releasers) {
    release();
  }
  releasers.clear();
}

function setScenarioFault(scenarioId, target, mode) {
  const faults = scenarioFaultState.get(scenarioId) ?? createScenarioFaults();
  faults[target] = mode;
  scenarioFaultState.set(scenarioId, faults);

  // A stalled download only ends when the client disconnects or the stall is lifted; lifting
  // it drops the held connection so the next attempt starts against the new fault mode.
  if (target === 'bundle' && mode !== 'stall') {
    releaseStalledDownloads(scenarioId);
  }
}

function getScenarioFault(scenarioId, target) {
  return scenarioFaultState.get(scenarioId)?.[target] ?? 'none';
}

function rememberRequest(scenarioId, kind, requestUrl, payload) {
  const debugState = scenarioDebugState.get(scenarioId);

  if (!debugState) {
    return;
  }

  const normalizedPayload = payload ?? {};
  const now = new Date().toISOString();

  if (kind === 'update') {
    debugState.lastUpdateRequest = {
      payload: normalizedPayload,
      recordedAt: now,
      url: `${requestUrl.pathname}${requestUrl.search}`,
    };
  } else if (kind === 'channel') {
    debugState.lastChannelRequest = {
      payload: normalizedPayload,
      recordedAt: now,
      url: `${requestUrl.pathname}${requestUrl.search}`,
    };
  } else if (kind === 'stats') {
    debugState.lastStatsRequest = {
      payload: normalizedPayload,
      recordedAt: now,
      url: `${requestUrl.pathname}${requestUrl.search}`,
    };
    // The native stats queue flushes batches as a JSON array of events.
    const events = Array.isArray(normalizedPayload) ? normalizedPayload : [normalizedPayload];
    for (const event of events) {
      if (event?.action) {
        const action = String(event.action);
        debugState.statsActionCounts[action] = (debugState.statsActionCounts[action] ?? 0) + 1;
        debugState.statsActions.push(action);
      }
    }
    debugState.statsActions = debugState.statsActions.slice(-12);
  }

  debugState.requestCounts[kind] = (debugState.requestCounts[kind] ?? 0) + 1;
}

function getScenarioForReleaseVersion(version) {
  return Object.values(scenarios).find((scenario) =>
    scenario.releases.some((release) => release.version === version),
  );
}

function rememberManifestFileRequest(version, requestUrl, method) {
  const scenario = getScenarioForReleaseVersion(version);

  if (!scenario) {
    return;
  }

  const debugState = scenarioDebugState.get(scenario.id);

  if (!debugState) {
    return;
  }

  debugState.requestCounts.manifestFile = (debugState.requestCounts.manifestFile ?? 0) + 1;
  debugState.manifestFiles.push({
    method,
    path: requestUrl.pathname,
    recordedAt: new Date().toISOString(),
    version,
  });
  debugState.manifestFiles = debugState.manifestFiles.slice(-24);
}

function updateScenarioState(scenario, action) {
  const currentIndex = scenarioState.get(scenario.id) ?? 0;

  if (action === 'reset') {
    scenarioState.set(scenario.id, 0);
    setScenarioFault(scenario.id, 'bundle', 'none');
    setScenarioFault(scenario.id, 'update', 'none');
    resetScenarioDebugState(scenario.id);
    return true;
  }

  if (action === 'advance') {
    scenarioState.set(scenario.id, Math.min(currentIndex + 1, scenario.releases.length - 1));
    return true;
  }

  return false;
}

function handleControl(requestUrl, action) {
  const scenario = getScenarioFromRequest(requestUrl);

  if (scenario instanceof Response) {
    return scenario;
  }

  if (!updateScenarioState(scenario, action)) {
    return jsonResponse({ error: 'unknown_action' }, { status: 400 });
  }

  return jsonResponse(getScenarioStatePayload(scenario));
}

function handleControlFault(requestUrl) {
  const scenario = getScenarioFromRequest(requestUrl);

  if (scenario instanceof Response) {
    return scenario;
  }

  const target = requestUrl.searchParams.get('target') ?? '';
  const mode = requestUrl.searchParams.get('mode') ?? '';

  if (!faultModes[target]?.has(mode)) {
    return jsonResponse({ error: 'unknown_fault', target, mode }, { status: 400 });
  }

  setScenarioFault(scenario.id, target, mode);
  console.log(`[fake-capgo] scenario=${scenario.id} fault ${target}=${mode}`);
  return jsonResponse(getScenarioStatePayload(scenario));
}

function handleControlState(requestUrl) {
  const scenario = getScenarioFromRequest(requestUrl);

  if (scenario instanceof Response) {
    return scenario;
  }

  const debugState = scenarioDebugState.get(scenario.id) ?? createScenarioDebugState();

  return jsonResponse({
    ...getScenarioStatePayload(scenario),
    debug: debugState,
  });
}

function getActiveReleaseForScenario(scenario) {
  const activeIndex = scenarioState.get(scenario.id) ?? 0;
  return scenario.releases[activeIndex];
}

function shouldReportNoNewVersion(scenario, currentVersion) {
  const activeIndex = scenarioState.get(scenario.id) ?? 0;
  const currentIndex = scenario.releases.findIndex((release) => release.version === currentVersion);
  return currentIndex >= activeIndex && currentIndex >= 0;
}

function encodeFilePath(relativePath) {
  return relativePath
    .split('/')
    .map((segment) => encodeURIComponent(segment))
    .join('/');
}

async function loadBundleChecksum(version) {
  const checksumPath = getBundleChecksumPath(version);

  if (!existsSync(checksumPath)) {
    return null;
  }

  const checksum = (await Bun.file(checksumPath).text()).trim();
  return checksum.length > 0 ? checksum : null;
}

async function loadManifestEntries(version) {
  const metadataPath = getManifestMetadataPath(version);

  if (!existsSync(metadataPath)) {
    return null;
  }

  const manifestData = await Bun.file(metadataPath).json();
  const files = Array.isArray(manifestData.files) ? manifestData.files : [];

  return files.map((entry) => ({
    ...entry,
    download_url: `${defaultDeviceBaseUrl}/manifest/${version}/${encodeFilePath(entry.file_name)}`,
  }));
}

async function handleUpdate(request, scenarioId) {
  const requestUrl = new URL(request.url);
  logRequest(requestUrl, request.method, `scenario=${scenarioId}`);

  const scenario = findScenario(scenarioId);

  if (!scenario) {
    return jsonResponse({ error: 'unknown_scenario' }, { status: 404 });
  }

  const payload = await readJsonPayload(request);
  const currentVersion = payload.version_name ?? 'builtin';
  const activeRelease = getActiveReleaseForScenario(scenario);
  rememberRequest(scenario.id, 'update', requestUrl, payload);

  const updateFault = getScenarioFault(scenario.id, 'update');

  if (updateFault !== 'none') {
    const debugState = scenarioDebugState.get(scenario.id);
    if (debugState) {
      debugState.updateFaults += 1;
    }
    console.log(`[fake-capgo] scenario=${scenario.id} injecting update fault=${updateFault}`);

    if (updateFault === 'http-500') {
      return jsonResponse({ error: 'fake_server_error', message: 'Injected update failure' }, { status: 500 });
    }

    return createDroppedResponse(new TextEncoder().encode(JSON.stringify({ version: activeRelease.version })), {
      contentType: 'application/json',
    });
  }

  if (shouldReportNoNewVersion(scenario, currentVersion)) {
    return jsonResponse({
      error: 'no_new_version_available',
      message: 'No new version available',
    });
  }

  console.log(`[fake-capgo] scenario=${scenario.id} current=${currentVersion} active=${activeRelease.version}`);

  if (scenario.delivery === 'manifest') {
    const manifestEntries = await loadManifestEntries(activeRelease.version);

    if (!manifestEntries) {
      return jsonResponse(
        {
          error: 'missing_manifest',
          message: `Manifest fixture not found for ${activeRelease.version}`,
        },
        { status: 500 },
      );
    }

    return jsonResponse({
      manifest: manifestEntries,
      url: `${defaultDeviceBaseUrl}/bundles/${activeRelease.version}.zip`,
      version: activeRelease.version,
    });
  }

  const zipPath = getBundleZipPath(activeRelease.version);
  const checksum = await loadBundleChecksum(activeRelease.version);

  if (!existsSync(zipPath)) {
    return jsonResponse(
      {
        error: 'missing_bundle',
        message: `Bundle fixture not found for ${activeRelease.version}`,
      },
      { status: 500 },
    );
  }

  if (!checksum) {
    return jsonResponse(
      {
        error: 'missing_checksum',
        message: `Checksum fixture not found for ${activeRelease.version}`,
      },
      { status: 500 },
    );
  }

  return jsonResponse({
    checksum,
    url: `${defaultDeviceBaseUrl}/bundles/${activeRelease.version}.zip`,
    version: activeRelease.version,
  });
}

// Marks a response that must die midway. Bun.serve cannot guarantee that (some versions drop
// Content-Length and end a failed stream as a clean chunked body), so the node:http layer below
// writes these itself: full Content-Length, roughly half the body, then a destroyed socket.
class InterruptedResponse {
  constructor(bytes, { contentType, stall = false, onDisconnect = () => {}, onDropped = () => {}, onRelease = null }) {
    this.bytes = bytes;
    this.contentType = contentType;
    this.stall = stall;
    this.onDisconnect = onDisconnect;
    this.onDropped = onDropped;
    this.onRelease = onRelease;
  }
}

function createDroppedResponse(bytes, options) {
  return new InterruptedResponse(bytes, options);
}

function writeInterruptedResponse(connection, res, interrupted) {
  const { bytes, contentType, stall, onDisconnect, onDropped, onRelease } = interrupted;
  const cutoff = Math.max(1, Math.floor(bytes.length / 2));
  let finished = false;

  const markDisconnected = () => {
    if (!finished) {
      finished = true;
      onDisconnect();
    }
  };

  const { socket } = connection;
  res.on('close', markDisconnected);
  connection.onGone(markDisconnected);

  let trickleTimer = null;
  const drop = () => {
    clearInterval(trickleTimer);
    if (finished) {
      return;
    }
    finished = true;
    onDropped();
    socket?.destroy();
  };

  res.writeHead(200, {
    ...baseHeaders,
    'content-length': String(bytes.length),
    'content-type': contentType,
  });
  res.write(Buffer.from(bytes.subarray(0, cutoff)));

  if (stall) {
    onRelease?.(drop);
    // Trickle one byte at a time like a very slow network. The writes also surface a client that
    // vanished (app killed), which an idle socket does not report on every Bun release.
    let offset = cutoff;
    trickleTimer = setInterval(() => {
      if (finished || offset >= bytes.length - 1) {
        clearInterval(trickleTimer);
        return;
      }
      res.write(Buffer.from(bytes.subarray(offset, offset + 1)), (error) => {
        if (error) {
          clearInterval(trickleTimer);
          markDisconnected();
        }
      });
      offset += 1;
    }, 500);
  } else {
    // Let the partial body reach the device before the reset: adb reverse relays through a
    // buffer, and resetting too early discards bytes still in flight on slow CI emulators.
    setTimeout(drop, 2000);
  }
}

function parseRangeStart(rangeHeader, size) {
  const match = /^bytes=(\d+)-$/.exec(rangeHeader?.trim() ?? '');

  if (!match) {
    return null;
  }

  const start = Number.parseInt(match[1], 10);
  return start > 0 && start < size ? start : null;
}

// Honours open-ended Range requests so clients that resume a dropped download (Android's
// WorkManager worker does) exercise their 206 append path against real partial content.
async function serveBundle(request, version, zipPath, debugState) {
  const file = Bun.file(zipPath);
  const rangeStart = parseRangeStart(request.headers.get('range'), file.size);

  if (rangeStart === null) {
    console.log(`[fake-capgo] bundle=${version} served`);
    return fileResponse(file, {
      headers: {
        'content-type': 'application/zip',
      },
    });
  }

  if (debugState) {
    debugState.bundleDownloads.ranged += 1;
  }
  console.log(`[fake-capgo] bundle=${version} served from byte ${rangeStart}`);
  // Slice the bytes directly: Blob.slice responses serve the whole file on older Bun releases.
  const bytes = new Uint8Array(await file.arrayBuffer()).subarray(rangeStart);
  return fileResponse(bytes, {
    status: 206,
    headers: {
      'content-range': `bytes ${rangeStart}-${file.size - 1}/${file.size}`,
      'content-type': 'application/zip',
    },
  });
}

async function handleBundle(request, method, version) {
  console.log(`[fake-capgo] ${method} /bundles/${version}.zip`);

  const zipPath = getBundleZipPath(version);

  if (!existsSync(zipPath)) {
    return new Response('bundle not found', { status: 404, headers: baseHeaders });
  }

  const scenario = getScenarioForReleaseVersion(version);
  const debugState = scenario ? scenarioDebugState.get(scenario.id) : null;
  const bundleFault = scenario ? getScenarioFault(scenario.id, 'bundle') : 'none';

  if (method === 'HEAD') {
    return fileResponse(null, {
      headers: {
        'content-type': 'application/zip',
      },
    });
  }

  if (debugState) {
    debugState.bundleDownloads.started += 1;
    debugState.lastBundleRequest = {
      fault: bundleFault,
      range: request.headers.get('range'),
      recordedAt: new Date().toISOString(),
      version,
    };
  }

  if (bundleFault === 'none' || !debugState) {
    if (debugState) {
      debugState.bundleDownloads.served += 1;
    }
    return serveBundle(request, version, zipPath, debugState);
  }

  debugState.bundleDownloads.faulted += 1;
  console.log(`[fake-capgo] bundle=${version} injecting fault=${bundleFault}`);

  if (bundleFault === 'http-500') {
    return new Response('injected bundle failure', { status: 500, headers: baseHeaders });
  }

  const bytes = new Uint8Array(await Bun.file(zipPath).arrayBuffer());

  if (bundleFault === 'corrupt') {
    // Same length as the real archive, so only the checksum gate can catch it.
    const corrupted = bytes.slice();
    const start = Math.floor(corrupted.length / 3);
    const end = Math.min(corrupted.length, start + 4096);
    for (let index = start; index < end; index += 1) {
      corrupted[index] ^= 0xff;
    }
    return fileResponse(corrupted, {
      headers: {
        'content-type': 'application/zip',
      },
    });
  }

  const releasers = stalledDownloadReleasers.get(scenario.id);
  debugState.bundleDownloads.inFlight += 1;
  let settled = false;
  const settle = () => {
    if (!settled) {
      settled = true;
      debugState.bundleDownloads.inFlight = Math.max(0, debugState.bundleDownloads.inFlight - 1);
    }
  };

  return createDroppedResponse(bytes, {
    contentType: 'application/zip',
    stall: bundleFault === 'stall',
    onDisconnect: () => {
      debugState.bundleDownloads.aborted += 1;
      console.log(`[fake-capgo] bundle=${version} client disconnected mid-download`);
      settle();
    },
    onDropped: () => {
      debugState.bundleDownloads.dropped += 1;
      console.log(`[fake-capgo] bundle=${version} connection dropped mid-download`);
      settle();
    },
    onRelease: (release) => {
      releasers?.add(() => {
        settle();
        release();
      });
    },
  });
}

function getSafeManifestFilePath(version, relativePath) {
  const manifestRoot = getManifestDirectoryPath(version);
  const absolutePath = path.resolve(manifestRoot, relativePath);
  const normalizedRoot = `${path.resolve(manifestRoot)}${path.sep}`;

  if (!absolutePath.startsWith(normalizedRoot) && absolutePath !== path.resolve(manifestRoot)) {
    return null;
  }

  return absolutePath;
}

function decodeManifestFilePath(pathname, version) {
  const prefix = `/manifest/${version}/`;
  const encodedPath = pathname.slice(prefix.length);

  return encodedPath
    .split('/')
    .map((segment) => decodeURIComponent(segment))
    .join('/');
}

function handleManifestFile(requestUrl, method, version) {
  const relativePath = decodeManifestFilePath(requestUrl.pathname, version);
  const absolutePath = getSafeManifestFilePath(version, relativePath);

  if (!absolutePath || !existsSync(absolutePath)) {
    logRequest(requestUrl, method, `manifest=${version} missing`);
    return new Response('manifest file not found', { status: 404, headers: baseHeaders });
  }

  logRequest(requestUrl, method, `manifest=${version} file=${relativePath}`);
  rememberManifestFileRequest(version, requestUrl, method);

  if (method === 'HEAD') {
    return fileResponse(null, {
      headers: {
        'content-type': 'application/octet-stream',
      },
    });
  }

  return fileResponse(Bun.file(absolutePath), {
    headers: {
      'content-type': 'application/octet-stream',
    },
  });
}

async function handleStats(request, requestUrl) {
  const scenario = getScenarioFromRequest(requestUrl);

  if (scenario instanceof Response) {
    return scenario;
  }

  const payload = await readJsonPayload(request);
  const actions = (Array.isArray(payload) ? payload : [payload]).map((event) => event?.action ?? 'unknown');
  logRequest(requestUrl, request.method, `scenario=${scenario.id} action=${actions.join(',')}`);
  rememberRequest(scenario.id, 'stats', requestUrl, payload);
  return jsonResponse({ status: 'ok' });
}

function createChannelResponse(defaultChannel) {
  if (!defaultChannel) {
    return {
      allowSet: true,
      channel: '',
      message: 'No channel override',
      status: 'unset',
    };
  }

  const channel = channelCatalog.find((entry) => entry.name === defaultChannel);

  return {
    allowSet: channel?.allow_self_set ?? true,
    channel: defaultChannel,
    message: `Using channel ${defaultChannel}`,
    status: 'ok',
  };
}

async function handleChannel(request, requestUrl, method) {
  const scenario = getScenarioFromRequest(requestUrl);

  if (scenario instanceof Response) {
    return scenario;
  }

  if (method === 'GET') {
    const queryPayload = Object.fromEntries(requestUrl.searchParams.entries());
    rememberRequest(scenario.id, 'channel', requestUrl, queryPayload);
    logRequest(requestUrl, method, `scenario=${scenario.id} list`);
    return jsonResponse(channelCatalog.filter((channel) => channel.allow_self_set));
  }

  const payload = await readJsonPayload(request);
  rememberRequest(scenario.id, 'channel', requestUrl, payload);

  if (method === 'PUT') {
    logRequest(
      requestUrl,
      method,
      `scenario=${scenario.id} default=${payload.defaultChannel ?? ''} app_id=${payload.app_id ?? ''} custom_id=${payload.custom_id ?? ''}`,
    );
    return jsonResponse(createChannelResponse(payload.defaultChannel ?? ''));
  }

  if (method === 'POST') {
    logRequest(
      requestUrl,
      method,
      `scenario=${scenario.id} channel=${payload.channel ?? ''} app_id=${payload.app_id ?? ''} custom_id=${payload.custom_id ?? ''}`,
    );

    if (payload.channel === 'private-alpha') {
      return jsonResponse({
        error: 'channel_self_set_not_allowed',
        message: 'Channel private-alpha does not allow self assignment',
      });
    }

    return jsonResponse({
      message: `Channel ${payload.channel} assigned`,
      status: 'ok',
    });
  }

  return null;
}

async function handleExactRoute(request, requestUrl, method, pathname) {
  if (method === 'OPTIONS') {
    return new Response(null, {
      headers: baseHeaders,
      status: 204,
    });
  }

  const routeKey = `${method} ${pathname}`;
  const exactHandlers = {
    'GET /health': async () => {
      logRequest(requestUrl, method);
      return jsonResponse({ status: 'ok' });
    },
    'GET /api/control/reset': async () => {
      logRequest(requestUrl, method);
      return handleControl(requestUrl, 'reset');
    },
    'POST /api/control/reset': async () => {
      logRequest(requestUrl, method);
      return handleControl(requestUrl, 'reset');
    },
    'GET /api/control/advance': async () => {
      logRequest(requestUrl, method);
      return handleControl(requestUrl, 'advance');
    },
    'POST /api/control/advance': async () => {
      logRequest(requestUrl, method);
      return handleControl(requestUrl, 'advance');
    },
    'GET /api/control/fault': async () => {
      logRequest(requestUrl, method);
      return handleControlFault(requestUrl);
    },
    'POST /api/control/fault': async () => {
      logRequest(requestUrl, method);
      return handleControlFault(requestUrl);
    },
    'GET /api/control/state': async () => {
      logRequest(requestUrl, method);
      return handleControlState(requestUrl);
    },
    'POST /api/stats': async () => handleStats(request, requestUrl),
    'GET /api/channel': async () => handleChannel(request, requestUrl, method),
    'POST /api/channel': async () => handleChannel(request, requestUrl, method),
    'PUT /api/channel': async () => handleChannel(request, requestUrl, method),
  };

  const handler = exactHandlers[routeKey];
  return handler ? handler() : null;
}

async function handleRequest(request) {
  const requestUrl = new URL(request.url);
  const { method } = request;
  const { pathname } = requestUrl;
  const exactRouteResponse = await handleExactRoute(request, requestUrl, method, pathname);

  if (exactRouteResponse) {
    return exactRouteResponse;
  }

  if (pathname.startsWith('/api/updates/') && method === 'POST') {
    const scenarioId = pathname.replace('/api/updates/', '');
    return handleUpdate(request, scenarioId);
  }

  if (pathname.startsWith('/bundles/') && (method === 'GET' || method === 'HEAD')) {
    const version = pathname.replace('/bundles/', '').replace(/\.zip$/, '');
    return handleBundle(request, method, version);
  }

  if (pathname.startsWith('/manifest/') && (method === 'GET' || method === 'HEAD')) {
    const [, , version] = pathname.split('/');
    return handleManifestFile(requestUrl, method, version);
  }

  return new Response('not found', { headers: baseHeaders, status: 404 });
}

function toRequestHeaders(incomingHeaders) {
  const headers = new Headers();
  for (const [key, value] of Object.entries(incomingHeaders)) {
    if (Array.isArray(value)) {
      value.forEach((entry) => headers.append(key, entry));
    } else if (value !== undefined) {
      headers.set(key, value);
    }
  }
  return headers;
}

async function writeResponse(res, response) {
  const body = response.body ? Buffer.from(await response.arrayBuffer()) : null;
  res.writeHead(response.status, Object.fromEntries(response.headers.entries()));
  res.end(body ?? undefined);
}

// Older Bun releases only report a vanished client to listeners attached before the request body
// is read, so track that from the very start of each request.
function trackConnection(req) {
  const listeners = new Set();
  let gone = false;
  const markGone = () => {
    if (!gone) {
      gone = true;
      listeners.forEach((listener) => listener());
    }
  };

  req.on('aborted', markGone);
  req.socket?.on('close', markGone);
  req.socket?.on('error', markGone);

  return {
    socket: req.socket,
    onGone(listener) {
      if (gone) {
        listener();
        return;
      }
      listeners.add(listener);
    },
  };
}

const server = http.createServer(async (req, res) => {
  const connection = trackConnection(req);

  try {
    const chunks = [];
    const acceptsBody = req.method !== 'GET' && req.method !== 'HEAD';
    // Draining a body also stops older Bun releases from reporting client disconnects, so only
    // read it when the method carries one (bundle downloads are GETs).
    if (acceptsBody) {
      for await (const chunk of req) {
        chunks.push(chunk);
      }
    }

    const hasBody = acceptsBody && chunks.length > 0;
    const request = new Request(new URL(req.url ?? '/', 'http://127.0.0.1'), {
      method: req.method,
      headers: toRequestHeaders(req.headers),
      body: hasBody ? Buffer.concat(chunks) : undefined,
    });
    const response = await handleRequest(request);

    if (response instanceof InterruptedResponse) {
      writeInterruptedResponse(connection, res, response);
      return;
    }

    await writeResponse(res, response);
  } catch (error) {
    console.error('[fake-capgo] request failed', error);
    if (!res.headersSent) {
      res.writeHead(500, baseHeaders);
    }
    res.end();
  }
});

await new Promise((resolve) => server.listen(defaultPort, '0.0.0.0', resolve));

const defaultPortSuffix = `:${defaultPort}`;
const listeningUrl = defaultHostBaseUrl.endsWith(defaultPortSuffix)
  ? `${defaultHostBaseUrl.slice(0, -defaultPortSuffix.length)}:${server.address().port}`
  : defaultHostBaseUrl;

console.log(`[fake-capgo] listening on ${listeningUrl}`);
