#!/usr/bin/env node
/**
 * Ensures every iOS XCTestCase class in CapacitorUpdaterPluginTests is listed in
 * a CI shard (-only-testing) in .github/workflows/test.yml, except excluded benches.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const testsDir = path.join(root, "ios/Tests/CapacitorUpdaterPluginTests");
const workflowPath = path.join(root, ".github/workflows/test.yml");

/** Timing-only; scripts/test-ios.sh skips it in CI via -skip-testing. */
const EXCLUDED = new Set(["InstallPerfTests"]);

const workflow = fs.readFileSync(workflowPath, "utf8");
const testIosBlock =
  workflow.match(/^  test_ios:[\s\S]*?(?=^  [a-zA-Z0-9_]+:)/m)?.[0] ?? "";
const activeTestIosLines = testIosBlock
  .split("\n")
  .filter((line) => {
    const trimmed = line.trim();
    return trimmed.length > 0 && !trimmed.startsWith("#");
  })
  .join("\n");
const listed = new Set(
  [...activeTestIosLines.matchAll(/-only-testing:CapacitorUpdaterPluginTests\/(\w+)/g)].map((m) => m[1])
);
const coreShards = [...activeTestIosLines.matchAll(
  /select_cmd:\s*scripts\/ci\/ios-capacitor-updater-core-shard-args\.sh (\S+)/g
)].map((match) => match[1]);

function checkCoreShardCoverage() {
  const source = fs.readFileSync(path.join(testsDir, "CapacitorUpdaterPluginTests.swift"), "utf8");
  const prefix = "-only-testing:CapacitorUpdaterPluginTests/CapacitorUpdaterTests/";
  const expected = new Set([...source.matchAll(/func\s+(test\w+)/g)].map((match) => prefix + match[1]));
  const counts = new Map();
  for (const shard of coreShards) {
    const output = execFileSync(path.join(root, "scripts/ci/ios-capacitor-updater-core-shard-args.sh"), [shard], {
      encoding: "utf8",
    });
    for (const test of output.trim().split("\n")) {
      counts.set(test, (counts.get(test) ?? 0) + 1);
    }
  }
  if (counts.size !== expected.size || [...expected].some((test) => counts.get(test) !== 1)) {
    throw new Error("Core CI shards must select every CapacitorUpdaterTests method exactly once.");
  }
  console.log(`Core shard coverage OK (${expected.size} tests across ${coreShards.length} shards).`);
}

if (coreShards.length > 0) {
  checkCoreShardCoverage();
}

const classRe = /(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase/g;
const missing = [];

for (const file of fs.readdirSync(testsDir).filter((f) => f.endsWith(".swift"))) {
  const text = fs.readFileSync(path.join(testsDir, file), "utf8");
  for (const match of text.matchAll(classRe)) {
    const name = match[1];
    if (EXCLUDED.has(name)) {
      continue;
    }
    if (name === "CapacitorUpdaterTests" && coreShards.length > 0) {
      continue;
    }
    if (!listed.has(name)) {
      missing.push(name);
    }
  }
}

if (missing.length > 0) {
  console.error(
    "iOS test classes missing from test.yml CI shards (add -only-testing or EXCLUDED if intentional):\n" +
      missing.map((c) => `  - ${c}`).join("\n")
  );
  process.exit(1);
}

console.log(`iOS test shard coverage OK (${listed.size} -only-testing entries, ${EXCLUDED.size} excluded).`);
