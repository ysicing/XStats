#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later
"""独立 Capture 的构建、公证、不可变发布与按改动跟随 XStats 发版。"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

from archive_debug_symbols import archive, CAPTURE_BINARIES
from backup_debug_symbols import backup
from publish_api import configured_endpoints, check_sparkle_endpoints, publish, verify_sparkle_feeds
from sparkle_appcast import load_localized_notes

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist/capture"
APP = ROOT / "build/DerivedData-capture-arm64/Build/Products/Release/XStats Capture.app"
NOTES = ROOT / "docs/CaptureReleaseNotes.json"
BASE = "https://c.ysicing.net/oss/apps/macOS/XStats/capture"
TARGET = "c-ip/oss/apps/macOS/XStats/capture"
IDENTIFIER = "work.12306.xstats.capture"
# 仅包含独立 Capture 的代码、资源与实际使用的共享更新代码。
RELATED = ("Apps/Capture/", "Packages/XStatsKit/Sources/CaptureCore/", "Packages/XStatsKit/Sources/CaptureUI/",
           "Packages/XStatsKit/Sources/Localization/CaptureTranslations.swift",
           "Packages/XStatsKit/Sources/Localization/L10n.swift", "Packages/XStatsKit/Sources/Localization/AppLanguage.swift",
           "Packages/XStatsKit/Sources/Localization/LanguagePickerTranslations.swift",
           "scripts/release_capture.py", "scripts/sign_sparkle.sh", "scripts/codesign_retry.sh",
           "scripts/archive_debug_symbols.py", "scripts/backup_debug_symbols.py",
           "scripts/sparkle_appcast.py", "docs/CaptureReleaseNotes.json",
           "Packages/XStatsKit/Sources/Updates/InstallationIdentity.swift", "Packages/XStatsKit/Sources/Updates/UpdateFeed.swift")


def run(*args, capture=False, **kwargs):
    result = subprocess.run([str(a) for a in args], check=True, text=True,
                            stdout=subprocess.PIPE if capture else None, **kwargs)
    return result.stdout.strip() if capture else ""


def digest(path):
    with Path(path).open("rb") as source:
        result = hashlib.sha256()
        for chunk in iter(lambda: source.read(1 << 20), b""):
            result.update(chunk)
        return result.hexdigest()


def target_settings(source):
    match = re.search(r"^  XStatsCapture:\n(.*?)(?=^  \w+:|\Z)", source, re.M | re.S)
    if not match:
        raise ValueError("project.yml 缺少独立 Capture target")
    return match.group(1)


def version_settings():
    source = target_settings((ROOT / "project.yml").read_text())
    version = re.search(r'CAPTURE_VERSION: "(\d+\.\d+\.\d+)"', source)
    build = re.search(r'CAPTURE_BUILD: "([1-9]\d*)"', source)
    if not version or not build:
        raise ValueError("Capture 独立版本配置无效")
    return version[1], build[1]


def sync_release_tags():
    # GitHub 创建的标签不一定附着在远端 main 当前尖端，普通 fetch main 不会补齐。
    # refspec 刻意不加 +：本地同名但指向不同提交的标签不得被静默覆盖。
    fetch = subprocess.run(["git", "fetch", "--quiet", "--no-tags", "origin", "refs/tags/capture-v*:refs/tags/capture-v*"],
                           capture_output=True, text=True)
    if fetch.returncode == 0:
        return
    local = dict(line.split()[::-1] for line in run("git", "for-each-ref", "--format=%(objectname) %(refname)", "refs/tags/capture-v*", capture=True).splitlines())
    remote = dict(line.split("\t")[::-1] for line in run("git", "ls-remote", "--tags", "origin", "refs/tags/capture-v*", capture=True).splitlines()
                  if not line.endswith("^{}"))
    conflicts = sorted(ref.removeprefix("refs/tags/") for ref, sha in local.items() if ref in remote and remote[ref] != sha)
    if conflicts:
        raise ValueError(f"本地 tag {', '.join(conflicts)} 与 origin 指向不同提交；不会自动覆盖，请核对来源后手动处理（如 git tag -d <tag> 后重试）")
    raise ValueError(f"同步 capture-v* 标签失败：{fetch.stderr.strip()}")


def localization_changed(baseline, paths):
    localized = [p for p in paths if p.startswith("Packages/XStatsKit/Sources/Localization/")]
    if not localized:
        return False
    sources = []
    # 不带 ref 的 git grep 读取工作区（含未提交修改），--untracked 再补上未跟踪文件。
    for ref in ((baseline,), ("--untracked",)):
        sources.append(run("git", "grep", "-h", "-I", "-e", ".", *ref, "--", "Apps/Capture/", "Packages/XStatsKit/Sources/CaptureCore/", "Packages/XStatsKit/Sources/CaptureUI/", capture=True))
    # 键可能由枚举 rawValue 传入 tr；取两个版本所有字面量，避免只匹配 tr("...") 漏掉动态入口。
    keys = {re.sub(r'\\\([^)]*\)', '{}', value) for value in re.findall(r'"((?:\\.|[^"\\])*)"', "\n".join(sources))}
    untracked = set(untracked_files())
    for path in localized:
        if path in untracked:
            changes = "\n".join("+" + line for line in (ROOT / path).read_text().splitlines())
        else:
            changes = run("git", "diff", "--unified=0", baseline, "--", path, capture=True)
        for line in changes.splitlines():
            if not line.startswith(("+", "-")) or line.startswith(("+++", "---")):
                continue
            row = line[1:].strip()
            separator = "\t" if "\t" in row else "\\t"
            key, found, _ = row.partition(separator)
            if found and key in keys:
                return True
    return False


def untracked_files():
    return run("git", "ls-files", "--others", "--exclude-standard", capture=True).splitlines()


def related_changes(baseline):
    # 与基线比较工作区而非仅 HEAD：已暂存、未暂存和未跟踪的改动都会进入随后的 release commit 或阻塞它，
    # 预检必须与发布后 --follow 看到的结论一致，否则会在 XStats 发布完才发现 Capture 需要发版。
    paths = run("git", "diff", "--name-only", baseline, capture=True).splitlines() + untracked_files()
    if any(path.startswith(RELATED) for path in paths):
        return True
    if localization_changed(baseline, paths):
        return True
    if "Taskfile.yml" in paths:
        old = run("git", "show", f"{baseline}:Taskfile.yml", capture=True)
        new = (ROOT / "Taskfile.yml").read_text()
        blocks = r"^  (?:compile-capture|generate):\n.*?(?=^  [^ \n]|\Z)"
        if re.findall(blocks, old, re.M | re.S) != re.findall(blocks, new, re.M | re.S):
            return True
    # 主程序发布每次都会修改 project.yml，只比较独立 target 和其共享构建设置。
    if "project.yml" in paths:
        old = run("git", "show", f"{baseline}:project.yml", capture=True)
        new = (ROOT / "project.yml").read_text()
        global_keys = r"^    (?:SWIFT_VERSION|MACOSX_DEPLOYMENT_TARGET|ENABLE_HARDENED_RUNTIME):.*$"
        symbols = r"^settingGroups:\n(.*?)(?=^targets:)"
        if (target_settings(old) != target_settings(new)
                or re.findall(global_keys, old, re.M) != re.findall(global_keys, new, re.M)
                or re.findall(symbols, old, re.M | re.S) != re.findall(symbols, new, re.M | re.S)):
            return True
    # 其他产品的依赖变化不推进 Capture；Sparkle 或 Capture 自身依赖变化需要发版。
    if "Packages/XStatsKit/Package.swift" in paths:
        old = run("git", "show", f"{baseline}:Packages/XStatsKit/Package.swift", capture=True)
        new = (ROOT / "Packages/XStatsKit/Package.swift").read_text()
        relevant = r'^.*(?:Sparkle|name: "Capture(?:Core|UI)").*$|\.target\(\s*name: "Capture(?:Core|UI)"[\s\S]*?(?=\n    \.(?:target|testTarget)\(|\n  \])'
        if re.findall(relevant, old, re.M) != re.findall(relevant, new, re.M):
            return True
    return False


def follow_required():
    tags = run("git", "tag", "--list", "capture-v*", "--sort=-version:refname", capture=True).splitlines()
    return not tags or related_changes(tags[0])


def notes_for(version):
    notes = json.loads(NOTES.read_text())
    source = notes.get("sourceNotes")
    if not isinstance(source, list) or not source or not all(isinstance(n, str) and n.strip() and "\n" not in n and "\r" not in n for n in source):
        raise ValueError("Capture 中文更新摘要无效")
    load_localized_notes({"version": version, "notes": source}, NOTES)
    datetime.date.fromisoformat(notes["date"])
    return notes


def clean_head():
    if run("git", "status", "--porcelain", "--untracked-files=normal", capture=True):
        raise ValueError("Capture 发布要求干净且已提交的源码；保留当前修改并先验证提交")
    if run("git", "branch", "--show-current", capture=True) != "main":
        raise ValueError("Capture 只从 main 发布")
    return run("git", "rev-parse", "HEAD", capture=True)


def object_hash(target):
    result = subprocess.run(["mc", "stat", "--json", target], capture_output=True, text=True, timeout=60)
    state = json.loads(result.stdout)
    if result.returncode:
        if state.get("error", {}).get("cause", {}).get("message") == "Object does not exist":
            return None
        raise ValueError("无法确认源站对象状态，停止发布")
    with tempfile.TemporaryFile() as output:
        subprocess.run(["mc", "cat", target], stdout=output, check=True, timeout=300)
        output.seek(0)
        result = hashlib.sha256()
        for chunk in iter(lambda: output.read(1 << 20), b""):
            result.update(chunk)
        return result.hexdigest()


def verify_bundle(app, team):
    run("codesign", "--verify", "--deep", "--strict", app)
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    version, build = version_settings()
    if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (IDENTIFIER, version, build):
        raise ValueError("Capture 制品身份或版本不一致")
    for forbidden in ("Contents/Library/SystemExtensions", "Contents/PlugIns", "Contents/MacOS/XStatsHelper"):
        if (app / forbidden).exists():
            raise ValueError("Capture 不得携带主程序组件")
    entitlement = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], check=True, capture_output=True).stdout
    rights = plistlib.loads(entitlement)
    if rights.get("com.apple.security.device.audio-input") is not True or any("networkextension" in k or "system-extension" in k or "get-task-allow" in k for k in rights):
        raise ValueError("Capture 发行权限不正确")
    for relative, _ in CAPTURE_BINARIES:
        binary = app / relative
        if run("lipo", "-archs", binary, capture=True) != "arm64":
            raise ValueError("Capture 制品必须为单一 arm64")
        details = subprocess.run(["codesign", "-dvv", str(binary)], check=True, capture_output=True, text=True).stderr
        if f"TeamIdentifier={team}" not in details or "Timestamp=" not in details or not re.search(r"flags=.*runtime", details):
            raise ValueError("Capture 内嵌二进制未使用相同团队、安全时间戳和 Hardened Runtime")


def make_manifest(version, build, name, notes):
    archive_path = DIST / f"{name}.zip"
    return {"appName": "XStats Capture", "bundleIdentifier": IDENTIFIER, "version": version, "build": build,
            "date": notes["date"], "minimumSystem": "14.0", "url": f"{BASE}/{name}.zip",
            "dmg": f"{BASE}/{name}.dmg", "sha256": digest(archive_path), "size": archive_path.stat().st_size,
            "notes": notes["sourceNotes"], "changelog": f"https://github.com/ysicing/XStats/releases/tag/capture-v{version}"}


def build_release(version, build, name, notes):
    commit = clean_head()
    if object_hash(f"{TARGET}/{name}.zip") is not None:
        raise ValueError("Capture 版本已发布，禁止重建覆盖；恢复请用 --publish-only")
    identity = os.environ.get("SIGN_ID")
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True)
    match = re.search(r'([A-F0-9]{40}) "Developer ID Application: .*?\(([A-Z0-9]+)\)"', identities) if not identity else re.search(rf'({re.escape(identity)}) "Developer ID Application: .*?\(([A-Z0-9]+)\)"', identities)
    if not match:
        raise ValueError("缺少有效 Developer ID Application 签名身份")
    identity, team = match.groups()
    run("task", "compile-capture", "CONFIG=Release", "CLEAN=1", f"SIGN_ID={identity}")
    if clean_head() != commit:
        raise ValueError("构建期间源码发生变化")
    verify_bundle(APP, team)
    symbols = archive(APP, APP.parent, ROOT / "release-symbols")
    print("私有符号备份：", backup(symbols, "home/oss/apps/macOS/XStats/capture"), flush=True)
    DIST.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="capture-release-") as temporary:
        work = Path(temporary)
        run("ditto", "-c", "-k", "--norsrc", "--keepParent", APP, work / "notarize.zip")
        run("xcrun", "notarytool", "submit", work / "notarize.zip", "--keychain-profile", os.environ.get("NOTARY_PROFILE", "XStats"), "--wait")
        run("xcrun", "stapler", "staple", APP)
        run("xcrun", "stapler", "validate", APP)
        run("spctl", "-a", "-vv", APP)
        staging = work / "dmg"
        staging.mkdir()
        run("ditto", APP, staging / APP.name)
        (staging / "Applications").symlink_to("/Applications")
        dmg = DIST / f"{name}.dmg"
        run("hdiutil", "create", "-volname", f"XStats Capture {version}", "-srcfolder", staging, "-ov", "-format", "UDZO", dmg)
        run("bash", "-c", 'source scripts/codesign_retry.sh; codesign_with_timestamp_retry --force --timestamp --sign "$1" "$2"', "capture-sign", identity, dmg)
        run("xcrun", "notarytool", "submit", dmg, "--keychain-profile", os.environ.get("NOTARY_PROFILE", "XStats"), "--wait")
        run("xcrun", "stapler", "staple", dmg)
        run("xcrun", "stapler", "validate", dmg)
        run("spctl", "-a", "-t", "open", "--context", "context:primary-signature", "-vv", dmg)
        run("ditto", "-c", "-k", "--norsrc", "--keepParent", APP, DIST / f"{name}.zip")
    manifest = make_manifest(version, build, name, notes)
    (DIST / "appcast.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    run("python3", "scripts/sparkle_appcast.py", DIST / "appcast.json", DIST / f"{name}.zip", "--notes-file", NOTES, "--app-info", APP / "Contents/Info.plist")
    (DIST / "xstats-capture.rb").write_text(f'''cask "xstats-capture" do
  version "{version}"
  sha256 "{digest(DIST / (name + '.dmg'))}"

  url "{BASE}/XStats-Capture-#{{version}}-AppleSilicon.dmg"
  name "XStats Capture"
  desc "Screenshot annotation, local redaction and screen recording"
  homepage "https://github.com/ysicing/XStats"

  livecheck do
    url :homepage
    regex(/^capture-v(\\d+\\.\\d+\\.\\d+)$/i)
    strategy :github_releases
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "XStats Capture.app"

  uninstall quit: "work.12306.xstats.capture"

  # XStatsCapture 素材缓存由两个产品共用，卸载任一产品时保留。
  zap trash: [
    "~/Library/Caches/work.12306.xstats.capture",
    "~/Library/Preferences/work.12306.xstats.capture.plist",
  ]
end
''')
    if clean_head() != commit:
        raise ValueError("打包期间源码发生变化")
    files = [f"{name}.{ext}" for ext in ("dmg", "zip", "xml")] + ["appcast.json", "xstats-capture.rb"]
    record = {"commit": commit, "team": team, "version": version, "build": build,
              "files": {f: digest(DIST / f) for f in files}, "notes": digest(NOTES)}
    (DIST / "release-provenance.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"✅ Capture {version} ({build}) 构建、公证、签名完成", flush=True)


def push_cask(tap, source, version):
    """把 cask 写入 tap 并推送；push 前先同步远端，避免 clone 后 tap 有新提交导致非快进拒绝。"""
    (tap / "Casks/xstats-capture.rb").write_bytes(Path(source).read_bytes())
    run("git", "-C", tap, "add", "Casks/xstats-capture.rb")
    if not subprocess.run(["git", "-C", str(tap), "diff", "--cached", "--quiet"]).returncode:
        return
    try:
        run("git", "-C", tap, "commit", "-q", "-m", f"chore(cask): 发布 Capture {version}")
        run("git", "-C", tap, "pull", "--rebase", "--quiet")
        run("git", "-C", tap, "push", "--quiet")
    except subprocess.CalledProcessError as error:
        raise ValueError("Capture cask 推送失败；JSON/XML 已发布但 GitHub Release 与标签尚未创建，"
                         "修复后运行 python3 scripts/release_capture.py --publish-only（幂等续传）") from error


def publish_release(version, build, name, notes):
    commit = clean_head()
    record = json.loads((DIST / "release-provenance.json").read_text())
    files = [f"{name}.{ext}" for ext in ("dmg", "zip", "xml")] + ["appcast.json", "xstats-capture.rb"]
    if (record.get("commit"), record.get("version"), record.get("build"), record.get("notes")) != (commit, version, build, digest(NOTES)) or record.get("files") != {f: digest(DIST / f) for f in files}:
        raise ValueError("Capture 来源记录与当前源码或制品不一致")
    run("git", "fetch", "--quiet", "origin", "main")
    if run("git", "rev-parse", "origin/main", capture=True) != commit:
        raise ValueError("Capture 发布前必须推送当前 main")
    with tempfile.TemporaryDirectory(prefix="capture-publish-") as temporary:
        work = Path(temporary)
        run("ditto", "-x", "-k", DIST / f"{name}.zip", work)
        verify_bundle(work / APP.name, record["team"])
        run("python3", "scripts/sparkle_appcast.py", DIST / "appcast.json", DIST / f"{name}.zip", "--verify", "--notes-file", NOTES, "--app-info", work / APP.name / "Contents/Info.plist")
        run("xcrun", "stapler", "validate", work / APP.name)
        run("spctl", "-a", "-vv", work / APP.name)
        run("xcrun", "stapler", "validate", DIST / f"{name}.dmg")
        run("spctl", "-a", "-t", "open", "--context", "context:primary-signature", "-vv", DIST / f"{name}.dmg")
        # 同名远端对象必须全部一致，完成预检后才上传，不覆盖已公开版本。
        states = {ext: object_hash(f"{TARGET}/{name}.{ext}") for ext in ("dmg", "zip", "xml")}
        if any(value is not None and value != digest(DIST / f"{name}.{ext}") for ext, value in states.items()):
            raise ValueError("拒绝覆盖已发布 Capture 制品")
        tag = f"capture-v{version}"
        existing = run("git", "ls-remote", "origin", f"refs/tags/{tag}", capture=True)
        if existing and existing.split()[0] != commit:
            raise ValueError("已发布 Capture tag 指向不同源码，禁止改写")
        for ext, state in states.items():
            path = DIST / f"{name}.{ext}"
            if state is None:
                run("mc", "--custom-header", "If-None-Match: *", "cp", "--disable-multipart", "--quiet", path, f"{TARGET}/{path.name}")
            online = work / f"readback.{ext}"
            run("curl", "-fSL", "--retry", "2", "--max-time", "300", f"{BASE}/{path.name}", "-o", online)
            if digest(online) != digest(path):
                raise ValueError("Capture 公开下载哈希不一致")
        body = work / "notes.md"
        body.write_text(f"## XStats Capture {version}\n\n" + "\n".join("- " + n for n in notes["sourceNotes"]) + "\n\n## English\n\n" + "\n".join("- " + n for n in notes["translations"]["en"]) + "\n\nmacOS 14+ · Apple Silicon\n")
        # 既有 Release 的制品冲突要在写入更新源之前发现；创建动作留到最后。
        release = subprocess.run(["gh", "release", "view", tag, "--json", "assets"], capture_output=True, text=True)
        if release.returncode == 0:
            assets = json.loads(release.stdout)["assets"]
            wanted = next((a for a in assets if a["name"] == name + ".dmg"), None)
            if not wanted or wanted.get("digest") != "sha256:" + digest(DIST / (name + ".dmg")):
                raise ValueError("既有 GitHub Capture Release 制品不一致；不覆盖")
        endpoints = configured_endpoints({**os.environ, "XSTATS_APP_ID": "xstats-capture"})
        app_info = plistlib.loads((work / APP.name / "Contents/Info.plist").read_bytes())
        publish(DIST / "appcast.json", endpoints, os.environ.get("XSTATS_RELEASE_TOKEN", ""),
                application_name="XStats Capture", sparkle_public_key=app_info["SUPublicEDKey"])
        verify_sparkle_feeds(DIST / f"{name}.xml", endpoints)
        run("gh", "repo", "clone", "ysicing/homebrew-tap", work / "tap", "--", "--quiet")
        push_cask(work / "tap", DIST / "xstats-capture.rb", version)
        # GitHub Release 与 capture-v* 标签是“发布已完成”的唯一标志，必须最后创建：
        # --follow 以最新标签为基线，若标签先于 JSON/XML/cask 出现，中途失败后重跑会得到“无相关改动”而静默跳过。
        # 标签缺失时重跑 --follow 会因对象已存在而明确拒绝重建，并指向 --publish-only。
        if release.returncode != 0:
            run("gh", "release", "create", tag, DIST / f"{name}.dmg", "--target", commit, "--title", f"XStats Capture {version}", "--notes-file", body, "--latest=false")
    sync_release_tags()
    print(f"✅ Capture {version} 已发布；主程序版本与更新源保持独立", flush=True)


def main():
    os.chdir(ROOT)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--publish-only", action="store_true")
    parser.add_argument("--check-follow", action="store_true")
    parser.add_argument("--follow", action="store_true")
    args = parser.parse_args()
    version, build = version_settings()
    sync_release_tags()
    if args.check_follow or args.follow:
        if not follow_required():
            print("Capture 无相关改动，跳过独立发版")
            return
        if run("git", "tag", "--list", f"capture-v{version}", capture=True):
            raise ValueError("Capture 有相关改动；请先推进 CAPTURE_VERSION/CAPTURE_BUILD 并补齐 CaptureReleaseNotes.json")
    tags = run("git", "tag", "--list", "capture-v*", "--sort=-version:refname", capture=True).splitlines()
    if tags and tags[0] != f"capture-v{version}":
        previous = tags[0].removeprefix("capture-v")
        if tuple(map(int, version.split("."))) <= tuple(map(int, previous.split("."))):
            raise ValueError("Capture 公开版本必须递增")
        old_settings = target_settings(run("git", "show", f"{tags[0]}:project.yml", capture=True))
        old_build = re.search(r'CAPTURE_BUILD: "([1-9]\d*)"', old_settings)
        if not old_build or int(build) <= int(old_build[1]):
            raise ValueError("Capture 构建号必须递增，Sparkle 以其判断更新")
    notes = notes_for(version)
    if args.check_follow:
        print(f"Capture 有相关改动，将跟随发布 {version} ({build})")
        return
    publishing = args.publish or args.publish_only or args.follow
    if publishing:
        if not os.environ.get("XSTATS_RELEASE_TOKEN"):
            raise ValueError("XSTATS_RELEASE_TOKEN 不能为空")
        check_sparkle_endpoints(configured_endpoints({**os.environ, "XSTATS_APP_ID": "xstats-capture"}))
    name = f"XStats-Capture-{version}-AppleSilicon"
    if not args.publish_only:
        build_release(version, build, name, notes)
    if publishing:
        publish_release(version, build, name, notes)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"error: Capture 发布停止：{error}") from error
