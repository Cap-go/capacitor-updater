#!/usr/bin/env node
/**
 * Generate a release changelog with Cloudflare Workers AI in CI.
 * Invoked from build.yml on tag releases via `bun run changelog:ai`.
 */

import { execFileSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';

const DEFAULT_MODEL = '@cf/moonshotai/kimi-k2.7-code';

function parseArgs(argv) {
  const args = { fromTag: process.env.FROM_TAG, toTag: process.env.TO_TAG };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--from-tag') args.fromTag = argv[++i];
    if (argv[i] === '--to-tag') args.toTag = argv[++i];
    if (argv[i] === '--model') args.model = argv[++i];
  }
  return args;
}

function git(args) {
  return execFileSync('git', args, { encoding: 'utf8' }).trim();
}

function resolveTags({ fromTag, toTag }) {
  const currentTag =
    toTag ??
    (process.env.GITHUB_REF?.startsWith('refs/tags/')
      ? process.env.GITHUB_REF.replace('refs/tags/', '')
      : null);

  if (!currentTag) {
    throw new Error('Missing target tag. Set GITHUB_REF to refs/tags/<tag> or pass --to-tag.');
  }

  const previousTag = fromTag ?? git(['describe', '--tags', '--abbrev=0', `${currentTag}^`]);
  return { previousTag, currentTag };
}

function buildPrompt(previousTag, currentTag) {
  const commits = git(['log', `${previousTag}..${currentTag}`, '--pretty=format:%s']);
  const diffLines = git(['diff', '--stat', `${previousTag}..${currentTag}`]).split('\n');
  const diffStat = diffLines.at(-1)?.trim() ?? '';

  return `You are a technical writer creating a changelog for a software project.

There are changes in the git repository between two points:
- From tag: ${previousTag}
- To tag: ${currentTag}
- Commits:
${commits || '(none)'}
- Diff summary: ${diffStat || '(no file changes)'}

## Instructions:
1. **Categorize changes** using standard changelog categories:
   - **Added**: New features
   - **Changed**: Changes in existing functionality
   - **Deprecated**: Soon-to-be removed features
   - **Removed**: Removed features
   - **Fixed**: Bug fixes
   - **Security**: Security improvements

2. **Write clear, user-focused descriptions** that explain:
   - What changed from a user's perspective
   - Why it matters
   - Any breaking changes or migration notes

3. **Use consistent formatting**:
   - Each item should be a concise bullet point
   - Start with an action verb when possible
   - Group related changes together

4. **Focus on semantic meaning** rather than technical implementation details

Output ONLY the changelog content in markdown format. Do NOT include any explanatory text, metadata, introductory phrases like "Based on the git analysis" or "Here's the changelog", or concluding remarks. Start IMMEDIATELY with the changelog categories and items (e.g., "## Added"). Do not include version numbers or dates. Do not preface your response with any text whatsoever.`;
}

async function generateChangelog(prompt, model) {
  const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
  const apiToken = process.env.CLOUDFLARE_API_TOKEN;

  if (!accountId || !apiToken) {
    throw new Error('CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN are required.');
  }

  const url = `https://api.cloudflare.com/client/v4/accounts/${accountId}/ai/run/${model}`;
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      messages: [{ role: 'user', content: prompt }],
    }),
  });

  const payload = await response.json();
  if (!response.ok || !payload.success) {
    throw new Error(`Cloudflare AI request failed with status ${response.status}`);
  }

  const content = payload.result?.choices?.[0]?.message?.content ?? payload.result?.response;
  if (!content || typeof content !== 'string') {
    throw new Error('Cloudflare AI returned an empty changelog response');
  }

  return content.trim();
}

function writeGithubOutput({ result, fromTag, toTag }) {
  const outputFile = process.env.GITHUB_OUTPUT;
  if (!outputFile) return;

  const delimiter = `changelog_${Date.now()}`;
  appendFileSync(outputFile, `result<<${delimiter}\n${result}\n${delimiter}\n`);
  appendFileSync(outputFile, `from_tag=${fromTag}\n`);
  appendFileSync(outputFile, `to_tag=${toTag}\n`);
}

const args = parseArgs(process.argv.slice(2));
const model = args.model ?? process.env.CLOUDFLARE_AI_MODEL ?? DEFAULT_MODEL;
const { previousTag, currentTag } = resolveTags(args);
const prompt = buildPrompt(previousTag, currentTag);

console.error(`Generating changelog with ${model}`);
console.error(`Range: ${previousTag}..${currentTag}`);

try {
  const result = await generateChangelog(prompt, model);
  writeGithubOutput({ result, fromTag: previousTag, toTag: currentTag });
} catch (error) {
  const message = error instanceof Error ? error.message : 'Unknown error';
  console.error(`Changelog generation failed: ${message}`);
  process.exit(1);
}
