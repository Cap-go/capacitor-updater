/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
import { registerPlugin } from '@capacitor/core';
import './history';

import { awaitInjectedAppReadyBundleId, withInjectedAppReadyBundleId } from './app-ready';
import type { AppReadyResult, CapacitorUpdaterPlugin, NotifyAppReadyOptions } from './definitions';

const CapacitorUpdaterNative = registerPlugin<CapacitorUpdaterPlugin>('CapacitorUpdater', {
  web: () => import('./web').then((m) => new m.CapacitorUpdaterWeb()),
});

export const CapacitorUpdater: CapacitorUpdaterPlugin = new Proxy(CapacitorUpdaterNative, {
  get(target, prop, receiver) {
    if (prop === 'notifyAppReady') {
      return async (options?: NotifyAppReadyOptions): Promise<AppReadyResult> => {
        const bundleId = options?.bundleId ?? (await awaitInjectedAppReadyBundleId());
        return target.notifyAppReady(withInjectedAppReadyBundleId(options, bundleId));
      };
    }
    return Reflect.get(target, prop, receiver);
  },
});

export * from './definitions';
