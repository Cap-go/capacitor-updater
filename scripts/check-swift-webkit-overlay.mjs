#!/usr/bin/env node
/**
 * Reject Swift WebKit overlay-only APIs in iOS plugin sources (libswiftWebKit.dylib).
 * See https://github.com/Cap-go/capacitor-updater/issues/1004
 *
 * Usage: node scripts/check-swift-webkit-overlay.mjs
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function parseArgs(argv) {
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--dir") {
      return path.resolve(argv[++i] || ".");
    }
  }
  return repoRoot;
}

const scanRoot = parseArgs(process.argv);
const iosSources = path.join(scanRoot, "ios", "Sources");

/** @type {{ id: string, pattern: RegExp, ignoreLine?: RegExp }[]} */
const RULES = [
  {
    id: "callAsyncJavaScript-overlay",
    pattern: /\bcallAsyncJavaScript\s*\(/,
    ignoreLine: /__callAsyncJavaScript\s*\(/,
  },
  {
    id: "evaluateJavaScript-contentWorld-overlay",
    pattern: /\bevaluateJavaScript\s*\([^)]*\bin\s*:/,
    ignoreLine: /completionHandler:\s*nil/,
  },
  {
    id: "createPDF-overlay",
    pattern: /\bcreatePDF\s*\(/,
  },
  {
    id: "createWebArchiveData-overlay",
    pattern: /\bcreateWebArchiveData\s*\(/,
  },
];

function walkSwiftFiles(dir) {
  const out = [];
  const stack = [dir];
  while (stack.length) {
    const current = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(full);
      } else if (entry.isFile() && entry.name.endsWith(".swift")) {
        out.push(full);
      }
    }
  }
  return out.sort();
}

function scanFile(filePath) {
  const lines = fs.readFileSync(filePath, "utf8").split(/\r?\n/);
  const hits = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trimStart();
    if (trimmed.startsWith("//") || trimmed.startsWith("*")) continue;
    for (const rule of RULES) {
      if (rule.ignoreLine?.test(line)) continue;
      if (rule.pattern.test(line)) {
        hits.push({ rule: rule.id, line: i + 1, text: line.trim() });
      }
    }
  }
  return hits;
}

function main() {
  if (!fs.existsSync(iosSources)) {
    console.error("[swift-webkit-overlay] ERROR: missing ios/Sources");
    process.exit(2);
  }

  const violations = [];
  for (const file of walkSwiftFiles(iosSources)) {
    for (const hit of scanFile(file)) {
      violations.push({
        ...hit,
        file: path.relative(scanRoot, file),
      });
    }
  }

  if (violations.length) {
    console.error("[swift-webkit-overlay] FAIL");
    for (const v of violations) {
      console.error(`- ${v.rule}: ${v.file}:${v.line}: ${v.text}`);
    }
    process.exit(1);
  }

  console.log("[swift-webkit-overlay] OK");
}

main();
