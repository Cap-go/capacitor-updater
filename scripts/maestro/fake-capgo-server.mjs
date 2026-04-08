import { existsSync } from 'node:fs';
import {
  defaultDeviceBaseUrl,
  defaultHostBaseUrl,
  defaultPort,
  getBundleZipPath,
  getScenario,
  scenarios,
} from './scenarios.mjs';

const scenarioState = new Map(Object.keys(scenarios).map((scenarioId) => [scenarioId, 0]));

function jsonResponse(payload, init = {}) {
  return Response.json(payload, {
    headers: {
      'cache-control': 'no-store',
    },
    ...init,
  });
}

function getScenarioId(requestUrl) {
  return requestUrl.searchParams.get('scenario');
}

function getScenarioFromQuery(requestUrl) {
  const scenarioId = getScenarioId(requestUrl);

  if (!scenarioId) {
    return null;
  }

  return getScenario(scenarioId);
}

function getScenarioStatePayload(scenario) {
  const activeReleaseIndex = scenarioState.get(scenario.id) ?? 0;

  return {
    scenario: scenario.id,
    activeRelease: scenario.releases[activeReleaseIndex].version,
    activeReleaseIndex,
  };
}

function getScenarioFromRequest(requestUrl) {
  const scenario = getScenarioFromQuery(requestUrl);

  if (!scenario) {
    return jsonResponse({ error: 'missing_scenario' }, { status: 400 });
  }

  return scenario;
}

function getReleaseForScenario(scenario, currentVersion) {
  const activeIndex = scenarioState.get(scenario.id) ?? 0;
  const activeRelease = scenario.releases[activeIndex];
  const currentIndex = scenario.releases.findIndex((release) => release.version === currentVersion);

  if (currentIndex >= activeIndex && currentIndex >= 0) {
    return scenario.releases[currentIndex];
  }

  return activeRelease;
}

function updateScenarioState(scenario, action) {
  const currentIndex = scenarioState.get(scenario.id) ?? 0;

  if (action === 'reset') {
    scenarioState.set(scenario.id, 0);
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

  return jsonResponse(getScenarioStatePayload(scenario));
}

async function handleUpdate(request, scenarioId) {
  const scenario = getScenario(scenarioId);
  const payload = await request.json().catch(() => ({}));
  const currentVersion = payload.version_name ?? 'builtin';
  const selectedRelease = getReleaseForScenario(scenario, currentVersion);
  const zipPath = getBundleZipPath(selectedRelease.version);

  if (!existsSync(zipPath)) {
    return jsonResponse(
      {
        error: 'missing_bundle',
        message: `Bundle fixture not found for ${selectedRelease.version}`,
      },
      { status: 500 },
    );
  }

  console.log(
    `[fake-capgo] scenario=${scenario.id} current=${currentVersion} active=${selectedRelease.version} device=${payload.device_id ?? 'unknown'}`,
  );

  return jsonResponse({
    version: selectedRelease.version,
    url: `${defaultDeviceBaseUrl}/bundles/${selectedRelease.version}.zip`,
  });
}

function handleBundle(version) {
  const zipPath = getBundleZipPath(version);

  if (!existsSync(zipPath)) {
    return new Response('bundle not found', { status: 404 });
  }

  return new Response(Bun.file(zipPath), {
    headers: {
      'content-type': 'application/zip',
      'cache-control': 'no-store',
    },
  });
}

function handleExactRoute(requestUrl, method, pathname) {
  const exactHandlers = {
    'GET /health': () => jsonResponse({ status: 'ok' }),
    'POST /api/control/reset': () => handleControl(requestUrl, 'reset'),
    'POST /api/control/advance': () => handleControl(requestUrl, 'advance'),
    'GET /api/control/state': () => handleControlState(requestUrl),
    'POST /api/stats': () => jsonResponse({ status: 'ok' }),
    'POST /api/channel': () => jsonResponse({ status: 'ok' }),
  };

  const handler = exactHandlers[`${method} ${pathname}`];
  return handler ? handler() : null;
}

async function handleRequest(request) {
  const requestUrl = new URL(request.url);
  const { method } = request;
  const { pathname } = requestUrl;
  const exactRouteResponse = handleExactRoute(requestUrl, method, pathname);

  if (exactRouteResponse) {
    return exactRouteResponse;
  }

  if (pathname.startsWith('/api/updates/') && method === 'POST') {
    const scenarioId = pathname.replace('/api/updates/', '');
    return handleUpdate(request, scenarioId);
  }

  if (pathname.startsWith('/bundles/') && (method === 'GET' || method === 'HEAD')) {
    const version = pathname.replace('/bundles/', '').replace(/\.zip$/, '');
    return handleBundle(version);
  }

  return new Response('not found', { status: 404 });
}

const server = Bun.serve({
  port: defaultPort,
  fetch: handleRequest,
});

const defaultPortSuffix = `:${defaultPort}`;
const listeningUrl = defaultHostBaseUrl.endsWith(defaultPortSuffix)
  ? `${defaultHostBaseUrl.slice(0, -defaultPortSuffix.length)}:${server.port}`
  : defaultHostBaseUrl;

console.log(`[fake-capgo] listening on ${listeningUrl}`);
