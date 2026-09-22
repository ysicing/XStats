#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Record and verify that release artifacts match the source Git history."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path


ALLOWED_RELEASE_FILES = {
    "project.yml",
    "CHANGELOG.md",
    "README.md",
    "README.en.md",
    "README.ja.md",
    "README.ko.md",
    "Assets/readme/activity.svg",
    "Assets/readme/activity.zh.svg",
}


class ProvenanceError(RuntimeError):
    pass


def git(repo: Path, *arguments: str, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["git", *arguments], cwd=repo, check=check, capture_output=True
    )


def git_text(repo: Path, *arguments: str) -> str:
    return git(repo, *arguments).stdout.decode().strip()


def git_paths(repo: Path, *arguments: str) -> set[str]:
    output = git(repo, *arguments).stdout
    return {item.decode() for item in output.split(b"\0") if item}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def prepare(repo: Path) -> str:
    changed = set()
    changed |= git_paths(repo, "diff", "--name-only", "-z")
    changed |= git_paths(repo, "diff", "--cached", "--name-only", "-z")
    changed |= git_paths(repo, "ls-files", "--others", "--exclude-standard", "-z")
    disallowed = sorted(changed - ALLOWED_RELEASE_FILES)
    if disallowed:
        raise ProvenanceError("构建前存在未提交的源码改动：" + ", ".join(disallowed))
    return git_text(repo, "rev-parse", "HEAD")


def record(repo: Path, output: Path, base_commit: str, version: str, build: str) -> None:
    payload = {
        "format": 1,
        "base_commit": base_commit,
        "version": version,
        "build": build,
        "project_sha256": sha256(repo / "project.yml"),
        "changelog_sha256": sha256(repo / "CHANGELOG.md"),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output)


def verify(repo: Path, provenance: Path, version: str, build: str) -> None:
    try:
        payload = json.loads(provenance.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProvenanceError(f"无法读取发布来源记录：{error}") from error

    if payload.get("format") != 1:
        raise ProvenanceError("不支持的发布来源记录格式")
    if payload.get("version") != version or payload.get("build") != build:
        raise ProvenanceError("发布来源记录与当前版本或构建号不一致")
    if sha256(repo / "project.yml") != payload.get("project_sha256"):
        raise ProvenanceError("project.yml 与构建时不一致")
    if sha256(repo / "CHANGELOG.md") != payload.get("changelog_sha256"):
        raise ProvenanceError("CHANGELOG.md 与构建时不一致")
    if git(repo, "status", "--porcelain", "--untracked-files=all").stdout:
        raise ProvenanceError("发布前工作区或暂存区不干净")

    base_commit = payload.get("base_commit")
    if not isinstance(base_commit, str) or not base_commit:
        raise ProvenanceError("发布来源记录缺少基础提交")
    if git(repo, "merge-base", "--is-ancestor", base_commit, "HEAD", check=False).returncode != 0:
        raise ProvenanceError("构建时的基础提交不是当前 HEAD 的祖先")
    changed = git_paths(repo, "diff", "--name-only", "-z", base_commit, "HEAD")
    disallowed = sorted(changed - ALLOWED_RELEASE_FILES)
    if disallowed:
        raise ProvenanceError("构建后源码发生变化：" + ", ".join(disallowed))


def main() -> None:
    repo = Path.cwd()
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        if command == "prepare" and len(sys.argv) == 2:
            print(prepare(repo))
        elif command == "record" and len(sys.argv) == 6:
            record(repo, Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5])
        elif command == "verify" and len(sys.argv) == 5:
            verify(repo, Path(sys.argv[2]), sys.argv[3], sys.argv[4])
        else:
            raise ProvenanceError(
                "用法：release_provenance.py prepare | record <文件> <基础提交> <版本> <构建号> | "
                "verify <文件> <版本> <构建号>"
            )
    except ProvenanceError as error:
        raise SystemExit(f"发布来源校验失败：{error}") from error


if __name__ == "__main__":
    main()
