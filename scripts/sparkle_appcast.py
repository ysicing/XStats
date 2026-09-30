#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later
"""从旧客户端的 JSON 清单生成、签名或核验对应的 Sparkle XML。私钥只读取钥匙串。"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
XSTATS = "https://github.com/ysicing/xstats/appcast"
XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"
# 更新摘要只提供中英文；所有中文语言使用简体中文，其余语言使用英文。
NOTE_LANGUAGES = ("en", "zh-Hans")
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("xstats", XSTATS)
ROOT = Path(__file__).resolve().parent.parent


def tools_directory() -> Path:
    override = os.environ.get("SPARKLE_TOOLS_DIR")
    candidates = [Path(override)] if override else [
        ROOT / "Packages/XStatsKit/.build/artifacts/sparkle/Sparkle/bin",
        ROOT / "build/DerivedData-arm64/SourcePackages/artifacts/sparkle/Sparkle/bin",
    ]
    for directory in candidates:
        if all((directory / name).is_file() for name in ("sign_update", "generate_keys")):
            return directory
    raise ValueError("未找到 Sparkle 签名工具，请先解析 Swift 依赖或设置 SPARKLE_TOOLS_DIR")


def run_tool(tool: Path, *arguments: str) -> str:
    result = subprocess.run([str(tool), *arguments], capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"Sparkle {tool.name} 失败，请检查签名钥匙串账户及制品")
    return result.stdout.strip()


def archive_digest(archive: Path) -> str:
    digest = hashlib.sha256()
    with archive.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(manifest: Path, archive: Path) -> dict:
    feed = json.loads(manifest.read_text(encoding="utf-8"))
    url = urlsplit(feed["url"])
    if url.scheme != "https" or not url.netloc or Path(url.path).name != archive.name or archive.suffix != ".zip":
        raise ValueError("清单下载地址与升级 ZIP 不一致")
    if feed["sha256"] != archive_digest(archive) or feed["size"] != archive.stat().st_size:
        raise ValueError("清单摘要或大小与升级 ZIP 不一致")
    if not str(feed["build"]).isdigit() or int(feed["build"]) <= 0 or not feed["notes"]:
        raise ValueError("清单构建号或更新摘要无效")
    return feed


def load_localized_notes(feed: dict, path: Path = ROOT / "ReleaseNotes.json") -> dict[str, list[str]]:
    source = json.loads(path.read_text(encoding="utf-8"))
    if source.get("version") != feed["version"] or source.get("sourceNotes") != feed["notes"]:
        raise ValueError("ReleaseNotes.json 的版本或中文摘要已过期，请同步当前版本译文")
    translations = source.get("translations")
    required = set(NOTE_LANGUAGES) - {"zh-Hans"}
    if not isinstance(translations, dict) or set(translations) != required:
        raise ValueError("ReleaseNotes.json 必须包含英文摘要")
    for language, notes in translations.items():
        if (not isinstance(notes, list) or len(notes) != len(feed["notes"])
                or not all(isinstance(note, str) and note.strip() and "\n" not in note and "\r" not in note for note in notes)):
            raise ValueError(f"ReleaseNotes.json 的 {language} 摘要必须与中文条目一一对应")
    return {"zh-Hans": feed["notes"], **translations}


def make_feed(feed: dict, signature: str, localized_notes: dict[str, list[str]] | None = None) -> bytes:
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("无效的 Ed25519 更新包签名")
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "XStats"
    ET.SubElement(channel, "link").text = "https://github.com/ysicing/xstats"
    ET.SubElement(channel, "description").text = "XStats updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"XStats {feed['version']}"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = feed["build"]
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = feed["version"]
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = feed["minimumSystem"]
    ET.SubElement(item, f"{{{SPARKLE}}}hardwareRequirements").text = "arm64"
    notes = localized_notes if localized_notes is not None else {"zh-Hans": feed["notes"]}
    for language in NOTE_LANGUAGES:
        if language not in notes:
            continue
        text = "\n".join(notes[language])
        ET.SubElement(item, "description", {XML_LANG: language, f"{{{SPARKLE}}}format": "plain-text"}).text = text
        # Sparkle 只留下系统偏好对应的 description；保留各语言原文供应用内即时切换。
        ET.SubElement(item, f"{{{XSTATS}}}notes-{language}").text = text
    for field in ("date", "dmg", "sha256"):
        if feed.get(field):
            ET.SubElement(item, f"{{{XSTATS}}}{field}").text = feed[field]
    if feed.get("changelog"):
        ET.SubElement(item, f"{{{SPARKLE}}}fullReleaseNotesLink").text = feed["changelog"]
    ET.SubElement(item, "enclosure", {
        "url": feed["url"], "length": str(feed["size"]), "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": signature, f"{{{SPARKLE}}}installationType": "application",
    })
    ET.indent(rss)
    data = ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n"
    if len(data) > 256 * 1024:
        raise ValueError("Sparkle XML 超过后端读取上限 256 KiB")
    return data


def verify_feed(feed: dict, xml: Path, archive: Path, tools: Path, account: str, localized_notes: dict[str, list[str]] | None = None) -> None:
    if xml.stat().st_size > 256 * 1024:
        raise ValueError("签名后的 Sparkle XML 超过后端读取上限 256 KiB")
    items = ET.parse(xml).getroot().findall("channel/item")
    if len(items) != 1:
        raise ValueError("Sparkle XML 必须只包含一个版本条目")
    item = items[0]
    if item.findtext(f"{{{SPARKLE}}}hardwareRequirements") != "arm64":
        raise ValueError("Sparkle XML 的架构必须为 arm64")
    for field, element in (("build", "version"), ("version", "shortVersionString"), ("minimumSystem", "minimumSystemVersion")):
        if item.findtext(f"{{{SPARKLE}}}{element}") != feed[field]:
            raise ValueError(f"Sparkle XML 与 JSON 的 {field} 不一致")
    enclosure = item.find("enclosure")
    if (enclosure is None or enclosure.get("url") != feed["url"]
            or enclosure.get("length") != str(feed["size"])
            or enclosure.get(f"{{{SPARKLE}}}installationType") != "application"):
        raise ValueError("Sparkle XML 与 JSON 的安装包不一致")
    expected = {language: "\n".join(notes) for language, notes in
                (localized_notes if localized_notes is not None else {"zh-Hans": feed["notes"]}).items()}
    descriptions = item.findall("description")
    if (len(descriptions) != len(expected)
            or {node.get(XML_LANG): node.text for node in descriptions} != expected
            or any(node.get(f"{{{SPARKLE}}}format") != "plain-text" for node in descriptions)):
        raise ValueError("Sparkle XML 的多语言更新摘要不一致")
    prefix = f"{{{XSTATS}}}notes-"
    retained = [node for node in item if node.tag.startswith(prefix)]
    if (len(retained) != len(expected)
            or {node.tag.removeprefix(prefix): node.text for node in retained} != expected):
        raise ValueError("Sparkle XML 的应用语言摘要不一致")
    for field in ("date", "dmg", "sha256"):
        if item.findtext(f"{{{XSTATS}}}{field}") != feed.get(field):
            raise ValueError(f"Sparkle XML 与 JSON 的 {field} 不一致")
    if item.findtext(f"{{{SPARKLE}}}fullReleaseNotesLink") != feed.get("changelog"):
        raise ValueError("Sparkle XML 与 JSON 的更新日志链接不一致")
    run_tool(tools / "sign_update", "--account", account, "--verify", str(archive), enclosure.get(f"{{{SPARKLE}}}edSignature", ""))
    run_tool(tools / "sign_update", "--account", account, "--verify", str(xml))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--verify", action="store_true")
    arguments = parser.parse_args()
    tools = tools_directory()
    account = os.environ.get("SPARKLE_KEY_ACCOUNT", "work.12306.xstats.sparkle")
    # 防止在新机器上误用其他项目的私钥，生成一个客户端无法验证的更新源。
    public_key = run_tool(tools / "generate_keys", "--account", account, "-p")
    with (ROOT / "App/Info.plist").open("rb") as source:
        expected = plistlib.load(source).get("SUPublicEDKey")
    if public_key != expected:
        raise ValueError("签名账户的公钥与应用 SUPublicEDKey 不一致")
    feed = load_manifest(arguments.manifest, arguments.archive)
    localized_notes = load_localized_notes(feed)
    xml = arguments.archive.with_suffix(".xml")
    if not arguments.verify:
        signature = run_tool(tools / "sign_update", "--account", account, "-p", str(arguments.archive))
        xml.write_bytes(make_feed(feed, signature, localized_notes))
        run_tool(tools / "sign_update", "--account", account, str(xml))
    verify_feed(feed, xml, arguments.archive, tools, account, localized_notes)
    print(f"Sparkle 更新源已核验：{xml.name}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, ET.ParseError) as error:
        raise SystemExit(f"error: {error}") from error
