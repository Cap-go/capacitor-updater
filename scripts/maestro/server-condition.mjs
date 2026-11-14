import process from 'node:process';

const state = JSON.parse(process.argv[2] ?? '{}');
const debug = state.debug ?? {};
const downloads = debug.bundleDownloads ?? {};
const stats = debug.statsActionCounts ?? {};
const conditions = new Map([
  ['downloads.aborted >= 1', () => downloads.aborted >= 1],
  ['downloads.ranged >= 1', () => downloads.ranged >= 1],
  ['downloads.dropped >= 1', () => downloads.dropped >= 1],
  ['downloads.inFlight >= 1', () => downloads.inFlight >= 1],
  ['downloads.faulted >= 1', () => downloads.faulted >= 1],
  ['downloads.served >= 1', () => downloads.served >= 1],
  ['downloads.started === 0', () => downloads.started === 0],
  ['debug.updateFaults >= 1', () => debug.updateFaults >= 1],
  ['(stats.checksum_fail ?? 0) >= 1', () => (stats.checksum_fail ?? 0) >= 1],
  ['(stats.update_check_error ?? 0) >= 1', () => (stats.update_check_error ?? 0) >= 1],
]);
const condition = conditions.get(process.argv[3]);
if (!condition) {
  console.error('Unknown fake-server condition');
  process.exit(2);
}
process.exit(condition() ? 0 : 1);
