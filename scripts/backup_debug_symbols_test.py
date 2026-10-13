#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Verify private, immutable symbol backups without touching a real storage service."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

from archive_debug_symbols import BINARIES


SCRIPT = Path(__file__).with_name("backup_debug_symbols.py")
MC = '''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ["SYMBOL_TEST_STORE"])
with (root / "calls").open("a") as log:
    log.write(json.dumps(args) + "\\n")
if args[0] == "anonymous":
    if os.environ.get("POLICY_ERROR"):
        sys.exit(1)
    print(json.dumps({"status": "success", "permission": os.environ.get("POLICY", "private")}))
    sys.exit(0)
conditional = args[:2] == ["--custom-header", "If-None-Match: *"]
if conditional:
    args = args[2:]
command = args[0]
target = args[-1]
path = root / "objects" / target
if command == "stat":
    if os.environ.get("STAT_ERROR"):
        print(json.dumps({"status": "error", "error": {"cause": {"message": "Access Denied"}}}))
        sys.exit(1)
    if not path.is_file():
        print(json.dumps({"status": "error", "error": {"cause": {"message": "Object does not exist"}}}))
        sys.exit(1)
    print(json.dumps({"status": "success"}))
elif command == "cp":
    if not conditional or "--disable-multipart" not in args or os.environ.get("UPLOAD_ERROR"):
        sys.exit(1)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = pathlib.Path(args[-2]).read_bytes()
    if os.environ.get("RACE"):
        path.write_bytes(data if os.environ["RACE"] == "same" else b"other build")
    try:
        with path.open("xb") as handle:
            handle.write(data)
    except FileExistsError:
        sys.exit(1)
elif command == "cat":
    if os.environ.get("READ_ERROR"):
        sys.exit(1)
    sys.stdout.buffer.write(b"corrupted" if os.environ.get("CORRUPT_READ") else path.read_bytes())
else:
    sys.exit(1)
'''


