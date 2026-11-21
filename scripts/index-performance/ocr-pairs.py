#!/usr/bin/env python3
"""Measure three alternating pairs on the frozen eight-round fixture's unique media."""
from __future__ import annotations

import argparse
from collections import Counter
from contextlib import closing
import ctypes
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import signal
import sqlite3
from statistics import median
import subprocess
import tempfile
import threading
import time

from run import Workload, command, mach_timebase, save_json

LABEL = 'mixed-distinct'
MEDIA = {'图像样本.png': 'png_ocr', '扫描文档.pdf': 'scanned_pdf_ocr', '向量文档.pdf': 'vector_pdf'}
INTERVAL = 0.25
ORDER = (('baseline', 'candidate'), ('candidate', 'baseline'), ('baseline', 'candidate'))
EXECUTABLES = ('Miji', 'miji-extract')


def sha(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inspect_fixture(root: Path, fixture: dict) -> tuple[dict, dict]:
    if fixture['directories'] != 8 or fixture['expected_indexed_content'] != 60:
        raise ValueError('expected the frozen eight-round fixture with 60 indexed contents')
    paths = {}
    for turn in range(8):
        for filename, template in fixture['templates'].items():
            key = f'mix-{turn:03d}/{filename}'
            paths[key] = sha(root / key)
            if turn == 0 and paths[key] != template['sha256']:
                raise ValueError(f'frozen template SHA-256 mismatch: {key}')
    formats = {name: len({digest for path, digest in paths.items() if Path(path).name == name})
               for name in fixture['templates']}
    counts = Counter(paths.values())
    if (len(paths) != fixture['sample_payloads'] or len(counts) != fixture['distinct_sample_payloads']
            or formats != fixture['distinct_payloads_by_format']):
        raise ValueError('frozen content counts or distinct hashes differ from the fixture manifest')
    cohorts = {}
    for filename, kind in MEDIA.items():
        matching = sorted(path for path in paths if Path(path).name == filename)
        cohorts[kind] = matching
        cohorts[f'{kind}_singletons'] = [path for path in matching if counts[paths[path]] == 1]
        cohorts[f'{kind}_duplicate_members'] = [path for path in matching if counts[paths[path]] > 1]
        expected_duplicates = [f'mix-{turn:03d}/{filename}' for turn in (0, 7)]
        if (len(cohorts[f'{kind}_singletons']) != 6
                or cohorts[f'{kind}_duplicate_members'] != expected_duplicates):
            raise ValueError(f'unexpected singleton/duplicate distribution for {filename}')
    for suffix in ('', '_singletons', '_duplicate_members'):
        cohorts[f'ocr{suffix}'] = sorted(cohorts[f'png_ocr{suffix}'] + cohorts[f'scanned_pdf_ocr{suffix}'])
    cohorts['all_media_singletons'] = sorted(cohorts['ocr_singletons'] + cohorts['vector_pdf_singletons'])
    return paths, cohorts


def binary_hashes(app: Path) -> dict[str, str]:
    return {name: sha(app / 'Contents/MacOS' / name) for name in EXECUTABLES}


def verify_timed_fixture(root: Path, hashes: dict, excluded: list[str]) -> None:
    if ({path: sha(root / path) for path in hashes} != hashes
            or any((root / path).exists() for path in excluded)):
        raise ValueError('isolated input bytes or excluded duplicate paths changed')


class PairedWorkload(Workload):
    def observe_media(self):
        try:
            reader = None
            with (self.output / 'media-commits.jsonl').open('w', buffering=1) as log:
                try:
                    while True:
                        if self.db.is_file():
                            try:
                                reader = reader or sqlite3.connect(self.db.as_uri() + '?mode=ro', uri=True,
                                                                   timeout=0.025)
                                rows = reader.execute("""
                                    SELECT relative_path, content_state, content_error FROM files
                                    WHERE extension IN ('png', 'pdf') AND relative_path LIKE 'mix-%/%'
                                """).fetchall()
                                observed = time.monotonic() - self.started
                                log.write(json.dumps({'seconds': observed,
                                                     'states': {path: state for path, state, _ in rows},
                                                     'errors': {path: error for path, _, error in rows if error}},
                                                     ensure_ascii=False) + '\n')
                            except sqlite3.OperationalError as error:
                                if not any(term in str(error) for term in ('locked', 'no such table', 'unable to open')):
                                    raise
                        if self.stop.wait(INTERVAL):
                            break
                finally:
                    if reader:
                        reader.close()
        except Exception as error:
            self.media_probe_error = error

    def measure(self, bundle, log):
        self.media_probe_error = None
        probe = threading.Thread(target=self.observe_media, name='media-commits')
        probe.start()
        try:
            super().measure(bundle, log)
        finally:
            self.stop.set()
            probe.join()
        if self.media_probe_error is not None:
            raise self.media_probe_error


def media_milestones(trace: Path, cohorts: dict) -> dict:
    first_done = {}
    for line in trace.read_text().splitlines():
        sample = json.loads(line)
        for path, state in sample['states'].items():
            if state == 'done':
                first_done.setdefault(path, sample['seconds'])
    missing = sorted(set().union(*cohorts.values()) - first_done.keys())
    if missing:
        raise ValueError(f'no sampled commit for: {missing}')
    return {name + '_all_done_observed': max(first_done[path] for path in paths)
            for name, paths in cohorts.items()}


def media_quality(db: Path, paths: list[str]) -> dict:
    # Swift JSONEncoder may change object key order. Verify the MJC1 payload and
    # compare the decoded result, including text, label order, warnings and pages.
    decode = ctypes.CDLL('/usr/lib/libcompression.dylib').compression_decode_buffer
    decode.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t,
                       ctypes.c_void_p, ctypes.c_int]
    decode.restype = ctypes.c_size_t
    result = {}
    with closing(sqlite3.connect(db.as_uri() + '?mode=ro', uri=True, timeout=0.5)) as reader:
        for path in paths:
            rows = reader.execute("""
                SELECT f.content_state, b.digest, b.packed FROM files f
                JOIN content_blobs b ON b.id=f.content_id WHERE f.relative_path=?
            """, (path,)).fetchall()
            if len(rows) != 1 or rows[0][0] != 'done':
                raise ValueError(f'missing completed indexed body: {path}')
            _, digest, packed = rows[0]
            header, payload = packed[:48], packed[48:]
            if (len(header) != 48 or header[:4] != b'MJC1' or header[4] not in (0, 1)
                    or header[5:8] != b'\0\0\0' or hashlib.sha256(payload).digest() != header[16:48]):
                raise ValueError(f'invalid MJC1 body: {path}')
            size = int.from_bytes(header[8:16], 'little')
            if not 0 < size <= 128 * 1024 * 1024:
                raise ValueError(f'invalid MJC1 body size: {path}')
            raw = payload
            if header[4] == 1:
                buffer = ctypes.create_string_buffer(size + 1)
                if decode(buffer, len(buffer), payload, len(payload), None, 0x801) != size:
                    raise ValueError(f'could not decode LZFSE body: {path}')
                raw = buffer.raw[:size]
            if len(raw) != size or hashlib.sha256(raw).digest() != digest:
                raise ValueError(f'indexed body SHA-256 mismatch: {path}')
            result[path] = json.loads(raw)
    return result


