import { WebPlugin } from '@capacitor/core';

import type { CapacitorUpdaterPlugin, BundleInfo } from './definitions';

const VERSION_BUILTIN: BundleInfo = { status: 'success', version: '', downloaded: '1970-01-01T00:00:00.000Z', id: 'builtin' };

export class CapacitorUpdaterWeb
  extends WebPlugin
  implements CapacitorUpdaterPlugin {
  async download(options: { url: string, version?: string }): Promise<BundleInfo> {
    console.warn('Cannot download version in web', options);
    return VERSION_BUILTIN;
  }
  async next(options: { id: string, version?: string }): Promise<BundleInfo> {
    console.warn('Cannot set next version in web', options);
    return VERSION_BUILTIN;
  }

  async isAutoUpdateEnabled(): Promise<{ enabled: boolean }> {
    console.warn('Cannot get isAutoUpdateEnabled version in web');
    return { enabled: false };
  }
  async set(options: { id: string, version?: string }): Promise<void> {
    console.warn('Cannot set version in web', options);
    return;
  }
  async getId(): Promise<{ id: string }> {
    console.warn('Cannot get ID in web');
    return { id: 'default' };
  }
  async getPluginVersion(): Promise<{ version: string }> {
    console.warn('Cannot get version in web');
    return { version: 'default'};
  }
  async delete(options: { id: string }): Promise<void> {
    console.warn('Cannot delete version in web', options);
  }
  async list(): Promise<{ versions: BundleInfo[] }> {
    console.warn('Cannot list version in web');
    return { versions: [] };
  }
  async reset(options?: { toLastSuccessful?: boolean }): Promise<void> {
    console.warn('Cannot reset version in web', options);
  }
  async current(): Promise<{ bundle: BundleInfo, native: string }> {
    console.warn('Cannot get current version in web');
    return { bundle: VERSION_BUILTIN, native: '0.0.0' };
  }
  async reload(): Promise<void> {
    console.warn('Cannot reload current version in web');
    return;
  }
  async notifyAppReady(): Promise<BundleInfo> {
    console.warn('Cannot notify App Ready in web');
    return VERSION_BUILTIN;
  }
  async setDelay(options: { delay: boolean }): Promise<void> {
    console.warn('Cannot setDelay delay update in web', options);
    return;
  }
}
