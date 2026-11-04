import fs from 'node:fs';
import path from 'node:path';

/** Resolve symlinks; walk up to the nearest existing ancestor when target does not exist yet. */
export function resolveRealPath(target) {
  const normalized = path.resolve(target);
  const suffix = [];
  let cursor = normalized;
  while (true) {
    try {
      const real = fs.realpathSync(cursor);
      return suffix.length === 0 ? real : path.join(real, ...suffix);
    } catch (err) {
      if (err?.code !== 'ENOENT') {
        throw err;
      }
      suffix.unshift(path.basename(cursor));
      const parent = path.dirname(cursor);
      if (parent === cursor) {
        throw err;
      }
      cursor = parent;
    }
  }
}
