#!/usr/bin/env python3
"""Summarize authored comparison runs and their raw process-tree observations."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from math import ceil
from statistics import median

from run import mach_timebase


def resources(path: Path, timebase: dict) -> dict:
    samples = [json.loads(line) for line in path.read_text().splitlines()]
    samples = [sample for sample in samples if sample['processes']]
    if not samples:
        return {}
    last = samples[-1]
    host = last['processes'][0]
    cpu_ticks = sum(host.get(name + '_ticks', host.get(name + '_ns', 0)) for name in (
        'user', 'system', 'exited_children_user', 'exited_children_system'))
    seconds = cpu_ticks * timebase['numerator'] / timebase['denominator'] / 1e9
    helper_max = {}
    helper_executables = {}
    for sample in samples:
        for child in sample['processes'][1:]:
            key = (child['pid'], child['start_abstime'])
            helper_max[key] = max(helper_max.get(key, 0), child['disk_write_bytes'])
            helper_executables[key] = Path(child['exe']).name
    live_cpu = sum(child.get(counter + '_ticks', child.get(counter + '_ns', 0))
                   for child in last['processes'][1:] for counter in ('user', 'system'))
    seconds += live_cpu * timebase['numerator'] / timebase['denominator'] / 1e9
    return {
        'sample_count': len(samples), 'last_sample_seconds': last['seconds'],
        'process_tree_cpu_seconds': seconds, 'process_tree_cpu_percent_of_one_core': 100 * seconds / last['seconds'],
        'host_peak_footprint_bytes': host['lifetime_max_footprint_bytes'],
        'observed_tree_peak_footprint_bytes': max(sum(p['footprint_bytes'] for p in s['processes']) for s in samples),
        'host_physical_disk_write_bytes': host['disk_write_bytes'],
        'observed_helpers_disk_write_bytes_lower_bound': sum(helper_max.values()),
        'observed_distinct_child_pids': len(helper_max),
        'observed_distinct_miji_extract_pids': sum(name == 'miji-extract' for name in helper_executables.values()),
        'peak_concurrent_children_observed': max(len(sample['processes']) - 1 for sample in samples),
        'peak_index_sqlite_bytes': max(sample['file_bytes'].get('index.sqlite', 0) for sample in samples),
        'peak_wal_bytes': max(sample['file_bytes'].get('index.sqlite-wal', 0) for sample in samples),
    }


def stage_timings(path: Path, rounds: int) -> dict:
    times = {}
    for line in path.read_text().splitlines():
        sample = json.loads(line)
        for label, progress in sample.get('content_classes', {}).items():
            count = rounds * 3 if label == 'office' else rounds
            if progress['done'] > 0:
                times.setdefault(f'{label}_first_done_observed', sample['seconds'])
            if progress['done'] == count:
                times.setdefault(f'{label}_all_done_observed', sample['seconds'])
    return times


def window_stats(path: Path, phases: dict | None) -> dict | None:
    if not phases or not path.exists():
        return phases
    batches = {}
    for line in path.read_text().splitlines():
        event = json.loads(line)
        phase = batches.setdefault(event['operation'], {})
        round_id = event['round']
        phase[round_id] = max(phase.get(round_id, 0), event['elapsed_seconds'])
    return {op: {**values, 'batch_p95_seconds': sorted(batches[op].values())[ceil(len(batches[op]) * 0.95) - 1]}
            for op, values in phases.items()}


def collect(root: Path, variants: list[str]) -> dict:
    result = {}
    for label in variants:
        directory = root / label
        run = json.loads((directory / 'run.json').read_text())
        timebase = run.get('mach_timebase') or mach_timebase()
        for workload in run['workloads']:
            case = directory / workload
            report = json.loads((case / 'result.json').read_text())
            trace = case / 'resources.jsonl'
            metrics = resources(trace, timebase) if trace.exists() else {}
            timings = dict(report['timings_seconds'])
            if workload.startswith('names-') and 'metadata_scan_completed_observed' in timings:
                # All name runs use the same observation milestone. The root's
                # Date timestamp is retained in the raw per-run result only.
                timings.pop('metadata_scan_completed', None)
            if workload.startswith('mixed'):
                # The harness may only check this after the backlog mutation.
                # Compare the root's stored completion time, when available.
                timings.pop('metadata_scan_completed_observed', None)
                if trace.exists():
                    timings.update(stage_timings(trace, report['fixture']['directories']))
            result.setdefault(workload, []).append({
                'run': label, 'status': 'error' if 'error' in report else 'passed', 'error': report.get('error'),
                'checks': len(report['checks']), 'terminal': report.get('terminal'),
                'backlog_pending_at_start': report.get('backlog_pending_at_start'),
                'timings_seconds': timings, 'resources': metrics,
                'window_visibility': window_stats(case / 'window-transitions.jsonl', report.get('window_visibility')),
            })
    return result


def compare(baseline: dict, candidate: dict) -> dict:
    changes = {}
    for workload in baseline.keys() & candidate.keys():
        changes[workload] = {}
        for section in ('timings_seconds', 'resources'):
            lhs, rhs = {}, {}
            for source, target in ((baseline, lhs), (candidate, rhs)):
                for sample in source[workload]:
                    if sample['status'] == 'passed':
                        for metric, value in sample[section].items():
                            target.setdefault(metric, []).append(value)
            for key in sorted(lhs.keys() & rhs.keys()):
                old, new = median(lhs[key]), median(rhs[key])
                changes[workload][key] = {'baseline_median': old, 'candidate_median': new,
                                          'baseline_samples': len(lhs[key]), 'candidate_samples': len(rhs[key]),
                                          'candidate_delta_pct': 100 * (new - old) / old if old else None}
        lhs, rhs = {}, {}
        for source, target in ((baseline, lhs), (candidate, rhs)):
            for sample in source[workload]:
                for operation, data in (sample['window_visibility'] or {}).items():
                    target.setdefault(operation, []).append(data['p95_seconds'])
        for operation in sorted(lhs.keys() & rhs.keys()):
            old, new = median(lhs[operation]), median(rhs[operation])
            changes[workload][f'{operation}_window_p95_seconds'] = {
                'baseline_median': old, 'candidate_median': new, 'candidate_delta_pct': 100 * (new - old) / old,
                'baseline_samples': len(lhs[operation]), 'candidate_samples': len(rhs[operation]),
            }
    return changes


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workspace', type=Path)
    parser.add_argument('--baseline', nargs='+', required=True)
    parser.add_argument('--candidate', nargs='+', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    baseline = collect(args.workspace, args.baseline)
    candidate = collect(args.workspace, args.candidate)
    report = {'baseline': baseline, 'candidate': candidate, 'comparison': compare(baseline, candidate),
              'method_notes': ['CPU includes the host, reaped descendants and any children alive in the final sample.',
                               'Tree footprint and child disk writes are sampled lower bounds. Short children can finish between observations.',
                               'Run startup, GUI visibility, and CLI search process overhead are reported as separately named milestones.']}
    args.out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
