#!/usr/bin/env python3
"""Measure an isolated, packaged Miji with live scanner, FSEvents and extraction."""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import sqlite3
import subprocess
import threading
import time
import uuid

from fixtures import restore
import window

RUSAGE_FIELDS = (
    'user_ticks system_ticks package_idle_wakeups interrupt_wakeups pageins wired_bytes resident_bytes footprint_bytes '
    'start_abstime exit_abstime exited_children_user_ticks exited_children_system_ticks child_idle_wakeups '
    'child_interrupt_wakeups child_pageins child_elapsed_abstime disk_read_bytes disk_write_bytes '
    'qos_default qos_maintenance qos_background qos_utility qos_legacy qos_initiated qos_interactive '
    'billed_system serviced_system logical_writes lifetime_max_footprint_bytes instructions cycles billed_energy '
    'serviced_energy interval_max_footprint runnable_time'
).split()
RESOURCE_KEYS = (
    'user_ticks', 'system_ticks', 'exited_children_user_ticks', 'exited_children_system_ticks', 'resident_bytes',
    'footprint_bytes', 'lifetime_max_footprint_bytes', 'disk_read_bytes', 'disk_write_bytes', 'logical_writes',
    'package_idle_wakeups', 'interrupt_wakeups',
)


class RUsage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in RUSAGE_FIELDS]


class ResourceProbe:
    def __init__(self):
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib')
        self.lib.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint]

    def tree(self, pid: int, parent: int | None = None) -> list[dict]:
        stats = RUsage()
        if self.lib.proc_pid_rusage(pid, 4, ctypes.byref(stats)) != 0:
            return []
        path = ctypes.create_string_buffer(4096)
        self.lib.proc_pidpath(pid, path, len(path))
        records = [{'pid': pid, 'parent': parent, 'exe': os.fsdecode(path.value),
                    'start_abstime': stats.start_abstime, **{key: getattr(stats, key) for key in RESOURCE_KEYS}}]
        children = (ctypes.c_int * 128)()
        count = self.lib.proc_listchildpids(pid, children, ctypes.sizeof(children))
        for child in children[:max(0, count)]:
            records.extend(self.tree(child, pid))
        return records


class MachTimebase(ctypes.Structure):
    _fields_ = [('numerator', ctypes.c_uint32), ('denominator', ctypes.c_uint32)]


def mach_timebase() -> dict:
    value = MachTimebase()
    result = ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(value))
    if result != 0:
        raise RuntimeError(f'mach_timebase_info failed: {result}')
    return {'numerator': value.numerator, 'denominator': value.denominator}


def save_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def command(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=30, **kwargs).stdout


def content_classes(reader: sqlite3.Connection) -> dict:
    counts = {}
    for path, extension, state in reader.execute(
        "SELECT relative_path, extension, content_state FROM files WHERE extension IN ('md','png','pdf','docx','pptx','xlsx')"
    ):
        if extension == 'md':
            label = 'markdown'
        elif extension == 'png':
            label = 'image_ocr'
        elif extension == 'pdf':
            label = 'scanned_pdf_ocr' if path.endswith('/扫描文档.pdf') else 'vector_pdf'
        else:
            label = 'office'
        group = counts.setdefault(label, {'seen': 0, 'done': 0, 'error': 0})
        group['seen'] += 1
        if state in ('done', 'error'):
            group[state] += 1
    return counts


def sample_resources(stop: threading.Event, started: float, pid: int, db: Path, output: Path, observe_content: bool) -> None:
    probe = ResourceProbe()
    reader = None
    with output.open('w', buffering=1) as log:
        while True:
            processes = probe.tree(pid)
            sizes = {}
            for path in db.parent.glob('index.sqlite*'):
                try:
                    sizes[path.name] = path.stat().st_size
                except FileNotFoundError:
                    pass
            row = {'seconds': time.monotonic() - started, 'processes': processes, 'file_bytes': sizes}
            if observe_content and db.is_file():
                try:
                    reader = reader or sqlite3.connect(db.as_uri() + '?mode=ro', uri=True, timeout=0.025)
                    row['content_classes'] = content_classes(reader)
                except sqlite3.OperationalError:
                    pass
            log.write(json.dumps(row, ensure_ascii=False) + '\n')
            if stop.wait(0.25):
                if reader:
                    reader.close()
                return


