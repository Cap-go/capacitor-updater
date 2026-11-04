import fs from 'node:fs';
import path from 'node:path';
import { resolveRealPath } from './resolve-real-path.mjs';

export { resolveRealPath };

/** True when `descendant` is `parent` or a path under `parent`. */
export function pathContains(parent, descendant) {
  const relative = path.relative(parent, descendant);
  if (relative === '') {
    return true;
  }
  if (path.isAbsolute(relative) || relative === '..' || relative.startsWith(`..${path.sep}`)) {
    return false;
  }
  return true;
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
