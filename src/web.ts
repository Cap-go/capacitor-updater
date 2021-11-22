import { WebPlugin } from '@capacitor/core';

import type { CapacitorUpdaterPlugin } from './definitions';

export class CapacitorUpdaterWeb
  extends WebPlugin
  implements CapacitorUpdaterPlugin {
  async download(options: { url: string }): Promise<{ version: string }> {
    console.log('Cannot download in web', options);
    return { version: ""};
  }
  async setVersion(options: { version: string }): Promise<void> {
    console.log('Cannot setVersion in web', options);
  }
  async load(): Promise<void> {
    console.log('Cannot load in web');
  }
}
