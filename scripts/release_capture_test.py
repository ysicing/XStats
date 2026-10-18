#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""隔离 Git 夹具验证条件发布与身份边界，不执行签名、上传或 API 写入。"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release_capture as capture
from publish_api import configured_endpoints, sparkle_feed_url


class CaptureReleaseTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, self.previous)
        self.root_patch = patch.object(capture, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "fixture@example.test")
        self.git("config", "user.name", "Fixture")
        self.project = 'settings:\n  base:\n    MARKETING_VERSION: "1.4.0"\n    SWIFT_VERSION: "6"\ntargets:\n  XStatsCapture:\n    settings:\n      CAPTURE_VERSION: "0.1.0"\n      CAPTURE_BUILD: "1"\n  XStats:\n    type: application\n'
        self.write("project.yml", self.project)
        self.write("Apps/Capture/App/Main.swift", 'tr("截图")\n')
        self.write("Taskfile.yml", "tasks:\n  compile-capture:\n    cmds: [capture]\n  build:\n    cmds: [main]\n")
        self.write("Packages/XStatsKit/Sources/Localization/Resources/en.tsv", "截图\tScreenshot\n主程序新功能\tMain feature\n")
        self.write("Packages/XStatsKit/Package.swift", 'name: "CaptureUI", dependencies: ["CaptureCore"]\n.package(url: "Sparkle", exact: "2.10.0")\n')
        self.commit()
        self.git("tag", "capture-v0.1.0")
        self.git("remote", "add", "origin", str(self.root))

    def git(self, *args):
        return subprocess.check_output(["git", *args], text=True).strip()

    def write(self, path, content):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def test_main_version_and_unrelated_features_do_not_release_capture(self):
        self.write("project.yml", self.project.replace('"1.4.0"', '"1.5.0"'))
        self.write("Packages/XStatsKit/Sources/Metrics/New.swift", "metrics\n")
        self.commit()
        self.assertFalse(capture.follow_required())

    def test_capture_changes_follow_main_and_require_new_version(self):
        self.write("Apps/Capture/App/Main.swift", "changed\n")
        self.commit()
        self.assertTrue(capture.follow_required())
        with patch("sys.argv", ["release_capture.py", "--check-follow"]):
            with self.assertRaisesRegex(ValueError, "CAPTURE_VERSION"):
                capture.main()

    def test_capture_settings_and_sparkle_dependency_are_related(self):
        self.write("project.yml", self.project.replace('"0.1.0"', '"0.1.1"'))
        self.commit()
        self.assertTrue(capture.follow_required())

    def test_unrelated_dependency_change_is_skipped(self):
        with (self.root / "Packages/XStatsKit/Package.swift").open("a") as output:
            output.write('.package(url: "Calendar", exact: "2")\n')
        self.commit()
        self.assertFalse(capture.follow_required())

    def test_sparkle_change_is_related(self):
        self.write("Packages/XStatsKit/Package.swift", 'name: "CaptureUI", dependencies: ["CaptureCore"]\n.package(url: "Sparkle", exact: "3.0.0")\n')
        self.commit()
        self.assertTrue(capture.follow_required())

    def test_dirty_source_cannot_build_or_publish(self):
        self.write("Apps/Capture/App/Main.swift", "dirty\n")
        with self.assertRaisesRegex(ValueError, "干净"):
            capture.clean_head()

    def test_capture_endpoints_cannot_overwrite_main(self):
        endpoints = configured_endpoints({"XSTATS_APP_ID": "xstats-capture"})
        self.assertEqual(len(endpoints), 3)
        self.assertTrue(all("/apps/xstats-capture/" in sparkle_feed_url(e) for e in endpoints))
        with self.assertRaises(ValueError):
            configured_endpoints({"XSTATS_APP_ID": "xstats-capture", "XSTATS_API_URL": "https://example.test/api/v1/apps/xstats/releases/current"})

    def test_manifest_uses_own_identity_and_downloads(self):
        with patch.object(capture, "DIST", self.root):
            self.write("XStats-Capture-0.1.0-AppleSilicon.zip", "zip fixture")
            feed = capture.make_manifest("0.1.0", "1", "XStats-Capture-0.1.0-AppleSilicon", {"date": "2026-10-17", "sourceNotes": ["Capture"]})
        self.assertEqual(feed["bundleIdentifier"], "work.12306.xstats.capture")
        self.assertIn("/capture/", feed["url"])
        self.assertIn("capture-v0.1.0", feed["changelog"])
        self.assertEqual(feed["size"], 11)

    def test_capture_translation_changes_release_but_unrelated_keys_do_not(self):
        path = "Packages/XStatsKit/Sources/Localization/Resources/en.tsv"
        self.write(path, "截图\tScreenshot\n主程序新功能\tChanged main feature\n")
        self.commit()
        self.assertFalse(capture.follow_required())
        self.write(path, "截图\tCapture image\n主程序新功能\tChanged main feature\n")
        self.commit()
        self.assertTrue(capture.follow_required())

    def test_only_capture_build_task_changes_trigger_release(self):
        self.write("Taskfile.yml", "tasks:\n  compile-capture:\n    cmds: [capture]\n  build:\n    cmds: [main-changed]\n")
        self.commit()
        self.assertFalse(capture.follow_required())
        self.write("Taskfile.yml", "tasks:\n  compile-capture:\n    cmds: [capture-changed]\n  build:\n    cmds: [main-changed]\n")
        self.commit()
        self.assertTrue(capture.follow_required())

    def test_remote_capture_tag_is_loaded_even_when_main_is_unchanged(self):
        remote = self.root / "remote.git"
        subprocess.run(["git", "clone", "--bare", "-q", str(self.root), str(remote)], check=True)
        self.git("remote", "set-url", "origin", str(remote))
        self.git("tag", "-d", "capture-v0.1.0")
        self.assertTrue(capture.follow_required())
        capture.sync_release_tags()
        self.assertFalse(capture.follow_required())

    def test_uncommitted_and_untracked_related_changes_require_release(self):
        main = "Apps/Capture/App/Main.swift"
        self.write(main, "unstaged\n")
        self.assertTrue(capture.follow_required())
        self.git("checkout", "--", main)
        self.assertFalse(capture.follow_required())
        self.write(main, "staged\n")
        self.git("add", main)
        self.assertTrue(capture.follow_required())
        self.git("reset", "-q", "--hard")
        self.assertFalse(capture.follow_required())
        self.write("Apps/Capture/App/New.swift", "untracked\n")
        self.assertTrue(capture.follow_required())
        with patch("sys.argv", ["release_capture.py", "--check-follow"]), self.assertRaisesRegex(ValueError, "CAPTURE_VERSION"):
            capture.main()

    def test_uncommitted_unrelated_and_main_only_changes_are_skipped(self):
        self.write("project.yml", self.project.replace('"1.4.0"', '"1.5.0"'))
        self.write("README.md", "docs\n")
        self.assertFalse(capture.follow_required())
        self.write("project.yml", self.project.replace('CAPTURE_BUILD: "1"', 'CAPTURE_BUILD: "2"'))
        self.assertTrue(capture.follow_required())

    def test_uncommitted_capture_translation_is_related_only_for_capture_keys(self):
        path = "Packages/XStatsKit/Sources/Localization/Resources/en.tsv"
        self.write(path, "截图\tScreenshot\n主程序新功能\tChanged\n")
        self.assertFalse(capture.follow_required())
        self.write(path, "截图\tCapture image\n主程序新功能\tMain feature\n")
        self.assertTrue(capture.follow_required())
        self.git("checkout", "--", path)
        self.write("Packages/XStatsKit/Sources/Localization/Resources/ja.tsv", "截图\tスクリーンショット\n")
        self.assertTrue(capture.follow_required())

    def test_tag_is_created_after_feed_and_cask_publication(self):
        name = "XStats-Capture-0.1.0-AppleSilicon"
        files = [name + "." + ext for ext in ("dmg", "zip", "xml")] + ["appcast.json", "xstats-capture.rb"]
        for file in files:
            self.write(file, file)
        self.write("notes.json", "notes")
        record = {"commit": "source", "team": "TEAM", "version": "0.1.0", "build": "1",
                  "notes": capture.digest(self.root / "notes.json"), "files": {f: capture.digest(self.root / f) for f in files}}
        self.write("release-provenance.json", json.dumps(record))
        events = []

        def fake_run(*args, **kwargs):
            command = tuple(str(a) for a in args)
            events.append(command)
            if command[0] == "ditto":
                info = Path(command[-1]) / "XStats Capture.app/Contents/Info.plist"
                info.parent.mkdir(parents=True)
                info.write_bytes(b"plist")
            if command[0] == "curl":
                Path(command[-1]).write_bytes((self.root / Path(command[-3]).name).read_bytes())
            return "source" if command[0] == "git" else ""

        def record_event(label):
            return lambda *a, **k: events.append((label,))

        notes = {"sourceNotes": ["中文"], "translations": {"en": ["English"]}}
        missing_release = subprocess.CompletedProcess([], 1, "", "")
        with patch.object(capture, "DIST", self.root), patch.object(capture, "NOTES", self.root / "notes.json"), \
                patch.object(capture, "clean_head", return_value="source"), patch.object(capture, "run", side_effect=fake_run), \
                patch.object(capture, "verify_bundle"), patch.object(capture, "object_hash", return_value=None), \
                patch.object(capture, "configured_endpoints", return_value=["e"]), \
                patch.object(capture.plistlib, "loads", return_value={"SUPublicEDKey": "key"}), \
                patch.object(capture, "publish", side_effect=record_event("publish")), \
                patch.object(capture, "verify_sparkle_feeds", side_effect=record_event("verify")), \
                patch.object(capture, "push_cask", side_effect=record_event("cask")), \
                patch.object(capture, "sync_release_tags"), patch.object(capture.subprocess, "run", return_value=missing_release):
            capture.publish_release("0.1.0", "1", name, notes)
        labels = [event[0] for event in events]
        create = next(i for i, event in enumerate(events) if event[:3] == ("gh", "release", "create"))
        self.assertEqual([labels.index(x) < create for x in ("publish", "verify", "cask")], [True] * 3)
        self.assertLess(labels.index("publish"), labels.index("verify"))
        self.assertLess(labels.index("verify"), labels.index("cask"))

    def test_cask_push_syncs_remote_before_push_and_reports_recovery(self):
        remote = self.root / "tap.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(remote)], check=True)
        seed = self.root / "seed"
        subprocess.run(["git", "clone", "-q", str(remote), str(seed)], check=True, stderr=subprocess.DEVNULL)
        other = self.root / "other"
        for clone in (seed,):
            subprocess.run(["git", "-C", str(clone), "config", "user.email", "t@example.test"], check=True)
            subprocess.run(["git", "-C", str(clone), "config", "user.name", "T"], check=True)
        (seed / "README.md").write_text("tap\n")
        subprocess.run(["git", "-C", str(seed), "add", "."], check=True)
        subprocess.run(["git", "-C", str(seed), "commit", "-qm", "init"], check=True)
        subprocess.run(["git", "-C", str(seed), "push", "-q", "origin", "HEAD:main"], check=True)
        tap = self.root / "tap"
        subprocess.run(["git", "clone", "-q", str(remote), str(tap)], check=True, stderr=subprocess.DEVNULL)
        subprocess.run(["git", "-C", str(tap), "config", "user.email", "t@example.test"], check=True)
        subprocess.run(["git", "-C", str(tap), "config", "user.name", "T"], check=True)
        # clone 之后 tap 又有别人的提交，直接 push 会被拒绝。
        (seed / "Casks").mkdir()
        (seed / "Casks/other.rb").write_text("other\n")
        subprocess.run(["git", "-C", str(seed), "add", "."], check=True)
        subprocess.run(["git", "-C", str(seed), "commit", "-qm", "other"], check=True)
        subprocess.run(["git", "-C", str(seed), "push", "-q", "origin", "HEAD:main"], check=True)
        self.write("xstats-capture.rb", "cask\n")
        (tap / "Casks").mkdir()
        capture.push_cask(tap, self.root / "xstats-capture.rb", "0.1.0")
        files = self.git("--git-dir", str(remote), "ls-tree", "-r", "--name-only", "main").splitlines()
        self.assertIn("Casks/xstats-capture.rb", files)
        self.assertIn("Casks/other.rb", files)
        # 推送失败要给出幂等恢复命令。
        self.write("xstats-capture.rb", "cask v2\n")
        subprocess.run(["git", "-C", str(tap), "remote", "set-url", "origin", str(self.root / "missing.git")], check=True)
        with self.assertRaisesRegex(ValueError, "--publish-only"):
            capture.push_cask(tap, self.root / "xstats-capture.rb", "0.1.1")

    def test_conflicting_local_capture_tag_is_reported_not_overwritten(self):
        remote = self.root / "remote.git"
        subprocess.run(["git", "clone", "--bare", "-q", str(self.root), str(remote)], check=True)
        self.git("remote", "set-url", "origin", str(remote))
        self.write("Apps/Capture/App/Main.swift", "next\n")
        self.commit()
        # 本地 0.1.0 被改指向新提交，与 origin 的 0.1.0 冲突。
        self.git("tag", "-f", "capture-v0.1.0")
        local = self.git("rev-parse", "capture-v0.1.0")
        with self.assertRaisesRegex(ValueError, "capture-v0.1.0.*不同提交"):
            capture.sync_release_tags()
        self.assertEqual(self.git("rev-parse", "capture-v0.1.0"), local)
        with patch("sys.argv", ["release_capture.py", "--check-follow"]), self.assertRaisesRegex(ValueError, "不同提交"):
            capture.main()

    def test_source_record_mismatch_stops_before_external_commands(self):
        name = "XStats-Capture-0.1.0-AppleSilicon"
        for extension in ("dmg", "zip", "xml"):
            self.write(name + "." + extension, extension)
        self.write("appcast.json", "{}")
        self.write("xstats-capture.rb", "cask")
        self.write("notes.json", "notes")
        files = [name + "." + ext for ext in ("dmg", "zip", "xml")] + ["appcast.json", "xstats-capture.rb"]
        record = {"commit": "old", "version": "0.1.0", "build": "1", "notes": capture.digest(self.root / "notes.json"),
                  "files": {f: capture.digest(self.root / f) for f in files}}
        self.write("release-provenance.json", json.dumps(record))
        with patch.object(capture, "DIST", self.root), patch.object(capture, "NOTES", self.root / "notes.json"), \
                patch.object(capture, "clean_head", return_value="new"), patch.object(capture, "run") as command:
            with self.assertRaisesRegex(ValueError, "来源记录"):
                capture.publish_release("0.1.0", "1", name, {})
            command.assert_not_called()

    def test_immutable_remote_conflict_stops_before_upload_or_api(self):
        name = "XStats-Capture-0.1.0-AppleSilicon"
        files = [name + "." + ext for ext in ("dmg", "zip", "xml")] + ["appcast.json", "xstats-capture.rb"]
        for file in files:
            self.write(file, file)
        self.write("notes.json", "notes")
        record = {"commit": "source", "team": "TEAM", "version": "0.1.0", "build": "1",
                  "notes": capture.digest(self.root / "notes.json"), "files": {f: capture.digest(self.root / f) for f in files}}
        self.write("release-provenance.json", json.dumps(record))
        with patch.object(capture, "DIST", self.root), patch.object(capture, "NOTES", self.root / "notes.json"), \
                patch.object(capture, "clean_head", return_value="source"), patch.object(capture, "run", return_value="source") as command, \
                patch.object(capture, "verify_bundle"), patch.object(capture, "object_hash", return_value="different"), \
                patch.object(capture, "publish") as api:
            with self.assertRaisesRegex(ValueError, "覆盖"):
                capture.publish_release("0.1.0", "1", name, {})
            api.assert_not_called()
            self.assertFalse(any(call.args[0] in ("mc", "curl", "gh") for call in command.call_args_list))


if __name__ == "__main__":
    unittest.main()
