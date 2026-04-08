import { mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import {
  bundleArtifactDir,
  defaultDeviceBaseUrl,
  exampleAppDir,
  getBundleZipPath,
  repoRoot,
  scenarios,
} from './scenarios.mjs';

function runCommand(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: 'inherit',
    });

    child.on('exit', (code) => {
      if (code === 0) {
        resolve();
        return;
      }

      reject(new Error(`${command} ${args.join(' ')} failed with exit code ${code}`));
    });
  });
}

async function buildBundle({ scenarioId, directUpdate, release }) {
  const env = {
    ...process.env,
    VITE_CAPGO_APP_LABEL: release.label,
    VITE_CAPGO_SCENARIO: scenarioId,
    VITE_CAPGO_DIRECT_UPDATE: directUpdate,
    VITE_CAPGO_SERVER_URL: `${defaultDeviceBaseUrl}/api/updates/${scenarioId}`,
  };

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
