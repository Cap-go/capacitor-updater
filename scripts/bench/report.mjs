// Build a markdown before/after comparison from the bench JSONL results.
//
// Usage: bun scripts/bench/report.mjs [--before before] [--after after] [--out .context/bench/report.md]
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { androidSize, iosSize } from './app-size.mjs';
import path from 'node:path';
import {
  benchDir,
  manifestSizes,
  modes,
  reuseKinds,
  reuseRatio,
  reuseSizes,
  shape,
  shapedSizes,
  variants,
  zipSizes,
} from './config.mjs';

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

  const has = (kinds) => [b, a].some((recs) => (recs ?? []).some((r) => kinds.includes(r.kind)));
  const medianOf = (recs, kind, sizeKey, variant, field) => {
    const vals = (recs ?? [])
      .filter((r) => r.ok && r.kind === kind && r.sizeKey === sizeKey && r.variant === variant && r[field] != null)
      .map((r) => r[field]);
    return stats(vals)?.median;
  };
  if (has(reuseKinds)) {
    lines.push(`#### Manifest reuse (background, ${Math.round(reuseRatio * 100)}% of the files already on the device)`);
    lines.push('');
    lines.push(
      '*delta cache*: version A with the same files was installed (untimed) right before B; only B is timed. ' +
        "*builtin*: the reused files ship in the app's builtin `public/`. " +
        '"Fetched" = payload requests the server saw for B (expected: new files + `index.html` + `bench.js`).',
    );
    lines.push('');
    lines.push('| Reuse from | Payload | Encryption | Before | After | Δ | Fetched before / after (expected) |');
    lines.push('|---|---|---|---|---|---|---|');
    for (const kind of reuseKinds) {
      for (const size of reuseSizes) {
        for (const variant of variants) {
          const pb = pick(b, kind, size.key, variant, 'background', 'totalMs');
          const pa = pick(a, kind, size.key, variant, 'background', 'totalMs');
          const fb = medianOf(b, kind, size.key, variant, 'requests');
          const fa = medianOf(a, kind, size.key, variant, 'requests');
          const exp =
            medianOf(a, kind, size.key, variant, 'expectedDownloads') ??
            medianOf(b, kind, size.key, variant, 'expectedDownloads');
          lines.push(
            `| ${kind === 'reuse-cache' ? 'delta cache' : 'builtin'} | ${size.files} files / ${size.key.split('-')[1].replace('MB', ' MB')} | ${variant === 'enc' ? 'on' : 'off'} | ${cell(pb.st, pb.failures)} | ${cell(pa.st, pa.failures)} | ${delta(pb.st, pa.st)} | ${fb ?? '-'} / ${fa ?? '-'} (${exp ?? '-'}) |`,
          );
        }
      }
    }
    lines.push('');
  }
  if (has(['shaped-zip', 'shaped-manifest'])) {
    lines.push(
      `#### Network-shaped (background, plain): ${shape.latencyMs} ms before every response, ${shape.mbit} Mbit/s total (shared token bucket)`,
    );
    lines.push('');
    lines.push(
      `The link alone needs ~${((20 * 1024 * 1024 * 8) / (shape.mbit * 1e6)).toFixed(1)} s for 20 MB and ~${((30 * 1024 * 1024 * 8) / (shape.mbit * 1e6)).toFixed(1)} s for 30 MB. ` +
        '"Link use" = payload bytes / total time, as a share of the cap.',
    );
    lines.push('');
    lines.push('| Payload | Before | After | Δ | Link use before / after | Peak parallel requests before / after |');
    lines.push('|---|---|---|---|---|---|');
    for (const size of shapedSizes) {
      const pb = pick(b, size.kind, size.key, 'plain', 'background', 'totalMs');
      const pa = pick(a, size.kind, size.key, 'plain', 'background', 'totalMs');
      const use = (p) =>
        p.st ? `${Math.round(((size.bytes * 8) / (p.st.median / 1000) / (shape.mbit * 1e6)) * 100)}%` : '-';
      const title =
        size.kind === 'shaped-zip'
          ? `zip ${size.key.replace('MB', ' MB')}`
          : `manifest ${size.files} files / ${size.key.split('-')[1].replace('MB', ' MB')}`;
      lines.push(
        `| ${title} | ${cell(pb.st, pb.failures)} | ${cell(pa.st, pa.failures)} | ${delta(pb.st, pa.st)} | ${use(pb)} / ${use(pa)} | ${medianOf(b, size.kind, size.key, 'plain', 'peakInFlight') ?? '-'} / ${medianOf(a, size.kind, size.key, 'plain', 'peakInFlight') ?? '-'} |`,
      );
    }
    lines.push('');
  }

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

// ---- app size ------------------------------------------------------------------
const kib = (n) =>
  n == null ? '-' : n >= 1024 * 1024 ? `${(n / 1024 / 1024).toFixed(2)} MiB` : `${(n / 1024).toFixed(1)} KiB`;
