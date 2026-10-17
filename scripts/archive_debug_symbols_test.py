#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Exercise UUID validation and symbolication with real Mach-O/dSYM fixtures."""

import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("archive_debug_symbols.py")


class DebugSymbolsTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.products = self.root / "products"
        self.app = self.products / "XStats.app"
        self.output = self.root / "symbols"
        (self.app / "Contents").mkdir(parents=True)
        with (self.app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "work.12306.xstats.app",
                          "CFBundleShortVersionString": "9.9.9", "CFBundleVersion": "999"}, handle)
        source = self.root / "probe.c"
        source.write_text("__attribute__((noinline)) int probe(int x) { return x + 7; }\n"
                          "int main(void) { return probe(0) == 7 ? 0 : 1; }\n")
        binary = self.root / "probe"
        obj = self.root / "probe.o"
        subprocess.run(["xcrun", "clang", "-arch", "arm64", "-g", "-O0", "-c", str(source), "-o", str(obj)], check=True)
        subprocess.run(["xcrun", "clang", "-arch", "arm64", str(obj), "-o", str(binary)], check=True)
        dsym = self.root / "probe.dSYM"
        subprocess.run(["xcrun", "dsymutil", str(binary), "-o", str(dsym)], check=True)
        self.address = next(line.split()[0] for line in subprocess.check_output(
            ["nm", "-n", str(binary)], text=True).splitlines() if line.endswith(" _probe"))
        subprocess.run(["xcrun", "strip", "-S", "-x", str(binary)], check=True, capture_output=True)
        paths = [
            ("Contents/MacOS/XStats", "XStats.app.dSYM"),
            ("Contents/MacOS/XStatsHelper", "XStatsHelper.dSYM"),
            ("Contents/PlugIns/XStatsWidget.appex/Contents/MacOS/XStatsWidget", "XStatsWidget.appex.dSYM"),
            ("Contents/Frameworks/Sparkle.framework/Versions/A/Sparkle", "Sparkle.framework.dSYM"),
            ("Contents/Frameworks/Sparkle.framework/Versions/A/Autoupdate", "Autoupdate.dSYM"),
            ("Contents/Frameworks/Sparkle.framework/Versions/A/Updater.app/Contents/MacOS/Updater", "Updater.app.dSYM"),
            ("Contents/Frameworks/Sparkle.framework/Versions/A/XPCServices/Installer.xpc/Contents/MacOS/Installer", "Installer.xpc.dSYM"),
            ("Contents/Frameworks/Sparkle.framework/Versions/A/XPCServices/Downloader.xpc/Contents/MacOS/Downloader", "Downloader.xpc.dSYM"),
        ]
        for relative, name in paths:
            destination = self.app / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(binary, destination)
            shutil.copytree(dsym, self.products / name)
        framework = self.app / "Contents/Frameworks/Sparkle.framework/Versions"
        (framework / "Current").symlink_to("A")

    def archive(self):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.app),
                               str(self.products), str(self.output)], capture_output=True, text=True)

    def test_archive_preserves_symbolication_and_can_be_reused(self):
        result = self.archive()
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.output / "XStats-9.9.9-999-AppleSilicon.dSYMs.zip"
        with zipfile.ZipFile(archive) as handle:
            handle.extractall(self.root / "extracted")
        extracted = self.root / "extracted" / archive.name.removesuffix(".zip")
        manifest = json.loads((extracted / "manifest.json").read_text())
        self.assertEqual((manifest["version"], manifest["build"]), ("9.9.9", "999"))
        self.assertEqual(len(manifest["binaries"]), 8)
        self.assertTrue(all(entry["uuids"].keys() == {"arm64"} for entry in manifest["binaries"]))
        dwarf = extracted / "XStats.app.dSYM/Contents/Resources/DWARF/probe"
        resolved = subprocess.check_output(["xcrun", "atos", "-arch", "arm64", "-o", str(dwarf), self.address], text=True)
        self.assertIn("probe.c:1", resolved)
        subprocess.run([str(self.app / "Contents/MacOS/XStats")], check=True)
        first = archive.read_bytes()
        self.assertEqual(self.archive().returncode, 0)
        self.assertEqual(archive.read_bytes(), first)

    def test_capture_archive_has_own_name_and_only_six_binaries(self):
        info_path = self.app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier"] = "work.12306.xstats.capture"
        info_path.write_bytes(plistlib.dumps(info))
        shutil.copy2(self.app / "Contents/MacOS/XStats", self.app / "Contents/MacOS/XStats Capture")
        shutil.copytree(self.products / "XStats.app.dSYM", self.products / "XStats Capture.app.dSYM")
        result = self.archive()
        self.assertEqual(result.returncode, 0, result.stderr)
        name = "XStats-Capture-9.9.9-999-AppleSilicon.dSYMs"
        with zipfile.ZipFile(self.output / (name + ".zip")) as bundle:
            manifest = json.loads(bundle.read(name + "/manifest.json"))
        self.assertEqual(manifest["product"], "XStats-Capture")
        self.assertEqual(len(manifest["binaries"]), 6)
        self.assertFalse(any("Helper" in e["path"] or "Widget" in e["path"] for e in manifest["binaries"]))

    def test_missing_dsym_stops_archiving(self):
        shutil.rmtree(self.products / "XStatsWidget.appex.dSYM")
        result = self.archive()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("XStatsWidget.appex.dSYM", result.stderr)
        self.assertFalse(list(self.output.glob("*.zip")))

    def test_mismatched_uuid_stops_archiving(self):
        source = self.root / "other.c"
        source.write_text("int main(void) { return 3; }\n")
        subprocess.run(["xcrun", "clang", "-arch", "arm64", "-g", str(source), "-o",
                        str(self.app / "Contents/MacOS/XStatsHelper")], check=True)
        result = self.archive()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UUID", result.stderr)
        self.assertFalse(list(self.output.glob("*.zip")))

    def test_matching_uuid_without_dwarf_information_is_rejected(self):
        shutil.copy2(self.app / "Contents/MacOS/XStatsHelper",
                     self.products / "XStatsHelper.dSYM/Contents/Resources/DWARF/probe")
        result = self.archive()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("XStatsHelper.dSYM", result.stderr)
        self.assertFalse(list(self.output.glob("*.zip")))

    def test_existing_archive_is_never_replaced_with_other_binary(self):
        self.assertEqual(self.archive().returncode, 0)
        archive = next(self.output.glob("*.zip"))
        original = archive.read_bytes()
        with (self.app / "Contents/MacOS/XStats").open("ab") as handle:
            handle.write(b"changed signature")
        result = self.archive()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(archive.read_bytes(), original)

    def test_incomplete_existing_archive_is_rejected(self):
        self.assertEqual(self.archive().returncode, 0)
        archive = next(self.output.glob("*.zip"))
        with zipfile.ZipFile(archive) as handle:
            manifest_path = archive.name.removesuffix(".zip") + "/manifest.json"
            manifest = handle.read(manifest_path)
        with zipfile.ZipFile(archive, "w") as handle:
            handle.writestr(manifest_path, manifest)
        self.assertNotEqual(self.archive().returncode, 0)


if __name__ == "__main__":
    unittest.main()
