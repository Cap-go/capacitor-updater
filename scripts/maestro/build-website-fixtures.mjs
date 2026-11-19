import { existsSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { artifactDir, repoRoot } from './scenarios.mjs';
import { runCommand } from './command.mjs';

const websiteRoot = path.join(artifactDir, 'website');
const tlsDir = path.join(websiteRoot, 'tls');
const sitesDir = path.join(websiteRoot, 'sites');

export async function ensureWebsiteFixtures() {
  await ensureTlsMaterial();
  await writeSites();
}

async function ensureTlsMaterial() {
  await mkdir(tlsDir, { recursive: true });

  const keyPath = path.join(tlsDir, 'key.pem');
  const certPath = path.join(tlsDir, 'cert.pem');
  const caPath = path.join(tlsDir, 'ca.pem');

  if (existsSync(keyPath) && existsSync(certPath) && existsSync(caPath)) {
    return { keyPath, certPath, caPath };
  }

  await runCommand(
    'openssl',
    [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-sha256',
      '-days',
      '3650',
      '-nodes',
      '-keyout',
      keyPath,
      '-out',
      certPath,
      '-subj',
      '/CN=Capgo Maestro Website/C=PT',
      '-addext',
      'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:10.0.2.2',
    ],
    { cwd: repoRoot },
  );

  await runCommand('cp', [certPath, caPath], { cwd: repoRoot });

  const rawDir = path.join(repoRoot, 'example-app/android/app/src/debug/res/raw');
  await mkdir(rawDir, { recursive: true });
  await runCommand('cp', [caPath, path.join(rawDir, 'maestro_website_ca.crt')], { cwd: repoRoot });

  return { keyPath, certPath, caPath };
}

async function writeSites() {
  await mkdir(path.join(sitesDir, 'good'), { recursive: true });
  await mkdir(path.join(sitesDir, 'fail'), { recursive: true });

  await writeFile(
    path.join(sitesDir, 'good', 'index.html'),
    `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Website Maestro Good</title>
    <script type="module" src="app.js"></script>
  </head>
  <body>
    <h1 id="website-maestro-good">Website Maestro Good</h1>
  </body>
</html>
`,
  );

  await writeFile(
    path.join(sitesDir, 'good', 'app.js'),
    `document.body.dataset.websiteMaestro = 'good';
`,
  );

  await writeFile(
    path.join(sitesDir, 'fail', 'index.html'),
    `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Website Maestro Fail</title>
    <script type="module" src="app.js"></script>
  </head>
  <body>
    <h1 id="website-maestro-fail">Website Maestro Fail</h1>
  </body>
</html>
`,
  );
}
