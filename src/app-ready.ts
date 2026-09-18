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

export async function awaitInjectedAppReadyBundleId(timeoutMs = 10000): Promise<string | undefined> {
  const existing = readInjectedAppReadyBundleId();
  if (existing) {
    return existing;
  }
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
    const bundleId = readInjectedAppReadyBundleId();
    if (bundleId) {
      return bundleId;
    }
  }
  return readInjectedAppReadyBundleId();
}

export function withInjectedAppReadyBundleId<T extends { bundleId?: string } | undefined>(
  options?: T,
  bundleId = readInjectedAppReadyBundleId(),
): (T & { bundleId?: string }) | undefined {
  if (!bundleId || options?.bundleId) {
    return options;
  }
  return {
    ...(options ?? ({} as T)),
    bundleId,
  };
}
