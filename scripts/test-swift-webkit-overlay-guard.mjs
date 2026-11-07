#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const guardScript = path.join(repoRoot, "scripts/check-swift-webkit-overlay.mjs");

function runGuard(extraArgs = []) {
  return spawnSync(process.execPath, [guardScript, ...extraArgs], {
    encoding: "utf8",
  });
}

const ok = runGuard();
if (ok.status !== 0) {
  console.error("guard must pass on current tree");
  console.error(ok.stderr || ok.stdout);
  process.exit(1);
}

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "capgo-webkit-guard-"));
const fakeSources = path.join(tmpRoot, "ios", "Sources", "Evil");
fs.mkdirSync(fakeSources, { recursive: true });
fs.writeFileSync(
  path.join(fakeSources, "Bad.swift"),
  'webView.callAsyncJavaScript("x", arguments: [:], in: nil, in: .page) { _ in }\n',
  "utf8"
);

const bad = runGuard(["--dir", tmpRoot]);
if (bad.status === 0) {
  console.error("guard should fail when overlay API is present");
  process.exit(1);
}

console.log("test-swift-webkit-overlay-guard: OK");
