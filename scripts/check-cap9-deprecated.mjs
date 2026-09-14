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

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

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

function resolvePluginDir(raw) {
  const base = process.cwd();
  const resolved = path.resolve(base, raw || ".");
  if (resolved !== base && !resolved.startsWith(`${base}${path.sep}`)) {
    console.error(`[cap9-deprecated] ERROR: --dir must stay under ${base}`);
    process.exit(2);
  }
  return resolved;
}

function parseArgs(argv) {
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

function readPackageJson(pluginDir) {
  const pkgPath = path.join(pluginDir, "package.json");
  try {
    return JSON.parse(fs.readFileSync(pkgPath, "utf8"));
  } catch (e) {
    console.error(`[cap9-deprecated] ERROR: invalid package.json (${pkgPath}): ${e?.message || e}`);
    process.exit(2);
  }
}

function collectScanPaths(pluginDir, pkg) {
  const cap = typeof pkg.capacitor === "object" && pkg.capacitor ? pkg.capacitor : {};
  const paths = [];
  if (cap.android) {
    paths.push(path.join(pluginDir, "android", "src", "main"));
  }
  if (cap.ios) {
    const iosSources = path.join(pluginDir, "ios", "Sources");
    paths.push(fs.existsSync(iosSources) ? iosSources : path.join(pluginDir, "ios"));
  }
  const packageSwift = path.join(pluginDir, "Package.swift");
  if (fs.existsSync(packageSwift)) {
    paths.push(packageSwift);
  }
  return paths.filter((p) => fs.existsSync(p));
}

function globArgsForExts(exts) {
  const args = [];
  for (const ext of exts) {
    args.push("--glob", `*${ext}`);
  }
  return args;
}

function scanRule(pluginDir, scanPaths, rule) {
  if (!scanPaths.length) {
    return [];
  }

  const rgArgs = [
    "--line-number",
    "--no-heading",
    "--color=never",
    "--pcre2",
    ...globArgsForExts(rule.exts),
    rule.pattern.source,
    ...scanPaths,
  ];

  const proc = spawnSync("rg", rgArgs, { encoding: "utf8" });
  if (proc.status === 1) {
    return [];
  }
  if (proc.status !== 0) {
    console.error(`[cap9-deprecated] ERROR: rg failed (${proc.stderr || proc.stdout})`);
    process.exit(2);
  }

  const hits = [];
  for (const line of proc.stdout.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const match = line.match(/^(.+?):(\d+):(.+)$/);
    if (!match) continue;
    const [, filePath, lineNo, text] = match;
    const relFile = path.relative(pluginDir, filePath);
    if (relFile.endsWith("Package.swift") && CORDova_SPM_LINE.test(text)) {
      continue;
    }
    if (rule.ignoreLine?.test(text)) {
      continue;
    }
    hits.push({
      file: relFile,
      line: Number(lineNo),
      text: text.trim(),
    });
  }
  return hits;
}

const args = parseArgs(process.argv);
const pluginDir = args.dir;

if (!fs.existsSync(path.join(pluginDir, "package.json"))) {
  console.error(`[cap9-deprecated] ERROR: missing package.json in ${pluginDir}`);
  process.exit(2);
}

const pkg = readPackageJson(pluginDir);
const cap = typeof pkg.capacitor === "object" && pkg.capacitor ? pkg.capacitor : {};
if (!cap.android && !cap.ios) {
  process.exit(0);
}

const scanPaths = collectScanPaths(pluginDir, pkg);
const violations = [];
for (const rule of RULES) {
  for (const hit of scanRule(pluginDir, scanPaths, rule)) {
    violations.push({ rule: rule.id, ...hit });
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
