#!/usr/bin/env bun
const runId = process.argv[2];
if (!runId || !/^\d+$/.test(runId)) {
  console.error('Usage: bun scripts/ci/report-ios-job-budget.mjs <GitHub Actions run ID>');
  process.exit(1);
}

const headers = {
  Accept: 'application/vnd.github+json',
  'X-GitHub-Api-Version': '2022-11-28',
  'User-Agent': 'capgo-ios-job-budget',
};
const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
if (token) headers.Authorization = `Bearer ${token}`;

const jobs = [];
const signal = AbortSignal.timeout(60000);
try {
  for (let page = 1; ; page += 1) {
    const response = await fetch(
      `https://api.github.com/repos/Cap-go/capacitor-updater/actions/runs/${runId}/jobs?per_page=100&page=${page}`,
      { headers, signal, redirect: 'error' },
    );
    if (!response.ok) {
      throw new Error(
        `GitHub API returned HTTP ${response.status}. Set GH_TOKEN or GITHUB_TOKEN if authentication is needed.`,
      );
    }
    const result = await response.json();
    jobs.push(...result.jobs);
    if (result.jobs.length === 0 || jobs.length >= result.total_count) break;
  }
} catch (error) {
  console.error(error.message);
  process.exit(1);
}

/** Returns whole elapsed seconds, or '-' while an endpoint is unavailable. */
function seconds(start, end) {
  return start && end ? Math.round((Date.parse(end) - Date.parse(start)) / 1000) : '-';
}

console.log('job\tresult\ttotal_s\tbefore_tests_s\ttest_step_s\tafter_tests_s');
for (const job of jobs) {
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
