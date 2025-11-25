/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import { WebPlugin } from '@capacitor/core';

import type {
  AppReadyResult,
  AutoUpdateEnabled,
  BundleId,
  BundleInfo,
  BundleListResult,
  CapacitorUpdaterPlugin,
  ChannelRes,
  ChannelUrl,
  CurrentBundleResult,
  DelayCondition,
  DeviceId,
  DownloadOptions,
  GetChannelRes,
  LatestVersion,
  ListChannelsResult,
  MultiDelayConditions,
  PluginVersion,
  ResetOptions,
  SetChannelOptions,
  SetCustomIdOptions,
  StatsUrl,
  UnsetChannelOptions,
  UpdateUrl,
  BuiltinVersion,
  AutoUpdateAvailable,
  SetShakeMenuOptions,
  ShakeMenuEnabled,
  UpdateFailedEvent,
} from './definitions';

const BUNDLE_BUILTIN: BundleInfo = {
  status: 'success',
  version: '',
  downloaded: '1970-01-01T00:00:00.000Z',
  id: 'builtin',
  checksum: '',
};

export class CapacitorUpdaterWeb extends WebPlugin implements CapacitorUpdaterPlugin {
  async setStatsUrl(options: StatsUrl): Promise<void> {
    console.warn('Cannot setStatsUrl in web', options);
    return;
  }

  async setUpdateUrl(options: UpdateUrl): Promise<void> {
    console.warn('Cannot setUpdateUrl in web', options);
    return;
  }

  async setChannelUrl(options: ChannelUrl): Promise<void> {
    console.warn('Cannot setChannelUrl in web', options);
    return;
  }

  async download(options: DownloadOptions): Promise<BundleInfo> {
    console.warn('Cannot download version in web', options);
    return BUNDLE_BUILTIN;
  }

  async next(options: BundleId): Promise<BundleInfo> {
    console.warn('Cannot set next version in web', options);
    return BUNDLE_BUILTIN;
  }

  async isAutoUpdateEnabled(): Promise<AutoUpdateEnabled> {
    console.warn('Cannot get isAutoUpdateEnabled in web');
    return { enabled: false };
  }

  async set(options: BundleId): Promise<void> {
    console.warn('Cannot set active bundle in web', options);
    return;
  }

  async getDeviceId(): Promise<DeviceId> {
    console.warn('Cannot get ID in web');
    return { deviceId: 'default' };
  }

  async getBuiltinVersion(): Promise<BuiltinVersion> {
    console.warn('Cannot get version in web');
    return { version: 'default' };
  }

  async getPluginVersion(): Promise<PluginVersion> {
    console.warn('Cannot get plugin version in web');
    return { version: 'default' };
  }

  async delete(options: BundleId): Promise<void> {
    console.warn('Cannot delete bundle in web', options);
  }

  async setBundleError(options: BundleId): Promise<BundleInfo> {
    console.warn('Cannot setBundleError in web', options);
    return BUNDLE_BUILTIN;
  }

  async list(): Promise<BundleListResult> {
    console.warn('Cannot list bundles in web');
    return { bundles: [] };
  }

  async reset(options?: ResetOptions): Promise<void> {
    console.warn('Cannot reset version in web', options);
  }

  async current(): Promise<CurrentBundleResult> {
    console.warn('Cannot get current bundle in web');
    return { bundle: BUNDLE_BUILTIN, native: '0.0.0' };
  }

  async reload(): Promise<void> {
    console.warn('Cannot reload current bundle in web');
    return;
  }

  async getLatest(): Promise<LatestVersion> {
    console.warn('Cannot getLatest current bundle in web');
    return {
      version: '0.0.0',
      message: 'Cannot getLatest current bundle in web',
    };
  }

  async setChannel(options: SetChannelOptions): Promise<ChannelRes> {
    console.warn('Cannot setChannel in web', options);
    return {
      status: 'error',
      error: 'Cannot setChannel in web',
    };
  }

  async unsetChannel(options: UnsetChannelOptions): Promise<void> {
    console.warn('Cannot unsetChannel in web', options);
    return;
  }

  async setCustomId(options: SetCustomIdOptions): Promise<void> {
    console.warn('Cannot setCustomId in web', options);
    return;
  }

  async getChannel(): Promise<GetChannelRes> {
    console.warn('Cannot getChannel in web');
    return {
      status: 'error',
      error: 'Cannot getChannel in web',
    };
  }

  async listChannels(): Promise<ListChannelsResult> {
    console.warn('Cannot listChannels in web');
    throw {
      message: 'Cannot listChannels in web',
      error: 'platform_not_supported',
    };
  }

  async notifyAppReady(): Promise<AppReadyResult> {
    return { bundle: BUNDLE_BUILTIN };
  }

  async setMultiDelay(options: MultiDelayConditions): Promise<void> {
    console.warn('Cannot setMultiDelay in web', options?.delayConditions);
    return;
  }

  async setDelay(option: DelayCondition): Promise<void> {
    console.warn('Cannot setDelay in web', option);
    return;
  }

  async cancelDelay(): Promise<void> {
    console.warn('Cannot cancelDelay in web');
    return;
  }

  async isAutoUpdateAvailable(): Promise<AutoUpdateAvailable> {
    console.warn('Cannot isAutoUpdateAvailable in web');
    return { available: false };
  }

  async getCurrentBundle(): Promise<BundleInfo> {
    console.warn('Cannot get current bundle in web');
    return BUNDLE_BUILTIN;
  }

  async getNextBundle(): Promise<BundleInfo | null> {
    return Promise.resolve(null);
  }

  async getFailedUpdate(): Promise<UpdateFailedEvent | null> {
    console.warn('Cannot getFailedUpdate in web');
    return null;
  }

  async setShakeMenu(_options: SetShakeMenuOptions): Promise<void> {
    throw this.unimplemented('Shake menu not available on web platform');
  }

  async isShakeMenuEnabled(): Promise<ShakeMenuEnabled> {
    return Promise.resolve({ enabled: false });
  }

  async getAppId(): Promise<{ appId: string }> {
    console.warn('Cannot getAppId in web');
    return { appId: 'default' };
  }

  async setAppId(options: { appId: string }): Promise<void> {
    console.warn('Cannot setAppId in web', options);
    return;
  }
}
