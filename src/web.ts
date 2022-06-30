import { WebPlugin } from '@capacitor/core';

import type { CapacitorUpdaterPlugin, BundleInfo } from './definitions';

const BUNDLE_BUILTIN: BundleInfo = { status: 'success', version: '', downloaded: '1970-01-01T00:00:00.000Z', id: 'builtin' };

export class CapacitorUpdaterWeb
  extends WebPlugin
  implements CapacitorUpdaterPlugin {
  async download(options: { url: string, version?: string }): Promise<BundleInfo> {
    console.warn('Cannot download version in web', options);
    return BUNDLE_BUILTIN;
  }
  async next(options: { id: string }): Promise<BundleInfo> {
    console.warn('Cannot set next version in web', options);
    return BUNDLE_BUILTIN;
  }

  async isAutoUpdateEnabled(): Promise<{ enabled: boolean }> {
    console.warn('Cannot get isAutoUpdateEnabled in web');
    return { enabled: false };
  }
  async set(options: { id: string }): Promise<void> {
    console.warn('Cannot set active bundle in web', options);
    return;
  }
  async getId(): Promise<{ id: string }> {
    console.warn('Cannot get ID in web');
    return { id: 'default' };
  }
  async getPluginVersion(): Promise<{ version: string }> {
    console.warn('Cannot get plugin version in web');
    return { version: 'default'};
  }
  async delete(options: { id: string }): Promise<void> {
    console.warn('Cannot delete bundle in web', options);
  }
  async list(): Promise<{ bundles: BundleInfo[] }> {
    console.warn('Cannot list bundles in web');
    return { bundles: [] };
  }
  async reset(options?: { toLastSuccessful?: boolean }): Promise<void> {
    console.warn('Cannot reset version in web', options);
  }
  async current(): Promise<{ bundle: BundleInfo, native: string }> {
    console.warn('Cannot get current bundle in web');
    return { bundle: BUNDLE_BUILTIN, native: '0.0.0' };
  }
  async reload(): Promise<void> {
    console.warn('Cannot reload current bundle in web');
    return;
  }
  async notifyAppReady(): Promise<BundleInfo> {
    console.warn('Cannot notify App Ready in web');
    return BUNDLE_BUILTIN;
  }
  async setDelay(options: { delay: boolean }): Promise<void> {
    console.warn('Cannot setDelay delay update in web', options);
    return;
  }
}
