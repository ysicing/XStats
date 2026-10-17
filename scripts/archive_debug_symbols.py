#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Keep UUID-matched release dSYMs outside distributable bundles and build cleanup."""

import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


BINARIES = (
    ("Contents/MacOS/XStats", "XStats.app.dSYM"),
    ("Contents/MacOS/XStatsHelper", "XStatsHelper.dSYM"),
    ("Contents/PlugIns/XStatsWidget.appex/Contents/MacOS/XStatsWidget", "XStatsWidget.appex.dSYM"),
    ("Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle", "Sparkle.framework.dSYM"),
    ("Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate", "Autoupdate.dSYM"),
    ("Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app/Contents/MacOS/Updater", "Updater.app.dSYM"),
    ("Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Installer.xpc/Contents/MacOS/Installer", "Installer.xpc.dSYM"),
    ("Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Downloader.xpc/Contents/MacOS/Downloader", "Downloader.xpc.dSYM"),
)


CAPTURE_BINARIES = (("Contents/MacOS/XStats Capture", "XStats Capture.app.dSYM"),) + BINARIES[3:]

def uuids(path: Path) -> dict[str, str]:
    output = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(path)], text=True)
    result = {arch: uuid.upper() for uuid, arch in re.findall(r"UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)", output)}
    if not result:
        raise ValueError(f"缺少 Mach-O UUID：{path.name}")
    return result


def archive(app: Path, products: Path, destination: Path) -> Path:
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    identifier = info.get("CFBundleIdentifier")
    if identifier not in ("work.12306.xstats.app", "work.12306.xstats.capture"):
        raise ValueError("不支持的符号归档应用")
    capture = identifier == "work.12306.xstats.capture"
    binaries = CAPTURE_BINARIES if capture else BINARIES
    product = "XStats-Capture" if capture else "XStats"
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not re.fullmatch(r"[0-9]+", build):
        raise ValueError("符号归档的版本或构建号无效")
    manifest = {"format": 1, "version": version, "build": build, "binaries": []}
    if capture:
        manifest["product"] = product
    for relative, name in binaries:
        binary, dsym = app / relative, products / name
        dwarf = dsym / "Contents/Resources/DWARF"
        if not dwarf.is_dir() or not any(p.is_file() and p.stat().st_size > 0 for p in dwarf.iterdir()):
            raise ValueError(f"缺少 dSYM 调试信息：{name}")
        debug_info_sizes = []
        for member in dwarf.iterdir():
            if not member.is_file():
                continue
            sections = subprocess.check_output(["xcrun", "otool", "-l", str(member)], text=True)
            debug_info_sizes.extend(re.findall(
                r"sectname __debug_info\s+segname __DWARF\s+addr \S+\s+size (0x[0-9a-fA-F]+)", sections))
        if not any(int(size, 16) > 0 for size in debug_info_sizes):
            raise ValueError(f"dSYM 没有 DWARF 调试信息：{name}")
        binary_uuids, debug_uuids = uuids(binary), uuids(dsym)
        if binary_uuids.keys() != {"arm64"} or any(debug_uuids.get(arch) != uuid for arch, uuid in binary_uuids.items()):
            raise ValueError(f"二进制与 dSYM 的 arm64 UUID 不匹配：{relative} / {name}")
        with binary.open("rb") as handle:
            digest = hashlib.sha256()
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        manifest["binaries"].append({"path": relative, "dsym": name, "uuids": binary_uuids, "sha256": digest.hexdigest()})

    name = f"{product}-{version}-{build}-AppleSilicon.dSYMs"
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    output = destination / (name + ".zip")
    if output.exists():
        with zipfile.ZipFile(output) as bundle:
            recorded = json.loads(bundle.read(name + "/manifest.json"))
            for _, dsym in binaries:
                prefix = name + "/" + dsym + "/Contents/Resources/DWARF/"
                if not any(entry.filename.startswith(prefix) and not entry.is_dir() and entry.file_size > 0
                           for entry in bundle.infolist()):
                    raise ValueError(f"已有符号归档缺少调试信息：{dsym}")
            if bundle.testzip() is not None:
                raise ValueError(f"已有符号归档损坏：{output.name}")
        if recorded != manifest:
            raise ValueError(f"已有符号归档属于不同构建，不允许覆盖：{output.name}")
        return output

    with tempfile.TemporaryDirectory(dir=destination) as work:
        staging = Path(work) / name
        staging.mkdir()
        for _, dsym in binaries:
            shutil.copytree(products / dsym, staging / dsym, symlinks=True)
        (staging / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        temporary = Path(work) / (name + ".zip")
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(staging), str(temporary)], check=True)
        temporary.chmod(0o600)
        # Publish atomically without overwriting an archive created by another process.
        output.hardlink_to(temporary)
    return output


if __name__ == "__main__":
    try:
        if len(sys.argv) != 4:
            raise ValueError("用法：archive_debug_symbols.py <App> <Release products> <符号保存目录>")
        print(archive(*(Path(argument) for argument in sys.argv[1:])))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        raise SystemExit(f"符号归档失败：{error}") from error
