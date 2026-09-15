#!/usr/bin/env node
/**
 * Capacitor 9 deprecated native API guard.
 *
 * Fails when plugin native sources still use APIs removed in Capacitor 9.
 * Does not flag Cordova SwiftPM product dependencies (still required on Cap 8).
 *
 * Usage:
 *   node scripts/check-cap9-deprecated.mjs
 *   node scripts/check-cap9-deprecated.mjs --workspace
 *   node scripts/check-cap9-deprecated.mjs --dir path
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SKIP_DIRS = new Set([
  "node_modules",
  "dist",
  "build",
  ".build",
  ".gradle",
  "Pods",
  "DerivedData",
  ".swiftpm",
  ".git",
  "example-app",
]);

/** @type {{ id: string, pattern: RegExp, exts: string[], ignoreLine?: RegExp }[]} */
const RULES = [
  {
    id: "hasOption",
    pattern: /\bhasOption\s*\(/,
    exts: [".java", ".kt", ".swift"],
  },
  {
    id: "getConfigValue",
    pattern: /\bgetConfigValue\s*\(/,
    exts: [".java", ".kt", ".swift"],
  },
  {
    id: "@NativePlugin",
    pattern: /@NativePlugin\b/,
    exts: [".java", ".kt"],
  },
  {
    id: "saveCall",
    pattern: /\bsaveCall\s*\(/,
    exts: [".java", ".kt", ".swift"],
  },
  {
    id: "getSavedCall",
    pattern: /\bgetSavedCall\s*\(/,
    exts: [".java", ".kt", ".swift"],
  },
  {
    id: "freeSavedCall",
    pattern: /\bfreeSavedCall\s*\(/,
    exts: [".java", ".kt", ".swift"],
  },
  {
    id: "releaseCall",
    pattern: /\breleaseCall\s*\(/,
    exts: [".java", ".kt", ".swift"],
    ignoreLine: /\.releaseCall\s*\(\s*withID:/,
  },
  {
    id: "pluginRequestPermission",
    pattern: /\bpluginRequestPermissions?\s*\(/,
    exts: [".java", ".kt"],
  },
  {
    id: "pluginRequestAllPermissions",
    pattern: /\bpluginRequestAllPermissions\s*\(/,
    exts: [".java", ".kt"],
  },
  {
    id: "hasDefinedPermissions",
    pattern: /\bhasDefinedPermissions\s*\(/,
    exts: [".java", ".kt"],
  },
  {
    id: "CAPBridge",
    pattern: /\bCAPBridge\./,
    exts: [".swift"],
    ignoreLine: /CAPBridgedPlugin/,
  },
  {
    id: "CAPNotifications",
    pattern: /\bCAPNotifications\b/,
    exts: [".swift"],
  },
];

const CORDova_SPM_LINE =
  /\.product\s*\(\s*name\s*:\s*"Cordova"\s*,\s*package\s*:\s*"capacitor-swift-pm"\s*\)/;

function readText(p) {
  try {
    return fs.readFileSync(p, "utf8");
  } catch {
    return "";
  }
}

function exists(p) {
  try {
    fs.accessSync(p);
    return true;
  } catch {
    return false;
  }
}

function parseArgs(argv) {
  const out = { dir: process.cwd(), workspace: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--workspace") {
      out.workspace = true;
      continue;
    }
    if (a === "--dir" || a === "--pluginDir") {
      out.dir = path.resolve(argv[++i] || ".");
      continue;
    }
  }
  return out;
}

function walkFiles(rootDir, exts) {
  const out = [];
  const stack = [rootDir];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      if (e.isDirectory()) {
        if (SKIP_DIRS.has(e.name)) continue;
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

function collectScanRoots(pluginDir, cap) {
  const roots = [];
  if (cap.android) {
    const androidMain = path.join(pluginDir, "android", "src", "main");
    if (exists(androidMain)) roots.push(androidMain);
  }
  if (cap.ios) {
    const iosSources = path.join(pluginDir, "ios", "Sources");
    if (exists(iosSources)) roots.push(iosSources);
    else {
      const iosDir = path.join(pluginDir, "ios");
      if (exists(iosDir)) roots.push(iosDir);
    }
  }
  const packageSwift = path.join(pluginDir, "Package.swift");
  if (exists(packageSwift)) roots.push(packageSwift);
  return roots;
}

function scanFile(filePath, rule) {
  const ext = path.extname(filePath);
  if (!rule.exts.includes(ext)) return [];

  const txt = readText(filePath);
  const lines = txt.split(/\r?\n/);
  const hits = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (filePath.endsWith("Package.swift") && CORDova_SPM_LINE.test(line)) {
      continue;
    }
    if (rule.ignoreLine?.test(line)) continue;
    if (rule.pattern.test(line)) {
      hits.push({ line: i + 1, text: line.trim() });
    }
  }
  return hits;
}

function listWorkspacePluginDirs(repoRoot) {
  const packagesRoot = path.join(repoRoot, "packages");
  if (!exists(packagesRoot)) return [];
  return fs
    .readdirSync(packagesRoot, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => path.join(packagesRoot, e.name))
    .filter((dir) => {
      const pkgPath = path.join(dir, "package.json");
      if (!exists(pkgPath)) return false;
      try {
        const pkg = JSON.parse(readText(pkgPath));
        const cap = typeof pkg.capacitor === "object" && pkg.capacitor ? pkg.capacitor : {};
        return Boolean(cap.android || cap.ios);
      } catch {
        return false;
      }
    })
    .sort();
}

/**
 * @returns {boolean} true when the plugin passes
 */
function checkPluginDir(pluginDir) {
  const pkgPath = path.join(pluginDir, "package.json");

  if (!exists(pkgPath)) {
    console.error(`[cap9-deprecated] ERROR: missing package.json in ${pluginDir}`);
    return false;
  }

  let pkg;
  try {
    pkg = JSON.parse(readText(pkgPath));
  } catch (e) {
    console.error(`[cap9-deprecated] ERROR: invalid package.json (${pkgPath}): ${e?.message || e}`);
    return false;
  }

  const cap = typeof pkg.capacitor === "object" && pkg.capacitor ? pkg.capacitor : {};
  if (!cap.android && !cap.ios) {
    return true;
  }

  const scanRoots = collectScanRoots(pluginDir, cap);
  const allExts = [...new Set(RULES.flatMap((r) => r.exts))];
  const files = [];
  for (const root of scanRoots) {
    if (root.endsWith("Package.swift")) {
      files.push(root);
      continue;
    }
    files.push(...walkFiles(root, allExts));
  }

  const violations = [];
  for (const file of files) {
    for (const rule of RULES) {
      const hits = scanFile(file, rule);
      for (const hit of hits) {
        violations.push({
          rule: rule.id,
          file: path.relative(pluginDir, file),
          line: hit.line,
          text: hit.text,
        });
      }
    }
  }

  if (violations.length) {
    const relDir = path.relative(process.cwd(), pluginDir) || ".";
    console.error(`[cap9-deprecated] FAIL in ${relDir}`);
    for (const v of violations) {
      console.error(`- ${v.rule}: ${v.file}:${v.line}: ${v.text}`);
    }
    return false;
  }

  return true;
}

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = parseArgs(process.argv);

if (args.workspace) {
  const pluginDirs = listWorkspacePluginDirs(repoRoot);
  if (!pluginDirs.length) {
    console.error("[cap9-deprecated] ERROR: no Capacitor plugin packages found under packages/*");
    process.exit(2);
  }
  let failed = false;
  for (const dir of pluginDirs) {
    if (!checkPluginDir(dir)) failed = true;
  }
  if (failed) process.exit(1);
  console.log(`[cap9-deprecated] OK (${pluginDirs.length} plugin package(s) scanned)`);
  process.exit(0);
}

const ok = checkPluginDir(args.dir);
process.exit(ok ? 0 : 1);
