#!/usr/bin/env python3
"""Read-only, bounded production-index observation. Does not open source files."""
import argparse
import ctypes
import datetime
import json
from pathlib import Path
import sqlite3
import shutil
import subprocess
import time
from zoneinfo import ZoneInfo

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--database', type=Path, default=Path.home() / 'Library/Application Support/Miji/index.sqlite')
parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / 'output/index-diagnosis')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
latest = args.output / 'monitor-latest.json'
previous = json.loads(latest.read_text()) if latest.exists() else None
start = time.monotonic()
result = {'time': datetime.datetime.now(ZoneInfo('Asia/Shanghai')).isoformat(), 'database': str(args.database)}
result['freeDiskBytes'] = shutil.disk_usage(args.database.parent).free
result['databaseBytes'] = args.database.stat().st_size if args.database.exists() else 0
wal=Path(str(args.database)+'-wal')
result['walBytes'] = wal.stat().st_size if wal.exists() else 0
processes = subprocess.run(['ps','-axo','pid,etime,pcpu,rss,comm'], capture_output=True, text=True, check=True).stdout
result['processes'] = [line.strip() for line in processes.splitlines() if line.rstrip().endswith('/Miji')]
# RSS hides compressed/swapped memory. Track the actual footprint of the app
# and its bounded extraction worker without pausing either process.
class RUsageInfo(ctypes.Structure):
    _fields_ = [('uuid',ctypes.c_uint8 * 16)] + [(name,ctypes.c_uint64) for name in (
        'user_time','system_time','idle_wakeups','interrupt_wakeups','pageins',
        'wired_size','resident_size','phys_footprint','start_time','exit_time')]

result['processMemory'] = []
try:
    libproc=ctypes.CDLL('/usr/lib/libproc.dylib')
    libproc.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
    libproc.proc_pid_rusage.restype=ctypes.c_int
    for line in processes.splitlines():
        if not line.rstrip().endswith(('/Miji','/miji-extract')):
            continue
        pid=int(line.split()[0]);info=RUsageInfo()
        if libproc.proc_pid_rusage(pid,0,ctypes.byref(info)) == 0:
            result['processMemory'].append({'pid':pid,'role':'extractor' if line.rstrip().endswith('/miji-extract') else 'app',
                                           'residentBytes':info.resident_size,'footprintBytes':info.phys_footprint})
except (OSError,AttributeError):
    pass
try:
    database = sqlite3.connect(args.database.resolve().as_uri() + '?mode=ro', uri=True, timeout=2)
    database.set_progress_handler(lambda: int(time.monotonic() - start > 15), 1000)
    # Covering metadata indexes keep monitoring away from large document bodies.
    rows = database.execute('SELECT kind,content_state,count(*) FROM files INDEXED BY files_pending GROUP BY root_id,content_state,kind').fetchall()
    result['counts'] = rows
    result['completed'] = sum(count for kind,state,count in rows if state == 'done')
    result['pending'] = sum(count for kind,state,count in rows if state == 'pending')
    result['errors'] = sum(count for kind,state,count in rows if state == 'error')
    result['files'] = sum(count for _,_,count in rows)
    roots = []
    for (payload,) in database.execute('SELECT payload FROM roots'):
        root = json.loads(payload)
        generation = database.execute('SELECT max(generation) FROM files WHERE root_id=?',(root['id'],)).fetchone()[0]
        visited = database.execute('SELECT count(*) FROM files WHERE root_id=? AND generation=?',(root['id'],generation)).fetchone()[0]
        roots.append({'name':root['name'],'online':root['isOnline'],'enabled':root['enabled'],'generation':generation,'visited':visited,'lastError':root.get('lastError')})
    result['roots'] = roots
    if previous and 'completed' in previous:
        result['completedDelta'] = result['completed'] - previous['completed']
        result['pendingDelta'] = result['pending'] - previous['pending']
        result['previousTime'] = previous['time']
    database.close()
except sqlite3.Error as error:
    result['observationError'] = str(error)
result['elapsedSeconds'] = round(time.monotonic()-start,3)
encoded = json.dumps(result,ensure_ascii=False,indent=2)
latest.write_text(encoded+'\n')
with (args.output / 'monitor-history.jsonl').open('a') as history:
    history.write(json.dumps(result,ensure_ascii=False)+'\n')
print(encoded)
