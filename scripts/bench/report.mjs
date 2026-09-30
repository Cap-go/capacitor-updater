// Build a markdown before/after comparison from the bench JSONL results.
//
// Usage: bun scripts/bench/report.mjs [--before before] [--after after] [--out .context/bench/report.md]
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { benchDir, manifestSizes, modes, variants, zipSizes } from './config.mjs';

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? fallback : process.argv[i + 1];
}

const before = arg('before', 'before');
const after = arg('after', 'after');
const out = arg('out', path.join(benchDir, 'report.md'));
const note = arg('note', '');
const platforms = ['ios', 'android'];

function load(label, platform) {
  const file = path.join(benchDir, `results-${label}-${platform}.jsonl`);
  if (!existsSync(file)) return null;
  return readFileSync(file, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter((r) => r && !r.warmup && r.label === label && r.platform === platform);
}

function stats(values) {
  if (!values.length) return null;
  const s = [...values].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  const median = s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  return { median, min: s[0], max: s[s.length - 1], n: s.length };
}

function fmt(ms) {
  if (ms == null) return '-';
  if (ms < 1000) return `${Math.round(ms)} ms`;
  return `${(ms / 1000).toFixed(2)} s`;
}

function cell(st, failures) {
  if (!st) return failures ? `FAIL (${failures}x)` : 'n/a';
  const range = st.n > 1 ? ` (${fmt(st.min)}–${fmt(st.max)})` : '';
  const n = st.n < 3 ? ` n=${st.n}` : '';
  const f = failures ? ` +${failures} fail` : '';
  return `**${fmt(st.median)}**${range}${n}${f}`;
}

function delta(b, a) {
  if (!b || !a) return '-';
  const d = ((a.median - b.median) / b.median) * 100;
  const sign = d > 0 ? '+' : '';
  return `${sign}${d.toFixed(0)}%`;
}

const rowsDef = [
  ...zipSizes.map((s) => ({ kind: 'zip', sizeKey: s.key, title: `zip ${s.key.replace('MB', ' MB')}` })),
  ...manifestSizes.map((s) => ({
    kind: 'manifest',
    sizeKey: s.key,
    title: `manifest ${s.files} files / ${s.key.split('-')[1].replace('KB', ' KB').replace('MB', ' MB')}`,
  })),
];

function pick(records, kind, sizeKey, variant, mode, field) {
  if (!records) return { st: null, failures: 0 };
  const matching = records.filter(
    (r) => r.kind === kind && r.sizeKey === sizeKey && r.variant === variant && r.mode === mode,
  );
  const okVals = matching.filter((r) => r.ok && r[field] != null).map((r) => r[field]);
  const failures = matching.filter((r) => !r.ok && r.final).length;
  return { st: stats(okVals), failures };
}

const lines = [];
const failureNotes = [];
lines.push('## Live-update performance: native (before) vs Rust core (after)');
lines.push('');
lines.push(
  'Median of 3 runs, (min–max) in parentheses. Negative delta = after is faster. ' +
    '*background* = JS `download()` call until it resolves (download + verify + decrypt + unzip/assemble). ' +
    '*direct* = `download()` + `set()` until the new bundle has called `notifyAppReady()` (bench HTTP calls excluded). ' +
    'Payloads are random (incompressible) bytes served from a local bun server on the host; manifest files are unique per run so nothing is reused from builtin or the delta cache. ' +
    'Warm-up cases are excluded.',
);
lines.push('');
if (note) {
  lines.push(note);
  lines.push('');
}

for (const platform of platforms) {
  const b = load(before, platform);
  const a = load(after, platform);
  if (!b && !a) continue;
  const platformTitle = platform === 'ios' ? 'iOS simulator (iPhone 17 Pro)' : 'Android emulator (API 36, arm64)';
  lines.push(`### ${platformTitle}`);
  lines.push('');
  for (const mode of modes) {
    lines.push(
      `#### ${mode === 'background' ? 'Background (download ready)' : 'Direct (download + set until app ready)'}`,
    );
    lines.push('');
    lines.push('| Payload | Encryption | Before | After | Δ |');
    lines.push('|---|---|---|---|---|');
    for (const row of rowsDef) {
      for (const variant of variants) {
        const pb = pick(b, row.kind, row.sizeKey, variant, mode, 'totalMs');
        const pa = pick(a, row.kind, row.sizeKey, variant, mode, 'totalMs');
        lines.push(
          `| ${row.title} | ${variant === 'enc' ? 'on' : 'off'} | ${cell(pb.st, pb.failures)} | ${cell(pa.st, pa.failures)} | ${delta(pb.st, pa.st)} |`,
        );
      }
    }
    lines.push('');
  }
  lines.push('<details><summary>Direct mode breakdown (download vs set() → app ready)</summary>');
  lines.push('');
  lines.push('| Payload | Encryption | Download before | Download after | Apply before | Apply after |');
  lines.push('|---|---|---|---|---|---|');
  for (const row of rowsDef) {
    for (const variant of variants) {
      const db = pick(b, row.kind, row.sizeKey, variant, 'direct', 'downloadMs').st;
      const da = pick(a, row.kind, row.sizeKey, variant, 'direct', 'downloadMs').st;
      const ab = pick(b, row.kind, row.sizeKey, variant, 'direct', 'applyMs').st;
      const aa = pick(a, row.kind, row.sizeKey, variant, 'direct', 'applyMs').st;
      lines.push(
        `| ${row.title} | ${variant === 'enc' ? 'on' : 'off'} | ${fmt(db?.median)} | ${fmt(da?.median)} | ${fmt(ab?.median)} | ${fmt(aa?.median)} |`,
      );
    }
  }
  lines.push('');
  lines.push('</details>');
  lines.push('');
  for (const [label, recs] of [
    [before, b],
    [after, a],
  ]) {
    // Group failed attempts per cell; normalise file names/urls so identical causes collapse.
    const groups = new Map();
    for (const r of (recs ?? []).filter((x) => !x.ok)) {
      const key = `${r.kind} ${r.sizeKey} ${r.variant} ${r.mode}`;
      const g = groups.get(key) ?? { attempts: 0, finals: 0, errors: new Set() };
      g.attempts += 1;
      if (r.final) g.finals += 1;
      g.errors.add(
        String(r.error)
          .replace(/https?:\/\/\S+/g, '<url>')
          .replace(/pad\/d\d+\/f\d+\.bin/g, '<file>'),
      );
      groups.set(key, g);
    }
    for (const [key, g] of groups) {
      failureNotes.push(
        `- ${platform} ${label} \`${key}\`: ${g.attempts} failed attempts, ${g.finals} run(s) lost. Errors: ${[...g.errors].map((e) => `\`${e}\``).join('; ')}`,
      );
    }
  }
}

if (failureNotes.length) {
  lines.push('### Failed attempts');
  lines.push('');
  lines.push(...failureNotes);
  lines.push('');
}

writeFileSync(out, `${lines.join('\n')}\n`);
console.log(lines.join('\n'));
console.error(`\n[bench] report written to ${out}`);