class Workload:
    def __init__(self, output: Path, label: str, fixture: dict, app: Path, timeout: float,
                 gui: dict | None, disable_reuse: bool, window_samples: int, window_batch: int, window_content: bool):
        self.output = output
        self.label = label
        self.fixture = fixture
        self.root = Path(fixture['path'])
        self.app = app
        self.cli = app / 'Contents/MacOS/miji-extract'
        self.timeout = timeout
        self.gui = gui
        self.window_samples = window_samples
        self.window_batch = window_batch
        self.window_content = window_content
        self.disable_reuse = disable_reuse
        self.mixed = label.startswith('mixed')
        self.extract_documents = self.mixed or window_content
        self.report = {'fixture': fixture, 'checks': [], 'timings_seconds': {}}
        self.stop = threading.Event()
        self.process = None
        self.reader = None
        self.support = output / 'support'
        self.support.mkdir(mode=0o700)
        self.db = self.support / 'index.sqlite'
        self.state = self.db.with_suffix('.sqlite.incremental.json')
        self.identity = 'local.miji.indexperformance.' + uuid.uuid4().hex

    def check(self, name: str, passed: bool, **evidence) -> None:
        self.report['checks'].append({'name': name, 'passed': passed, **evidence})
        if not passed:
            raise RuntimeError(f'{name}: {evidence}')

    def record(self, name: str, since: float) -> None:
        self.report['timings_seconds'][name] = time.monotonic() - since
        print(self.label, name, f"{self.report['timings_seconds'][name]:.3f}s", flush=True)

    def wait(self, name, predicate):
        until = time.monotonic() + self.timeout
        while time.monotonic() < until:
            if self.process.poll() is not None:
                raise RuntimeError(f'app exited with status {self.process.returncode} while waiting for {name}')
            try:
                value = predicate()
            except sqlite3.OperationalError as error:
                if not any(term in str(error) for term in ('locked', 'no such table', 'unable to open')):
                    raise
                value = False
            if value:
                return value
            time.sleep(0.06)
        raise TimeoutError(f'{self.label}: {name} did not occur within {self.timeout}s')

    def connect(self):
        if not self.db.is_file():
            return False
        self.reader = sqlite3.connect(self.db.as_uri() + '?mode=ro', uri=True, timeout=0.2)
        self.reader.execute('PRAGMA query_only=ON')
        return True

    def read_root(self):
        roots = self.reader.execute('SELECT id, payload FROM roots').fetchall()
        if not roots:
            return False
        self.check('only the authored root is configured', len(roots) == 1 and Path(json.loads(roots[0][1])['path']).resolve() == self.root,
                   roots=[json.loads(root[1])['path'] for root in roots])
        self.root_id = roots[0][0]
        return True

    def file(self, path: str):
        return self.reader.execute('SELECT content_state, size FROM files WHERE root_id=? AND relative_path=?',
                                   (self.root_id, path)).fetchone()

    def pending(self):
        return self.reader.execute("SELECT count(*) FROM files WHERE root_id=? AND content_state='pending'",
                                   (self.root_id,)).fetchone()[0]

    def checkpoint(self):
        try:
            return json.loads(self.state.read_text())['roots'].get(self.root_id)
        except FileNotFoundError:
            return None

    def scan_finished(self):
        root = json.loads(self.reader.execute('SELECT payload FROM roots WHERE id=?', (self.root_id,)).fetchone()[0])
        checkpoint = self.checkpoint()
        return bool(root.get('lastScan') and checkpoint and not checkpoint.get('scan'))

    def search(self, name: str, scope: str, query: str, expected_paths: list[str], absent: bool = False) -> None:
        start = time.monotonic()
        hits = json.loads(command([self.cli, 'search', '--database', self.db, '--scope', scope, '--query', query]))
        elapsed = time.monotonic() - start
        paths = {str(Path(hit['path']).resolve().relative_to(self.root)) for hit in hits}
        expected = set(expected_paths)
        self.check(name, expected.isdisjoint(paths) if absent else expected <= paths, query=query, scope=scope,
                   paths=sorted(paths), search_seconds_including_cli_start=elapsed,
                   snippets=[hit['snippet'] for hit in hits if hit['snippet']][:2])

    def edit(self, phase: str):
        paths = self.fixture['edits'][phase]
        before = self.root / paths['before']
        after = paths['before'] if self.mixed else paths['after']
        if self.mixed:
            self.wait(f'{phase} old and removed contents indexed', lambda: all(
                (self.file(paths[key]) or ('',))[0] == 'done' for key in ('before', 'remove')))
            self.search(f'{phase}: old content exists', 'content', f'zzcontent{phase}old', [paths['before']])
            self.search(f'{phase}: removed content exists', 'content', f'zzcontent{phase}remove', [paths['remove']])
        else:
            self.search(f'{phase}: old name exists', 'name', before.stem, [paths['before']])
            self.search(f'{phase}: removed name exists', 'name', Path(paths['remove']).stem, [paths['remove']])
        pending = self.pending()
        if phase == 'backlog':
            self.check('mixed mutations start with real extraction backlog', pending > 0, pending=pending)
        else:
            self.check('idle mutations start with empty extraction queue', pending == 0, pending=pending)
        stats = {}
        started = time.monotonic()
        (self.root / paths['add']).write_text(f'zzcontent{phase}added\n')
        stats['add'] = time.monotonic()
        content = f'zzcontent{phase}replacementlong\n'
        if self.mixed:
            before.write_text(content)
        else:
            before.rename(self.root / after)
        stats['edit'] = time.monotonic()
        (self.root / paths['remove']).unlink()
        stats['delete'] = time.monotonic()
        self.report[f'{phase}_started_seconds'] = started - self.started
        self.report[f'{phase}_pending_at_start'] = pending
        states = {
            'add_metadata': lambda: self.file(paths['add']) is not None,
            'edit_metadata': lambda: (self.file(after) or ('', -1))[1] == len(content) if self.mixed
            else self.file(after) is not None and self.file(paths['before']) is None,
            'delete_metadata': lambda: self.file(paths['remove']) is None,
        }
        if self.mixed:
            states.update(add_content=lambda: (self.file(paths['add']) or ('',))[0] == 'done',
                          edit_content=lambda: (self.file(after) or ('', -1)) == ('done', len(content)))
        while states:
            def visible():
                return [name for name, predicate in states.items() if predicate()]
            for name in self.wait(f'{phase} mutations {list(states)}', visible):
                milestone = f'{phase}_{name}'
                self.record(milestone, stats[name.split('_', 1)[0]])
                if self.mixed:
                    self.report.setdefault('pending_at_milestones', {})[milestone] = self.pending()
                del states[name]
        self.search(f'{phase}: added file searchable by name', 'name', Path(paths['add']).stem, [paths['add']])
        self.search(f'{phase}: removed name disappears', 'name', Path(paths['remove']).stem, [paths['remove']], absent=True)
        if self.mixed:
            self.search(f'{phase}: added content searchable', 'content', f'zzcontent{phase}added', [paths['add']])
            self.search(f'{phase}: edited content searchable', 'content', f'zzcontent{phase}replacementlong', [after])
            self.search(f'{phase}: old content disappears', 'content', f'zzcontent{phase}old', [after], absent=True)
            self.search(f'{phase}: deleted content disappears', 'content', f'zzcontent{phase}remove', [paths['remove']], absent=True)
        else:
            self.search(f'{phase}: renamed file searchable', 'name', Path(after).stem, [after])
            self.search(f'{phase}: old name disappears', 'name', before.stem, [paths['before']], absent=True)

    def verify_handles(self):
        handles = command(['lsof', '-a', '-p', str(self.process.pid), '-Fn'])
        (self.output / 'lsof.txt').write_text(handles)
        databases = {Path(line[1:]).resolve() for line in handles.splitlines()
                     if line.startswith('n/') and Path(line[1:]).name.startswith('index.sqlite')}
        self.check('open Miji SQLite handles are in the isolated support directory',
                   self.db in databases and all(path.parent == self.support for path in databases),
                   sql_paths=sorted(str(path) for path in databases))

    def prepare_fixture(self):
        restore(self.root, self.mixed)

    def run(self):
        self.check('fixture is within the isolated workspace', self.root.is_relative_to(self.output.parents[1] / 'roots'))
        self.prepare_fixture()
        bundle = self.output / self.app.name
        shutil.copytree(self.app, bundle)
        plist = bundle / 'Contents/Info.plist'
        values = plistlib.loads(plist.read_bytes())
        self.check('packaged app and extraction helper exist', values.get('CFBundleExecutable') == 'Miji' and self.cli.is_file())
        values['CFBundleIdentifier'] = self.identity
        plist.write_bytes(plistlib.dumps(values))
        self.cli = bundle / 'Contents/MacOS/miji-extract'
        command(['codesign', '--force', '--sign', '-', '--identifier', self.identity, bundle])
        command(['codesign', '--verify', '--deep', '--strict', bundle])
        preferences = dict(images=self.mixed, documents=self.extract_documents, externalImages=False, externalDocuments=False,
                           retainOffline=True, includeHidden=True, excludeDevelopmentCaches=False, autoAddExternal=False,
                           ignoredExternalVolumes=[])
        self.report.update(bundle_id=self.identity, bundle=str(bundle), preferences=preferences, root=str(self.root),
                           support=str(self.support), executable_sha256=hashlib.sha256((bundle / 'Contents/MacOS/Miji').read_bytes()).hexdigest(),
                           helper_sha256=hashlib.sha256(self.cli.read_bytes()).hexdigest())
        command(['defaults', 'write', self.identity, 'indexingPreferences', '-data', json.dumps(preferences).encode().hex()])
        try:
            with (self.output / 'app.log').open('w') as log:
                self.measure(bundle, log)
        finally:
            self.stop.set()
            if self.reader:
                self.reader.close()
            if self.process and self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            subprocess.run(['defaults', 'delete', self.identity], capture_output=True, timeout=10)

    def measure(self, bundle: Path, log):
        env = {key: value for key, value in os.environ.items() if not key.startswith('MIJI_')}
        env.update(MIJI_DATA_DIR=str(self.support), MIJI_INITIAL_ROOT=str(self.root), MIJI_UI_TESTING='1',
                   MallocSpaceEfficient='1')
        if self.disable_reuse:
            env['MIJI_DISABLE_EXTRACTION_REUSE'] = '1'
        if self.gui:
            env.update(MIJI_UI_QUERY=self.gui['query'] or Path(self.fixture['first_path']).stem,
                       MIJI_UI_SCOPE=self.gui['scope'], MIJI_UI_PREVIEW='hidden')
        self.started_wall_time = time.time()
        self.started = time.monotonic()
        self.report['launch_unix_seconds'] = self.started_wall_time
        self.process = subprocess.Popen([bundle / 'Contents/MacOS/Miji'], env=env, stdout=log, stderr=log,
                                        cwd=self.output, start_new_session=True)
        self.report['pid'] = self.process.pid
        sampler = threading.Thread(target=sample_resources, args=(self.stop, self.started, self.process.pid, self.db,
                                                                  self.output / 'resources.jsonl', self.mixed and not self.gui),
                                   daemon=True)
        sampler.start()
        try:
            if self.gui:
                filename = self.gui['filename'] or self.fixture['first_path']
                visible = json.loads(command([self.gui['executable'], str(self.process.pid), filename, '25']))
                self.record('gui_first_marker_visible', self.started)
                self.report['gui_accessibility'] = {'query': env['MIJI_UI_QUERY'], 'scope': self.gui['scope'], **visible}
            self.wait('isolated SQLite opens', self.connect)
            self.wait('configured isolated indexing root', self.read_root)
            if not self.gui:
                self.wait('first marker metadata', lambda: self.file(self.fixture['first_path']))
                self.record('first_marker_metadata', self.started)
            self.verify_handles()
            if self.window_samples:
                self.wait('initial scan finishes before fixed-query window sampling', self.scan_finished)
                self.report['window_visibility'] = window.measure(self.root, self.output, self.gui['executable'],
                                                                  self.process.pid, self.window_samples, self.window_batch,
                                                                  self.window_content)
                return
            if self.gui:
                return
            self.search('first marker searchable', 'name', Path(self.fixture['first_path']).stem, [self.fixture['first_path']])
            self.record('first_marker_search_verified', self.started)
            if self.mixed:
                self.edit('backlog')
            self.wait('metadata scan completes', self.scan_finished)
            root = json.loads(self.reader.execute('SELECT payload FROM roots WHERE id=?', (self.root_id,)).fetchone()[0])
            # Foundation JSONEncoder represents Date as seconds since 2001-01-01.
            self.report['timings_seconds']['metadata_scan_completed'] = root['lastScan'] + 978307200 - self.started_wall_time
            self.record('metadata_scan_completed_observed', self.started)
            self.wait('extraction queue empty', lambda: self.pending() == 0)
            self.record('content_queue_drained_observed', self.started)
            if self.mixed:
                for name, info in self.fixture['templates'].items():
                    self.search(f'{name} extracted and searchable', 'content', info['expected_query'], [f'mix-000/{name}'])
                if probe := self.fixture.get('distinct_vector_probe'):
                    self.search('unique vector body indexed independently', 'content', probe['query'], [probe['path']])
                    self.search('unique vector body does not leak into another PDF', 'content', probe['query'],
                                [probe['absent_path']], absent=True)
            self.edit('idle')
            self.read_root()
            row = self.reader.execute("SELECT count(*),sum(content_state='error'),sum(content_id IS NOT NULL) FROM files").fetchone()
            self.report['terminal'] = dict(zip(('records', 'errors', 'indexed_content'), row))
            self.check('expected number of records with no errors', row[0] == self.fixture['expected_records'] and row[1] == 0,
                       actual=self.report['terminal'], expected=self.fixture['expected_records'])
            if self.mixed:
                self.check('all mixed content indexed', row[2] == self.fixture['expected_indexed_content'], actual=row[2],
                           expected=self.fixture['expected_indexed_content'])
        finally:
            self.stop.set()
            sampler.join(timeout=3)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workspace', type=Path)
    parser.add_argument('app', type=Path)
    parser.add_argument('variant', help='Unique result directory name for this run')
    parser.add_argument('--workloads', nargs='+', default=['names-100000', 'names-1000000', 'mixed'])
    parser.add_argument('--timeout', type=float, default=600)
    parser.add_argument('--disable-extraction-reuse', action='store_true',
                        help='Disable optional byte-identical extraction reuse for a same-binary comparison')
    parser.add_argument('--gui-probe', type=Path, help='Only measure startup to an actual AX result in the native panel')
    parser.add_argument('--window-samples', type=int, default=0, help='Measure each visible operation this many times')
    parser.add_argument('--window-content', action='store_true',
                        help='Measure fixed-query small text content additions, edits and deletions')
    parser.add_argument('--window-batch', type=int, default=6, help='Batch mutations, keeping at most seven visible rows')
    parser.add_argument('--gui-query', help='Search the exact query in the independently launched GUI')
    parser.add_argument('--gui-filename', help='First visible filename expected to match the GUI query')
    parser.add_argument('--gui-scope', choices=['name', 'content', 'all'], default='name')
    parser.add_argument('--source', required=True, help='Source commit and working tree checkpoint used for packaging')
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    if not workspace.is_relative_to(Path('/private/tmp')) or Path(args.variant).name != args.variant:
        parser.error('one private temp workspace and a variant directory name are required')
    args.app = args.app.resolve()
    if not args.app.is_relative_to(workspace):
        parser.error('copy or package the app inside your temporary workspace')
    if args.window_samples < 0 or not 1 <= args.window_batch <= 6:
        parser.error('sampling count must be nonnegative and batch size must be between 1 and 6')
    if args.window_content and not args.window_samples:
        parser.error('--window-content needs a positive --window-samples')
    if args.window_samples:
        if not args.gui_probe or args.gui_query or args.gui_filename or args.gui_scope != 'name':
            parser.error('window sampling needs --gui-probe and supplies its own query, filename and scope')
        fixture = window.fixture(workspace, args.window_content)
        args.workloads = [fixture['name']]
        args.gui_query, args.gui_filename = fixture['query'], fixture['first_path']
        args.gui_scope = 'content' if args.window_content else 'name'
        manifest = {'workloads': {fixture['name']: fixture}}
    else:
        manifest = json.loads((workspace / 'fixtures.json').read_text())
    result = workspace / args.variant
    result.mkdir()
    save_json(result / 'run.json', {'source': args.source, 'system': command(['sw_vers']).strip(),
                                     'hardware': command(['sysctl', '-n', 'hw.model', 'hw.memsize', 'hw.ncpu']).split(),
                                     'workloads': args.workloads, 'sample_interval_seconds': 0.25, 'mach_timebase': mach_timebase(),
                                     'extraction_reuse_disabled': args.disable_extraction_reuse,
                                     'window_samples_per_operation': args.window_samples, 'window_batch_size': args.window_batch})
    success = True
    if bool(args.gui_query) != bool(args.gui_filename) or (args.gui_query and not args.gui_probe):
        parser.error('--gui-query and --gui-filename must be supplied together with --gui-probe')
    gui = {'executable': args.gui_probe.resolve(), 'query': args.gui_query, 'filename': args.gui_filename,
           'scope': args.gui_scope} if args.gui_probe else None
    for label in args.workloads:
        output = result / label
        output.mkdir()
        workload = Workload(output, label, manifest['workloads'][label], args.app, args.timeout, gui,
                            args.disable_extraction_reuse, args.window_samples, args.window_batch, args.window_content)
        try:
            workload.run()
        except (Exception, KeyboardInterrupt) as error:
            success = False
            failure = str(error) or type(error).__name__
            if isinstance(error, subprocess.CalledProcessError) and error.stderr:
                failure += '\n' + error.stderr.strip()
            workload.report['error'] = failure
            print(label, failure, flush=True)
            if isinstance(error, KeyboardInterrupt):
                break
        finally:
            save_json(output / 'result.json', workload.report)
    return 0 if success else 1


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    raise SystemExit(main())
