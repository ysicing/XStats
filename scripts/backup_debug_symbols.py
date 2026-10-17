#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Back up validated release symbols to private storage and verify every object."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

from archive_debug_symbols import BINARIES, CAPTURE_BINARIES


DEFAULT_TARGET = "home/oss/apps/macOS/XStats"


def sha256(path: Path) -> str:
    with path.open("rb") as handle:
        digest = hashlib.sha256()
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_private(target: str) -> None:
    result = subprocess.run(["mc", "anonymous", "--json", "get", target + "/"],
                            capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise ValueError("无法确认符号备份目录的私有权限，停止上传")
    policy = json.loads(result.stdout)
    if policy.get("status") != "success" or policy.get("permission") != "private":
        raise ValueError("符号备份目录允许匿名访问，停止上传")


def upload_verified(path: Path, target: str, expected: str, work: Path) -> None:
    result = subprocess.run(["mc", "stat", "--no-list", "--json", target],
                            capture_output=True, text=True, timeout=60)
    state = json.loads(result.stdout)
    if result.returncode != 0:
        if (state.get("status") != "error"
                or state.get("error", {}).get("cause", {}).get("message") != "Object does not exist"):
            raise ValueError("无法确认远端符号对象是否存在，停止上传")
        # A single conditional PUT also prevents another build machine from racing this check.
        # If another process wins, only an identical, fully readable object permits continuation.
        subprocess.run(["mc", "--custom-header", "If-None-Match: *", "cp", "--disable-multipart",
                        "--quiet", str(path), target], capture_output=True, timeout=300)
    elif state.get("status") != "success":
        raise ValueError("远端符号对象状态无效，停止上传")

    downloaded = work / "readback"
    with downloaded.open("wb") as handle:
        result = subprocess.run(["mc", "cat", target], stdout=handle, stderr=subprocess.PIPE, timeout=300)
    if result.returncode != 0:
        raise ValueError("符号备份上传或回读失败；本地归档已保留，可重试")
    if downloaded.stat().st_size != path.stat().st_size or sha256(downloaded) != expected:
        raise ValueError("远端符号对象 SHA-256 不一致，禁止覆盖；本地归档已保留")


def backup(archive: Path, target: str) -> str:
    target = target.rstrip("/")
    if not re.fullmatch(r"[A-Za-z0-9_-]+/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*", target):
        raise ValueError("符号备份目标必须是 mc 别名下的对象存储路径")
    with zipfile.ZipFile(archive) as bundle:
        member = bundle.getinfo(archive.stem + "/manifest.json")
        if member.file_size > 512 * 1024:
            raise ValueError("符号清单超过大小上限")
        manifest = json.loads(bundle.read(member))
        version, build = manifest["version"], manifest["build"]
        product = manifest.get("product", "XStats")
        if product not in ("XStats", "XStats-Capture"):
            raise ValueError("不支持的符号归档产品")
        binaries = CAPTURE_BINARIES if product == "XStats-Capture" else BINARIES
        if (manifest.get("format") != 1 or not isinstance(version, str) or not isinstance(build, str)
                or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not re.fullmatch(r"[0-9]+", build)
                or archive.name != f"{product}-{version}-{build}-AppleSilicon.dSYMs.zip"):
            raise ValueError("符号归档名称与版本清单不一致")
        entries = manifest["binaries"]
        if len(entries) != len(binaries) or [(item["path"], item["dsym"]) for item in entries] != list(binaries):
            raise ValueError("符号清单缺少预期二进制")
        for item in entries:
            if (item["uuids"].keys() != {"arm64"}
                    or not re.fullmatch(r"[0-9A-Fa-f-]{36}", item["uuids"]["arm64"])
                    or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"])):
                raise ValueError("符号清单中的 UUID 或二进制哈希无效")
            prefix = archive.stem + "/" + item["dsym"] + "/Contents/Resources/DWARF/"
            if not any(entry.filename.startswith(prefix) and not entry.is_dir() and entry.file_size > 0
                       for entry in bundle.infolist()):
                raise ValueError("符号归档缺少调试信息：" + item["dsym"])
        if bundle.testzip() is not None:
            raise ValueError("符号归档 ZIP 校验失败")

    digest = sha256(archive)
    prefix = f"{target}/dSYMs/{version}-{build}/{digest}"
    remote_archive = prefix + "/" + archive.name
    manifest["archive"] = {"file": archive.name, "sha256": digest, "bytes": archive.stat().st_size}
    require_private(prefix)
    with tempfile.TemporaryDirectory(prefix="xstats-symbol-backup-") as temporary:
        work = Path(temporary)
        sidecar = work / "manifest.json"
        sidecar.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        upload_verified(archive, remote_archive, digest, work)
        # The small manifest is a completion marker and allows UUID lookup without downloading dSYMs.
        upload_verified(sidecar, prefix + "/manifest.json", sha256(sidecar), work)
    require_private(prefix)
    return remote_archive


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("用法：backup_debug_symbols.py <dSYM 归档 ZIP>")
        print(backup(Path(sys.argv[1]), os.environ.get("DEBUG_SYMBOLS_TARGET", DEFAULT_TARGET)))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError,
            zipfile.BadZipFile) as error:
        raise SystemExit(f"私有符号备份失败：{error}") from error
