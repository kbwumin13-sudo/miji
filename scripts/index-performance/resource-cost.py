#!/usr/bin/env python3
"""Measure a signed app at idle, under a fixed filesystem event rate, and after drain."""

from __future__ import annotations

import argparse
import ctypes
import json
import math
import os
from pathlib import Path
from statistics import median
import subprocess
import time

from run import RUsage, ResourceProbe, Workload, command, mach_timebase, save_json


class ResourceWorkload(Workload):
    def __init__(self, output, label, fixture, app, watcher_ms, duration):
        super().__init__(output, label, fixture, app, 120, None, False, 0, 6, False)
        self.watcher_ms = watcher_ms
        self.duration = duration
        self.probe = ResourceProbe()
        self.timebase = mach_timebase()
        self.markers = self.report['phases'] = {}

    def counters(self):
        tree = self.probe.tree(self.process.pid)
        if not tree:
            raise RuntimeError("resource sampling lost the application process")
        host, *children = tree
        totals = RUsage()
        if self.probe.lib.proc_pid_rusage(self.process.pid, 4, ctypes.byref(totals)):
            raise RuntimeError("unable to read application wakeups")
        cpu_ticks = sum(host[key] for key in ('user_ticks', 'system_ticks', 'exited_children_user_ticks',
                                             'exited_children_system_ticks'))
        cpu_ticks += sum(row['user_ticks'] + row['system_ticks'] for row in children)
        metrics = {name: host[name] for name in ('logical_writes', 'disk_read_bytes', 'disk_write_bytes')}
        metrics['cpu_seconds'] = cpu_ticks * self.timebase['numerator'] / self.timebase['denominator'] / 1e9
        metrics['package_idle_wakeups'] = totals.package_idle_wakeups + totals.child_idle_wakeups
        metrics['interrupt_wakeups'] = totals.interrupt_wakeups + totals.child_interrupt_wakeups
        return {'uptime_ns': time.monotonic_ns(), 'counters': metrics, 'processes': tree,
                'footprint': sum(row['footprint_bytes'] for row in tree),
                'files': {file.name: file.stat().st_size for file in self.support.glob('index.sqlite*')
                          if file.is_file()}}

    def record_phase(self, name, collect, action=lambda _: 0):
        samples = [self.counters()]
        began = time.monotonic()
        operations = 0
        for tick in range(round(self.duration * 5)):
            deadline = began + (tick + 1) * 0.2
            operations += action(tick)
            time.sleep(max(0, deadline - time.monotonic()))
            samples.append(self.counters())
        before, after = samples[0], samples[-1]
        footprints = sorted(sample['footprint'] for sample in samples)
        self.markers[name] = {
            'seconds': (after['uptime_ns'] - before['uptime_ns']) / 1e9,
            'operations': operations,
            'samples': len(samples),
            'process_tree_peak_bytes': footprints[-1],
            'process_tree_p95_bytes': footprints[math.ceil(len(samples) * 0.95) - 1],
            'wal_peak_bytes': max(sample['files'].get('index.sqlite-wal', 0) for sample in samples),
            'delta': {key: after['counters'][key] - value for key, value in before['counters'].items()},
        }
        for sample in samples:
            collect.write(json.dumps({'phase': name, **sample}) + '\n')
        collect.flush()

    def settle(self):
        # A fixed quiet period crosses both variants' polling/coalescing windows.
        # Revision and inbox verification ensures the dirty work has drained.
        previous = None
        stable_since = time.monotonic()
        deadline = stable_since + 40
        while time.monotonic() < deadline:
            checkpoint = self.checkpoint() or {}
            revision = self.reader.execute('SELECT revision FROM catalog_state WHERE id=1').fetchone()[0]
            blocked = any(checkpoint.get(key) for key in ('pending', 'inFlight', 'interleaved', 'scan'))
            if revision != previous or blocked:
                previous, stable_since = revision, time.monotonic()
            if time.monotonic() - stable_since >= 5:
                return revision
            time.sleep(0.25)
        raise TimeoutError('catalog and durable inbox did not settle')

    def measure(self, bundle, log):
        event_paths = [self.root / ('zzmijiresource%04d.dat' % i) for i in range(round(self.duration * 5))]
        env = {key: value for key, value in os.environ.items() if not key.startswith('MIJI_')}
        env.update(MIJI_DATA_DIR=str(self.support), MIJI_INITIAL_ROOT=str(self.root), MIJI_UI_TESTING='1',
                   MallocSpaceEfficient='1')
        if self.watcher_ms is not None:
            env['MIJI_INDEX_EVENT_LATENCY_MS'] = str(self.watcher_ms)
        self.process = subprocess.Popen([bundle / 'Contents/MacOS/Miji'], env=env, stdout=log, stderr=log,
                                        cwd=self.output, start_new_session=True)
        self.report.update(pid=self.process.pid, override_latency_ms=self.watcher_ms, mach_timebase=self.timebase)
        try:
            self.wait('database opens', self.connect)
            self.wait('isolated root exists', self.read_root)
            handles = command(['lsof', '-a', '-p', str(self.process.pid), '-Fn'])
            (self.output / 'lsof.txt').write_text(handles)
            db_paths = {Path(line[1:]).resolve() for line in handles.splitlines()
                        if line.startswith('n/') and Path(line[1:]).name.startswith('index.sqlite')}
            self.check('only isolated index handles', self.db in db_paths and all(f.parent == self.support for f in db_paths))
            self.wait('initial scan finishes', self.scan_finished)
            self.settle()
            with (self.output / 'resource-phases.jsonl').open('w') as raw:
                self.record_phase('idle', raw)
                self.record_phase('event_storm', raw, lambda tick: write_event(event_paths[tick], tick))
                drain_start = time.monotonic()
                self.wait('all burst paths visible', lambda: self.reader.execute(
                    "SELECT count(*) FROM files WHERE root_id=? AND relative_path>=? AND relative_path<?",
                    (self.root_id, 'zzmijiresource', 'zzmijiresourcf')).fetchone()[0] == len(event_paths))
                self.report['storm_visibility_drain_seconds'] = time.monotonic() - drain_start
                self.settle()
                self.record_phase('after_drain', raw)
            self.report['terminal_records'] = self.reader.execute('SELECT count(*) FROM files').fetchone()[0]
            self.check('correct number of indexed rows after the storm',
                       self.report['terminal_records'] == self.fixture['expected_records'] + len(event_paths))
        finally:
            for path in event_paths:
                path.unlink(missing_ok=True)


