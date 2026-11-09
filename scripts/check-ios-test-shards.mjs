#!/usr/bin/env node
/**
 * Ensures every iOS XCTestCase class in CapacitorUpdaterPluginTests is listed in
 * a CI shard (-only-testing) in .github/workflows/test.yml, except excluded benches.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const testsDir = path.join(root, "ios/Tests/CapacitorUpdaterPluginTests");
const workflowPath = path.join(root, ".github/workflows/test.yml");

/** Timing-only; scripts/test-ios.sh skips it in CI via -skip-testing. */
const EXCLUDED = new Set(["InstallPerfTests"]);

/** Method-level core shards; see scripts/ci/ios-capacitor-updater-core-shard-args.sh */
const CORE_SHARD_SCRIPT = "ios-capacitor-updater-core-shard-args.sh";

const workflow = fs.readFileSync(workflowPath, "utf8");
const listed = new Set(
  [...workflow.matchAll(/-only-testing:CapacitorUpdaterPluginTests\/(\w+)/g)].map((m) => m[1])
);

const classRe = /(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase/g;
const missing = [];

for (const file of fs.readdirSync(testsDir).filter((f) => f.endsWith(".swift"))) {
  const text = fs.readFileSync(path.join(testsDir, file), "utf8");
  for (const match of text.matchAll(classRe)) {
    const name = match[1];
    if (EXCLUDED.has(name)) {
      continue;
    }
    if (name === "CapacitorUpdaterTests" && workflow.includes(CORE_SHARD_SCRIPT)) {
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
