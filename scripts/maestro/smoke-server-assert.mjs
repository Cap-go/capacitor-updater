import process from 'node:process';

const state = JSON.parse(process.argv[2]);
const scenarioId = process.argv[3];
const failures = [];
const debug = state.debug ?? {};
const update = debug.lastUpdateRequest ?? {};
const channel = debug.lastChannelRequest ?? {};
const updatePayload = update.payload ?? {};
const channelPayload = channel.payload ?? {};
const requestCounts = debug.requestCounts ?? {};
const defaultAppId = 'app.capgo.updater';
const runtimeAppId = `${defaultAppId}.e2e`;

function expect(condition, message) {
  if (!condition) {
    failures.push(message);
  }
}

switch (scenarioId) {
  case 'manual-zip':
    expect(channel.url?.includes('/api/channel?scenario=manual-zip&source=runtime-channel'), 'missing persisted runtime channel URL request');
    expect(channelPayload.app_id === defaultAppId, 'runtime app ID unexpectedly persisted across relaunch');
    expect(channelPayload.app_id !== runtimeAppId, 'channel request still used runtime app ID after relaunch');
    expect((updatePayload.custom_id ?? channelPayload.custom_id) === 'qa-user-42', 'missing persisted custom ID');
    expect((requestCounts.channel ?? 0) >= 1, 'expected persisted channel verification to hit the fake server');
    expect((requestCounts.stats ?? 0) >= 1, 'expected stats traffic to hit the fake server');
    break;
  case 'manual-zip-no-persist':
    expect(channel.url?.includes('/api/channel?scenario=manual-zip-no-persist'), 'missing default channel URL request after relaunch');
    expect(!channel.url?.includes('source=runtime-channel'), 'channel URL unexpectedly stayed on the runtime override');
    expect(channelPayload.app_id === defaultAppId, 'runtime app ID unexpectedly persisted across relaunch');
    expect(channelPayload.app_id !== runtimeAppId, 'channel request still used runtime app ID after relaunch');
    expect((channelPayload.custom_id ?? '') !== 'qa-user-42', 'custom ID unexpectedly persisted across relaunch');
    expect((requestCounts.channel ?? 0) >= 2, 'expected repeated channel checks to hit the fake server');
    expect((requestCounts.stats ?? 0) >= 1, 'expected stats traffic to hit the fake server');
    break;
  case 'manual-zip-config-guards':
    expect(!update.url?.includes('source=runtime-update'), 'guarded config unexpectedly accepted a runtime update URL override');
    expect(channel.url?.includes('/api/channel?scenario=manual-zip-config-guards'), 'missing default channel URL request for guarded config');
    expect(!channel.url?.includes('source=runtime-channel'), 'guarded config unexpectedly accepted a runtime channel URL override');
    expect(channelPayload.app_id === defaultAppId, 'guarded config unexpectedly accepted the runtime app ID override');
    expect(channelPayload.app_id !== runtimeAppId, 'guarded config channel request still used runtime app ID override');
    expect((updatePayload.custom_id ?? channelPayload.custom_id) === 'qa-user-42', 'custom ID should still persist when only URL/App ID setters are guarded');
    expect((requestCounts.channel ?? 0) >= 1, 'expected guarded config channel checks to hit the fake server');
    expect((requestCounts.stats ?? 0) >= 1, 'expected stats traffic to hit the fake server');
    break;
  default:
    expect(update.url?.includes(`/api/updates/${scenarioId}`), 'missing update request');
    expect(channel.url?.includes(`/api/channel?scenario=${scenarioId}`), 'missing channel request');
    expect((requestCounts.channel ?? 0) >= 1, 'expected channel traffic to hit the fake server');
    expect((requestCounts.update ?? 0) >= 1, 'expected update traffic to hit the fake server');
    break;
}

if (failures.length) {
  console.error('Smoke server assertions failed:');
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}
