import { WebPlugin } from '@capacitor/core';

import type { CapacitorUpdaterPlugin } from './definitions';

export class CapacitorUpdaterWeb
  extends WebPlugin
  implements CapacitorUpdaterPlugin {
  async updateApp(options: { url: string }): Promise<{ done: boolean }> {
    console.log('Cannot updateApp in web', options);
    return { done: false};
  }
}
