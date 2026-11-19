import process from 'node:process';

const state = JSON.parse(process.argv[2] ?? '{}');
const requestKind = process.argv[3] ?? '';
const count = state.debug?.requestCounts?.[requestKind] ?? 0;
console.log(String(count));
