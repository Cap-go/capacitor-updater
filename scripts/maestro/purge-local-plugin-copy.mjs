import { readdirSync, rmSync } from 'node:fs';
import { exampleAppDir, repoRoot } from './scenarios.mjs';

/**
 * Bun's file:.. store can keep removed native sources across CI cache restores.
 * Drop cached plugin copies before reinstalling so deleted Swift files are gone.
 */
export function purgeLocalPluginCopy() {
  for (const root of [exampleAppDir, repoRoot]) {
    const bunDir = `${root}/node_modules/.bun`;
    try {
      for (const entry of readdirSync(bunDir)) {
        if (entry.startsWith('@capgo+capacitor-updater@')) {
          rmSync(`${bunDir}/${entry}`, { recursive: true, force: true });
        }
      }
    } catch {
      // .bun may not exist yet.
    }

    try {
      rmSync(`${root}/node_modules/@capgo/capacitor-updater`, { recursive: true, force: true });
    } catch {
      // Package link may not exist yet.
    }
  }
}
