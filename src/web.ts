import { WebPlugin } from '@capacitor/core';

import type { CapacitorUpdaterPlugin } from './definitions';

export class CapacitorUpdaterWeb
  extends WebPlugin
  implements CapacitorUpdaterPlugin {
  async download(options: { url: string }): Promise<{ version: string }> {
    console.log('Cannot download version in web', options);
    return { version: ""};
  }
  async set(options: { version: string, versionName?: string }): Promise<void> {
    console.log('Cannot set version in web', options);
  }
  async delete(options: { version: string }): Promise<void> {
    console.log('Cannot delete version in web', options);
  }
  async list(): Promise<{ versions: string[] }> {
    console.log('Cannot list version in web');
    return { versions: []};
  }
  async reset(): Promise<void> {
    console.log('Cannot reset version in web');
  }
  async current(): Promise<{ current: string }> {
    console.log('Cannot get current version in web');
    return { current: 'default'};
  }
  async reload(): Promise<void> {
    console.log('Cannot reload current version in web');
    return;
  }
  async versionName(): Promise<{ versionName: string }> {
    console.log('Cannot get current versionName in web');
    return { versionName: 'default'};
  }
}
