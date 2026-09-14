#!/usr/bin/env node
/**
 * Capacitor 9 deprecated native API guard.
 *
 * Fails when plugin native sources still use APIs removed in Capacitor 9.
 * Does not flag Cordova SwiftPM product dependencies (still required on Cap 8).
 *
 * Usage:
 *   node scripts/check-cap9-deprecated.mjs
 *   node scripts/check-cap9-deprecated.mjs --dir path
 */

import path from "node:path";
import {
  BASE_SKIP_DIRS,
  parsePluginDirArgs,
  pathExists,
  readTextFile,
  walkFiles,
} from "./plugin-check-common.mjs";

const SKIP_DIRS = new Set([...BASE_SKIP_DIRS, "example-app"]);

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
    ignoreLine: /bridge(\?)?\.saveCall\s*\(/,
  },
  {
    id: "getSavedCall",
    pattern: /\bgetSavedCall\s*\(/,
    exts: [".java", ".kt", ".swift"],
    ignoreLine: /bridge(\?)?\.getSavedCall\s*\(/,
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
    ignoreLine: /bridge(\?)?\.releaseCall\s*\(|\.releaseCall\s*\(\s*withID:/,
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

function collectScanRoots(pluginDir, pkg) {
  const cap = typeof pkg.capacitor === "object" && pkg.capacitor ? pkg.capacitor : {};
  const roots = [];
  if (cap.android) {
    const androidMain = path.join(pluginDir, "android", "src", "main");
    if (pathExists(androidMain, pluginDir)) roots.push(androidMain);
  }
  if (cap.ios) {
    const iosSources = path.join(pluginDir, "ios", "Sources");
    if (pathExists(iosSources, pluginDir)) roots.push(iosSources);
    else {
      const iosDir = path.join(pluginDir, "ios");
      if (pathExists(iosDir, pluginDir)) roots.push(iosDir);
    }
  }
  const packageSwift = path.join(pluginDir, "Package.swift");
  if (pathExists(packageSwift, pluginDir)) roots.push(packageSwift);
  return roots;
}

function scanFile(pluginDir, filePath, rule) {
  const ext = path.extname(filePath);
  if (!rule.exts.includes(ext)) return [];

  const txt = readTextFile(filePath, pluginDir);
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

const args = parsePluginDirArgs(process.argv);
const pluginDir = args.dir;
const pkgPath = path.join(pluginDir, "package.json");

if (!pathExists(pkgPath, pluginDir)) {
  console.error(`[cap9-deprecated] ERROR: missing package.json in ${pluginDir}`);
  process.exit(2);
}

let pkg;
try {
  pkg = JSON.parse(readTextFile(pkgPath, pluginDir));
} catch (e) {
  console.error(`[cap9-deprecated] ERROR: invalid package.json (${pkgPath}): ${e?.message || e}`);
  process.exit(2);
}

const cap = typeof pkg.capacitor === "object" && pkg.capacitor ? pkg.capacitor : {};
if (!cap.android && !cap.ios) {
  process.exit(0);
}

const scanRoots = collectScanRoots(pluginDir, pkg);
const allExts = [...new Set(RULES.flatMap((r) => r.exts))];
const files = [];
for (const root of scanRoots) {
  if (root.endsWith("Package.swift")) {
    files.push(root);
    continue;
  }
  files.push(...walkFiles(root, allExts, SKIP_DIRS, pluginDir));
}

const violations = [];
for (const file of files) {
  for (const rule of RULES) {
    const hits = scanFile(pluginDir, file, rule);
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
  process.exit(1);
}

process.exit(0);
