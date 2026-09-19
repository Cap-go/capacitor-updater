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

const NOTIFY_APP_READY_RETRY_MS = 20000;
const NOTIFY_APP_READY_BINDING_WAIT_MS = 20000;

const CapacitorUpdaterNative = registerPlugin<CapacitorUpdaterNativeBridge>('CapacitorUpdater', {
  web: () => import('./web').then((m) => new m.CapacitorUpdaterWeb()),
});

async function readCommittedCurrentBundle(target: CapacitorUpdaterPlugin) {
  const { bundle } = await target.current();
  return bundle;
}

async function notifyAppReadyWithInternalBinding(
  target: CapacitorUpdaterNativeBridge,
  bundleId?: string,
): Promise<AppReadyResult> {
  const deadline = Date.now() + NOTIFY_APP_READY_RETRY_MS;
  let lastResult: AppReadyResult | undefined;

  while (Date.now() < deadline) {
    lastResult = await target.notifyAppReady(bundleId ? { bundleId } : undefined);
    const bundle = await readCommittedCurrentBundle(target);
    if (bundle.status === 'success' && (!bundleId || bundle.id === bundleId)) {
      return { bundle };
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }

  const bundle = await readCommittedCurrentBundle(target);
  if (bundle.status === 'success' && (!bundleId || bundle.id === bundleId)) {
    return { bundle };
  }
  return lastResult ?? (await target.notifyAppReady(bundleId ? { bundleId } : undefined));
}

export const CapacitorUpdater: CapacitorUpdaterPlugin = new Proxy(CapacitorUpdaterNative, {
  get(target, prop, receiver) {
    if (prop === 'notifyAppReady') {
      return async (): Promise<AppReadyResult> => {
        const bundleId =
          readInjectedAppReadyBundleId() ??
          (Capacitor.isNativePlatform()
            ? await awaitInjectedAppReadyBundleId(NOTIFY_APP_READY_BINDING_WAIT_MS)
            : undefined);
        if (Capacitor.isNativePlatform() && bundleId) {
          await awaitAppReadyPageStartedToken(NOTIFY_APP_READY_BINDING_WAIT_MS);
        }
        return notifyAppReadyWithInternalBinding(target, bundleId);
      };
    }
    return Reflect.get(target, prop, receiver);
  },
});

export * from './definitions';
