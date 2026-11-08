#!/usr/bin/env node
/**
 * Run a small Maestro helper script with Node (macOS CI runners ship Node; avoids Bun install on Maestro-only jobs).
 */
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const scriptName = process.argv[2];
const scriptArgs = process.argv.slice(3);
const scriptPath = path.join(path.dirname(fileURLToPath(import.meta.url)), scriptName);

const result = spawnSync(process.execPath, [scriptPath, ...scriptArgs], {
  stdio: 'inherit',
});

process.exit(result.status ?? 1);