def write_event(path, tick):
    path.write_text(str(tick))
    # A second event on a preceding path creates a controlled interleaving.
    if tick >= 3:
        sibling = path.with_name('zzmijiresource%04d.dat' % (tick - 3))
        sibling.write_text(str(tick) * 4)
        return 2
    return 1


def summary(runs):
    metrics = {}
    for label, group in runs.items():
        metrics[label] = {}
        for phase in ('idle', 'event_storm', 'after_drain'):
            phases = [run['phases'][phase] for run in group]
            metrics[label][phase] = {
                key: {'median': median(values), 'range': [min(values), max(values)]}
                for key, values in {
                    'peak_bytes': [p['process_tree_peak_bytes'] for p in phases],
                    'p95_bytes': [p['process_tree_p95_bytes'] for p in phases],
                    'wal_peak_bytes': [p['wal_peak_bytes'] for p in phases],
                    **{name: [p['delta'][name] for p in phases] for name in phases[0]['delta']},
                }.items()
            }
    return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workbench', type=Path)
    parser.add_argument('old', type=Path)
    parser.add_argument('final', type=Path)
    parser.add_argument('run_name')
    parser.add_argument('--rounds', type=int, default=2)
    parser.add_argument('--seconds', type=int, default=10)
    parser.add_argument('--workload', default='names-100000')
    parser.add_argument('--variant', action='append', choices=['old-1000ms','candidate-1000ms','candidate-500ms'])
    args = parser.parse_args()
    root = args.workbench.resolve()
    if not root.is_relative_to('/private/tmp') or Path(args.run_name).name != args.run_name:
        parser.error('an isolated /private/tmp workbench and simple run name are required')
    fixture = json.loads((root / 'fixtures.json').read_text())['workloads'][args.workload]
    out = root / args.run_name
    out.mkdir()
    variants = [('old-1000ms', args.old, None), ('candidate-1000ms', args.final, 1000),
                ('candidate-500ms', args.final, None)]
    if args.variant:
        variants = [variant for variant in variants if variant[0] in args.variant]
    runs = {label: [] for label, _, _ in variants}
    for round_index in range(args.rounds):
        order = variants if round_index % 2 == 0 else list(reversed(variants))
        for label, app, watcher_ms in order:
            folder = out / ('%02d-%s' % (round_index + 1, label))
            folder.mkdir()
            run = ResourceWorkload(folder, args.workload, fixture, app.resolve(), watcher_ms, args.seconds)
            print('resource', folder.name, flush=True)
            try:
                run.run()
            except Exception as error:
                run.report['error'] = str(error)
                raise
            finally:
                save_json(folder / 'result.json', run.report)
            runs[label].append(run.report)
    save_json(out / 'summary.json', {'workload': args.workload, 'rounds': args.rounds,
                                     'phase_seconds': args.seconds, 'metrics': summary(runs), 'runs': runs})


if __name__ == '__main__':
    main()
