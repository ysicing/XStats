#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

import tempfile
import unittest
from pathlib import Path
from subprocess import run

import release_provenance


class ReleaseProvenanceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.repo = Path(self.temporary.name)
        self.write("project.yml", 'MARKETING_VERSION: "1.0.0"\nCURRENT_PROJECT_VERSION: "109"\n')
        self.write("CHANGELOG.md", "# 更新日志\n\n## 1.0.0 · 2026-09-22\n\n- 首次发布。\n")
        self.write("README.md", "# XStats\n")
        self.write("Sources/App.swift", "let version = 1\n")
        self.write(".gitignore", "dist/\n")
        self.git("init", "-b", "main")
        self.git("config", "user.name", "XStats Test")
        self.git("config", "user.email", "test@example.test")
        self.git("add", ".")
        self.git("commit", "-m", "initial")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, relative: str, content: str) -> None:
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def git(self, *arguments: str) -> str:
        result = run(["git", *arguments], cwd=self.repo, check=True, capture_output=True, text=True)
        return result.stdout.strip()

    def test_prepare_allows_release_metadata_but_rejects_dirty_source(self) -> None:
        self.write("CHANGELOG.md", "# 更新日志\n\n## 1.0.0 · 2026-09-22\n\n- 更新说明。\n")
        self.assertEqual(release_provenance.prepare(self.repo), self.git("rev-parse", "HEAD"))

        self.write("Sources/App.swift", "let version = 2\n")
        with self.assertRaises(release_provenance.ProvenanceError):
            release_provenance.prepare(self.repo)

    def test_verify_rejects_source_changes_after_build(self) -> None:
        base = release_provenance.prepare(self.repo)
        self.write("project.yml", 'MARKETING_VERSION: "1.0.0"\nCURRENT_PROJECT_VERSION: "110"\n')
        provenance = self.repo / "dist/release-provenance.json"
        release_provenance.record(self.repo, provenance, base, "1.0.0", "110")
        self.git("add", "project.yml")
        self.git("commit", "-m", "chore(release): 1.0.0")

        release_provenance.verify(self.repo, provenance, "1.0.0", "110")

        self.write("Sources/App.swift", "let version = 2\n")
        self.git("add", "Sources/App.swift")
        self.git("commit", "-m", "change source after build")
        with self.assertRaises(release_provenance.ProvenanceError):
            release_provenance.verify(self.repo, provenance, "1.0.0", "110")


if __name__ == "__main__":
    unittest.main()
