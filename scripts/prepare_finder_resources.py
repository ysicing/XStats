#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later

"""签名前仅精简 Finder 扩展的资源副本，不改动主程序、Widget 或源码译表。"""

import plistlib
import re
import shutil
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FINDER_SOURCES = (
    "Apps/XStats/FinderExtension/FinderExtension.swift",
    "Packages/XStatsKit/Sources/FinderDocuments/FinderDocument.swift",
    "Packages/XStatsKit/Sources/FinderDocuments/FinderDocumentStore.swift",
)
LOCALIZATION = Path("Packages/XStatsKit/Sources/Localization")


def finder_keys(root):
    text = (root / LOCALIZATION / "FinderDocumentTranslations.swift").read_text()
    table = re.search(r'finderDocumentEnglish = #"""(.*?)"""#', text, re.S)
    if table is None:
        raise ValueError("缺少 Finder 专用英文翻译表")
    keys = {line.strip().split("\t", 1)[0] for line in table[1].splitlines() if "\t" in line}
    if not keys:
        raise ValueError("Finder 专用翻译表不能为空")
    for relative in FINDER_SOURCES:
        source = (root / relative).read_text()
        literals = re.findall(r'"((?:[^"\\\n]|\\.)*)"', source)
        used = {value for value in literals if re.search(r"[\u4e00-\u9fff]", value)}
        if missing := used - keys:
            raise ValueError(f"Finder 文案未加入专用翻译表：{sorted(missing)}")
    return keys


def require_local(path, app):
    path.relative_to(app)
    for candidate in (path, *path.parents):
        if candidate.is_symlink():
            raise ValueError(f"Finder 资源不能使用符号链接：{candidate}")
        if candidate == app:
            break


def prepare(app):
    app = Path(app).absolute()
    extension = app / "Contents/PlugIns/XStatsFinderExtension.appex"
    for bundle, identifier in (
        (app, "work.12306.xstats.app"),
        (extension, "work.12306.xstats.app.finder"),
    ):
        info = bundle / "Contents/Info.plist"
        require_local(info, app)
        if plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") != identifier:
            raise ValueError(f"Bundle ID 与 Finder 资源精简目标不一致：{bundle}")
    resources = extension / "Contents/Resources"
    catalogs = resources / "XStatsKit_Localization.bundle/Contents/Resources"
    templates = resources / "XStatsKit_FinderDocuments.bundle"
    require_local(catalogs, app)
    require_local(templates, app)
    keys = finder_keys(ROOT)
    expected = {path.name for path in (ROOT / LOCALIZATION / "Resources").glob("*.tsv")}
    actual = {path.name for path in catalogs.glob("*.tsv")}
    if not expected or actual != expected:
        raise ValueError(f"Finder 语言资源不完整：{sorted(expected ^ actual)}")
    prepared = {}
    for name in sorted(expected):
        path = catalogs / name
        require_local(path, app)
        selected = []
        found = set()
        for line in path.read_text(encoding="utf-8").splitlines():
            parts = line.split("\t", 1)
            if parts[0] not in keys:
                continue
            if len(parts) != 2 or not parts[1] or parts[0] in found:
                raise ValueError(f"Finder 译文无效或重复：{name}，{parts[0]}")
            selected.append(line)
            found.add(parts[0])
        if found != keys:
            raise ValueError(f"Finder 缺少译文：{name}，{sorted(keys - found)}")
        prepared[path] = ("\n".join(selected) + "\n").encode("utf-8")
    if templates.exists() and not templates.is_dir():
        raise ValueError("Finder 模板资源包不是目录")
    # 所有语言检查通过后才修改副本；扩展仅入队请求，模板由主程序读取。
    for path, data in prepared.items():
        if path.read_bytes() != data:
            path.write_bytes(data)
    if templates.exists():
        shutil.rmtree(templates)
    return len(keys), len(prepared)


if __name__ == "__main__":
    try:
        keys, languages = prepare(Path(sys.argv[1]))
        print(f"Finder 资源已精简：{languages} 份译表各保留 {keys} 条文案，模板仅保留在主程序")
    except (IndexError, OSError, ValueError) as error:
        sys.exit(f"error: {error}")
