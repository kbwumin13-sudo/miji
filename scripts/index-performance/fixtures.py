#!/usr/bin/env python3
"""Create deterministic Mac index benchmark fixtures under a new temp workspace."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
from collections import Counter
import shutil
import subprocess

PROJECT = Path(__file__).resolve().parents[2]
FIRST = 'zzbenchmarkfirst.dat'
FORMATS = {
    '图像样本.png': '海棠春风', '扫描文档.pdf': '海棠春风', '向量文档.pdf': '纸上银河',
    '文字处理.docx': '云帆远航', '数据工作簿.xlsx': '单元碧波', '演示文稿.pptx': '幻灯晨光',
    '知识卡片.md': '松间清泉',
}


def edit_paths(phase: str, mixed: bool) -> dict[str, str]:
    extension = 'txt' if mixed else 'dat'
    return {kind: f'zzbench{phase}{kind}.{extension}' for kind in ('add', 'before', 'after', 'remove')}


def seed(root: Path, phase: str, mixed: bool) -> None:
    paths = edit_paths(phase, mixed)
    (root / paths['before']).write_text(f'zzcontent{phase}old\n')
    (root / paths['remove']).write_text(f'zzcontent{phase}remove\n')


def restore(root: Path, mixed: bool) -> None:
    for phase in (('backlog', 'idle') if mixed else ('idle',)):
        for path in edit_paths(phase, mixed).values():
            (root / path).unlink(missing_ok=True)
        seed(root, phase, mixed)


def prepare(workspace: Path, sizes: list[int], rounds: int, distinct_rounds: int) -> None:
    if not workspace.is_dir() or not workspace.resolve().is_relative_to(Path('/private/tmp')):
        raise ValueError('use an existing private temporary workspace created under /private/tmp')
    manifest_path = workspace / 'fixtures.json'
    if manifest_path.exists():
        raise ValueError(f'fixture manifest already exists: {manifest_path}')
    volumes = workspace / 'roots'
    volumes.mkdir()
    manifest = {'workspace': str(workspace), 'workloads': {}}
    for size in sizes:
        label = f'names-{size}'
        root = volumes / label
        root.mkdir()
        (root / FIRST).touch()
        seed(root, 'idle', False)
        shards = min(256, max(1, (size + 999) // 1000))
        for shard in range(shards):
            folder = root / f'bucket-{shard:03d}'
            folder.mkdir()
            for number in range(shard, size, shards):
                descriptor = os.open(folder / f'record-{number:07d}.dat', os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                os.close(descriptor)
        manifest['workloads'][label] = {
            'path': str(root), 'regular_files': size + 3, 'directories': shards,
            'first_path': FIRST, 'description': 'Empty .dat files, one unique numbered filename per regular file.',
            'path_pattern': 'bucket-{number % shards:03d}/record-{number:07d}.dat',
        }
        print(label, 'prepared', flush=True)
    for label, replicates, variants in [('mixed', rounds, 0), ('mixed-distinct', distinct_rounds, distinct_rounds - 2)]:
        if not replicates:
            continue
        templates = workspace / 'fixture-templates'
        source = templates / 'fixtures'
        if not source.exists():
            subprocess.run(['python3', PROJECT / 'scripts/e2e-check.py', '--fixtures-only'], check=True,
                           env={**os.environ, 'MIJI_QA_DIR': str(templates)})
        root = volumes / label
        root.mkdir()
        if variants > 0:
            subprocess.run(['swift', PROJECT / 'scripts/index-performance/media-variants.swift', source, root, str(variants)],
                           check=True)
        (root / FIRST).touch()
        seed(root, 'backlog', True)
        seed(root, 'idle', True)
        sample = {}
        hashes = Counter()
        by_format = {name: set() for name in FORMATS}
        for turn in range(replicates):
            folder = root / f'mix-{turn:03d}'
            folder.mkdir(exist_ok=True)
            for source_name, token in FORMATS.items():
                template = source / source_name
                target = folder / source_name
                if not target.exists():
                    shutil.copyfile(template, target)
                digest = hashlib.sha256(target.read_bytes()).hexdigest()
                hashes[digest] += 1
                by_format[source_name].add(digest)
                if turn == 0:
                    sample[source_name] = {'sha256': digest, 'bytes': template.stat().st_size, 'expected_query': token}
        manifest['workloads'][label] = {
            'path': str(root), 'regular_files': replicates * len(FORMATS) + 5, 'directories': replicates,
            'first_path': FIRST, 'expected_indexed_content': replicates * len(FORMATS) + 4,
            'templates': sample, 'sample_payloads': sum(hashes.values()), 'distinct_sample_payloads': len(hashes),
            'duplicate_sample_payloads': sum(hashes.values()) - len(hashes),
            'distinct_payloads_by_format': {name: len(digests) for name, digests in by_format.items()},
            'description': 'Authored files with real Vision OCR. The distinct workload draws different serials per PNG/PDF.',
        }
        if variants > 0:
            manifest['workloads'][label]['distinct_vector_probe'] = {
                'query': f'"Synthetic benchmark specimen {variants}"',
                'path': f'mix-{variants:03d}/向量文档.pdf', 'absent_path': 'mix-000/向量文档.pdf',
            }
        print(label, 'prepared', flush=True)
    for label, workload in manifest['workloads'].items():
        workload['expected_records'] = workload['regular_files'] + workload['directories']
        workload['edits'] = {phase: edit_paths(phase, label.startswith('mixed'))
                             for phase in (('backlog', 'idle') if label.startswith('mixed') else ('idle',))}
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workspace', type=Path)
    parser.add_argument('--sizes', nargs='*', type=int, default=[10**5, 10**6])
    parser.add_argument('--mixed-rounds', type=int, default=32)
    parser.add_argument('--mixed-distinct-rounds', type=int, default=0,
                        help='Also create a mixed workload with distinguishable OCR and PDF content')
    args = parser.parse_args()
    if args.mixed_distinct_rounds not in (0,) and args.mixed_distinct_rounds < 3:
        parser.error('--mixed-distinct-rounds must be 0 or at least 3')
    prepare(args.workspace.resolve(), args.sizes, args.mixed_rounds, args.mixed_distinct_rounds)
