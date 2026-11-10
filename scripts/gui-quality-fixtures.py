#!/usr/bin/env python3
"""Prepare owned synthetic GUI data, including a real detachable APFS volume.

First generate inputs with MIJI_QA_DIR=/tmp/miji-qa scripts/e2e-check.py --fixtures-only.
Then run this with --fixtures /tmp/miji-qa/fixtures --cli .build/release/miji-cli
--directory /tmp/miji-gui. It writes launch.json and detaches its volume on exit.
Never pass a production database or an existing destination directory.
"""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli', required=True)
parser.add_argument('--fixtures', type=Path, required=True)
parser.add_argument('--directory', type=Path, required=True)
args = parser.parse_args()
base = args.directory.resolve()
if base.exists():
    raise SystemExit('Destination exists; choose a fresh isolated directory')
base.mkdir(parents=True)
cli = str(Path(args.cli).resolve())
source_pdf = args.fixtures / '向量文档.pdf'
if not source_pdf.is_file():
    raise SystemExit('Generate the authored E2E fixtures first')
data = base / 'data'
data.mkdir()
database = data / 'index.sqlite'
work = base / '工作盘'
image = base / 'owned-apfs.dmg'
mount = Path('/Volumes') / ('样本归档盘-QA-' + uuid.uuid4().hex[:8])


def run(*argv):
    return subprocess.check_output([str(x) for x in argv], stderr=subprocess.PIPE, timeout=180)


def call(command, *argv):
    return json.loads(run(cli, command, '--database', database, *argv))


def sample_app(path):
    contents = path / 'Contents'
    contents.mkdir(parents=True)
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'example.invalid.starnote.fixture',
        'CFBundleName': 'StarNote', 'CFBundlePackageType': 'APPL',
    }))


def populate(root):
    (root / '课程').mkdir(parents=True)
    shutil.copy2(source_pdf, root / '课程/项目计划.pdf')
    sample_app(root / '工具/StarNote.app')


def owned_devices():
    info = plistlib.loads(run('hdiutil', 'info', '-plist'))
    devices = []
    for item in info.get('images', []):
        if Path(item.get('image-path', '')).resolve() != image.resolve():
            continue
        entities = item.get('system-entities', [])
        whole = [x['dev-entry'] for x in entities if x.get('dev-entry', '').removeprefix('/dev/disk').isdigit()]
        devices += whole[:1] or [x['dev-entry'] for x in entities if x.get('mount-point') == str(mount)][:1]
    return devices


try:
    populate(work)
    (work / '资料').mkdir()
    shutil.copy2(source_pdf, work / '资料/项目计划.pdf')
    shutil.copy2(source_pdf, work / '资料/待恢复.pdf')
    sample_app(work / '办公/StarNote.app')
    (work / '资料/海棠计划.txt').write_text('海棠灌溉 项目计划：虚构的工作盘资料。\n', encoding='utf-8')
    indexed_work = call('index', '--root', work)
    if indexed_work['contentFailed'] or not indexed_work['scanComplete']:
        raise RuntimeError('Synthetic work volume indexing failed')
    # Preserve stored content while deliberately making the original unavailable.
    (work / '资料/待恢复.pdf').unlink()
    run('hdiutil', 'create', '-size', '128m', '-fs', 'APFS', '-volname', mount.name, '-type', 'UDIF', '-nospotlight', image)
    if mount.exists():
        raise RuntimeError('Unexpected mount point already exists')
    run('hdiutil', 'attach', '-nobrowse', '-mountpoint', mount, '-plist', image)
    archive = mount / '归档盘'
    populate(archive)
    (archive / '离线资料.txt').write_text('离线红杉：这份虚构正文保存在已索引内容中。\n连接样本归档盘后可打开原文件。', encoding='utf-8')
    indexed_archive = call('index', '--root', archive)
    if indexed_archive['contentFailed'] or not indexed_archive['scanComplete']:
        raise RuntimeError('Synthetic external volume indexing failed')
finally:
    for device in owned_devices():
        run('hdiutil', 'detach', device)

roots = call('refresh')
assert not next(r for r in roots if r['id'] == indexed_archive['rootID'])['isOnline']
manifest = {
    'data': str(data), 'initialRoot': str(work),
    'workRootID': indexed_work['rootID'], 'offlineRootID': indexed_archive['rootID'],
    'source': 'authored fixtures only', 'volumeDetached': not owned_devices(),
    'presets': {
        'supplementing': {'MIJI_UI_QUERY': '项目计划', 'MIJI_UI_CONTENT_DELAY_MS': '5000'},
        'filters': {'MIJI_UI_QUERY': '纸上银河', 'MIJI_UI_SCOPE': 'content', 'MIJI_UI_KIND': 'document', 'MIJI_UI_SORT': 'modified', 'MIJI_UI_ROOT_ID': indexed_work['rootID']},
        'cross-volume': {'MIJI_UI_QUERY': '项目计划'},
        'offline': {'MIJI_UI_QUERY': '离线红杉', 'MIJI_UI_SCOPE': 'content', 'MIJI_UI_ROOT_ID': indexed_archive['rootID']},
        'unavailable': {'MIJI_UI_QUERY': '待恢复'},
    },
    'requiredEnvironment': {'MIJI_DATA_DIR': str(data), 'MIJI_INITIAL_ROOT': str(work), 'MIJI_UI_TESTING': '1', 'MIJI_NO_AUTOSTART': '1', 'MIJI_UI_PAUSE_INDEX': '1'},
}
(base / 'launch.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(base / 'launch.json')