const sizeDelta = (x, y) => (x == null || y == null ? '-' : `${y - x >= 0 ? '+' : '-'}${kib(Math.abs(y - x))}`);
const ab = androidSize(before);
const aa = androidSize(after);
const ib = iosSize(before);
const ia = iosSize(after);
if (ab || aa || ib || ia) {
  lines.push('### App size (release bench builds, plain variant)');
  lines.push('');
  lines.push(
    "The bench app's web assets (`public/`, including the 180 MB builtin pad used by the reuse cases) are listed separately; the rows without web assets show the native footprint.",
  );
  lines.push('');
  if (ab || aa) {
    lines.push('#### Android (signed release APK, all ABIs)');
    lines.push('');
    lines.push('| | Before | After | Δ |');
    lines.push('|---|---|---|---|');
    lines.push(
      `| APK total | ${kib(ab?.apkBytes)} | ${kib(aa?.apkBytes)} | ${sizeDelta(ab?.apkBytes, aa?.apkBytes)} |`,
    );
    const noWeb = (x) => (x ? x.apkBytes - x.webCompressed : null);
    lines.push(
      `| APK without web assets | ${kib(noWeb(ab))} | ${kib(noWeb(aa))} | ${sizeDelta(noWeb(ab), noWeb(aa))} |`,
    );
    lines.push(
      `| classes*.dex (uncompressed) | ${kib(ab?.dexBytes)} | ${kib(aa?.dexBytes)} | ${sizeDelta(ab?.dexBytes, aa?.dexBytes)} |`,
    );
    const abis = [...new Set([...(ab?.libs ?? []), ...(aa?.libs ?? [])].map((l) => l.abi))].sort();
    for (const abi of abis) {
      const lb = ab?.libs.find((l) => l.abi === abi);
      const la = aa?.libs.find((l) => l.abi === abi);
      lines.push(
        `| lib/${abi}/libcapgo_updater_core.so (in APK) | ${lb ? `${kib(lb.size)} (${kib(lb.compressed)})` : '-'} | ${la ? `${kib(la.size)} (${kib(la.compressed)})` : '-'} | ${sizeDelta(lb?.size ?? 0, la?.size ?? 0)} |`,
      );
    }
    if (aa) {
      const dexDiff = (aa.dexBytes ?? 0) - (ab?.dexBytes ?? 0);
      const estimate = aa.arm64Gzip + dexDiff - (ab?.arm64Gzip ?? 0);
      lines.push('');
      lines.push(
        `Estimated per-device download change (arm64 split): gzip -9 of the arm64 \`.so\` (${kib(aa.arm64Gzip)}) ${dexDiff >= 0 ? '+' : '-'} dex difference (${kib(Math.abs(dexDiff))}) = **${estimate >= 0 ? '+' : '-'}${kib(Math.abs(estimate))}**.`,
      );
    }
    lines.push('');
  }
  if (ib || ia) {
    lines.push('#### iOS (Release simulator .app)');
    lines.push('');
    lines.push('| | Before | After | Δ |');
    lines.push('|---|---|---|---|');
    lines.push(
      `| .app total | ${kib(ib?.appBytes)} | ${kib(ia?.appBytes)} | ${sizeDelta(ib?.appBytes, ia?.appBytes)} |`,
    );
    const noWeb = (x) => (x ? x.appBytes - x.webBytes : null);
    lines.push(
      `| .app without web assets | ${kib(noWeb(ib))} | ${kib(noWeb(ia))} | ${sizeDelta(noWeb(ib), noWeb(ia))} |`,
    );
    lines.push(
      `| App executable (${ia?.exeArchs ?? ib?.exeArchs}) | ${kib(ib?.exeBytes)} | ${kib(ia?.exeBytes)} | ${sizeDelta(ib?.exeBytes, ia?.exeBytes)} |`,
    );
    lines.push(
      `| App executable, arm64 slice | ${kib(ib?.exeArm64Bytes)} | ${kib(ia?.exeArm64Bytes)} | ${sizeDelta(ib?.exeArm64Bytes, ia?.exeArm64Bytes)} |`,
    );
    const fws = [...new Set([...(ib?.frameworks ?? []), ...(ia?.frameworks ?? [])].map((f) => f.name))].sort();
    for (const name of fws) {
      const fb = ib?.frameworks.find((f) => f.name === name);
      const fa = ia?.frameworks.find((f) => f.name === name);
      lines.push(
        `| Frameworks/${name} | ${kib(fb?.bytes)} | ${kib(fa?.bytes)} | ${sizeDelta(fb?.bytes ?? 0, fa?.bytes ?? 0)} |`,
      );
    }
    if (!fws.length) lines.push('| Frameworks/ | (none) | (none) | - |');
    lines.push('');
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
