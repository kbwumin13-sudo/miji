#!/usr/bin/env python3
"""Open a real 1.3.0 fixture index with a candidate and check content continuity."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
import time
import uuid


def command(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE, timeout=20)


def make_app(source, folder, identity):
    app = folder / identity / source.name
    app.parent.mkdir()
    shutil.copytree(source, app)
    plist = app / "Contents/Info.plist"
    info = plistlib.loads(plist.read_bytes())
    info["CFBundleIdentifier"] = identity
    plist.write_bytes(plistlib.dumps(info))
    command(["codesign", "--force", "--sign", "-", "--identifier", identity, str(app)])
    command(["codesign", "--verify", "--deep", "--strict", str(app)])
    return app


def query(db, sql, args=()):
    with sqlite3.connect(db.as_uri() + "?mode=ro", uri=True, timeout=.5) as reader:
        return reader.execute(sql, args).fetchall()


def wait(process, probe):
    until = time.monotonic() + 15
    while process.poll() is None and time.monotonic() < until:
        try:
            if probe():
                return
        except sqlite3.OperationalError:
            pass
        time.sleep(.05)
    raise RuntimeError("isolated app did not reach its expected state")


def snapshot(db):
    return {
        "schema": query(db, "PRAGMA user_version")[0][0],
        "roots": query(db, "SELECT id, online, enabled, payload FROM roots ORDER BY id"),
        "files": query(db, "SELECT id, root_id, relative_path, content_id, content_state, generation FROM files ORDER BY id"),
        "bodies": query(db, "SELECT id, hex(digest), length(packed) FROM content_blobs ORDER BY id"),
    }


def run(app, identity, support, source, check):
    prefs = {"images": True, "documents": True, "externalImages": True,
             "externalDocuments": True, "retainOffline": True, "includeHidden": True,
             "excludeDevelopmentCaches": False, "autoAddExternal": False, "ignoredExternalVolumes": []}
    command(["defaults", "write", identity, "indexingPreferences", "-data", json.dumps(prefs).encode().hex()])
    env = {key: value for key, value in os.environ.items() if not key.startswith("MIJI_")}
    env.update(MIJI_DATA_DIR=str(support), MIJI_INITIAL_ROOT=str(source), MIJI_UI_TESTING="1",
               MallocSpaceEfficient="1")
    pid = None
    log = support.parent / (identity + ".log")
    try:
        with log.open("w") as output:
            process = subprocess.Popen([app / "Contents/MacOS/Miji"], env=env, stdout=output, stderr=output)
            pid = process.pid
            try:
                wait(process, lambda: str(support / "index.sqlite") in command(["lsof", "-p", str(pid), "-Fn"]))
                check(process)
                time.sleep(.5)
            finally:
                process.terminate()
                process.wait(timeout=15)
    finally:
        subprocess.run(["defaults", "delete", identity], capture_output=True, timeout=10)
    return pid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline_app", type=Path)
    parser.add_argument("candidate_app", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="miji-upgrade-", dir="/private/tmp") as directory:
        workspace = Path(directory)
        base_id = "local.miji.upgrade." + uuid.uuid4().hex
        next_id = "local.miji.upgrade." + uuid.uuid4().hex
        baseline = make_app(args.baseline_app.resolve(), workspace, base_id)
        candidate = make_app(args.candidate_app.resolve(), workspace, next_id)
        source, offline = workspace / "source", workspace / "offline"
        source.mkdir()
        offline.mkdir()
        (source / "在线样本.txt").write_text("独立觅迹升级保留的在线正文")
        (offline / "离线样本.txt").write_text("独立觅迹升级保留的离线正文")
        support = workspace / "baseline"
        db = support / "index.sqlite"
        base_pid = run(baseline, base_id, support, source, lambda app: wait(app, lambda: query(
            db, "SELECT count(*) FROM files WHERE content_state='done'")[0][0] == 1))
        old_cli = baseline / "Contents/MacOS/miji-extract"
        indexed = json.loads(command([old_cli, "index", "--database", db, "--root", offline]))
        command([old_cli, "offline", "--database", db, "--root-id", indexed["rootID"]])
        offline.rename(workspace / "disconnected")
        before = snapshot(db)
        copied = workspace / "candidate"
        shutil.copytree(support, copied)
        candidate_db = copied / "index.sqlite"
        next_pid = run(candidate, next_id, copied, source, lambda app: wait(app, lambda: query(
            candidate_db, "SELECT count(*) FROM files WHERE content_state='done'")[0][0] == 2))
        after = snapshot(candidate_db)
        cli = candidate / "Contents/MacOS/miji-extract"
        hits = {}
        for key in ("在线", "离线"):
            results = json.loads(command([cli, "search", "--database", candidate_db, "--scope", "content",
                                          "--query", "升级保留的" + key + "正文"]))
            if len(results) != 1 or results[0]["online"] != (key == "在线"):
                raise AssertionError(f"incorrect {key} result")
            hits[key] = results[0]["name"]
        evidence = {
            "old_pid": base_pid, "new_pid": next_pid,
            "baseline_binary_sha256": hashlib.sha256((args.baseline_app / "Contents/MacOS/Miji").read_bytes()).hexdigest(),
            "candidate_binary_sha256": hashlib.sha256((args.candidate_app / "Contents/MacOS/Miji").read_bytes()).hexdigest(),
            "schema_files_roots_and_bodies_equal": before == after,
            "same_rows_and_generations": before["files"] == after["files"],
            "same_body_ids_digests_and_sizes": before["bodies"] == after["bodies"],
            "search": hits,
            "body_count": len(after["bodies"]),
            "pending": query(candidate_db, "SELECT count(*) FROM files WHERE content_state='pending'")[0][0],
        }
        args.report.write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + "\n")
        if before != after or evidence["pending"]:
            raise AssertionError("candidate unexpectedly requeued or changed stored data")


if __name__ == "__main__":
    main()
