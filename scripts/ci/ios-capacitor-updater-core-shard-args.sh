#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_FILE="$ROOT_DIR/ios/Tests/CapacitorUpdaterPluginTests/CapacitorUpdaterPluginTests.swift"
SHARD="${1:-}"

if [[ "$SHARD" != "a" && "$SHARD" != "b" && "$SHARD" != "c" ]]; then
  echo "usage: $0 a|b|c" >&2
  exit 1
fi

node --input-type=module - "$TEST_FILE" "$SHARD" <<'EOF'
import fs from 'node:fs'

const [testFile, shard] = process.argv.slice(2)
const text = fs.readFileSync(testFile, 'utf8')
const tests = [...text.matchAll(/func\s+(test[A-Za-z0-9_]+)/g)].map((m) => m[1])
const shards = ['a', 'b', 'c']
const shardIndex = shards.indexOf(shard)
const selected = tests.filter((_, index) => index % shards.length === shardIndex)
if (selected.length === 0) {
  console.error(`No tests selected for core shard ${shard}`)
  process.exit(1)
}
for (const name of selected) {
  console.log(`-only-testing:CapacitorUpdaterPluginTests/CapacitorUpdaterTests/${name}`)
}
EOF
