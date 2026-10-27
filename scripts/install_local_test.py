#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Run the installer in a temporary filesystem with isolated macOS services."""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WIDGET_ID = "work.12306.xstats.app.widget"
SUFFIX = "/Contents/PlugIns/XStatsWidget.appex"

SERVICE = r'''#!/usr/bin/env python3
import json, os, pathlib, re, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["INSTALL_TEST_ROOT"])
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps([name, *args]) + "\n")
state_file = root / "registry.json"
state = json.loads(state_file.read_text())
if name == "pluginkit":
    if "-m" in args:
        if os.environ.get("INSTALL_TEST_QUERY_FAIL"):
            print("match: Connection invalid", file=sys.stderr)
            sys.exit(1)
        if os.environ.get("INSTALL_TEST_MALFORMED"):
            print("unexpected registry reply")
            sys.exit(0)
        if os.environ.get("INSTALL_TEST_REPLY"):
            print(os.environ["INSTALL_TEST_REPLY"])
            sys.exit(0)
        for entry in state:
            print("     work.12306.xstats.app.widget(1.4.10)")
            print("            Path = " + entry["path"])
            print("            Parent Bundle = " + entry["parent"])
        print(" (%d plug-ins)" % len(state))
    elif args[0] == "-r":
        if os.environ.get("INSTALL_TEST_REMOVE_FAIL"):
            sys.exit(2)
        state = [x for x in state if x["path"] != args[1]]
    elif args[0] == "-a":
        if os.environ.get("INSTALL_TEST_ADD_FAIL"):
            sys.exit(2)
        path = args[1]
        state = [{"path": path, "parent": path.removesuffix(
            "/Contents/PlugIns/XStatsWidget.appex")}]
        if os.environ.get("INSTALL_TEST_REDISCOVER"):
            state.append({"path": str(root / "other workspace/Old.app") +
                          "/Contents/PlugIns/XStatsWidget.appex",
                          "parent": str(root / "other workspace/Old.app")})
        if os.environ.get("INSTALL_TEST_WRONG_PARENT"):
            state[0]["parent"] = str(root / "Wrong.app")
    state_file.write_text(json.dumps(state))
elif name == "lsregister":
    if args[0] == "-f" and os.environ.get("INSTALL_TEST_REGISTER_FAIL"):
        sys.exit(2)
elif name == "mdfind":
    print(root / "other workspace/Old.app")
elif name in ["pgrep", "pkill"]:
    processes_file = root / "processes.json"
    processes = json.loads(processes_file.read_text())
    if args[0] != "-f":
        sys.exit("process match must use an executable path")
    pattern = args[1].replace("[[:space:]]", r"\s")
    matches = [p for p in processes if re.search(pattern, p)]
    if name == "pkill":
        processes_file.write_text(json.dumps([p for p in processes if p not in matches]))
    elif matches:
        print("\n".join(str(100 + i) for i in range(len(matches))))
    sys.exit(0 if matches else 1)
elif name == "codesign":
    if os.environ.get("INSTALL_TEST_BAD_SIGNATURE"):
        sys.exit(1)
elif name == "defaults":
    print("1.4.10" if args[-1] == "CFBundleShortVersionString" else "159")
'''


class InstallLocalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xstats-install-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo with spaces"
        (self.repo / "scripts").mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.target = self.root / "Applications/XStats.app"
        self.source = self.repo / "build/DerivedData-arm64/Build/Products/Release/XStats.app"
        self.other = self.root / "other workspace/Old.app"
        self.stale = self.repo / "build/DerivedData-arm64/Build/Products/Debug/XStats.app"
        self.missing = self.root / "deleted preview/FoldPreview.app"
        for app in [self.source, self.target, self.other, self.stale]:
            self.make_app(app)
        # A parent with a different identifier must still be found by its Widget.
        self.make_app(self.other, "work.12306.xstats.foldpreview")
        self.settings = self.root / "Library/widget-layout.plist"
        self.settings.parent.mkdir()
        self.settings.write_bytes(b"existing-five-widgets-and-layout")
        self.registry = [
            {"path": str(app) + SUFFIX, "parent": str(app)}
            for app in [self.target, self.source, self.other, self.missing]
        ]
        (self.root / "registry.json").write_text(json.dumps(self.registry))
        (self.root / "processes.json").write_text("[]")
        for name in ["pluginkit", "lsregister", "mdfind", "pgrep", "pkill",
                     "codesign", "open", "defaults"]:
            path = self.bin / name
            path.write_text(SERVICE)
            path.chmod(0o755)
        # Redirect fixed system paths in the copied script, never in production.
        script = (ROOT / "scripts/install_local.sh").read_text()
        script = script.replace("/Applications/", str(self.root / "Applications") + "/")
        script = script.replace(
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
            "LaunchServices.framework/Support/lsregister", str(self.bin / "lsregister"))
        self.script = self.repo / "scripts/install_local.sh"
        self.script.write_text(script)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", HOME=str(self.root),
                        INSTALL_TEST_ROOT=str(self.root), TMPDIR=str(self.root))

    def make_app(self, path, bundle_id="work.12306.xstats.app"):
        for bundle, identifier in [(path, bundle_id), (Path(str(path) + SUFFIX), WIDGET_ID)]:
            (bundle / "Contents").mkdir(parents=True, exist_ok=True)
            info = {"CFBundleIdentifier": identifier,
                    "CFBundleShortVersionString": "1.4.10", "CFBundleVersion": "159"}
            if identifier == WIDGET_ID:
                info["NSExtension"] = {
                    "NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        (path / "marker").write_text(str(path))

    def run_install(self, source=None, **flags):
        (self.root / "calls.jsonl").write_text("")
        return subprocess.run(["bash", str(self.script), str(source or self.source)],
                              env=dict(self.env, **flags), capture_output=True,
                              text=True, timeout=20)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_repairs_deleted_and_renamed_preview_registrations_preserving_files(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        for app in [self.other, self.missing]:
            self.assertIn(["pluginkit", "-r", str(app) + SUFFIX], calls)
            self.assertIn(["lsregister", "-u", str(app)], calls)
        self.assertIn(["pluginkit", "-a", str(self.target) + SUFFIX], calls)
        # LaunchServices may fail with -10814 when a bundle is unregistered twice.
        self.assertEqual(calls.count(["lsregister", "-u", str(self.target)]), 1)
        self.assertEqual(json.loads((self.root / "registry.json").read_text()), [
            {"path": str(self.target) + SUFFIX, "parent": str(self.target)}])
        for app in [self.other, self.stale]:
            self.assertEqual((app / "marker").read_text(), str(app))
        self.assertEqual(self.settings.read_bytes(), b"existing-five-widgets-and-layout")
        self.assertEqual((self.target / "marker").read_text(), str(self.source))
        self.assertIn(["open", str(self.target)], calls)
        self.assertFalse(any("NotificationCenter" in arg for call in calls for arg in call))

    def test_registry_failure_stops_before_replacing_installed_app(self):
        for flag in ["INSTALL_TEST_QUERY_FAIL", "INSTALL_TEST_MALFORMED",
                     "INSTALL_TEST_REMOVE_FAIL"]:
            with self.subTest(flag=flag):
                result = self.run_install(**{flag: "1"})
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual((self.target / "marker").read_text(), str(self.target))
                self.assertTrue(self.source.exists())
                self.assertNotIn(["open", str(self.target)], self.calls())

    def test_registered_legacy_app_is_only_unregistered_once(self):
        legacy = self.root / "Applications/OpenStats.app"
        self.make_app(legacy)
        self.registry.append({"path": str(legacy) + SUFFIX, "parent": str(legacy)})
        (self.root / "registry.json").write_text(json.dumps(self.registry))
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls().count(["lsregister", "-u", str(legacy)]), 1)
        self.assertFalse(legacy.exists())
        self.assertIn(["open", str(self.target)], self.calls())

    def test_invalid_parent_in_registry_is_not_unregistered(self):
        records = [{"path": str(self.other) + SUFFIX, "parent": str(self.root / "Unrelated.app")}]
        (self.root / "registry.json").write_text(json.dumps(records))
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(call[:2] == ["lsregister", "-u"] for call in self.calls()))
        self.assertTrue(self.source.exists())

    def test_only_stops_processes_in_source_and_installed_app(self):
        unrelated = [str(self.other) + "/Contents/MacOS/XStats",
                     str(self.other) + SUFFIX + "/Contents/MacOS/XStatsWidget"]
        owned = [str(self.target) + "/Contents/MacOS/XStats",
                 str(self.source) + SUFFIX + "/Contents/MacOS/XStatsWidget -LaunchArguments data"]
        (self.root / "processes.json").write_text(json.dumps(unrelated + owned))
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.root / "processes.json").read_text()), unrelated)

    def test_empty_registry_can_be_installed(self):
        (self.root / "registry.json").write_text("[]")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["open", str(self.target)], self.calls())

    def test_partial_or_inconsistent_registry_stops_before_unregistering(self):
        for reply in [
            f" {WIDGET_ID}(1.4.10)\n Path = {self.other}{SUFFIX}\n (1 plug-in)",
            f" {WIDGET_ID}(1.4.10)\n Path = {self.other}{SUFFIX}\n"
            f" Parent Bundle = {self.other}\n (2 plug-ins)",
        ]:
            with self.subTest(reply=reply):
                result = self.run_install(INSTALL_TEST_REPLY=reply)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(any(call[0] == "lsregister" or call[:2] == ["pluginkit", "-r"]
                                     for call in self.calls()))
                self.assertTrue(self.source.exists())

    def test_failed_registration_never_reports_success_or_launches(self):
        for flag in ["INSTALL_TEST_ADD_FAIL", "INSTALL_TEST_REGISTER_FAIL",
                     "INSTALL_TEST_WRONG_PARENT", "INSTALL_TEST_REDISCOVER"]:
            with self.subTest(flag=flag):
                # Each attempt starts with a separate source; failed postchecks keep the target.
                (self.root / "registry.json").write_text(json.dumps(self.registry))
                source = self.repo / f"{flag}/XStats.app"
                self.make_app(source)
                result = self.run_install(source, **{flag: "1"})
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn(["open", str(self.target)], self.calls())
                self.assertTrue(self.target.exists())

    def test_rejects_installed_target_as_source_before_mutating(self):
        result = self.run_install(self.target)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.target / "marker").exists())
        self.assertEqual((self.target / "marker").read_text(), str(self.target))
        self.assertFalse(any(call[0] in ["pkill", "pluginkit", "lsregister", "open"]
                             for call in self.calls()))

    def test_rejects_wrong_identity_or_invalid_signature_before_mutating(self):
        self.make_app(self.source, "work.12306.xstats.other")
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.source.exists())
        self.make_app(self.source)
        result = self.run_install(INSTALL_TEST_BAD_SIGNATURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.source.exists())
        self.assertFalse(any(call[0] in ["pkill", "pluginkit", "lsregister", "open"]
                             for call in self.calls()))


if __name__ == "__main__":
    unittest.main()
