#!/usr/bin/env python3
"""Measure watcher, SQLite, name publication and AX from a frozen names fixture."""
from __future__ import annotations

import argparse
from contextlib import ExitStack
import fcntl
import json
from math import ceil
import os
from pathlib import Path
import signal
from statistics import median
import subprocess
import threading
import time

from run import Workload, command, mach_timebase, sample_resources, save_json
from summarize import resources
import window

QUERY = 'zzbenchmarkmillion'
ANCHOR = f'{QUERY}anchor.dat'
OPERATIONS = ('add', 'rename', 'delete')
SAMPLE_INTERVAL = 0.25


def now_ns() -> int:
    return time.monotonic_ns()


class Trace:
    def __init__(self, path: Path, process: subprocess.Popen):
        self.path = path
        self.process = process
        self.stream = None
        self.partial = ''
        self.records = []

    def __enter__(self):
        return self

    def __exit__(self, *_):
        if self.stream:
            self.stream.close()

    def drain(self):
        if not self.stream:
            try:
                self.stream = self.path.open()
            except FileNotFoundError:
                return
        lines = (self.partial + self.stream.read()).split('\n')
        self.records.extend(json.loads(line) for line in lines[:-1] if line)
        self.partial = lines[-1]

    def wait(self, label, evaluate, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(f'app exited while waiting for {label}: {self.process.returncode}')
            self.drain()
            match = evaluate()
            if match is not None:
                return match
            time.sleep(0.005)
        raise TimeoutError(f'{label} did not occur within {timeout}s in {self.path}')

    def first(self, phase, since, timeout, predicate=lambda _: True):
        return self.wait(phase, lambda: next((
            row for row in self.records
            if row['phase'] == phase and row['uptime_ns'] >= since and predicate(row)
        ), None), timeout)


def comparable_path(path: str | None) -> str | None:
    if path is None:
        return None
    data_mount = '/System/Volumes/Data'
    if path.startswith(data_mount + '/'):
        path = path[len(data_mount):]
    if path.startswith('/private/tmp/'):
        path = path[len('/private'):]
    return path


def source_paths(number: int) -> tuple[str, str]:
    return f'{QUERY}{number:03d}a.dat', f'{QUERY}{number:03d}r.dat'


def join_stages(records: list[dict], root: Path, change: dict) -> list[dict] | None:
    """A rename joins both the committed destination and the pruned source."""
    started = change['operation_completed_uptime_ns']
    event_map = {}
    commit_map = {}
    for effect in ('present', 'absent'):
        if effect not in change['condition']:
            continue
        path = comparable_path(str(root / change['condition'][effect]))
        event = next((row for row in records if row['phase'] == 'event' and comparable_path(row.get('path')) == path
                      and row['uptime_ns'] >= started), None)
        if event is None:
            return None
        event_map[effect] = event
        for row in records:
            if (row['phase'] != 'commit' or row['uptime_ns'] < event['uptime_ns']
                    or row['revision'] <= row['previous_revision']):
                continue
            if effect == 'present' and row['operation'] == 'upsert' and path in map(comparable_path, row.get('paths', ())):
                commit_map[effect] = row
                break
            if effect == 'absent' and row['operation'] == 'prune' and comparable_path(row.get('path')) == path:
                commit_map[effect] = row
                break
        else:
            return None
    revision = max(row['revision'] for row in commit_map.values())
    committed = max(row['uptime_ns'] for row in commit_map.values())
    publish = next((row for row in records if row['phase'] == 'publish' and row['revision'] >= revision
                    and row['uptime_ns'] >= committed), None)
    if publish is None:
        return None
    receipt = max(row['uptime_ns'] for row in event_map.values())
    return {'events': event_map, 'commits': commit_map, 'publication': publish,
            'event_received_uptime_ns': receipt, 'database_committed_uptime_ns': committed,
            'name_published_uptime_ns': publish['uptime_ns']}


def write_row(stream, row):
    stream.write(json.dumps(row, ensure_ascii=False) + '\n')


class Million(Workload):
    def __init__(self, output, fixture, app, args, stable_batches, source_digest):
        gui = {'executable': args.gui_probe, 'query': QUERY, 'scope': 'name'}
        super().__init__(output, output.name, fixture, app, args.scan_timeout, gui, False, 0, 1, False)
        self.args = args
        self.stable_batches = stable_batches
        self.source_digest = source_digest
        self.live = source_paths(0)
        self.written = set()
        self.transitions = []
        self.previous_callback_batches = set()

    def prepare_fixture(self):
        if any(self.root.glob(f'{QUERY}*')):
            raise RuntimeError(f'benchmark paths already exist under {self.root}')
        for filename in (ANCHOR, *self.live):
            self.touch(filename)

    def touch(self, name):
        (self.root / name).touch(exist_ok=False)
        self.written.add(name)

    def run(self):
        try:
            super().run()
        finally:
            for filename in self.written:
                (self.root / filename).unlink(missing_ok=True)

    def require_idle(self, since, revision=None):
        end = self.trace.first('idle', since, self.args.transition_timeout)
        if revision is not None:
            self.trace.first('publish', since, self.args.transition_timeout, lambda row: row['revision'] >= revision)
        checkpoint = self.checkpoint() or {}
        self.check('background scheduler idle with clean scan and no pending extraction',
                   bool(checkpoint) and not any(checkpoint.get(key) for key in ('pending', 'inFlight', 'scan', 'interleaved', 'deferredRetry'))
                   and self.pending() == 0, checkpoint=checkpoint, uptime_ns=end['uptime_ns'])
        return end['uptime_ns']

    def ax(self, conditions) -> dict:
        return window.probe(self.gui['executable'], self.process.pid, QUERY, ANCHOR, conditions,
                            self.args.transition_timeout)

    def batch(self, phase, number, trigger, mutations, transitions):
        added, renamed = source_paths(number)
        rename_source, delete_source = self.live
        changes = []
        for operation in OPERATIONS:
            submitted = now_ns()
            if operation == 'add':
                self.touch(added)
                condition = {'present': added}
            elif operation == 'rename':
                (self.root / rename_source).rename(self.root / renamed)
                self.written.add(renamed)
                condition = {'present': renamed, 'absent': rename_source}
            else:
                (self.root / delete_source).unlink()
                condition = {'absent': delete_source}
            completed = now_ns()
            changes.append({'phase': phase, 'trial': self.label, 'batch': number, 'operation': operation,
                            'condition': {'id': operation, **condition}, 'operation_started_uptime_ns': submitted,
                            'operation_completed_uptime_ns': completed, 'phase_trigger_uptime_ns': trigger,
                            'trigger_to_operation_ms': (submitted - trigger) / 1e6})
        self.live = (added, renamed)
        for change in changes:
            write_row(mutations, change)
        if phase == 'just_after_scan':
            self.check('all mutations issued promptly after the real root scan completion',
                       max(change['trigger_to_operation_ms'] for change in changes) <= self.args.immediate_ms,
                       limit_ms=self.args.immediate_ms, actual_ms=[change['trigger_to_operation_ms'] for change in changes])
        observed = self.ax([change['condition'] for change in changes])
        def resolve():
            rows = [join_stages(self.trace.records, self.root, change) for change in changes]
            return rows if all(row is not None for row in rows) else None

        joined = self.trace.wait(f'{phase} batch {number} event, commit and publication', resolve,
                                 self.args.transition_timeout)
        callbacks = {event['batch'] for rows in joined for event in rows['events'].values()}
        self.check('watcher callback batches do not overlap earlier trials',
                   callbacks.isdisjoint(self.previous_callback_batches), number=number, callback_ids=sorted(callbacks))
        self.previous_callback_batches.update(callbacks)
        for change, stages in zip(changes, joined, strict=True):
            ax_visible = observed['visible_at_uptime_ns'][change['operation']]
            clock = [change['operation_completed_uptime_ns'], stages['event_received_uptime_ns'],
                     stages['database_committed_uptime_ns'], stages['name_published_uptime_ns'], ax_visible]
            row = {**change, **stages, 'ax_visible_uptime_ns': ax_visible, 'ax_polls': observed['polls'],
                   'latency_ms': {metric: (clock[end] - clock[start]) / 1e6
                                  for metric, start, end in (
                                      ('operation_to_event', 0, 1), ('event_to_commit', 1, 2),
                                      ('commit_to_name_publish', 2, 3), ('name_publish_to_ax', 3, 4),
                                      ('operation_to_commit', 0, 2), ('operation_to_name_publish', 0, 3),
                                      ('operation_to_ax', 0, 4))}}
            write_row(transitions, row)
            self.transitions.append(row)
            self.check('operation, FSEvents, SQLite commit, publish and AX timestamps are ordered',
                       clock == sorted(clock), operation=change['operation'], clock=clock)
            for effect in ('present', 'absent'):
                name = change['condition'].get(effect)
                if name is not None:
                    self.check('committed SQLite state matches observed AX rows', bool(self.file(name)) == (effect == 'present'),
                               operation=change['operation'], effect=effect, name=name)
        print(self.label, phase, number, 'AX ms',
              [round(row['latency_ms']['operation_to_ax']) for row in self.transitions[-3:]], flush=True)
        last_commit = max(row['database_committed_uptime_ns'] for row in joined)
        return self.require_idle(last_commit)

    def measure(self, bundle: Path, log):
        self.started_ns = now_ns()
        trace_path = self.output / 'index-trace.jsonl'
        env = {key: value for key, value in os.environ.items() if not key.startswith('MIJI_')}
        env.update(MIJI_DATA_DIR=str(self.support), MIJI_INITIAL_ROOT=str(self.root), MIJI_UI_TESTING='1',
                   MIJI_UI_QUERY=QUERY, MIJI_UI_SCOPE='name', MIJI_UI_PREVIEW='hidden',
                   MIJI_INDEX_TRACE_FILE=str(trace_path), MIJI_INDEX_TRACE_PATH_PREFIX=str(self.root / QUERY),
                   MIJI_INDEX_EVENT_LATENCY_MS=str(self.args.watcher_ms), MallocSpaceEfficient='1')
        self.process = subprocess.Popen([bundle / 'Contents/MacOS/Miji'], env=env, stdout=log, stderr=log,
                                        cwd=self.output, start_new_session=True)
        self.report.update(pid=self.process.pid, source_app_executable_sha256=self.source_digest,
                           started_uptime_ns=self.started_ns, stable_batches=self.stable_batches, resource_windows={})
        cpu_path = self.output / 'resources.jsonl'
        sampler = threading.Thread(target=sample_resources, args=(self.stop, self.started_ns / 1e9, self.process.pid,
                                                                  self.db, cpu_path, False), daemon=True)
        sampler.start()
        windows = self.report['resource_windows']
        try:
            with ExitStack() as stack:
                self.trace = stack.enter_context(Trace(trace_path, self.process))
                mutations = stack.enter_context((self.output / 'mutations.jsonl').open('w', buffering=1))
                transitions = stack.enter_context((self.output / 'transitions.jsonl').open('w', buffering=1))
                self.wait('isolated SQLite opens', self.connect)
                self.wait('configured isolated indexing root', self.read_root)
                self.verify_handles()
                watcher = self.trace.first('watching', self.started_ns, self.args.transition_timeout)
                self.report['watcher'] = watcher
                self.check('actual FSEvents stream watches only the frozen root at the requested latency',
                           watcher['latency_ms'] == self.args.watcher_ms
                           and list(map(comparable_path, watcher['paths'])) == [comparable_path(str(self.root))],
                           watcher=watcher, requested_latency_ms=self.args.watcher_ms)
                self.report['initial_ax'] = self.ax([{'id': name, 'present': name} for name in self.live])
                scan = self.trace.first('scan_finished', self.started_ns, self.args.scan_timeout,
                                        lambda row: comparable_path(row['path']) == comparable_path(str(self.root)) and row['complete'])
                self.report['scan_finished'] = scan
                windows['initial_scan'] = [self.started_ns, scan['uptime_ns']]
                idle = self.batch('just_after_scan', 1, scan['uptime_ns'], mutations, transitions)
                windows['just_after_scan'] = [scan['uptime_ns'], now_ns()]
                self.report['after_first_batch_idle_uptime_ns'] = idle
                if self.stable_batches:
                    time.sleep(self.args.settle_seconds)
                    quiet_start = now_ns()
                    time.sleep(self.args.idle_seconds)
                    quiet_end = now_ns()
                    windows['no_mutations_idle'] = [quiet_start, quiet_end]
                    idle = quiet_end
                    for number in range(2, self.stable_batches + 2):
                        idle = self.batch('quiescent', number, idle, mutations, transitions)
                    windows['quiescent_mutations'] = [quiet_end, now_ns()]
                expected = self.fixture['expected_records'] + 3
                actual = self.reader.execute('SELECT count(*) FROM files').fetchone()[0]
                self.check('final SQLite row count matches the frozen fixture and the three live AX rows',
                           actual == expected, actual=actual, expected=expected)
                self.check('the fixed AX anchor still has indexed SQLite metadata', bool(self.file(ANCHOR)))
        finally:
            # Capture at least one sample after the last measured transition.
            time.sleep(SAMPLE_INTERVAL)
            self.stop.set()
            sampler.join(timeout=3)
            if cpu_path.is_file():
                self.report['resources'] = resources(cpu_path, mach_timebase())
                self.report['resource_metrics_by_window'] = resource_windows(cpu_path, self.started_ns, windows)


def resource_windows(path, launch, windows):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    rows = [row for row in rows if row['processes']]
    timebase = mach_timebase()
    seconds_per_tick = timebase['numerator'] / timebase['denominator'] / 1e9
    counters = ('package_idle_wakeups', 'interrupt_wakeups', 'disk_read_bytes', 'disk_write_bytes', 'logical_writes')
    by_window = {}
    for name, (start, end) in windows.items():
        samples = [row for row in rows if start <= launch + int(row['seconds'] * 1e9) <= end]
        if len(samples) < 2:
            by_window[name] = {'samples': len(samples)}
            continue
        first = samples[0]['processes'][0]
        last = samples[-1]['processes'][0]
        elapsed = samples[-1]['seconds'] - samples[0]['seconds']
        cpu = seconds_per_tick * sum(last[key] - first[key] for key in (
            'user_ticks', 'system_ticks', 'exited_children_user_ticks', 'exited_children_system_ticks'))
        by_window[name] = {'samples': len(samples), 'sampled_seconds': elapsed, 'host_and_reaped_children_cpu_seconds': cpu,
                           'cpu_percent_of_one_core': 100 * cpu / elapsed,
                           'median_host_footprint_bytes': median(row['processes'][0]['footprint_bytes'] for row in samples),
                           'peak_host_footprint_bytes': max(row['processes'][0]['footprint_bytes'] for row in samples),
                           'last_file_bytes': samples[-1]['file_bytes'],
                           **{key: last[key] - first[key] for key in counters}}
    return by_window


def summarize(rows):
    stats = {}
    for phase in ('just_after_scan', 'quiescent'):
        stats[phase] = {}
        for operation in OPERATIONS:
            samples = [row for row in rows if row['phase'] == phase and row['operation'] == operation]
            if not samples:
                continue
            stats[phase][operation] = {'independent_trial_batches': len(samples),
                                       'cold_launches': len({row['trial'] for row in samples}),
                                       'metrics_ms': {}}
            for key in samples[0]['latency_ms']:
                values = sorted(row['latency_ms'][key] for row in samples)
                rank = ceil(0.95 * len(values))
                stats[phase][operation]['metrics_ms'][key] = {'p50': median(values), 'p95': values[rank - 1],
                                                               'p95_rank': rank, 'max': values[-1]}
    return stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workspace', type=Path)
    parser.add_argument('app', type=Path, help='Signed isolated-build input app inside the benchmark workspace')
    parser.add_argument('variant', help='New result directory name')
    parser.add_argument('--source', required=True)
    parser.add_argument('--gui-probe', required=True, type=Path)
    parser.add_argument('--watcher-ms', choices=(500, 1000), type=int, required=True)
    parser.add_argument('--cold-runs', type=int, default=2)
    parser.add_argument('--stable-batches', type=int, default=20)
    parser.add_argument('--scan-timeout', type=float, default=150)
    parser.add_argument('--transition-timeout', type=float, default=15)
    parser.add_argument('--immediate-ms', type=float, default=100)
    parser.add_argument('--settle-seconds', type=float, default=2)
    parser.add_argument('--idle-seconds', type=float, default=6)
    parser.add_argument('--fixture', default='names-1000000', choices=('names-1000000', 'names-100000'),
                        help='Use the existing 100k fixture only for harness smoke tests')
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    args.app = args.app.resolve()
    args.gui_probe = args.gui_probe.resolve()
    if not workspace.is_relative_to(Path('/private/tmp')) or not args.app.is_relative_to(workspace):
        parser.error('use a workspace under /private/tmp and an app inside that workspace')
    if not args.variant or Path(args.variant).name != args.variant or args.variant in ('.', '..'):
        parser.error('variant must be a new directory name')
    if args.cold_runs < 1 or args.stable_batches < 0 or min(args.scan_timeout, args.transition_timeout, args.immediate_ms) <= 0:
        parser.error('positive runs, timeouts and immediate threshold and nonnegative stable batch count are required')
    if args.settle_seconds < 0 or args.idle_seconds < 2 * SAMPLE_INTERVAL:
        parser.error('idle interval must contain at least two resource samples')
    manifest = json.loads((workspace / 'fixtures.json').read_text())
    fixture = manifest['workloads'][args.fixture]
    root = Path(fixture['path']).resolve()
    expected_root = workspace / 'roots' / args.fixture
    if root != expected_root:
        parser.error(f'fixture root must be {expected_root}')
    command(['codesign', '--verify', '--deep', '--strict', args.app])
    digest = command(['shasum', '-a', '256', args.app / 'Contents/MacOS/Miji']).split()[0]
    before = now_ns()
    observed = int(command([args.gui_probe, 'clock']).strip())
    after = now_ns()
    if not before <= observed <= after:
        raise RuntimeError('Swift DispatchTime and Python monotonic_ns do not share the expected timebase')
    with (workspace / f'.{args.fixture}.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = workspace / args.variant
        result.mkdir()
        report = {'source': args.source, 'app': str(args.app), 'executable_sha256': digest, 'fixture': fixture,
                  'requested_watcher_ms': args.watcher_ms, 'configured_cold_runs': args.cold_runs,
                  'configured_stable_batches': args.stable_batches, 'sample_interval_seconds': SAMPLE_INTERVAL,
                  'clock_calibration_uptime_ns': [before, observed, after], 'mach_timebase': mach_timebase(),
                  'system': command(['sw_vers']).strip(),
                  'hardware': command(['sysctl', '-n', 'hw.model', 'hw.memsize', 'hw.ncpu']).split(),
                  'runs': []}
        rows = []
        try:
            for repeat in range(1, args.cold_runs + 1):
                output = result / f'cold-{repeat:02d}'
                output.mkdir()
                count = args.stable_batches if repeat == args.cold_runs else 0
                workload = Million(output, fixture, args.app, args, count, digest)
                try:
                    workload.run()
                    rows.extend(workload.transitions)
                except (Exception, KeyboardInterrupt) as error:
                    if isinstance(error, subprocess.CalledProcessError) and error.stderr:
                        workload.report['error'] = error.stderr.strip()
                    else:
                        workload.report['error'] = str(error) or type(error).__name__
                    print(workload.report['error'], flush=True)
                    return 1
                finally:
                    save_json(output / 'result.json', workload.report)
                    report['runs'].append({'path': output.name, 'status': 'error' if 'error' in workload.report else 'passed'})
        finally:
            report['timings'] = summarize(rows)
            save_json(result / 'result.json', report)
    return 0


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    raise SystemExit(main())
