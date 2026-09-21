#!/usr/bin/env python3
"""生成应用内在线升级读取的版本清单 appcast.json。

    Scripts/appcast.py <版本> <build> <下载地址前缀> <Apple 芯片 zip> <Apple 芯片 dmg> > dist/appcast.json

清单只发布 Apple Silicon 安装包。

更新摘要取自 CHANGELOG.md 中该版本的条目：每条取冒号或句号之前的部分（过短时带上冒号后的内容），最多 10 条。
"""
import hashlib
import json
import os
import re
import sys

MAX_NOTES = 10
MAX_LENGTH = 48


def summarize(line: str) -> str:
    text = re.sub(r"`([^`]*)`", r"\1", line).strip()
    text = re.sub(r"\*\*([^*]*)\*\*", r"\1", text)
    head = re.split(r"[：。；]", text, maxsplit=1)[0]
    # 冒号前只是个标题（如“主窗口”）时带上后面的内容，否则摘要看不出改了什么
    text = head if len(head) >= 10 else text.split("。", 1)[0]
    text = text.rstrip("，、 ")
    return text if len(text) <= MAX_LENGTH else text[: MAX_LENGTH - 1] + "…"


def release_notes(changelog: str, version: str) -> tuple[str, list[str]]:
    section = re.search(rf"^## {re.escape(version)} · (\S+)\n(.*?)(?=^## |\Z)", changelog, re.S | re.M)
    if not section:
        sys.exit(f"CHANGELOG.md 里没有 {version} 的条目")
    date, body = section.group(1), section.group(2)
    notes = []
    for line in body.splitlines():
        if line.startswith("- "):
            summary = summarize(line[2:])
            if summary and summary not in notes:
                notes.append(summary)
    if len(notes) > MAX_NOTES:
        rest = len(notes) - MAX_NOTES + 1
        notes = notes[: MAX_NOTES - 1] + [f"以及另外 {rest} 项新增、调整与修复"]
    return date, notes


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def asset(base: str, zip_path: str, dmg_path: str) -> dict:
    return {
        "url": f"{base}/{os.path.basename(zip_path)}",
        "sha256": sha256(zip_path),
        "size": os.path.getsize(zip_path),
        "dmg": f"{base}/{os.path.basename(dmg_path)}",
    }


def main() -> None:
    version, build, base, arm_zip, arm_dmg = sys.argv[1:6]
    root = os.path.join(os.path.dirname(__file__), "..")
    with open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8") as handle:
        date, notes = release_notes(handle.read(), version)
    feed = {
        "version": version,
        "build": build,
        "date": date,
        "minimumSystem": "14.0",
        **asset(base, arm_zip, arm_dmg),
        "notes": notes,
        "changelog": "https://getopenstats.com/#changelog",
    }
    json.dump(feed, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
