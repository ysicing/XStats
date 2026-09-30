#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later
"""生成 GitHub Release 的完整中文正文和英文更新说明，不执行发布。"""

import argparse
from pathlib import Path
import re

from appcast import release_notes
from sparkle_appcast import ROOT, load_localized_notes


def render(version: str, changelog: str, translations: Path) -> str:
    section = re.search(rf"^## {re.escape(version)} · \S+\n(.*?)(?=^## |\Z)", changelog, re.S | re.M)
    if not section or not section.group(1).strip():
        raise ValueError(f"CHANGELOG.md 里没有 {version} 的正文")
    _, notes = release_notes(changelog, version)
    if not notes:
        raise ValueError(f"CHANGELOG.md 里没有 {version} 的更新条目")
    localized = load_localized_notes({"version": version, "notes": notes}, translations)
    # 中文保留原有分类、链接和升级提示；英文复用发布摘要，避免维护两份重复译文。
    english = "\n".join(f"- {note}" for note in localized["en"])
    return f"## 中文\n\n{section.group(1).strip()}\n\n## English\n\n{english}\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    args = parser.parse_args()
    print(render(args.version, (ROOT / "CHANGELOG.md").read_text(encoding="utf-8"),
                 ROOT / "ReleaseNotes.json"), end="")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(f"error: {error}") from error
