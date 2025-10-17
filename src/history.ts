/*
 * Maintains navigation history across Capgo-controlled reloads when keepUrlPathAfterReload is enabled.
 */

const KEEP_FLAG_KEY = '__capgo_keep_url_path_after_reload';
const HISTORY_STORAGE_KEY = '__capgo_history_stack__';
const MAX_STACK_ENTRIES = 100;

const isBrowser = typeof window !== 'undefined' && typeof document !== 'undefined' && typeof history !== 'undefined';

if (isBrowser) {
  const win = window as typeof window & {
    __capgoHistoryPatched?: boolean;
    __capgoKeepUrlPathAfterReload?: boolean;
  };

  if (!win.__capgoHistoryPatched) {
    win.__capgoHistoryPatched = true;

    const isFeatureConfigured = (): boolean => {
      try {
        if (win.__capgoKeepUrlPathAfterReload) {
          return true;
        }
      } catch (err) {
        // ignore access issues
      }
      try {
        return window.localStorage.getItem(KEEP_FLAG_KEY) === '1';
      } catch (err) {
        return false;
      }
    };

    type StoredHistory = { stack: string[]; index: number };

    const readStored = (): StoredHistory => {
      try {
        const raw = window.sessionStorage.getItem(HISTORY_STORAGE_KEY);
        if (!raw) {
          return { stack: [], index: -1 };
        }
        const parsed = JSON.parse(raw) as StoredHistory;
        if (!parsed || !Array.isArray(parsed.stack) || typeof parsed.index !== 'number') {
          return { stack: [], index: -1 };
        }
        return parsed;
      } catch (err) {
        return { stack: [], index: -1 };
      }
    };

    const writeStored = (stack: string[], index: number): void => {
      try {
        window.sessionStorage.setItem(HISTORY_STORAGE_KEY, JSON.stringify({ stack, index }));
      } catch (err) {
        // Storage might be unavailable; fail silently.
      }
    };

    const clearStored = (): void => {
      try {
        window.sessionStorage.removeItem(HISTORY_STORAGE_KEY);
      } catch (err) {
        // ignore
      }
    };

    const normalize = (url?: string | URL | null): string | null => {
      try {
        const base = url ?? window.location.href;
        const parsed = new URL(base instanceof URL ? base.toString() : base, window.location.href);
        return `${parsed.pathname}${parsed.search}${parsed.hash}`;
      } catch (err) {
        return null;
      }
    };

    const trimStack = (stack: string[], index: number): StoredHistory => {
      if (stack.length <= MAX_STACK_ENTRIES) {
        return { stack, index };
      }
      const start = stack.length - MAX_STACK_ENTRIES;
      const trimmed = stack.slice(start);
      const adjustedIndex = Math.max(0, index - start);
      return { stack: trimmed, index: adjustedIndex };
    };

    const runWhenReady = (fn: () => void): void => {
      if (document.readyState === 'complete' || document.readyState === 'interactive') {
        fn();
      } else {
        window.addEventListener('DOMContentLoaded', fn, { once: true });
      }
    };

    let featureActive = false;
    let isRestoring = false;
    let restoreScheduled = false;

    const ensureCurrentTracked = () => {
      if (!featureActive) {
        return;
      }
      const stored = readStored();
      const current = normalize();
      if (!current) {
        return;
      }
      if (stored.stack.length === 0) {
        stored.stack.push(current);
        stored.index = 0;
        writeStored(stored.stack, stored.index);
        return;
      }
      if (stored.index < 0 || stored.index >= stored.stack.length) {
        stored.index = stored.stack.length - 1;
      }
      if (stored.stack[stored.index] !== current) {
        stored.stack[stored.index] = current;
        writeStored(stored.stack, stored.index);
      }
    };

    const record = (url: string | URL | null | undefined, replace: boolean) => {
      if (!featureActive || isRestoring) {
        return;
      }
      const normalized = normalize(url);
      if (!normalized) {
        return;
      }
      let { stack, index } = readStored();
      if (stack.length === 0) {
        stack.push(normalized);
        index = stack.length - 1;
      } else if (replace) {
        if (index < 0 || index >= stack.length) {
          index = stack.length - 1;
        }
        stack[index] = normalized;
      } else {
        if (index >= stack.length - 1) {
          stack.push(normalized);
          index = stack.length - 1;
        } else {
          stack = stack.slice(0, index + 1);
          stack.push(normalized);
          index = stack.length - 1;
        }
      }
      ({ stack, index } = trimStack(stack, index));
      writeStored(stack, index);
    };

    const restoreHistory = () => {
      if (!featureActive || isRestoring) {
        return;
      }
      const stored = readStored();
      if (stored.stack.length === 0) {
        ensureCurrentTracked();
        return;
      }
      const targetIndex =
        stored.index >= 0 && stored.index < stored.stack.length ? stored.index : stored.stack.length - 1;
      const normalizedCurrent = normalize();
      if (stored.stack.length === 1 && normalizedCurrent === stored.stack[0]) {
        return;
      }
      const firstEntry = stored.stack[0];
      if (!firstEntry) {
        return;
      }
      isRestoring = true;
      try {
        history.replaceState(history.state, document.title, firstEntry);
        for (let i = 1; i < stored.stack.length; i += 1) {
          history.pushState(history.state, document.title, stored.stack[i]);
        }
      } catch (err) {
        isRestoring = false;
        return;
      }
      isRestoring = false;
      const currentIndex = stored.stack.length - 1;
      const offset = targetIndex - currentIndex;
      if (offset !== 0) {
        history.go(offset);
      } else {
        history.replaceState(history.state, document.title, stored.stack[targetIndex]);
        window.dispatchEvent(new PopStateEvent('popstate'));
      }
    };

    const scheduleRestore = () => {
      if (!featureActive || restoreScheduled) {
        return;
      }
      restoreScheduled = true;
      runWhenReady(() => {
        restoreScheduled = false;
        restoreHistory();
      });
    };

    let originalPushState: typeof history.pushState | null = null;
    let originalReplaceState: typeof history.replaceState | null = null;

    const popstateHandler = () => {
      if (!featureActive || isRestoring) {
        return;
      }
      const normalized = normalize();
      if (!normalized) {
        return;
      }
      const stored = readStored();
      const idx = stored.stack.lastIndexOf(normalized);
      if (idx >= 0) {
        stored.index = idx;
      } else {
        stored.stack.push(normalized);
        stored.index = stored.stack.length - 1;
      }
      const trimmed = trimStack(stored.stack, stored.index);
      writeStored(trimmed.stack, trimmed.index);
    };

    const patchHistory = () => {
      if (originalPushState && originalReplaceState) {
        return;
      }
      originalPushState = history.pushState;
      originalReplaceState = history.replaceState;

      history.pushState = function pushStatePatched(state: any, title: string, url?: string | URL | null) {
        const result = originalPushState!.call(history, state, title, url as any);
        record(url, false);
        return result;
      };

      history.replaceState = function replaceStatePatched(state: any, title: string, url?: string | URL | null) {
        const result = originalReplaceState!.call(history, state, title, url as any);
        record(url, true);
        return result;
      };

      window.addEventListener('popstate', popstateHandler);
    };

    const unpatchHistory = () => {
      if (originalPushState) {
        history.pushState = originalPushState;
        originalPushState = null;
      }
      if (originalReplaceState) {
        history.replaceState = originalReplaceState;
        originalReplaceState = null;
      }
      window.removeEventListener('popstate', popstateHandler);
    };

    const setFeatureActive = (enabled: boolean) => {
      if (featureActive === enabled) {
        if (featureActive) {
          ensureCurrentTracked();
          scheduleRestore();
        }
        return;
      }
      featureActive = enabled;
      if (featureActive) {
        patchHistory();
        ensureCurrentTracked();
        scheduleRestore();
      } else {
        unpatchHistory();
        clearStored();
      }
    };

    window.addEventListener('CapacitorUpdaterKeepUrlPathAfterReload', (event) => {
      const evt = event as CustomEvent<{ enabled?: boolean }>;
      const enabled = evt?.detail?.enabled;
      if (typeof enabled === 'boolean') {
        win.__capgoKeepUrlPathAfterReload = enabled;
        setFeatureActive(enabled);
      } else {
        win.__capgoKeepUrlPathAfterReload = true;
        setFeatureActive(true);
      }
    });

    setFeatureActive(isFeatureConfigured());
  }
}

export {};