def measurement_stats(pairs: list[dict]) -> dict:
    def stats(values):
        return {'median': median(values), 'min': min(values), 'max': max(values), 'values': values}

    complete = [pair['runs'] for pair in pairs if pair.get('media_quality_differences') == []]
    if not complete:
        return {}
    result = {}
    for metric in complete[0]['baseline']['metrics']:
        old = [pair['baseline']['metrics'][metric] for pair in complete]
        new = [pair['candidate']['metrics'][metric] for pair in complete]
        result[metric] = {
            'baseline_seconds': stats(old), 'candidate_seconds': stats(new),
            'paired_delta_seconds': stats([b - a for a, b in zip(old, new)]),
            'paired_delta_percent': stats([100 * (b - a) / a for a, b in zip(old, new)]),
        }
    return result


def run_one(workspace: Path, destination: Path, fixture: dict, cohorts: dict, app: Path,
            expected_binaries: dict, timeout: float) -> tuple[dict, dict]:
    staging = workspace / destination.name / LABEL
    staging.mkdir(parents=True)
    destination.mkdir()
    workload = PairedWorkload(staging, LABEL, fixture, app, timeout, None, False, 0, 6, False)
    quality = {}
    run = {'result': str(destination / 'result.json'), 'status': 'error'}
    print(destination.name, 'started', flush=True)
    try:
        workload.run()
        if (binary_hashes(app) != expected_binaries
                or workload.report['helper_sha256'] != expected_binaries['miji-extract']):
            raise ValueError('frozen original executable or copied helper changed')
        quality = media_quality(workload.db, sorted(cohorts['ocr'] + cohorts['vector_pdf']))
        save_json(destination / 'indexed-media.json', quality)
        for path, body in quality.items():
            filename = Path(path).name
            token = fixture['templates'][filename]['expected_query']
            text = body['text']
            if token not in ''.join(text.split()) or body.get('warning') or body['pages'] != 1:
                raise ValueError(f'fixture text, warning or page count differs from expectation: {path}')
            if filename.endswith('.pdf') and not body.get('pageRanges'):
                raise ValueError(f'missing indexed page locations: {path}')
            turn = int(Path(path).parent.name.removeprefix('mix-'))
            serials = [line for line in text.splitlines() if line.startswith('Synthetic benchmark specimen ')]
            if serials != ([f'Synthetic benchmark specimen {turn}'] if 1 <= turn <= 6 else []):
                raise ValueError(f'indexed serial differs from the authored fixture: {path}')
        run['metrics'] = media_milestones(staging / 'media-commits.jsonl', cohorts)
        run['metrics']['content_queue_drained_observed'] = (
            workload.report['timings_seconds']['content_queue_drained_observed'])
        run['status'] = 'passed'
    except (Exception, KeyboardInterrupt) as error:
        run['error'] = str(error) or type(error).__name__
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            run['error'] += '\n' + error.stderr.strip()
        workload.report['error'] = run['error']
        print(destination.name, run['error'], flush=True)
        if isinstance(error, KeyboardInterrupt):
            run['interrupted'] = True
    finally:
        for name in ('app.log', 'lsof.txt', 'media-commits.jsonl', 'resources.jsonl'):
            if (staging / name).is_file():
                shutil.copy2(staging / name, destination / name)
        save_json(destination / 'result.json', workload.report)
    return run, quality


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture_manifest', type=Path)
    parser.add_argument('baseline_app', type=Path)
    parser.add_argument('candidate_app', type=Path)
    parser.add_argument('output', type=Path, help='New directory for the six runs and report')
    for variant in ('baseline', 'candidate'):
        parser.add_argument(f'--{variant}-source', required=True)
        parser.add_argument(f'--{variant}-sha256', nargs=2, metavar=('MAIN', 'HELPER'), required=True)
    parser.add_argument('--timeout', type=float, default=600)
    parser.add_argument('--resume', action='store_true', help='Keep finished pairs and replay incomplete pairs')
    parser.add_argument('--max-pairs', type=int, default=len(ORDER), help='Maximum new pair attempts in this session')
    args = parser.parse_args()
    if args.max_pairs < 1:
        parser.error('--max-pairs must be positive')
    manifest = json.loads(args.fixture_manifest.read_text())
    fixture = manifest['workloads'][LABEL]
    frozen = Path(fixture['path']).resolve()
    workspace = Path(manifest['workspace']).resolve()
    if not workspace.is_relative_to(Path('/private/tmp')) or frozen != workspace / 'roots' / LABEL:
        parser.error('the frozen corpus must be the isolated mixed-distinct fixture under /private/tmp')
    frozen_hashes, frozen_cohorts = inspect_fixture(frozen, fixture)
    excluded = sorted(frozen_cohorts[f'{kind}_duplicate_members'][1] for kind in MEDIA.values())
    paths = {path: digest for path, digest in frozen_hashes.items() if path not in excluded}
    cohorts = {name.replace('_singletons', '_original_singletons'): sorted(set(members) - set(excluded))
               for name, members in frozen_cohorts.items() if not name.endswith('_duplicate_members')}
    cohorts['all_media'] = sorted(cohorts['ocr'] + cohorts['vector_pdf'])
    if len({paths[path] for path in cohorts['all_media']}) != len(cohorts['all_media']):
        raise ValueError('the timed PNG and PDF input must be byte-distinct')
    apps = {variant: getattr(args, variant + '_app').resolve() for variant in ('baseline', 'candidate')}
    builds = {}
    for variant, app in apps.items():
        if app.is_relative_to(Path('/Applications')) or app.is_relative_to(Path.home() / 'Applications'):
            parser.error('use isolated packaged artifacts')
        expected = dict(zip(EXECUTABLES, getattr(args, variant + '_sha256')))
        if binary_hashes(app) != expected:
            parser.error(f'{variant} executable SHA-256 differs from the frozen manifest')
        command(['codesign', '--verify', '--deep', '--strict', app])
        builds[variant] = {'app': str(app), 'source': getattr(args, variant + '_source'), 'sha256': expected}

    output = args.output.resolve()
    report_path = output / 'report.json'
    metadata = {
              'system': command(['sw_vers']).strip(), 'hardware': command(
                  ['sysctl', '-n', 'hw.model', 'hw.memsize', 'hw.ncpu']).split(),
              'mach_timebase': mach_timebase(), 'sample_interval_seconds': INTERVAL,
              'fixture_manifest': str(args.fixture_manifest.resolve()),
              'fixture_manifest_sha256': sha(args.fixture_manifest), 'frozen_root': str(frozen),
              'frozen_payload_sha256': frozen_hashes, 'timed_payload_sha256': paths,
              'omitted_frozen_copy_paths': excluded, 'cohorts': cohorts, 'builds': builds,
              'order': [list(variants) for variants in ORDER],
              'method': [
                  'Six serial launches in AB/BA/AB order. Each uses a fresh app process, test bundle ID and empty data directory.',
                  'All rounds use the same temporary clone. The second byte-identical copy of each PNG, scanned PDF and vector PDF is removed. All other authored sample bytes are kept.',
                  'Default OCR, image classification and extraction reuse. The runner removes inherited MIJI_* overrides.',
                  'App-local reuse starts empty each run. Dataset hashing reads the input, and macOS file, Vision and system caches are neither flushed nor controlled.',
                  'Milestones are launch-to-observed SQLite commits, including startup and scheduling. Media polling is roughly 250 ms.',
                  'Timed media comprise 7 unique PNGs, 7 unique scanned PDFs and 7 unique vector PDFs. The original-singletons cohorts also exclude the retained originals from the three duplicate groups.',
                  'The OCR milestones are measured inside the mixed workload and exclude the vector PDFs. The other document formats retain their original duplicate samples.',
                  'The overall milestone is the harness queue-drained observation after its backlog mutation checks.',
                  'Indexed-media comparisons include decoded OCR text, labels, warnings, page counts and page locations.',
              ]}
    if args.resume:
        report = json.loads(report_path.read_text())
        for key, value in metadata.items():
            if key != 'method' and report.get(key) != value:
                parser.error(f'existing report differs from current measurement inputs: {key}')
        report['method'] = metadata['method']
        if 'benchmark_windows' not in report:
            report['benchmark_windows'] = [{key: report[key] for key in (
                'started_utc', 'finished_utc', 'status', 'error') if key in report}]
    else:
        output.mkdir(parents=True)
        report = {**metadata, 'started_utc': datetime.now(timezone.utc).isoformat(), 'pairs': []}
    window = {'started_utc': datetime.now(timezone.utc).isoformat()}
    report.setdefault('benchmark_windows', []).append(window)
    report.pop('finished_utc', None)
    report.pop('error', None)
    report['status'] = 'running'
    completed = {pair['number'] for pair in report['pairs'] if pair.get('media_quality_differences') == []}
    attempts = Counter(pair['number'] for pair in report['pairs'])
    remaining = [(number, variants) for number, variants in enumerate(ORDER, 1) if number not in completed]
    save_json(report_path, report)
    try:
        with tempfile.TemporaryDirectory(prefix='miji-ocr-pairs-', dir='/private/tmp') as directory:
            working = Path(directory)
            root = working / 'roots' / LABEL
            shutil.copytree(frozen, root)
            for path in excluded:
                (root / path).unlink()
            timed_fixture = {**fixture, 'path': str(root), 'description': (
                'Frozen eight-round clone with the byte-identical second PNG, scanned PDF and vector PDF removed.')}
            for field in ('regular_files', 'expected_indexed_content', 'expected_records',
                          'sample_payloads', 'duplicate_sample_payloads'):
                timed_fixture[field] -= len(excluded)
            verify_timed_fixture(root, paths, excluded)
            for number, variants in remaining[:args.max_pairs]:
                attempt = attempts[number] + 1
                prefix = f'pair-{number:02d}' if attempt == 1 else f'pair-{number:02d}-attempt-{attempt:02d}'
                while any((output / f'{prefix}-{variant}').exists() for variant in variants):
                    attempt += 1
                    prefix = f'pair-{number:02d}-attempt-{attempt:02d}'
                pair = {'number': number, 'attempt': attempt, 'order': variants, 'runs': {}}
                report['pairs'].append(pair)
                quality = {}
                save_json(report_path, report)
                for variant in variants:
                    label = f'{prefix}-{variant}'
                    pair['runs'][variant], quality[variant] = run_one(
                        working, output / label, timed_fixture, cohorts, apps[variant], builds[variant]['sha256'],
                        args.timeout)
                    verify_timed_fixture(root, paths, excluded)
                    save_json(report_path, report)
                    if pair['runs'][variant].get('interrupted'):
                        raise KeyboardInterrupt
                if all(run['status'] == 'passed' for run in pair['runs'].values()):
                    pair['media_quality_differences'] = sorted(
                        path for path in quality['baseline'] if quality['baseline'][path] != quality['candidate'][path])
                save_json(report_path, report)
                if pair.get('media_quality_differences') != []:
                    raise ValueError(f'{prefix} did not complete both runs with equivalent OCR output')
                completed.add(number)
            if inspect_fixture(frozen, fixture)[0] != frozen_hashes:
                raise ValueError('original frozen payloads changed during the experiment')
            report['frozen_payloads_verified_after_series'] = True
        report['status'] = 'passed' if len(completed) == len(ORDER) else 'paused'
    except (Exception, KeyboardInterrupt) as error:
        report['status'] = 'error'
        report['error'] = str(error) or type(error).__name__
        print(report['error'], flush=True)
    finally:
        report['metrics'] = measurement_stats(report['pairs'])
        report['completed_pair_count'] = len(completed)
        report['finished_utc'] = datetime.now(timezone.utc).isoformat()
        window.update(finished_utc=report['finished_utc'], status=report['status'])
        if 'error' in report:
            window['error'] = report['error']
        save_json(report_path, report)
    return 0 if report['status'] in ('passed', 'paused') else 1


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    raise SystemExit(main())
