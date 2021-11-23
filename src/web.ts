import { WebPlugin } from '@capacitor/core';

import type { CapacitorUpdaterPlugin } from './definitions';

export class CapacitorUpdaterWeb
  extends WebPlugin
  implements CapacitorUpdaterPlugin {
  async download(options: { url: string }): Promise<{ version: string }> {
    console.log('Cannot download version in web', options);
    return { version: ""};
  }
  async set(options: { version: string }): Promise<void> {
    console.log('Cannot set version in web', options);
  }
  async delete(options: { version: string }): Promise<void> {
    console.log('Cannot delete version in web', options);
  }
  async list(): Promise<{ versions: string[] }> {
    console.log('Cannot list version in web');
    return { versions: []};
  }
}
