/*
 * Ensures notifyAppReady includes the bundle identity injected by the native layer.
 */

const APP_READY_BUNDLE_ID_KEY = '__capgoAppReadyBundleId';

type CapgoWindow = typeof window & {
  [APP_READY_BUNDLE_ID_KEY]?: string;
};

export function readInjectedAppReadyBundleId(): string | undefined {
  if (typeof window === 'undefined') {
    return undefined;
  }
  const bundleId = (window as CapgoWindow)[APP_READY_BUNDLE_ID_KEY];
  return typeof bundleId === 'string' && bundleId.length > 0 ? bundleId : undefined;
}

export function withInjectedAppReadyBundleId<T extends { bundleId?: string } | undefined>(
  options?: T,
): (T & { bundleId?: string }) | undefined {
  const bundleId = readInjectedAppReadyBundleId();
  if (!bundleId || options?.bundleId) {
    return options;
  }
  return {
    ...(options ?? ({} as T)),
    bundleId,
  };
}
