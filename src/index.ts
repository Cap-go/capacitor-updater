/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
import { Capacitor, registerPlugin } from '@capacitor/core';
import './history';

import { awaitInjectedAppReadyBundleId, readInjectedAppReadyBundleId } from './app-ready';
import type { AppReadyResult, CapacitorUpdaterPlugin } from './definitions';

type CapacitorUpdaterNativeBridge = CapacitorUpdaterPlugin & {
  notifyAppReady(options?: { bundleId?: string }): Promise<AppReadyResult>;
};

const NOTIFY_APP_READY_RETRY_MS = 60000;

const CapacitorUpdaterNative = registerPlugin<CapacitorUpdaterNativeBridge>('CapacitorUpdater', {
  web: () => import('./web').then((m) => new m.CapacitorUpdaterWeb()),
});

async function notifyAppReadyWithInternalBinding(
  target: CapacitorUpdaterNativeBridge,
  bundleId?: string,
): Promise<AppReadyResult> {
  const deadline = Date.now() + NOTIFY_APP_READY_RETRY_MS;
  let lastResult: AppReadyResult | undefined;

  while (Date.now() < deadline) {
    lastResult = await target.notifyAppReady(bundleId ? { bundleId } : undefined);
    if (lastResult?.bundle?.status === 'success') {
      return lastResult;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }

  return lastResult ?? (await target.notifyAppReady(bundleId ? { bundleId } : undefined));
}

export const CapacitorUpdater: CapacitorUpdaterPlugin = new Proxy(CapacitorUpdaterNative, {
  get(target, prop, receiver) {
    if (prop === 'notifyAppReady') {
      return async (): Promise<AppReadyResult> => {
        const bundleId =
          readInjectedAppReadyBundleId() ??
          (Capacitor.isNativePlatform() ? await awaitInjectedAppReadyBundleId() : undefined);
        return notifyAppReadyWithInternalBinding(target, bundleId);
      };
    }
    return Reflect.get(target, prop, receiver);
  },
});

export * from './definitions';
