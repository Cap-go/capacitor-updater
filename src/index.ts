import { registerPlugin } from '@capacitor/core';

import type { CapacitorUpdaterPlugin } from './definitions';

const CapacitorUpdater = registerPlugin<CapacitorUpdaterPlugin>('CapacitorUpdater', {
  web: () => import('./web').then((m) => new m.CapacitorUpdaterWeb()),
});

export * from './definitions';
export { CapacitorUpdater };
