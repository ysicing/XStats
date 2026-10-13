#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Run the real task graph against controlled build-tool boundaries."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TASK = shutil.which("task")


class ReleaseBuildTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        (self.work / "scripts").mkdir()
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")
        shutil.copy(ROOT / "Taskfile.yml", self.work)
        self.write_executable(self.bin / "security", '#!/bin/bash\necho \'1) ABC "Developer ID Application: Test (TEAM123456)"\'\n')
        self.write_executable(self.bin / "xcodegen", "#!/bin/bash\nexit 0\n")
        self.write_executable(self.work / "scripts/sign_sparkle.sh", "#!/bin/bash\ntouch signed\n")
        self.write_executable(self.bin / "xcodebuild", '''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
pathlib.Path("build-args.json").write_text(json.dumps(args))
derived = pathlib.Path(args[args.index("-derivedDataPath") + 1])
products = derived / "Build/Products/Release"
if "clean" in args:
    if os.environ.get("FAIL_CLEAN") == "1":
        sys.exit(17)
    shutil.rmtree(products)
products.mkdir(parents=True, exist_ok=True)
widget = products / "XStatsWidget.appex"
if not widget.exists():
    widget.write_text("freshly linked")
''')
        self.products = self.work / "build/DerivedData-arm64/Build/Products/Release"
        self.products.mkdir(parents=True)
        (self.products / "XStatsWidget.appex").write_text("old stripped binary")
        self.cache = self.work / "build/DerivedData-arm64/SourcePackages/cache"
        self.cache.parent.mkdir(parents=True)
        self.cache.write_text("downloaded dependencies")

    def write_executable(self, path, source):
        path.write_text(source)
        path.chmod(0o755)

    def build(self, clean):
        return subprocess.run([TASK, "build", "CONFIG=Release", "INSTALL=0", "BUMP=0",
                               "SIGN_ID=-", f"CLEAN={clean}"],
                              cwd=self.work, env=self.env, text=True, capture_output=True)

    def test_clean_build_replaces_stale_widget_and_retains_dependencies(self):
        result = self.build(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.products / "XStatsWidget.appex").read_text(), "freshly linked")
        self.assertEqual(self.cache.read_text(), "downloaded dependencies")
        self.assertTrue((self.work / "signed").exists())
        args = json.loads((self.work / "build-args.json").read_text())
        self.assertLess(args.index("clean"), args.index("build"))

    def test_local_build_stays_incremental(self):
        result = self.build(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.products / "XStatsWidget.appex").read_text(), "old stripped binary")
        self.assertNotIn("clean", json.loads((self.work / "build-args.json").read_text()))

    def test_failed_clean_does_not_sign_old_build(self):
        self.env["FAIL_CLEAN"] = "1"
        result = self.build(1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / "signed").exists())

    def test_release_requests_clean_without_installing_or_bumping_twice(self):
        shutil.copy(ROOT / "scripts/release.sh", self.work / "scripts")
        shutil.copy(ROOT / "scripts/codesign_retry.sh", self.work / "scripts")
        self.write_executable(self.work / "scripts/version.sh", "#!/bin/bash\necho 1.3.1\n")
        (self.work / "project.yml").write_text('CURRENT_PROJECT_VERSION: "145"\n')
        self.write_executable(self.bin / "python3", '#!/bin/bash\n[ "$2" != prepare ] || echo revision\nexit 0\n')
        self.write_executable(self.bin / "task", '#!/bin/bash\nprintf "%s\\n" "$@" > release-task-args\nexit 73\n')
        result = subprocess.run(["bash", "scripts/release.sh"], cwd=self.work,
                                env=dict(self.env, SIGN_ID="ABC", DIST="dist"), text=True, capture_output=True)
        self.assertEqual(result.returncode, 73, result.stderr)
        args = (self.work / "release-task-args").read_text().splitlines()
        for argument in ["build", "CONFIG=Release", "INSTALL=0", "BUMP=0", "CLEAN=1", "SIGN_ID=ABC"]:
            self.assertIn(argument, args)


if __name__ == "__main__":
    unittest.main()
