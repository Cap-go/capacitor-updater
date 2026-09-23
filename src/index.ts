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
  isAppReadyPageStartedMatched,
  readAppReadyBindingToken,
  readInjectedAppReadyBundleId,
} from './app-ready';
import type { AppReadyResult, CapacitorUpdaterPlugin } from './definitions';

type CapacitorUpdaterNativeBridge = CapacitorUpdaterPlugin & {
  notifyAppReady(options?: { bundleId?: string; loadToken?: string }): Promise<AppReadyResult>;
};

const NOTIFY_APP_READY_WAIT_MS = 55000;

const CapacitorUpdaterNative = registerPlugin<CapacitorUpdaterNativeBridge>('CapacitorUpdater', {
  web: () => import('./web').then((m) => new m.CapacitorUpdaterWeb()),
});

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

async function awaitBindingState(remainingMs: number): Promise<string | undefined> {
  let bundleId = readInjectedAppReadyBundleId();
  if (!bundleId) {
    bundleId = await awaitInjectedAppReadyBundleId(Math.min(remainingMs, 250));
    if (!bundleId) {
      return undefined;
    }
  }

  if (!isAppReadyPageStartedMatched()) {
    await awaitAppReadyPageStartedToken(Math.min(remainingMs, 250));
  }

  return bundleId;
}

async function notifyAppReadyWithInternalBinding(target: CapacitorUpdaterNativeBridge): Promise<AppReadyResult> {
  const deadline = Date.now() + NOTIFY_APP_READY_WAIT_MS;
  let lastResult: AppReadyResult | undefined;

  while (Date.now() < deadline) {
    const remainingMs = deadline - Date.now();
    if (remainingMs <= 0) {
      break;
    }

    const bundleId = await awaitBindingState(remainingMs);
    if (!bundleId) {
      await sleep(25);
      continue;
    }

    const loadToken = readAppReadyBindingToken();
    lastResult = await target.notifyAppReady({
      bundleId,
      ...(loadToken != null ? { loadToken: String(loadToken) } : {}),
    });
    const { bundle } = await target.current();
    if (bundle.status === 'success' && bundle.id === bundleId) {
      return { bundle };
    }
    await sleep(50);
  }

  const bundleId = readInjectedAppReadyBundleId();
  const { bundle } = await target.current();
  if (bundle.status === 'success' && (!bundleId || bundle.id === bundleId)) {
    return { bundle };
  }
  if (bundleId) {
    const loadToken = readAppReadyBindingToken();
    return (
      lastResult ??
      (await target.notifyAppReady({
        bundleId,
        ...(loadToken != null ? { loadToken: String(loadToken) } : {}),
      }))
    );
  }
  const loadToken = readAppReadyBindingToken();
  return (
    lastResult ??
    (await target.notifyAppReady(loadToken != null ? { loadToken: String(loadToken) } : undefined))
  );
}

export const CapacitorUpdater: CapacitorUpdaterPlugin = new Proxy(CapacitorUpdaterNative, {
  get(target, prop, receiver) {
    if (prop === 'notifyAppReady') {
      return async (): Promise<AppReadyResult> =>
        Capacitor.getPlatform() === 'web' ? target.notifyAppReady() : notifyAppReadyWithInternalBinding(target);
    }
    return Reflect.get(target, prop, receiver);
  },
});

export * from './definitions';
