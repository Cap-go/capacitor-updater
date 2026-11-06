#!/usr/bin/env bun
import { spawnSync } from 'node:child_process';

const runId = process.argv[2];
if (!runId || !/^\d+$/.test(runId)) {
  console.error('Usage: bun scripts/ci/report-ios-job-budget.mjs <GitHub Actions run ID>');
  process.exit(1);
}

const response = spawnSync(
  'gh',
  ['api', `repos/Cap-go/capacitor-updater/actions/runs/${runId}/jobs?per_page=100`, '--paginate', '--slurp'],
  { encoding: 'utf8' },
);
if (response.status !== 0) {
  console.error(response.error?.message ?? response.stderr);
  process.exit(1);
}

/** Returns whole elapsed seconds, or '-' while an endpoint is unavailable. */
function seconds(start, end) {
  return start && end ? Math.round((Date.parse(end) - Date.parse(start)) / 1000) : '-';
}

console.log('job\tresult\ttotal_s\tbefore_tests_s\ttest_step_s\tafter_tests_s');
for (const job of JSON.parse(response.stdout).flatMap((page) => page.jobs)) {
  if (job.name !== 'Build iOS native tests' && !job.name.startsWith('test_ios /')) continue;
  const tests = job.steps.find((step) => step.name.startsWith('Run iOS native tests'));
  console.log(
    [
      job.name,
      job.conclusion ?? job.status,
      seconds(job.started_at, job.completed_at),
      tests ? seconds(job.started_at, tests.started_at) : '-',
      tests ? seconds(tests.started_at, tests.completed_at) : '-',
      tests ? seconds(tests.completed_at, job.completed_at) : '-',
    ].join('\t'),
  );
}