class SymbolBackupTests(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        (binary_dir / "mc").write_text(MC)
        (binary_dir / "mc").chmod(0o700)
        self.env = {**os.environ, "PATH": str(binary_dir) + os.pathsep + os.environ["PATH"],
                    "SYMBOL_TEST_STORE": str(self.root),
                    "DEBUG_SYMBOLS_TARGET": "home/oss/apps/macOS/XStats",
                    "SIGN_ID": "ABC", "DIST": "dist"}
        self.archive = self.root / "XStats-9.9.9-999-AppleSilicon.dSYMs.zip"
        name = self.archive.stem
        self.manifest = {"format": 1, "version": "9.9.9", "build": "999", "binaries": [
            {"path": path, "dsym": dsym, "uuids": {"arm64": "12345678-1234-1234-1234-123456789ABC"},
             "sha256": "0" * 64} for path, dsym in BINARIES]}
        with zipfile.ZipFile(self.archive, "w") as bundle:
            bundle.writestr(name + "/manifest.json", json.dumps(self.manifest))
            for _, dsym in BINARIES:
                bundle.writestr(name + "/" + dsym + "/Contents/Resources/DWARF/probe", b"dwarf fixture")

    def backup(self, **extra):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.archive)],
                              env={**self.env, **extra}, capture_output=True, text=True)

    def objects(self):
        return [path for path in (self.root / "objects").rglob("*") if path.is_file()]

    def test_upload_readback_and_identical_resume(self):
        first = self.backup()
        self.assertEqual(first.returncode, 0, first.stderr)
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.assertIn("home/oss/apps/macOS/XStats/dSYMs/9.9.9-999/" + digest, first.stdout)
        self.assertEqual(len(self.objects()), 2)
        remote = next(path for path in self.objects() if path.suffix == ".zip")
        self.assertEqual(remote.read_bytes(), self.archive.read_bytes())
        manifest = json.loads(next(path for path in self.objects() if path.name == "manifest.json").read_text())
        self.assertEqual(manifest["archive"]["sha256"], digest)
        self.assertEqual(manifest["binaries"], self.manifest["binaries"])
        (self.root / "calls").write_text("")
        second = self.backup()
        self.assertEqual(second.returncode, 0, second.stderr)
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        self.assertFalse(any("cp" in call for call in calls))
        self.assertEqual(first.stdout, second.stdout)

    def test_public_or_unknown_policy_prevents_upload(self):
        for extra in ({"POLICY": "download"}, {"POLICY_ERROR": "1"}):
            with self.subTest(extra=extra):
                result = self.backup(**extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.objects())

    def test_storage_query_error_is_not_missing(self):
        self.assertNotEqual(self.backup(STAT_ERROR="1").returncode, 0)
        self.assertFalse(self.objects())

    def test_upload_failure_preserves_local_archive(self):
        self.assertNotEqual(self.backup(UPLOAD_ERROR="1").returncode, 0)
        self.assertTrue(self.archive.is_file())
        self.assertFalse(self.objects())

    def test_readback_failure_or_corruption_stops_before_manifest(self):
        for extra in ({"READ_ERROR": "1"}, {"CORRUPT_READ": "1"}):
            with self.subTest(extra=extra):
                self.assertNotEqual(self.backup(**extra).returncode, 0)
                self.assertFalse(any(path.name == "manifest.json" for path in self.objects()))

    def test_existing_corrupt_object_is_never_overwritten(self):
        self.assertEqual(self.backup().returncode, 0)
        remote = next(path for path in self.objects() if path.suffix == ".zip")
        remote.write_bytes(b"existing corruption")
        self.assertNotEqual(self.backup().returncode, 0)
        self.assertEqual(remote.read_bytes(), b"existing corruption")

    def test_concurrent_identical_upload_is_safe(self):
        result = self.backup(RACE="same")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_concurrent_different_upload_is_rejected(self):
        self.assertNotEqual(self.backup(RACE="different").returncode, 0)
        self.assertTrue(all(path.read_bytes() == b"other build" for path in self.objects()))

    def test_different_archives_with_same_version_do_not_collide(self):
        self.assertEqual(self.backup().returncode, 0)
        with zipfile.ZipFile(self.archive, "a") as bundle:
            bundle.writestr(self.archive.stem + "/extra", b"second build")
        self.assertEqual(self.backup().returncode, 0)
        self.assertEqual(len(self.objects()), 4)

    def test_missing_debug_information_prevents_upload(self):
        with zipfile.ZipFile(self.archive, "w") as bundle:
            bundle.writestr(self.archive.stem + "/manifest.json", json.dumps(self.manifest))
        self.assertNotEqual(self.backup().returncode, 0)
        self.assertFalse(self.objects())

    def test_release_stops_before_notarization_when_backup_fails(self):
        repo = self.root / "repo"
        scripts = repo / "scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SCRIPT.with_name("release.sh"), scripts / "release.sh")
        shutil.copy2(SCRIPT.with_name("codesign_retry.sh"), scripts / "codesign_retry.sh")
        shutil.copy2(SCRIPT, scripts / SCRIPT.name)
        # The archive generator already has real Mach-O coverage; reuse this test archive here.
        (scripts / "archive_debug_symbols.py").write_text(
            "BINARIES = " + repr(BINARIES) + "\nif __name__ == '__main__':\n    print(" + repr(str(self.archive)) + ")\n")
        (scripts / "release_provenance.py").write_text("print('fixture')")
        (scripts / "version.sh").write_text("#!/bin/sh\necho 9.9.9\n")
        (scripts / "version.sh").chmod(0o700)
        (repo / "project.yml").write_text('CURRENT_PROJECT_VERSION: "999"\n')
        binary_dir = self.root / "bin"
        (binary_dir / "security").write_text('#!/bin/sh\necho \'1) ABC "Developer ID Application: Fixture (TEAM123)"\'\n')
        (binary_dir / "task").write_text("#!/bin/sh\nexit 0\n")
        for name in ("xcrun", "codesign", "hdiutil"):
            (binary_dir / name).write_text('#!/bin/sh\necho unexpected >> "$SYMBOL_TEST_STORE/distribution-calls"\nexit 1\n')
        for path in binary_dir.iterdir():
            path.chmod(0o700)
        result = subprocess.run(["bash", str(scripts / "release.sh")], env={**self.env, "UPLOAD_ERROR": "1"},
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("私有符号备份失败", result.stderr)
        self.assertFalse((self.root / "distribution-calls").exists())
        self.assertTrue(self.archive.is_file())


if __name__ == "__main__":
    unittest.main()
