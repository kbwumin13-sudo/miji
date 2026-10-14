#!/usr/bin/env python3
"""Local CLI acceptance with authored fixtures and an owned APFS image.

Run: python3 scripts/e2e-check.py
Prepare the GUI fixture folder: python3 scripts/e2e-check.py --fixtures-only
No pip dependencies, source changes, user indexes or user disks are required.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time
import traceback
import uuid
import zipfile
from xml.sax.saxutils import escape

PROJECT = Path(__file__).resolve().parents[1]
QA = PROJECT / "output" / "qa"
FIXTURES = QA / "fixtures"


def xml(text: str) -> str:
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + text


def archive(path: Path, parts: dict[str, str | bytes]) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as package:
        for name, value in parts.items():
            package.writestr(name, value.encode("utf-8") if isinstance(value, str) else value)


def fixtures() -> dict:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swift", str(PROJECT / "scripts/qa-fixtures.swift"), str(FIXTURES)], cwd=PROJECT, check=True, timeout=120)
    content_types = 'http://schemas.openxmlformats.org/package/2006/content-types'
    package_rel = 'http://schemas.openxmlformats.org/package/2006/relationships'
    office_rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    word = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
    drawing = 'http://schemas.openxmlformats.org/drawingml/2006/main'
    presentation = 'http://schemas.openxmlformats.org/presentationml/2006/main'
    spreadsheet = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'

    def types(overrides: dict[str, str]) -> str:
        entries = ''.join(f'<Override PartName="/{name}" ContentType="{mime}"/>' for name, mime in overrides.items())
        return xml(f'<Types xmlns="{content_types}"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>{entries}</Types>')

    def relations(rows: list[tuple[str, str, str]]) -> str:
        entries = ''.join(f'<Relationship Id="{name}" Type="{office_rel}/{kind}" Target="{target}"/>' for name, kind, target in rows)
        return xml(f'<Relationships xmlns="{package_rel}">{entries}</Relationships>')

    def paragraph(text: str) -> str:
        return f'<w:p><w:r><w:t xml:space="preserve">{escape(text)}</w:t></w:r></w:p>'

    txt = FIXTURES / "课程 资料" / "数学分析笔记.txt"
    txt.parent.mkdir(exist_ok=True)
    txt.write_text("青竹微风：连续函数的极限证明。\n共同关键词 正式资料。\n精确短语 alpha beta；标点 C++ 与 foo-bar。\n注入式文字 ' OR 1=1 -- 是普通文本。\n", encoding="utf-8")
    (txt.parent / "数学草稿.txt").write_text("青竹微风：连续函数的草稿。\n共同关键词 草稿。\n", encoding="utf-8")
    (FIXTURES / "知识卡片.md").write_text("# 觅迹验收\n\n松间清泉：Markdown 正文索引。\n共同关键词 阅读材料。\n", encoding="utf-8")
    archive(FIXTURES / "文字处理.docx", {
        "[Content_Types].xml": types({"word/document.xml": "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", "word/header1.xml": "application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"}),
        "_rels/.rels": relations([("rId1", "officeDocument", "word/document.xml")]),
        "word/document.xml": xml(f'<w:document xmlns:w="{word}" xmlns:r="{office_rel}"><w:body>{paragraph("云帆远航：DOCX 正文与段落。")}{paragraph("共同关键词 文档材料。")}'
                                 f'<w:tbl><w:tr><w:tc>{paragraph("左格白露")}</w:tc><w:tc>{paragraph("右格秋分")}</w:tc></w:tr></w:tbl><w:sectPr><w:headerReference w:type="default" r:id="rIdHeader"/></w:sectPr></w:body></w:document>'),
        "word/_rels/document.xml.rels": relations([("rIdHeader", "header", "header1.xml")]),
        "word/header1.xml": xml(f'<w:hdr xmlns:w="{word}">{paragraph("页眉秋水")}</w:hdr>'),
    })
    archive(FIXTURES / "演示文稿.pptx", {
        "[Content_Types].xml": types({"ppt/presentation.xml": "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml", "ppt/slides/slide1.xml": "application/vnd.openxmlformats-officedocument.presentationml.slide+xml", "ppt/notesSlides/notesSlide1.xml": "application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml"}),
        "_rels/.rels": relations([("rId1", "officeDocument", "ppt/presentation.xml")]),
        "ppt/presentation.xml": xml(f'<p:presentation xmlns:p="{presentation}" xmlns:r="{office_rel}"><p:sldIdLst><p:sldId id="256" r:id="rIdSlide"/></p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>'),
        "ppt/_rels/presentation.xml.rels": relations([("rIdSlide", "slide", "slides/slide1.xml")]),
        "ppt/slides/slide1.xml": xml(f'<p:sld xmlns:p="{presentation}" xmlns:a="{drawing}"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="QA text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="457200" y="457200"/><a:ext cx="8229600" cy="4572000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="zh-CN" sz="2800"/><a:t>幻灯晨光：PPTX 幻灯片正文。</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>'),
        "ppt/slides/_rels/slide1.xml.rels": relations([("rIdNotes", "notesSlide", "../notesSlides/notesSlide1.xml")]),
        "ppt/notesSlides/notesSlide1.xml": xml(f'<p:notes xmlns:p="{presentation}" xmlns:a="{drawing}"><p:cSld><p:spTree><p:sp><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>备注山岚：演讲者笔记。</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>'),
    })
    archive(FIXTURES / "数据工作簿.xlsx", {
        "[Content_Types].xml": types({"xl/workbook.xml": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml", "xl/worksheets/sheet1.xml": "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml", "xl/sharedStrings.xml": "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"}),
        "_rels/.rels": relations([("rId1", "officeDocument", "xl/workbook.xml")]),
        "xl/workbook.xml": xml(f'<workbook xmlns="{spreadsheet}" xmlns:r="{office_rel}"><sheets><sheet name="验收数据" sheetId="1" r:id="rIdSheet"/></sheets></workbook>'),
        "xl/_rels/workbook.xml.rels": relations([("rIdSheet", "worksheet", "worksheets/sheet1.xml"), ("rIdShared", "sharedStrings", "sharedStrings.xml")]),
        "xl/sharedStrings.xml": xml(f'<sst xmlns="{spreadsheet}" count="1" uniqueCount="1"><si><r><t>单元</t></r><r><t>碧波：共享文字。</t></r></si></sst>'),
        "xl/worksheets/sheet1.xml": xml(f'<worksheet xmlns="{spreadsheet}"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="inlineStr"><is><t>内联雪松</t></is></c><c r="D1"><f>1+2</f><v>3</v></c></row></sheetData></worksheet>'),
    })
    preview = (FIXTURES / "iWork预览素材.pdf").read_bytes()
    for name in ["预览文书.pages", "预览表格.numbers", "预览演示.key"]:
        # This is explicitly a Preview.pdf test container, not authored IWA data.
        archive(FIXTURES / name, {"QuickLook/Preview.pdf": preview})
    (FIXTURES / "iWork预览素材.pdf").unlink()
    expected = {
        "fixtureDirectory": str(FIXTURES),
        "documents": {"数学分析笔记.txt": "青竹微风", "数学草稿.txt": "青竹微风", "知识卡片.md": "松间清泉", "向量文档.pdf": "纸上银河", "文字处理.docx": "云帆远航", "演示文稿.pptx": "幻灯晨光", "数据工作簿.xlsx": "单元碧波", "预览文书.pages": "预览星河", "预览表格.numbers": "预览星河", "预览演示.key": "预览星河"},
        "ocr": {"file": "图像样本.png", "text": "海棠春风", "rasterPDF": "扫描文档.pdf"},
        "boundaries": ["全部素材由脚本生成，未使用用户资料或原应用数据。", "iWork 是仅含 QuickLook/Preview.pdf 的自建测试容器，未验证真实 IWA 文档。", "Office 为手写最小 OOXML 包，未验证第三方 Office 排版兼容性。"],
        "sha256": {str(p.relative_to(FIXTURES)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(FIXTURES.rglob("*")) if p.is_file()},
    }
    QA.mkdir(parents=True, exist_ok=True)
    (QA / "fixtures.json").write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return expected


class Acceptance:
    def __init__(self, run_id: str, cli: str | None):
        self.run_id = run_id
        self.run_dir = QA / "runs" / run_id
        self.logs = self.run_dir / "logs"
        self.logs.mkdir(parents=True)
        self.datastore = QA / "datastore" / run_id
        self.datastore.mkdir(parents=True)
        self.database = self.datastore / "index.sqlite"
        self.cli = Path(cli).resolve() if cli else None
        self.image = self.run_dir / "miji-qa-apfs.dmg"
        self.mounts = [Path("/Volumes") / f"MijiQA-{run_id}-{letter}" for letter in ["A", "B"]]
        self.checks: list[dict] = []
        self.commands: list[dict] = []
        self.context: dict = {"runID": run_id, "runDirectory": str(self.run_dir), "database": str(self.database), "fixtureDirectory": str(FIXTURES)}

    def run(self, args: list[str | Path], label: str, timeout: int = 120) -> bytes:
        argv = [str(a) for a in args]
        number = len(self.commands) + 1
        stem = f"{number:03d}-{re.sub(r'[^a-zA-Z0-9_-]', '_', label)}"
        start = time.monotonic()
        print(f"[{number:03d}] {label}", flush=True)
        try:
            result = subprocess.run(argv, cwd=PROJECT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
            stdout, stderr, code = result.stdout, result.stderr, result.returncode
        except subprocess.TimeoutExpired as error:
            stdout, stderr, code = error.stdout or b"", error.stderr or b"", -1
            stderr += f"\ncommand timed out after {timeout}s".encode()
        (self.logs / f"{stem}.stdout").write_bytes(stdout)
        (self.logs / f"{stem}.stderr").write_bytes(stderr)
        self.commands.append({"args": argv, "label": label, "exitCode": code, "elapsedSeconds": round(time.monotonic() - start, 4), "stdout": str((self.logs / f"{stem}.stdout").relative_to(self.run_dir)), "stderr": str((self.logs / f"{stem}.stderr").relative_to(self.run_dir))})
        if code:
            raise RuntimeError(f"{label} 退出码 {code}：{stderr.decode('utf-8', 'replace')[-1800:]}")
        return stdout

    def check(self, name: str, passed: bool, details=None) -> None:
        self.checks.append({"name": name, "passed": bool(passed), "details": details})
        if not passed:
            print(f"MAIN NOTICE / 验收失败：{name}；证据：{details}", flush=True)

    def call(self, command: str, *args: str | Path, label: str | None = None):
        return json.loads(self.run([self.cli, command, "--database", self.database, *args], label or command))

    def search(self, query: str, *, scope="all", kind=None, online=False, label="search") -> list[dict]:
        args = ["--query", query, "--scope", scope, "--limit", "1000"]
        if kind:
            args += ["--kind", kind]
        if online:
            args.append("--online-only")
        return self.call("search", *args, label=label)

    @staticmethod
    def names(hits: list[dict]) -> set[str]:
        return {hit["name"] for hit in hits}

    def local_checks(self, expected: dict) -> None:
        indexed = self.call("index", "--root", FIXTURES, label="index-fixtures")
        self.context["fixtureIndex"] = indexed
        self.check("完整扫描且提取无失败", indexed["scanComplete"] and not indexed["scanErrors"] and indexed["contentFailed"] == 0, indexed)
        self.context["fixtureRootID"] = indexed["rootID"]
        for name, token in expected["documents"].items():
            hits = self.search(token, scope="content", kind="document", label=f"body-{Path(name).suffix[1:]}")
            matches = [h for h in hits if h["name"] == name]
            self.check(f"{name} 正文命中", len(matches) == 1 and "正文" in matches[0]["matchedIn"] and token in matches[0]["snippet"], matches)
        for token, name in [("页眉秋水", "文字处理.docx"), ("左格白露", "文字处理.docx"), ("备注山岚", "演示文稿.pptx"), ("内联雪松", "数据工作簿.xlsx")]:
            self.check(f"补充内容 {token}", name in self.names(self.search(token, scope="content", label="additional-office-content")))
        for name in ["图像样本.png", "扫描文档.pdf"]:
            hits = self.search("海棠春风", scope="content", label="real-ocr")
            matches = [h for h in hits if h["name"] == name]
            self.check(f"{name} 中文 OCR", len(matches) == 1 and "正文" in matches[0]["matchedIn"], matches)
        extracted = json.loads(self.run([self.cli, "extract", "--file", FIXTURES / "图像样本.png"], "extract-image-ocr-classification"))
        self.context["imageExtraction"] = extracted
        self.check("图片 OCR 提取证据", "海棠春风" in extracted["text"], extracted["text"])
        labels = extracted.get("labels", [])
        english = [label for label in labels if label.isascii() and any(c.isalpha() for c in label)]
        chinese = [label for label in labels if any('\u4e00' <= c <= '\u9fff' for c in label)]
        self.check("真实 Vision 分类产生英文类别与中文别名", bool(english) and bool(chinese), labels)
        for label in (english[:1] + chinese[:1]):
            # Quote labels to preserve compound identifiers and literal spaces.
            query = '"' + label.replace('\\', '\\\\').replace('"', '\\"') + '"'
            hits = self.search(query, scope="content", kind="image", label="classification-label-search")
            matches = [h for h in hits if h["name"] == "图像样本.png"]
            self.check(f"图片标签检索 {label}", len(matches) == 1 and "图片标签" in matches[0]["matchedIn"], matches)
        for query in ["shuxuefenxibiji", "sxfxbj"]:
            hits = self.search(query, scope="name", label="filename-pinyin")
            self.check(f"文件名拼音 {query}", self.names(hits) == {"数学分析笔记.txt"} and hits[0]["matchedIn"] == "文件名", hits)
        for token in ["竹", "青竹"]:
            hits = self.search(token, scope="content", label="short-chinese")
            self.check(f"短中文 {token}", self.names(hits) == {"数学分析笔记.txt", "数学草稿.txt"}, hits)
        hits = self.search('青竹 连续 ext:txt kind:文档 path:"课程 资料" -草稿', label="combined-query")
        self.check("多词 AND / ext / kind / path / 排除", self.names(hits) == {"数学分析笔记.txt"}, hits)
        hits = self.search('共同关键词 -草稿 -ext:md', kind="document", label="negative-filters")
        self.check("负词与负扩展过滤", self.names(hits) == {"数学分析笔记.txt", "文字处理.docx"}, hits)
        self.check("正文 scope 排除纯文件名命中", not self.search("shuxuefenxibiji", scope="content", label="scope-filter"))
        self.check("图片 kind 排除文档正文", not self.search("青竹微风", kind="image", label="kind-filter"))
        for query in ['"alpha beta"', '"C++"', '"foo-bar"', '"\' OR 1=1 --"']:
            hits = self.search(query, scope="content", label="phrase-and-punctuation")
            self.check(f"字面短语 {query}", self.names(hits) == {"数学分析笔记.txt"}, hits)
        self.check("SQL 注入式 ext 输入不扩大结果", not self.search("ext:txt'OR'1'='1", label="sql-injection-filter"))
        # Each CLI invocation opens a fresh connection, including this roots/stats/search.
        roots = self.call("roots", label="roots-restart-persistence")
        stats = self.call("stats", label="stats-local")
        self.context["localStatistics"] = stats
        self.check("独立 CLI 进程保留 root 与统计", any(r["id"] == indexed["rootID"] for r in roots) and stats["errors"] == 0 and stats["pending"] == 0 and stats["indexedContent"] >= len(expected["documents"]) + 2, stats)
        all_hits = self.search("", label="no-self-index")
        self.check("日志与 datastore 未被索引", all(Path(hit["path"]).is_relative_to(FIXTURES) for hit in all_hits), {"files": len(all_hits), "datastore": str(self.datastore)})
        for extension in ["pages", "numbers", "key"]:
            name = next(name for name in expected["documents"] if name.endswith('.' + extension))
            preview = json.loads(self.run([self.cli, "extract", "--file", FIXTURES / name], f"iwork-warning-{extension}"))
            self.check(f"iWork {extension} 预览边界明确", "预览星河" in preview["text"] and "预览" in (preview.get("warning") or ""), preview)
        # Test explicit CLI flags separately from physical unmount detection.
        self.call("offline", "--root-id", indexed["rootID"], label="explicit-offline")
        hits = self.search("青竹微风", label="explicit-offline-search")
        self.check("显式 offline 可查正文", len(hits) == 2 and all(not h["online"] for h in hits), hits)
        self.check("online-only 过滤离线 root", not self.search("青竹微风", online=True, label="online-only-filter"))
        self.call("online", "--root-id", indexed["rootID"], label="explicit-online")
        self.check("显式 online 恢复", len(self.search("青竹微风", online=True, label="explicit-online-search")) == 2)

    def owned_devices(self) -> list[str]:
        info = plistlib.loads(self.run(["hdiutil", "info", "-plist"], "owned-image-inventory"))
        devices = []
        for image in info.get("images", []):
            path = image.get("image-path")
            if not path or Path(path).resolve() != self.image.resolve():
                continue
            entries = image.get("system-entities", [])
            whole = [e["dev-entry"] for e in entries if re.fullmatch(r"/dev/disk\d+", e.get("dev-entry", ""))]
            devices += whole[:1] or [e["dev-entry"] for e in entries if e.get("mount-point") in [str(m) for m in self.mounts]][:1]
        return devices

    def detach_owned(self) -> None:
        for device in self.owned_devices():
            self.run(["hdiutil", "detach", device], "detach-owned-image")

    def disk_checks(self) -> None:
        self.run(["hdiutil", "create", "-size", "128m", "-fs", "APFS", "-volname", f"MijiQA-{self.run_id}", "-type", "UDIF", "-nospotlight", self.image], "create-owned-apfs", timeout=180)
        mount_a, mount_b = self.mounts
        # Disk Arbitration creates/removes these mount points; direct mkdir in
        # /Volumes is not allowed for an ordinary macOS user.
        for mount in self.mounts:
            if mount.exists():
                raise RuntimeError(f"测试挂载点意外存在，拒绝复用：{mount}")
        attached = plistlib.loads(self.run(["hdiutil", "attach", "-nobrowse", "-mountpoint", mount_a, "-plist", self.image], "attach-first-path"))
        self.check("挂载的自建卷确为 APFS", any(e.get("mount-point") == str(mount_a) and e.get("volume-kind") == "apfs" for e in attached["system-entities"]), attached)
        source = mount_a / "自建资料"
        source.mkdir()
        (source / "磁盘资料.txt").write_text("离线红杉：这是独立 APFS 测试卷的正文。\n挂载路径改变后内容仍应可查。\n", encoding="utf-8")
        indexed = self.call("index", "--root", source, label="index-owned-volume")
        roots = self.call("roots", label="volume-roots-before-unmount")
        root = next(r for r in roots if r["id"] == indexed["rootID"])
        self.context["volumeBefore"] = root
        self.check("APFS 测试卷完整索引与 UUID 记录", indexed["scanComplete"] and indexed["contentCompleted"] == 1 and indexed["contentFailed"] == 0 and root["isExternal"] and root.get("volumeUUID") and root["volumeRelativePath"] == "自建资料", root)
        self.check("已连接测试卷可查正文", self.names(self.search("离线红杉", online=True, label="volume-online-body")) == {"磁盘资料.txt"})
        self.detach_owned()
        offline_roots = self.call("refresh", label="automatic-offline-refresh")
        offline_root = next(r for r in offline_roots if r["id"] == root["id"])
        self.context["volumeOffline"] = offline_root
        self.check("卸载后 refresh 自动 offline", offline_root["isOnline"] is False, offline_root)
        hits = self.search("离线红杉", scope="content", label="detached-volume-body")
        self.check("卸载后正文保留可搜索", len(hits) == 1 and hits[0]["online"] is False and "正文" in hits[0]["matchedIn"] and not Path(hits[0]["path"]).exists(), hits)
        self.check("卸载后 online-only 无结果", not self.search("离线红杉", online=True, label="detached-online-filter"))
        self.run(["hdiutil", "attach", "-nobrowse", "-mountpoint", mount_b, "-plist", self.image], "reattach-different-path")
        refreshed = self.call("refresh", label="same-uuid-rebase-refresh")
        rebased = next(r for r in refreshed if r["id"] == root["id"])
        self.context["volumeRebased"] = rebased
        self.check("同 UUID 异路径 rebase 与 online 恢复", rebased["volumeUUID"] == root["volumeUUID"] and rebased["path"] == str(mount_b / "自建资料") and rebased["isOnline"] is True, rebased)
        hits = self.search("离线红杉", scope="content", online=True, label="rebased-online-body")
        self.check("rebase 后正文和新文件路径有效", len(hits) == 1 and hits[0]["path"] == str(mount_b / "自建资料" / "磁盘资料.txt") and Path(hits[0]["path"]).is_file(), hits)
        self.detach_owned()
        self.call("refresh", label="final-volume-offline")

    def cleanup(self) -> None:
        if self.image.exists():
            self.detach_owned()
            self.check("测试镜像全部卸载", not self.owned_devices())
        self.check("自建挂载点均已清理", all(not mount.exists() for mount in self.mounts))
        self.context["cleanup"] = "测试卷已卸载；自建镜像、数据库与日志保留。"

    def report(self, expected: dict) -> bool:
        passed = bool(self.checks) and all(c["passed"] for c in self.checks)
        result = {"status": "passed" if passed else "failed", "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "checksPassed": sum(c["passed"] for c in self.checks), "checksTotal": len(self.checks), **self.context, "checks": self.checks, "commands": self.commands, "boundaries": expected["boundaries"]}
        (self.run_dir / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        failures = [c for c in self.checks if not c["passed"]]
        lines = [f"# Miji CLI 端到端验收：{result['status']}", "", f"- 检查：{result['checksPassed']}/{result['checksTotal']} 通过", f"- 样本：`{FIXTURES}`", f"- 独立数据库：`{self.database}`", f"- CLI：`{self.cli}`", f"- 完整证据：`result.json` 和 `logs/`", f"- 清理：{self.context.get('cleanup', '未完成，请检查 result.json')}", "", "## 失败与阻塞", ""]
        lines += [f"- {c['name']}：{c['details']}" for c in failures] or ["无。"]
        lines += ["", "## 验证边界", ""] + [f"- {boundary}" for boundary in expected["boundaries"]]
        lines += ["- 分类类别由真实 Vision 输出决定；断言非空英文类别、中文别名及二者可检索，不固定系统模型排序。", "- 只验证自建小样本与小型 APFS 镜像；未验证用户外置盘或大规模索引性能。", "", "## 重复运行", "", "```sh", "python3 scripts/e2e-check.py", "```", ""]
        (self.run_dir / "验收报告.md").write_text("\n".join(lines), encoding="utf-8")
        (QA / "latest.json").write_text(json.dumps({"runID": self.run_id, "status": result["status"], "result": str(self.run_dir / "result.json"), "report": str(self.run_dir / "验收报告.md")}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"RESULT {result['status']} {result['checksPassed']}/{result['checksTotal']} {self.run_dir / 'result.json'}", flush=True)
        return passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures-only", action="store_true")
    parser.add_argument("--cli", help="Use a specific already-built miji-cli")
    args = parser.parse_args()
    expected = fixtures()
    print(f"GUI FIXTURES READY: {FIXTURES}", flush=True)
    if args.fixtures_only:
        return 0
    run_id = dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    acceptance = Acceptance(run_id, args.cli)
    # SIGTERM follows the same finally-cleanup path as Ctrl-C.
    def stop(signum, frame):
        raise KeyboardInterrupt(f"signal {signum}")
    signal.signal(signal.SIGTERM, stop)
    try:
        if not acceptance.cli:
            binary = acceptance.run(["swift", "build", "--show-bin-path"], "locate-debug-cli").decode().strip().splitlines()[-1]
            acceptance.cli = Path(binary) / "miji-cli"
        if not acceptance.cli.is_file():
            raise RuntimeError("CLI 尚未构建，请等待打包完成或先运行 swift build。")
        # A concurrent packaging build may replace the original executable.
        # Every command in this run uses the same byte-for-byte CLI snapshot.
        source_cli = acceptance.cli
        binary_bytes = source_cli.read_bytes()
        acceptance.cli = acceptance.run_dir / "miji-cli"
        acceptance.cli.write_bytes(binary_bytes)
        acceptance.cli.chmod(source_cli.stat().st_mode & 0o777)
        acceptance.context["cliSource"] = str(source_cli)
        acceptance.context["cliSHA256"] = hashlib.sha256(binary_bytes).hexdigest()
        acceptance.local_checks(expected)
        acceptance.disk_checks()
    except (Exception, KeyboardInterrupt) as error:
        acceptance.check("执行阻塞", False, str(error))
        (acceptance.run_dir / "exception.txt").write_text(traceback.format_exc(), encoding="utf-8")
    finally:
        try:
            acceptance.cleanup()
        except Exception as error:
            acceptance.check("测试卷清理失败", False, str(error))
    return 0 if acceptance.report(expected) else 1


if __name__ == "__main__":
    sys.exit(main())
