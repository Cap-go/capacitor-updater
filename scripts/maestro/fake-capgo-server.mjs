import { existsSync } from 'node:fs';
import { defaultPort, defaultDeviceBaseUrl, getBundleZipPath, getScenario, scenarios } from './scenarios.mjs';

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

function getReleaseForScenario(scenario, currentVersion) {
  const activeIndex = scenarioState.get(scenario.id) ?? 0;
  const activeRelease = scenario.releases[activeIndex];
  const currentIndex = scenario.releases.findIndex((release) => release.version === currentVersion);

  if (currentIndex >= activeIndex && currentIndex >= 0) {
    return scenario.releases[currentIndex];
  }

  return activeRelease;
}

async function handleControl(requestUrl, action) {
  const scenario = getScenarioFromQuery(requestUrl);

  if (!scenario) {
    return jsonResponse({ error: 'missing_scenario' }, { status: 400 });
  }
  const currentIndex = scenarioState.get(scenario.id) ?? 0;

  if (action === 'reset') {
    scenarioState.set(scenario.id, 0);
  } else if (action === 'advance') {
    scenarioState.set(scenario.id, Math.min(currentIndex + 1, scenario.releases.length - 1));
  } else {
    return jsonResponse({ error: 'unknown_action' }, { status: 400 });
  }

  const nextIndex = scenarioState.get(scenario.id) ?? 0;
  return jsonResponse({
    scenario: scenario.id,
    activeRelease: scenario.releases[nextIndex].version,
    activeReleaseIndex: nextIndex,
  });
}

async function handleUpdate(request, requestUrl, scenarioId) {
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

async function handleBundle(version) {
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

const server = Bun.serve({
  port: defaultPort,
  async fetch(request) {
    const requestUrl = new URL(request.url);
    const pathname = requestUrl.pathname;

    if (pathname === '/health') {
      return jsonResponse({ status: 'ok' });
    }

    if (pathname === '/api/control/reset' && request.method === 'POST') {
      return handleControl(requestUrl, 'reset');
    }

    if (pathname === '/api/control/advance' && request.method === 'POST') {
      return handleControl(requestUrl, 'advance');
    }

    if (pathname === '/api/control/state' && request.method === 'GET') {
      const scenario = getScenarioFromQuery(requestUrl);

      if (!scenario) {
        return jsonResponse({ error: 'missing_scenario' }, { status: 400 });
      }

      const activeReleaseIndex = scenarioState.get(scenario.id) ?? 0;
      return jsonResponse({
        scenario: scenario.id,
        activeRelease: scenario.releases[activeReleaseIndex].version,
        activeReleaseIndex,
      });
    }

    if (pathname.startsWith('/api/updates/') && request.method === 'POST') {
      const scenarioId = pathname.replace('/api/updates/', '');
      return handleUpdate(request, requestUrl, scenarioId);
    }

    if (pathname === '/api/stats' && request.method === 'POST') {
      return jsonResponse({ status: 'ok' });
    }

    if (pathname === '/api/channel' && request.method === 'POST') {
      return jsonResponse({ status: 'ok' });
    }

    if (pathname.startsWith('/bundles/') && (request.method === 'GET' || request.method === 'HEAD')) {
      const version = pathname.replace('/bundles/', '').replace(/\.zip$/, '');
      return handleBundle(version);
    }

    return new Response('not found', { status: 404 });
  },
});

console.log(`[fake-capgo] listening on http://127.0.0.1:${server.port}`);
