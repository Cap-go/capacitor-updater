#!/usr/bin/env node
/**
 * Capacitor plugin wiring/name checker.
 *
 * Enforces that runtime plugin name matches across:
 * - JS: registerPlugin('Name')
 * - Android: @CapacitorPlugin(name = "Name")
 * - iOS: CAPBridgedPlugin jsName = "Name"
 *
 * And (when iOS is declared in package.json capacitor config):
 * - CocoaPods podspec s.name matches SwiftPM Package(name: ...) and .library(name: ...)
 *
 * Usage:
 *   node tools/check-capacitor-plugin-wiring.mjs            # checks current working dir
 *   node tools/check-capacitor-plugin-wiring.mjs --dir path # checks given plugin dir
 */

import fs from "node:fs";
import path from "node:path";

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
]);

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

function uniq(arr) {
  const out = [];
  for (const x of arr) {
    if (!x) continue;
    if (!out.includes(x)) out.push(x);
  }
  return out;
}

function parseArgs(argv) {
  const out = { dir: process.cwd() };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--dir" || a === "--pluginDir") {
      out.dir = path.resolve(argv[++i] || ".");
      continue;
    }
  }
  return out;
}

const args = parseArgs(process.argv);
const pluginDir = args.dir;
const pkgPath = path.join(pluginDir, "package.json");

if (!exists(pkgPath)) {
  console.error(`[wiring] ERROR: missing package.json in ${pluginDir}`);
  process.exit(2);
}

let pkg;
try {
  pkg = JSON.parse(readText(pkgPath));
} catch (e) {
  console.error(`[wiring] ERROR: invalid package.json (${pkgPath}): ${e?.message || e}`);
  process.exit(2);
}

const cap = typeof pkg.capacitor === "object" && pkg.capacitor ? pkg.capacitor : {};
const supportsAndroid = typeof cap.android === "object" && cap.android;
const supportsIos = typeof cap.ios === "object" && cap.ios;

// Not a Capacitor plugin package (e.g. meta/workspace package).
// We only enforce wiring rules for actual plugin packages declaring a `capacitor` config.
if (!supportsAndroid && !supportsIos) {
  process.exit(0);
}

// ---------------- JS (registerPlugin) ----------------
const jsSrcDir = path.join(pluginDir, "src");
let jsName = "";
if (exists(jsSrcDir)) {
  const jsFiles = walkFiles(jsSrcDir, [".ts", ".js"]);
  const reRegister = /registerPlugin(?:<[^>]*>)?\(\s*['"]([^'"]+)['"]/;
  for (const f of jsFiles) {
    const m = reRegister.exec(readText(f));
    if (m) {
      jsName = m[1];
      break;
    }
  }
}

// ---------------- Android (@CapacitorPlugin) ----------------
let androidNames = [];
if (supportsAndroid) {
  const androidMain = path.join(pluginDir, "android", "src", "main");
  const files = walkFiles(androidMain, [".java", ".kt"]);
  const foundAnnotations = [];
  for (const f of files) {
    const txt = readText(f);
    if (!txt.includes("@CapacitorPlugin")) continue;
    foundAnnotations.push(f);
    const m =
      /@CapacitorPlugin\(\s*name\s*=\s*"([^"]+)"/.exec(txt) ||
      /@CapacitorPlugin\(\s*name\s*=\s*([A-Za-z0-9_]+)\b/.exec(txt);
    if (m) androidNames.push(m[1]);
  }
  androidNames = uniq(androidNames);

  // Enforce explicit name attribute to prevent silent class-name drift.
  if (foundAnnotations.length && !androidNames.length) {
    console.error(
      `[wiring] ERROR: Android has @CapacitorPlugin but none specify name = \"...\". Add an explicit name to the plugin class.`
    );
    process.exit(1);
  }
}

// ---------------- iOS (jsName) ----------------
let iosJsNames = [];
if (supportsIos) {
  const iosDir = path.join(pluginDir, "ios");
  const scanRoot = exists(path.join(iosDir, "Sources")) ? path.join(iosDir, "Sources") : iosDir;
  const swiftFiles = walkFiles(scanRoot, [".swift"]);
  const reJsName = /\bjsName\s*=\s*"([^"]+)"/g;
  for (const f of swiftFiles) {
    const txt = readText(f);
    if (!txt.includes("jsName")) continue;
    let m;
    while ((m = reJsName.exec(txt))) iosJsNames.push(m[1]);
  }
  iosJsNames = uniq(iosJsNames);
}

// ---------------- Podspec/SPM ----------------
function parsePodspecName(podspecPath) {
  const txt = readText(podspecPath);
  const m = /\bs\.name\s*=\s*'([^']+)'/.exec(txt);
  return m ? m[1] : "";
}

function parseSpmNames(packageSwiftPath) {
  const txt = readText(packageSwiftPath);
  const pkg = /Package\(\s*name\s*:\s*"([^"]+)"/.exec(txt)?.[1] || "";
  const libs = [];
  const reLib = /\.library\(\s*name\s*:\s*"([^"]+)"/g;
  let m;
  while ((m = reLib.exec(txt))) libs.push(m[1]);
  return { pkgName: pkg, libNames: uniq(libs) };
}

// ---------------- Validate ----------------
const errors = [];

if (!jsName) {
  errors.push("JS: no registerPlugin('...') found under src/");
}

if (supportsAndroid) {
  if (!androidNames.length) errors.push("Android: missing @CapacitorPlugin(name = \"...\")");
  if (jsName && androidNames.length && androidNames.some((n) => n !== jsName)) {
    errors.push(`Android: @CapacitorPlugin(name)=${JSON.stringify(androidNames)} != JS registerPlugin=${jsName}`);
  }
}

if (supportsIos) {
  if (!iosJsNames.length) errors.push('iOS: missing jsName = "..." in Swift sources');
  if (jsName && iosJsNames.length && iosJsNames.some((n) => n !== jsName)) {
    errors.push(`iOS: jsName=${JSON.stringify(iosJsNames)} != JS registerPlugin=${jsName}`);
  }

  const podspecs = fs
    .readdirSync(pluginDir, { withFileTypes: true })
    .filter((e) => e.isFile() && e.name.endsWith(".podspec"))
    .map((e) => path.join(pluginDir, e.name))
    .sort();
  if (!podspecs.length) errors.push("iOS: missing *.podspec at plugin root");
  if (podspecs.length > 1) errors.push(`iOS: multiple podspecs at plugin root: ${podspecs.map((p) => path.basename(p))}`);

  const pkgSwift = path.join(pluginDir, "Package.swift");
  if (!exists(pkgSwift)) {
    errors.push("iOS: missing Package.swift at plugin root");
  } else if (podspecs.length) {
    const podName = parsePodspecName(podspecs[0]);
    const { pkgName, libNames } = parseSpmNames(pkgSwift);
    if (!podName) errors.push("Podspec: missing s.name = '...'");
    if (!pkgName) errors.push('SPM: missing Package(name: "...")');
    if (podName && pkgName && podName !== pkgName) {
      errors.push(`Podspec: s.name=${podName} != Package(name)=${pkgName}`);
    }
    if (pkgName && libNames.length && !libNames.includes(pkgName)) {
      errors.push(`SPM: Package(name)=${pkgName} not present in .library(name) list ${JSON.stringify(libNames)}`);
    }
  }
}

if (errors.length) {
  const relDir = path.relative(process.cwd(), pluginDir) || ".";
  console.error(`[wiring] FAIL in ${relDir}`);
  for (const e of errors) console.error(`- ${e}`);
  process.exit(1);
}

process.exit(0);
