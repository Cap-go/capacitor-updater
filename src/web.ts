import { WebPlugin } from '@capacitor/core';

import type { CapacitorUpdaterPlugin, VersionInfo } from './definitions';

const VERSION_BUILTIN: VersionInfo = { status: 'success', version: '', downloaded: '1970-01-01T00:00:00.000Z', name: 'builtin' };

export class CapacitorUpdaterWeb
  extends WebPlugin
  implements CapacitorUpdaterPlugin {
  async download(options: { url: string, versionName?: string }): Promise<VersionInfo> {
    console.warn('Cannot download version in web', options);
    return VERSION_BUILTIN;
  }
  async next(options: { version: string, versionName?: string }): Promise<VersionInfo> {
    console.warn('Cannot set next version in web', options);
    return VERSION_BUILTIN;
  }
  async set(options: { version: string, versionName?: string }): Promise<void> {
    console.warn('Cannot set version in web', options);
    return;
  }
  async getId(): Promise<{ id: string }> {
    console.warn('Cannot get ID in web');
    return { id: 'default' };
  }
  async delete(options: { version: string }): Promise<void> {
    console.warn('Cannot delete version in web', options);
  }
  async list(): Promise<{ versions: VersionInfo[] }> {
    console.warn('Cannot list version in web');
    return { versions: [] };
  }
  async reset(options?: { toLastSuccessful?: boolean }): Promise<void> {
    console.warn('Cannot reset version in web', options);
  }
  async current(): Promise<{ bundle: VersionInfo, native: string }> {
    console.warn('Cannot get current version in web');
    return { bundle: VERSION_BUILTIN, native: '0.0.0' };
  }
  async reload(): Promise<void> {
    console.warn('Cannot reload current version in web');
    return;
  }
  async notifyAppReady(): Promise<VersionInfo> {
    console.warn('Cannot notify App Ready in web');
    return VERSION_BUILTIN;
  }
  async delayUpdate(): Promise<void> {
    console.warn('Cannot delay update in web');
    return;
  }
  async cancelDelay(): Promise<void> {
    console.warn('Cannot cancel delay update in web');
    return;
  }
}
