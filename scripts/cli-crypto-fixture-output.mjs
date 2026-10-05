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

/** True when `descendant` is `parent` or a path under `parent`. */
export function pathContains(parent, descendant) {
  const relative = path.relative(parent, descendant);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

/**
 * Refuse output directories that contain the repository or the generator cwd (after symlink resolution).
 * Returns the resolved output directory path for mkdir and cleanup.
 */
export function assertSafeFixtureOutputDir(outputDir, { root, cwd }) {
  const resolvedOutput = resolveRealPath(outputDir);
  const resolvedRoot = fs.realpathSync(root);
  const resolvedCwd = fs.realpathSync(cwd);
  if (pathContains(resolvedOutput, resolvedRoot) || pathContains(resolvedOutput, resolvedCwd)) {
    throw new Error(
      `Refusing to write fixtures into ${outputDir}: it contains the repository or the current folder`,
    );
  }
  return resolvedOutput;
}
