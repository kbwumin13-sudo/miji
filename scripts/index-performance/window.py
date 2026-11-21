"""Measure live result mutations without retyping the query."""
from __future__ import annotations

import json
from math import ceil
from pathlib import Path
from statistics import median
import subprocess
import time

NAME_QUERY = 'zzbenchmarkwindow'
TEXT_QUERY = 'zzbenchmarkwindowbody'
NAME_ANCHOR = NAME_QUERY + 'anchor.dat'
TEXT_ANCHOR = 'panel-anchor-document.txt'


def fixture(workspace: Path, content: bool) -> dict:
    name = 'window-content-visibility' if content else 'window-visibility'
    root = workspace / 'roots' / name
    root.mkdir(parents=True, exist_ok=True)
    anchor, query = (TEXT_ANCHOR, TEXT_QUERY) if content else (NAME_ANCHOR, NAME_QUERY)
    (root / anchor).write_text(query if content else '')
    return {'path': str(root), 'first_path': anchor, 'query': query, 'name': name}


def probe(executable: Path, pid: int, query: str, anchor: str, conditions: list, timeout: float = 15) -> dict:
    observed = subprocess.run([executable, 'window', str(pid), str(timeout), query, anchor, json.dumps(conditions)],
                              check=True, capture_output=True, text=True, timeout=timeout + 5)
    return json.loads(observed.stdout)


def rename_case(root: Path, operation: str, old: str, new: str) -> dict:
    if operation == 'add':
        (root / old).touch(exist_ok=False)
        return {'present': old}
    if operation == 'rename':
        (root / old).rename(root / new)
        return {'present': new, 'absent': old}
    (root / new).unlink()
    return {'absent': new}


def text_case(root: Path, operation: str, name: str) -> dict:
    path = root / name
    if operation == 'delete':
        path.unlink()
        return {'absent': name}
    body = {
        'add': f'{TEXT_QUERY} first edition\n',
        'edit_remove': 'second edition without the selected search word\n',
        'edit_restore': f'{TEXT_QUERY} third edition with different body\n',
    }[operation]
    # The same-volume staging file is outside the watched root. The indexed
    # path changes through a single rename, matching common editor saves.
    staging = root.parent / f'.{name}.window-stage.tmp'
    try:
        staging.write_text(body)
        staging.replace(path)
    finally:
        staging.unlink(missing_ok=True)
    return {'absent': name} if operation == 'edit_remove' else {'present': name}


def measure(root: Path, output: Path, executable: Path, pid: int, samples: int, batch_size: int, content: bool) -> dict:
    operations = ('add', 'edit_remove', 'edit_restore', 'delete') if content else ('add', 'rename', 'delete')
    timings = {op: [] for op in operations}
    anchor, query = (TEXT_ANCHOR, TEXT_QUERY) if content else (NAME_ANCHOR, NAME_QUERY)
    # The separate anchor confirms the window is still showing the fixed query.
    probe(executable, pid, query, anchor, [{'id': 'anchor', 'present': anchor}])
    with (output / 'window-transitions.jsonl').open('w', buffering=1) as raw:
        for offset in range(0, samples, batch_size):
            numbers = [f'{number:04d}' for number in range(offset, min(offset + batch_size, samples))]
            before = {n: f'panel-doc-{n}.txt' if content else f'{query}{n}before.dat' for n in numbers}
            after = {} if content else {n: f'{query}{n}after.dat' for n in numbers}
            try:
                for operation in timings:
                    conditions = []
                    started = {}
                    for number in numbers:
                        started[number] = time.monotonic_ns()
                        if content:
                            condition = text_case(root, operation, before[number])
                        else:
                            condition = rename_case(root, operation, before[number], after[number])
                        conditions.append({'id': number, **condition})
                    observed = probe(executable, pid, query, anchor, conditions)
                    for condition in conditions:
                        number = condition['id']
                        observed_ns = observed['visible_at_uptime_ns'][number]
                        elapsed = (observed_ns - started[number]) / 1e9
                        record = {'round': offset // batch_size + 1, 'operation': operation, 'query': observed['query'],
                                  'scope': 'content' if content else 'name', 'condition': condition,
                                  'observed_monotonic_ns': observed_ns, 'mutation_monotonic_ns': started[number],
                                  'elapsed_seconds': elapsed, 'polls': observed['polls']}
                        raw.write(json.dumps(record) + '\n')
                        if elapsed < 0:
                            raise RuntimeError('AX and writer monotonic clocks do not share the expected timebase')
                        timings[operation].append(elapsed)
                print('window visibility', offset + len(numbers), '/', samples, flush=True)
            finally:
                for path in (*before.values(), *after.values()):
                    (root / path).unlink(missing_ok=True)
    return {op: {'samples': len(seconds), 'batches': ceil(samples / batch_size),
                 'median_seconds': median(seconds), 'p95_seconds': sorted(seconds)[ceil(len(seconds) * 0.95) - 1],
                 'max_seconds': max(seconds)} for op, seconds in timings.items()}
