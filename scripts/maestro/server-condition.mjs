import process from 'node:process';

const state = JSON.parse(process.argv[2] ?? '{}');
const debug = state.debug ?? {};
const downloads = debug.bundleDownloads ?? {};
const stats = debug.statsActionCounts ?? {};
const condition = process.argv[3] ?? 'false';

const evaluate = new Function(
  'state',
  'debug',
  'downloads',
  'stats',
  `return (${condition});`,
);

process.exit(evaluate(state, debug, downloads, stats) ? 0 : 1);
