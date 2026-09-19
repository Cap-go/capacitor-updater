/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
import { Capacitor, registerPlugin } from '@capacitor/core';
import './history';

import {
  awaitAppReadyPageStartedToken,
  awaitInjectedAppReadyBundleId,
  readInjectedAppReadyBundleId,
} from './app-ready';
import type { AppReadyResult, CapacitorUpdaterPlugin } from './definitions';

type CapacitorUpdaterNativeBridge = CapacitorUpdaterPlugin & {
  notifyAppReady(options?: { bundleId?: string }): Promise<AppReadyResult>;
};

const CapacitorUpdaterNative = registerPlugin<CapacitorUpdaterNativeBridge>('CapacitorUpdater', {
  web: () => import('./web').then((m) => new m.CapacitorUpdaterWeb()),
});

export const CapacitorUpdater: CapacitorUpdaterPlugin = new Proxy(CapacitorUpdaterNative, {
  get(target, prop, receiver) {
    if (prop === 'notifyAppReady') {
      return async (): Promise<AppReadyResult> => {
        const bundleId =
          readInjectedAppReadyBundleId() ??
          (Capacitor.isNativePlatform() ? await awaitInjectedAppReadyBundleId() : undefined);
        if (Capacitor.isNativePlatform() && bundleId) {
          await awaitAppReadyPageStartedToken();
        }
        return target.notifyAppReady(bundleId ? { bundleId } : undefined);
      };
    }
    return Reflect.get(target, prop, receiver);
  },
});

export * from './definitions';
