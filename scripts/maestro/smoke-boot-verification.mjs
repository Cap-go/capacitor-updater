import process from 'node:process';

const state = JSON.parse(process.argv[2]);
const scenarioId = process.argv[3];
const beforeChannelCount = Number(process.argv[4]);
const defaultAppId = process.argv[5];
const runtimeAppId = `${defaultAppId}.e2e`;

const debug = state.debug ?? {};
const channel = debug.lastChannelRequest ?? {};
const channelPayload = channel.payload ?? {};
const channelCount = debug.requestCounts?.channel ?? 0;
const channelUrl = channel.url ?? '';
const channelAppId = channelPayload.app_id ?? '';
const channelCustomId = channelPayload.custom_id ?? '';

let ok = channelCount > beforeChannelCount;

if (scenarioId === 'manual-zip') {
  ok =
    ok &&
    channelUrl.includes('/api/channel?scenario=manual-zip&source=runtime-channel') &&
    channelAppId === defaultAppId &&
    channelAppId !== runtimeAppId &&
    channelCustomId === 'qa-user-42';
} else if (scenarioId === 'manual-zip-config-guards') {
  ok =
    ok &&
    channelUrl.includes('/api/channel?scenario=manual-zip-config-guards') &&
    channelAppId === defaultAppId &&
    channelAppId !== runtimeAppId &&
    !channelUrl.includes('source=runtime-channel') &&
    channelCustomId === 'qa-user-42';
} else if (scenarioId === 'manual-zip-no-persist') {
  ok =
    ok &&
    channelUrl.includes('/api/channel?scenario=manual-zip-no-persist') &&
    channelAppId === defaultAppId &&
    channelAppId !== runtimeAppId &&
    !channelUrl.includes('source=runtime-channel') &&
    channelCustomId !== 'qa-user-42';
}

process.exit(ok ? 0 : 1);
