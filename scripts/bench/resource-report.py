#!/usr/bin/env python3
"""Join app-process samples to benchmark windows; retain raw timings and failures."""
import argparse
import bisect
import json
import statistics
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory', type=Path)
parser.add_argument('--samples', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()


def read_rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


rows = []
for path in sorted(args.directory.glob('results-*.jsonl')):
    for row in read_rows(path):
        if row.get('warmup'):
            continue
        samples_file = args.samples / f"resources-{row['label']}-{row['platform']}-{row['variant']}-r{row['run']}.jsonl"
        samples = read_rows(samples_file) if samples_file.exists() else []
        times = [sample['ts'] for sample in samples]
        start, end = row['hostStartedAt'], row['hostFinishedAt']
        lo = max(0, bisect.bisect_right(times, start) - 1)
        hi = min(len(samples), bisect.bisect_left(times, end) + 1)
        window = samples[lo:hi]
        if window and len(window) >= 2 and window[0]['pid'] == window[-1]['pid']:
            row['resources'] = {
                'samples': len(window),
                'cpuMs': window[-1]['cpuMs'] - window[0]['cpuMs'],
                'sampledPeakRssBytes': max(sample['rssBytes'] for sample in window),
                'startRssBytes': window[0]['rssBytes'],
                'boundaryOverhangMs': [start - window[0]['ts'], window[-1]['ts'] - end],
            }
            tail_index = bisect.bisect_left(times, end + 1500)
            if tail_index < len(samples) and samples[tail_index]['pid'] == window[0]['pid']:
                tail = samples[lo:tail_index + 1]
                row['resources']['cpuThroughSettleMs'] = tail[-1]['cpuMs'] - tail[0]['cpuMs']
                row['resources']['settleSampleOverhangMs'] = tail[-1]['ts'] - end - 1500
                row['resources']['sampledPeakRssBytes'] = max(sample['rssBytes'] for sample in tail)
                if 'footprintBytes' in tail[0]:
                    row['resources']['sampledPeakFootprintBytes'] = max(sample['footprintBytes'] for sample in tail)
            if 'threads' in window[0]:
                row['resources']['sampledPeakThreads'] = max(sample['threads'] for sample in window)
            if 'footprintBytes' in window[0]:
                row['resources']['sampledPeakFootprintBytes'] = max(sample['footprintBytes'] for sample in samples[lo:tail_index + 1] if sample['pid'] == window[0]['pid']) if tail_index < len(samples) else max(sample['footprintBytes'] for sample in window)
        rows.append(row)

groups = {}
for row in rows:
    key = (row['platform'], row['label'], row['variant'], row['kind'], row['sizeKey'])
    groups.setdefault(key, []).append(row)

summary = []
for key, group in groups.items():
    entry = dict(zip(['platform', 'label', 'variant', 'kind', 'sizeKey'], key))
    entry.update(attempts=len(group), successes=sum(bool(row['ok']) for row in group))
    for field, source in [('downloadMs', None), ('cpuMs', 'resources'), ('cpuThroughSettleMs', 'resources'), ('sampledPeakRssBytes', 'resources'),
                          ('sampledPeakFootprintBytes', 'resources'), ('sampledPeakThreads', 'resources')]:
        values = [(row if source is None else row.get(source, {})).get(field) for row in group if row['ok']]
        values = [value for value in values if value is not None]
        if values:
            entry[field] = {'n': len(values), 'median': statistics.median(values), 'min': min(values), 'max': max(values)}
    summary.append(entry)
args.output.write_text(json.dumps({'rows': rows, 'summary': summary}, indent=2) + '\n')
print(f'{len(rows)} attempts, {sum(bool(row["ok"]) for row in rows)} successful; {len(summary)} summary cells')
