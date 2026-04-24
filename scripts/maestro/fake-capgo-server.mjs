import { existsSync } from 'node:fs';
import path from 'node:path';
import {
  defaultDeviceBaseUrl,
  defaultHostBaseUrl,
  defaultPort,
  findScenario,
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
    id: 'beta',
    name: 'beta',
    public: false,
    allow_self_set: true,
  },
  {
    id: 'public-preview',
    name: 'public-preview',
    public: true,
    allow_self_set: true,
  },
  {
    id: 'private-alpha',
    name: 'private-alpha',
    public: false,
    allow_self_set: false,
  },
];

function createScenarioDebugState() {
  return {
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
    statsActions: [],
  };
}

const scenarioState = new Map(Object.keys(scenarios).map((scenarioId) => [scenarioId, 0]));
const scenarioDebugState = new Map(Object.keys(scenarios).map((scenarioId) => [scenarioId, createScenarioDebugState()]));

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
    if (normalizedPayload.action) {
      debugState.statsActions.push(String(normalizedPayload.action));
      debugState.statsActions = debugState.statsActions.slice(-12);
    }
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

  if (!existsSync(zipPath)) {
    return jsonResponse(
      {
        error: 'missing_bundle',
        message: `Bundle fixture not found for ${activeRelease.version}`,
      },
      { status: 500 },
    );
  }

  return jsonResponse({
    url: `${defaultDeviceBaseUrl}/bundles/${activeRelease.version}.zip`,
    version: activeRelease.version,
  });
}

function handleBundle(method, version) {
  console.log(`[fake-capgo] ${method} /bundles/${version}.zip`);

  const zipPath = getBundleZipPath(version);

  if (!existsSync(zipPath)) {
    return new Response('bundle not found', { status: 404, headers: baseHeaders });
  }

  if (method === 'HEAD') {
    return fileResponse(null, {
      headers: {
        'content-type': 'application/zip',
      },
    });
  }

  return fileResponse(Bun.file(zipPath), {
    headers: {
      'content-type': 'application/zip',
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
  logRequest(requestUrl, request.method, `scenario=${scenario.id} action=${payload.action ?? 'unknown'}`);
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
    logRequest(requestUrl, method, `scenario=${scenario.id} default=${payload.defaultChannel ?? ''}`);
    return jsonResponse(createChannelResponse(payload.defaultChannel ?? ''));
  }

  if (method === 'POST') {
    logRequest(requestUrl, method, `scenario=${scenario.id} channel=${payload.channel ?? ''}`);

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
    return handleBundle(method, version);
  }

  if (pathname.startsWith('/manifest/') && (method === 'GET' || method === 'HEAD')) {
    const [, , version] = pathname.split('/');
    return handleManifestFile(requestUrl, method, version);
  }

  return new Response('not found', { headers: baseHeaders, status: 404 });
}

const server = Bun.serve({
  hostname: '0.0.0.0',
  port: defaultPort,
  fetch: handleRequest,
});

const defaultPortSuffix = `:${defaultPort}`;
const listeningUrl = defaultHostBaseUrl.endsWith(defaultPortSuffix)
  ? `${defaultHostBaseUrl.slice(0, -defaultPortSuffix.length)}:${server.port}`
  : defaultHostBaseUrl;

console.log(`[fake-capgo] listening on ${listeningUrl}`);
