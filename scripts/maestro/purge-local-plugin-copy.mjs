import { readdirSync, rmSync } from 'node:fs';
import { exampleAppDir, repoRoot } from './scenarios.mjs';

/**
 * Bun's file:.. store can keep removed native sources across CI cache restores.
 * Drop cached plugin copies before reinstalling so deleted Swift files are gone.
 */
export function purgeLocalPluginCopy() {
  for (const root of [exampleAppDir, repoRoot]) {
    const bunDir = `${root}/node_modules/.bun`;
    let entries = [];
    try {
      entries = readdirSync(bunDir);
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
    for (const entry of entries) {
      if (entry.startsWith('@capgo+capacitor-updater@')) {
        rmSync(`${bunDir}/${entry}`, { recursive: true, force: true });
      }
    }

    // force:true ignores missing paths; other I/O errors still throw.
    rmSync(`${root}/node_modules/@capgo/capacitor-updater`, { recursive: true, force: true });
  }
}
