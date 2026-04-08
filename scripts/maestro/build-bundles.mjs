import { mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import {
  bundleArtifactDir,
  createBuildEnv,
  exampleAppDir,
  getBundleZipPath,
  repoRoot,
  scenarios,
} from './scenarios.mjs';
import { runCommand } from './command.mjs';

async function buildBundle({ scenarioId, directUpdate, release }) {
  const env = createBuildEnv({
    scenarioId,
    directUpdate,
    appLabel: release.label,
  });

  await runCommand('bun', ['run', 'build'], {
    cwd: exampleAppDir,
    env,
  });

  await runCommand('zip', ['-qr', getBundleZipPath(release.version), '.'], {
    cwd: path.join(exampleAppDir, 'dist'),
  });
}

await rm(bundleArtifactDir, { force: true, recursive: true });
await mkdir(bundleArtifactDir, { recursive: true });
await runCommand('bun', ['run', 'build'], {
  cwd: repoRoot,
  env: process.env,
});
await runCommand('bun', ['install'], {
  cwd: exampleAppDir,
  env: process.env,
});

for (const scenario of Object.values(scenarios)) {
  for (const release of scenario.releases) {
    await buildBundle({
      scenarioId: scenario.id,
      directUpdate: scenario.directUpdate,
      release,
    });
  }
}
