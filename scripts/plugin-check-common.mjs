import fs from "node:fs";
import path from "node:path";

export const BASE_SKIP_DIRS = new Set([
  "node_modules",
  "dist",
  "build",
  ".build",
  ".gradle",
  "Pods",
  "DerivedData",
  ".swiftpm",
  ".git",
]);

export function resolvePathInside(root, target) {
  const rootResolved = path.resolve(root);
  const resolved = path.resolve(rootResolved, target);
  if (resolved !== rootResolved && !resolved.startsWith(`${rootResolved}${path.sep}`)) {
    throw new Error(`path escapes allowed root: ${target}`);
  }
  return resolved;
}

export function readTextFile(filePath, allowedRoot) {
  let resolved;
  try {
    resolved = resolvePathInside(allowedRoot, filePath);
  } catch {
    return "";
  }
  try {
    return fs.readFileSync(resolved, "utf8");
  } catch {
    return "";
  }
}

export function pathExists(filePath, allowedRoot) {
  try {
    fs.accessSync(resolvePathInside(allowedRoot, filePath));
    return true;
  } catch {
    return false;
  }
}

export function resolvePluginDir(raw) {
  const base = process.cwd();
  const resolved = path.resolve(base, raw || ".");
  if (resolved !== base && !resolved.startsWith(`${base}${path.sep}`)) {
    console.error(`[plugin-check] ERROR: --dir must stay under ${base}`);
    process.exit(2);
  }
  return resolved;
}

export function parsePluginDirArgs(argv) {
  const out = { dir: process.cwd() };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--dir" || a === "--pluginDir") {
      out.dir = resolvePluginDir(argv[++i]);
      continue;
    }
  }
  return out;
}

export function walkFiles(rootDir, exts, skipDirs = BASE_SKIP_DIRS, allowedRoot = rootDir) {
  const out = [];
  const stack = [path.resolve(rootDir)];
  const rootResolved = path.resolve(allowedRoot);
  while (stack.length) {
    const dir = stack.pop();
    if (dir !== rootResolved && !dir.startsWith(`${rootResolved}${path.sep}`)) {
      continue;
    }
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      if (e.isDirectory()) {
        if (skipDirs.has(e.name)) continue;
        stack.push(path.join(dir, e.name));
        continue;
      }
      if (!e.isFile()) continue;
      for (const ext of exts) {
        if (e.name.endsWith(ext)) {
          out.push(path.join(dir, e.name));
          break;
        }
      }
    }
  }
  out.sort();
  return out;
}
