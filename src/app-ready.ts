/*
 * Internal helpers for notifyAppReady bundle binding injected by the native layer.
 */

const APP_READY_BUNDLE_ID_KEY = '__capgoAppReadyBundleId';
const APP_READY_BINDING_TOKEN_KEY = '__capgoAppReadyBindingToken';
const APP_READY_PAGE_STARTED_TOKEN_KEY = '__capgoAppReadyPageStartedToken';

type CapgoWindow = typeof window & {
  [APP_READY_BUNDLE_ID_KEY]?: string;
  [APP_READY_BINDING_TOKEN_KEY]?: number;
  [APP_READY_PAGE_STARTED_TOKEN_KEY]?: number;
};

function readPositiveNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : undefined;
}

export function readInjectedAppReadyBundleId(): string | undefined {
  if (typeof window === 'undefined') {
    return undefined;
  }
  const bundleId = (window as CapgoWindow)[APP_READY_BUNDLE_ID_KEY];
  return typeof bundleId === 'string' && bundleId.length > 0 ? bundleId : undefined;
}

export async function awaitInjectedAppReadyBundleId(timeoutMs = 60000): Promise<string | undefined> {
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

function readAppReadyBindingToken(): number | undefined {
  if (typeof window === 'undefined') {
    return undefined;
  }
  return readPositiveNumber((window as CapgoWindow)[APP_READY_BINDING_TOKEN_KEY]);
}

function readAppReadyPageStartedToken(): number | undefined {
  if (typeof window === 'undefined') {
    return undefined;
  }
  return readPositiveNumber((window as CapgoWindow)[APP_READY_PAGE_STARTED_TOKEN_KEY]);
}

function appReadyPageStartedMatchesBinding(): boolean {
  const bindingToken = readAppReadyBindingToken();
  if (!bindingToken) {
    return false;
  }
  return readAppReadyPageStartedToken() === bindingToken;
}

export async function awaitAppReadyPageStartedToken(timeoutMs = 60000): Promise<boolean> {
  if (appReadyPageStartedMatchesBinding()) {
    return true;
  }
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
    if (appReadyPageStartedMatchesBinding()) {
      return true;
    }
  }
  return appReadyPageStartedMatchesBinding();
}
