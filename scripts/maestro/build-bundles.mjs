import { createHash } from 'node:crypto';
import { cp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import {
  bundleArtifactDir,
  createBuildEnv,
  exampleAppDir,
  findScenario,
  getManifestDirectoryPath,
  getManifestMetadataPath,
  getBundleZipPath,
  manifestArtifactDir,
  repoRoot,
  scenarios,
} from './scenarios.mjs';
import { runCommand } from './command.mjs';

const scenarioSelection = process.argv[2]?.trim() || 'all';
const selectedScenarios =
  scenarioSelection === 'all'
    ? Object.values(scenarios)
    : [findScenario(scenarioSelection)].filter(Boolean);

if (!selectedScenarios.length) {
  throw new Error(`Unknown Maestro scenario selection: ${scenarioSelection}`);
}

async function buildBundle({ scenarioId, directUpdate, release }) {
  const env = createBuildEnv({
    scenarioId,
    directUpdate,
    appLabel: release.label,
    autoUpdate: release.autoUpdate ?? false,
    extraEnv: release.env ?? {},
  });

  await runCommand('bun', ['run', 'build'], {
    cwd: exampleAppDir,
    env,
  });

  await runCommand('zip', ['-qr', getBundleZipPath(release.version), '.'], {
    cwd: path.join(exampleAppDir, 'dist'),
  });

  await buildManifestArtifacts(release.version);
}

async function listFilesRecursively(rootDir, currentDir = rootDir) {
  const entries = await readdir(currentDir, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    const absolutePath = path.join(currentDir, entry.name);

    if (entry.isDirectory()) {
      files.push(...(await listFilesRecursively(rootDir, absolutePath)));
      continue;
    }

    const relativePath = path.relative(rootDir, absolutePath).replaceAll(path.sep, '/');
    files.push(relativePath);
  }

  return files.sort((left, right) => left.localeCompare(right));
}

async function buildManifestArtifacts(version) {
  const distDir = path.join(exampleAppDir, 'dist');
  const manifestDir = getManifestDirectoryPath(version);
  const manifestEntries = [];
  const files = await listFilesRecursively(distDir);

  await cp(distDir, manifestDir, {
    recursive: true,
    force: true,
  });

  for (const relativeFilePath of files) {
    const absoluteFilePath = path.join(distDir, relativeFilePath);
    const contents = await readFile(absoluteFilePath);
    const fileHash = createHash('sha256').update(contents).digest('hex');

    manifestEntries.push({
      file_name: relativeFilePath,
      file_hash: fileHash,
    });
  }

  await writeFile(getManifestMetadataPath(version), JSON.stringify({ files: manifestEntries }, null, 2));
}

await rm(bundleArtifactDir, { force: true, recursive: true });
await rm(manifestArtifactDir, { force: true, recursive: true });
await mkdir(bundleArtifactDir, { recursive: true });
await mkdir(manifestArtifactDir, { recursive: true });
await runCommand('bun', ['run', 'build'], {
  cwd: repoRoot,
  env: process.env,
});
await runCommand('bun', ['install'], {
  cwd: exampleAppDir,
  env: process.env,
});

for (const scenario of selectedScenarios) {
  for (const release of scenario.releases) {
    await buildBundle({
      scenarioId: scenario.id,
      directUpdate: scenario.directUpdate,
      release: {
        ...release,
        autoUpdate: scenario.autoUpdate,
        env: {
          ...(scenario.env ?? {}),
          ...(release.env ?? {}),
        },
      },
    });
  }
}
