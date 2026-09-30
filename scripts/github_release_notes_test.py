#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from github_release_notes import ROOT, render


class GitHubReleaseNotesTests(unittest.TestCase):
    changelog = """# 更新日志

## 1.0.0 · 2026-09-30

### 新增

- 新增菜单栏功能：支持自定义显示和[设置说明](https://example.test/settings)。

### 修复

- 修复更新后的启动问题；旧版首次升级可手动打开一次。

## 0.9.0 · 2026-09-29

- 历史条目不属于本次发布。
"""

    def metadata(self):
        return {"version": "1.0.0", "sourceNotes": ["新增菜单栏功能：支持自定义显示和[设置说明](https://example.test/settings)",
                                                    "修复更新后的启动问题"],
                "translations": {"en": ["Add a menu bar feature with custom display and [settings](https://example.test/settings)",
                                         "Fix relaunch after updating; open the app manually once after the first upgrade from an older version"]}}

    def test_preserves_full_chinese_and_adds_english_without_previous_releases(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ReleaseNotes.json"
            path.write_text(json.dumps(self.metadata(), ensure_ascii=False), encoding="utf-8")
            body = render("1.0.0", self.changelog, path)
        chinese, english = body.split("## English\n\n", 1)
        self.assertTrue(chinese.startswith("## 中文\n\n"))
        self.assertIn("### 新增", chinese)
        self.assertIn("### 修复", chinese)
        self.assertIn("支持自定义显示和[设置说明](https://example.test/settings)。", chinese)
        self.assertIn("旧版首次升级可手动打开一次。", chinese)
        self.assertIn("open the app manually once after the first upgrade", english)
        self.assertIn("[settings](https://example.test/settings)", english)
        self.assertNotIn("历史条目", body)
        self.assertNotIn("0.9.0", body)

    def test_stale_or_missing_english_fails_before_emitting_body(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ReleaseNotes.json"
            for mutation in ({"version": "0.9.0"}, {"sourceNotes": ["outdated"]}, {"translations": {}}):
                with self.subTest(mutation=mutation):
                    path.write_text(json.dumps({**self.metadata(), **mutation}), encoding="utf-8")
                    with self.assertRaises(ValueError):
                        render("1.0.0", self.changelog, path)

    def test_missing_empty_or_no_item_release_is_rejected(self):
        for changelog in (self.changelog.replace("## 1.0.0 ·", "## 1.0.1 ·"),
                          "## 1.0.0 · 2026-09-30\n\n## 0.9.0 · 2026-09-29\n- old\n",
                          "## 1.0.0 · 2026-09-30\n\nOnly explanatory text\n"):
            with self.subTest(changelog=changelog), self.assertRaises(ValueError):
                render("1.0.0", changelog, Path("missing.json"))

    def test_cli_generates_current_release_and_unknown_version_has_no_output(self):
        metadata = json.loads((ROOT / "ReleaseNotes.json").read_text(encoding="utf-8"))
        command = [sys.executable, str(ROOT / "scripts/github_release_notes.py")]
        valid = subprocess.run([*command, metadata["version"]], capture_output=True, text=True)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertIn("## 中文\n", valid.stdout)
        self.assertIn("## English\n", valid.stdout)
        for note in metadata["translations"]["en"]:
            self.assertIn(note, valid.stdout)
        invalid = subprocess.run([*command, "999.999.999"], capture_output=True, text=True)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertEqual(invalid.stdout, "")


if __name__ == "__main__":
    unittest.main()
