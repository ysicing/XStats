#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

import base64
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

from sparkle_appcast import NOTE_LANGUAGES, ROOT, SPARKLE, XML_LANG, XSTATS, load_localized_notes, load_manifest, make_feed, verify_feed


class SparkleAppcastTests(unittest.TestCase):
    def test_main_archive_does_not_require_network_extension(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "main.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("XStats.app/Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": "work.12306.xstats.app",
                                                                              "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "200"}))
            data = archive.read_bytes()
            feed = {"version": "1.0.0", "build": "200", "size": len(data), "notes": ["test"],
                    "url": "https://example.test/main.zip", "sha256": hashlib.sha256(data).hexdigest()}
            manifest = Path(directory) / "appcast.json"
            manifest.write_text(json.dumps(feed))
            self.assertEqual(load_manifest(manifest, archive), feed)

    def test_capture_archive_cannot_be_mistaken_for_main(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "capture.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("XStats Capture.app/Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": "work.12306.xstats.capture",
                                                                                      "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}))
            data = archive.read_bytes()
            feed = {"version": "0.1.0", "build": "1", "size": len(data), "notes": ["test"],
                    "bundleIdentifier": "work.12306.xstats.capture", "url": "https://example.test/capture.zip", "sha256": hashlib.sha256(data).hexdigest()}
            manifest = Path(directory) / "appcast.json"
            manifest.write_text(json.dumps(feed))
            self.assertEqual(load_manifest(manifest, archive), feed)
            feed["bundleIdentifier"] = "work.12306.xstats.app"
            manifest.write_text(json.dumps(feed))
            with self.assertRaises(ValueError):
                load_manifest(manifest, archive)

    def test_component_archive_requires_its_own_bundle_and_matching_extension(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "component.zip"
            manifest = Path(directory) / "appcast.json"
            for identifier, root, extension_build in (
                    ("work.12306.xstats.networkmonitor", "XStats Network Monitor.app", "136"),
                    ("work.12306.xstats.app", "XStats Network Monitor.app", "136"),
                    ("work.12306.xstats.networkmonitor", "XStats.app", "136"),
                    ("work.12306.xstats.networkmonitor", "XStats Network Monitor.app", "137")):
                with self.subTest(identifier=identifier, root=root, extension_build=extension_build):
                    with zipfile.ZipFile(archive, "w") as bundle:
                        bundle.writestr(root + "/Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": identifier,
                                                                                     "CFBundleShortVersionString": "0.15.0", "CFBundleVersion": "136"}))
                        bundle.writestr(root + "/Contents/Library/SystemExtensions/work.12306.xstats.app.networkextension.systemextension/Contents/Info.plist",
                                        plistlib.dumps({"CFBundleIdentifier": "work.12306.xstats.app.networkextension",
                                                        "CFBundleShortVersionString": "0.15.0", "CFBundleVersion": extension_build}))
                    data = archive.read_bytes()
                    feed = {"version": "0.15.0", "build": "136", "size": len(data), "notes": ["test"],
                            "bundleIdentifier": "work.12306.xstats.networkmonitor",
                            "appName": "XStats Network Monitor", "networkExtension": {"version": "0.15.0", "build": "136"},
                            "url": "https://example.test/component.zip", "sha256": hashlib.sha256(data).hexdigest()}
                    manifest.write_text(json.dumps(feed))
                    if identifier == "work.12306.xstats.networkmonitor" and root == "XStats Network Monitor.app" and extension_build == "136":
                        self.assertEqual(load_manifest(manifest, archive), feed)
                    else:
                        with self.assertRaises(ValueError):
                            load_manifest(manifest, archive)

    def test_archive_root_version_and_build_must_match_manifest(self):
        extension = {"CFBundleIdentifier": "work.12306.xstats.app.networkextension",
                     "CFBundleShortVersionString": "0.15.0", "CFBundleVersion": "136"}
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "update.zip"
            manifest = Path(directory) / "appcast.json"
            for identifier, root in (
                    ("work.12306.xstats.app", "XStats.app"),
                    ("work.12306.xstats.capture", "XStats Capture.app"),
                    ("work.12306.xstats.networkmonitor", "XStats Network Monitor.app")):
                for version, build in (("2.0.0", "200"), ("1.0.0", "200"), ("2.0.0", "100"),
                                       ("1.0.0", "100"), (None, "200"), ("2.0.0", None),
                                       ("", "200"), ("2.0.0", 200), ("2.0.0", "0200")):
                    with self.subTest(identifier=identifier, version=version, build=build):
                        info = {"CFBundleIdentifier": identifier}
                        if version is not None:
                            info["CFBundleShortVersionString"] = version
                        if build is not None:
                            info["CFBundleVersion"] = build
                        with zipfile.ZipFile(archive, "w") as bundle:
                            bundle.writestr(root + "/Contents/Info.plist", plistlib.dumps(info))
                            if identifier == "work.12306.xstats.networkmonitor":
                                bundle.writestr(root + "/Contents/Library/SystemExtensions/work.12306.xstats.app.networkextension.systemextension/Contents/Info.plist",
                                                plistlib.dumps(extension))
                        data = archive.read_bytes()
                        feed = {"version": "2.0.0", "build": "200", "size": len(data), "notes": ["test"],
                                "bundleIdentifier": identifier, "url": "https://example.test/update.zip",
                                "sha256": hashlib.sha256(data).hexdigest()}
                        if identifier == "work.12306.xstats.networkmonitor":
                            feed["networkExtension"] = {"version": "0.15.0", "build": "136"}
                        manifest.write_text(json.dumps(feed))
                        if version == "2.0.0" and build == "200":
                            self.assertEqual(load_manifest(manifest, archive), feed)
                        else:
                            with self.assertRaises(ValueError):
                                load_manifest(manifest, archive)

    def test_signed_extension_version_is_preserved_and_tampering_is_rejected(self):
        feed = {"version": "1.0.0", "build": "200", "minimumSystem": "14.0", "size": 3,
                "url": "https://example.test/update.zip", "notes": ["test"],
                "networkExtension": {"version": "0.15.0", "build": "136"}}
        signature = base64.b64encode(b"s" * 64).decode()
        root = ET.fromstring(make_feed(feed, signature))
        item = root.find("channel/item")
        self.assertEqual(item.findtext(f"{{{XSTATS}}}network-extension-build"), "136")
        with tempfile.TemporaryDirectory() as directory, patch("sparkle_appcast.run_tool") as tool:
            item.find(f"{{{XSTATS}}}network-extension-build").text = "137"
            xml = Path(directory) / "update.xml"
            xml.write_bytes(ET.tostring(root))
            with self.assertRaises(ValueError):
                verify_feed(feed, xml, Path(directory) / "update.zip", Path(directory), "test")
            tool.assert_not_called()
    def test_xml_preserves_release_and_escapes_notes(self):
        feed = {"version": "1.0.0", "build": "200", "minimumSystem": "14.0", "size": 3,
                "url": "https://example.test/XStats-1.0.0-AppleSilicon.zip", "notes": ["<test> & 新版本", "line two"], "date": "2026-09-30",
                "dmg": "https://example.test/update.dmg", "sha256": "a" * 64,
                "changelog": "https://example.test/changelog"}
        signature = base64.b64encode(b"s" * 64).decode()
        item = ET.fromstring(make_feed(feed, signature)).find("channel/item")
        self.assertEqual(item.findtext(f"{{{SPARKLE}}}version"), "200")
        self.assertEqual(item.findtext(f"{{{SPARKLE}}}shortVersionString"), "1.0.0")
        self.assertEqual(item.findtext(f"{{{SPARKLE}}}hardwareRequirements"), "arm64")
        self.assertEqual(item.findtext("description"), "<test> & 新版本\nline two")
        self.assertEqual(item.find("description").get(f"{{{SPARKLE}}}format"), "plain-text")
        for field in ("date", "dmg", "sha256"):
            self.assertEqual(item.findtext(f"{{{XSTATS}}}{field}"), feed[field])
        self.assertEqual(item.findtext(f"{{{SPARKLE}}}fullReleaseNotesLink"), feed["changelog"])
        self.assertEqual(item.find("enclosure").get(f"{{{SPARKLE}}}edSignature"), signature)
        with self.assertRaises(ValueError):
            make_feed(feed, base64.b64encode(b"short").decode())

    def test_verify_rejects_wrong_metadata_even_before_signature_tools(self):
        feed = {"version": "1.0.0", "build": "200", "minimumSystem": "14.0", "size": 3,
                "url": "https://example.test/XStats-1.0.0-AppleSilicon.zip", "notes": ["test"]}
        signature = base64.b64encode(b"s" * 64).decode()
        with tempfile.TemporaryDirectory() as directory, patch("sparkle_appcast.run_tool") as tool:
            xml = Path(directory) / "update.xml"
            for field, value in (("build", "201"), ("url", "https://example.test/other.zip"),
                                 ("size", 4), ("notes", ["other"]), ("minimumSystem", "15.0")):
                with self.subTest(field=field):
                    xml.write_bytes(make_feed({**feed, field: value}, signature))
                    with self.assertRaises(ValueError):
                        verify_feed(feed, xml, Path(directory) / "update.zip", Path(directory), "test")
            root = ET.fromstring(make_feed(feed, signature))
            root.find("channel/item").find(f"{{{SPARKLE}}}hardwareRequirements").text = "x86_64"
            xml.write_bytes(ET.tostring(root))
            with self.assertRaises(ValueError):
                verify_feed(feed, xml, Path(directory) / "update.zip", Path(directory), "test")
            root = ET.fromstring(make_feed(feed, signature))
            root.find("channel").append(ET.fromstring(ET.tostring(root.find("channel/item"))))
            xml.write_bytes(ET.tostring(root))
            with self.assertRaises(ValueError):
                verify_feed(feed, xml, Path(directory) / "update.zip", Path(directory), "test")
            tool.assert_not_called()

    def test_english_translation_matches_the_current_changelog(self):
        from appcast import release_notes
        source = json.loads((ROOT / "docs/ReleaseNotes.json").read_text())
        _, notes = release_notes((ROOT / "CHANGELOG.md").read_text(), source["version"])
        localized = load_localized_notes({"version": source["version"], "notes": notes})
        self.assertEqual(set(localized), {"en", "zh-Hans"})
        self.assertEqual(localized["zh-Hans"], notes)

    def test_stale_incomplete_or_invalid_translations_are_rejected(self):
        feed = {"version": "1.0.0", "notes": ["source"]}
        source = {"version": "1.0.0", "sourceNotes": ["source"],
                  "translations": {language: [language] for language in NOTE_LANGUAGES if language != "zh-Hans"}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ReleaseNotes.json"
            path.write_text(json.dumps(source))
            self.assertEqual(load_localized_notes(feed, path)["en"], ["en"])
            mutations = [
                {**source, "version": "0.9.0"}, {**source, "sourceNotes": ["stale"]},
                {**source, "translations": {}},
                {**source, "translations": {**source["translations"], "ja": ["extra"]}},
                *[{**source, "translations": {**source["translations"], "en": value}}
                  for value in ([], [""], ["one", "two"], ["split\nline"], [1])],
            ]
            for value in mutations:
                with self.subTest(value=value):
                    path.write_text(json.dumps(value))
                    with self.assertRaises(ValueError):
                        load_localized_notes(feed, path)

    def test_signed_xml_contains_native_and_application_language_notes(self):
        feed = {"version": "1.0.0", "build": "200", "minimumSystem": "14.0", "size": 3,
                "url": "https://example.test/update.zip", "notes": ["中文"]}
        localized = {"zh-Hans": feed["notes"], "en": ["<English> & details"]}
        signature = base64.b64encode(b"s" * 64).decode()
        with tempfile.TemporaryDirectory() as directory, patch("sparkle_appcast.run_tool") as tool:
            xml = Path(directory) / "update.xml"
            data = make_feed(feed, signature, localized)
            xml.write_bytes(data)
            verify_feed(feed, xml, Path(directory) / "update.zip", Path(directory), "test", localized)
            self.assertEqual(tool.call_count, 2)
            item = ET.fromstring(data).find("channel/item")
            descriptions = item.findall("description")
            self.assertEqual(descriptions[0].get(XML_LANG), "en")
            self.assertEqual({node.get(XML_LANG): node.text for node in descriptions},
                             {language: "\n".join(notes) for language, notes in localized.items()})
            for field in ("description", f"{{{XSTATS}}}notes-en"):
                root = ET.fromstring(data)
                root.find("channel/item").find(field).text = "tampered"
                xml.write_bytes(ET.tostring(root))
                tool.reset_mock()
                with self.assertRaises(ValueError):
                    verify_feed(feed, xml, Path(directory) / "update.zip", Path(directory), "test", localized)
                tool.assert_not_called()
            root = ET.fromstring(data)
            item = root.find("channel/item")
            item.append(ET.fromstring(ET.tostring(item.find("description"))))
            xml.write_bytes(ET.tostring(root))
            with self.assertRaises(ValueError):
                verify_feed(feed, xml, Path(directory) / "update.zip", Path(directory), "test", localized)

    def test_feed_size_limit_includes_translations(self):
        feed = {"version": "1.0.0", "build": "200", "minimumSystem": "14.0", "size": 3,
                "url": "https://example.test/update.zip", "notes": ["source"]}
        with self.assertRaises(ValueError):
            make_feed(feed, base64.b64encode(b"s" * 64).decode(), {"en": ["x" * (256 * 1024)]})


    def test_stale_manifest_or_wrong_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "XStats-1.0.0-AppleSilicon.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("XStats.app/Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": "work.12306.xstats.app",
                                                                              "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "200"}))
                bundle.writestr("XStats.app/Contents/Library/SystemExtensions/work.12306.xstats.app.networkextension.systemextension/Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": "work.12306.xstats.app.networkextension", "CFBundleShortVersionString": "0.15.0", "CFBundleVersion": "136"}))
            original = archive.read_bytes()
            manifest = Path(directory) / "appcast.json"
            feed = {"version": "1.0.0", "build": "200", "size": len(original), "notes": ["test"], "networkExtension": {"version": "0.15.0", "build": "136"},
                    "url": f"https://example.test/{archive.name}", "sha256": hashlib.sha256(original).hexdigest()}
            manifest.write_text(json.dumps(feed))
            self.assertEqual(load_manifest(manifest, archive), feed)
            archive.write_bytes(b"modified archive")
            with self.assertRaises(ValueError):
                load_manifest(manifest, archive)
            archive.write_bytes(original)
            feed["url"] = "https://example.test/Another.zip"
            manifest.write_text(json.dumps(feed))
            with self.assertRaises(ValueError):
                load_manifest(manifest, archive)


class AppcastManifestTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.work = Path(directory.name)
        (self.work / "scripts").mkdir()
        shutil.copy(ROOT / "scripts/appcast.py", self.work / "scripts")
        self.app = self.work / "XStats.app"
        (self.app / "Contents").mkdir(parents=True)
        self.archive = self.work / "update.zip"
        self.command = [sys.executable, str(self.work / "scripts/appcast.py"), "2.0.0", "200",
                        "https://example.test", str(self.archive), str(self.work / "update.dmg"), str(self.app)]

    def test_manifest_generation_rejects_changed_or_missing_app_identity(self):
        (self.work / "CHANGELOG.md").write_text("## 2.0.0 · 2026-10-22\n- release\n", encoding="utf-8")
        with zipfile.ZipFile(self.archive, "w") as bundle:
            bundle.writestr("XStats.app/Contents/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": "work.12306.xstats.app",
                "CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "200"}))
        for identifier, version, build in (
                ("work.12306.xstats.app", "1.0.0", "200"),
                ("work.12306.xstats.app", "2.0.0", "100"),
                ("work.12306.xstats.capture", "2.0.0", "200"),
                ("work.12306.xstats.app", None, "200"),
                ("work.12306.xstats.app", "2.0.0", None)):
            with self.subTest(identifier=identifier, version=version, build=build):
                info = {"CFBundleIdentifier": identifier}
                if version is not None:
                    info["CFBundleShortVersionString"] = version
                if build is not None:
                    info["CFBundleVersion"] = build
                (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                result = subprocess.run(self.command, cwd=self.work, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("ValueError", result.stderr)
                self.assertNotIn("FileNotFoundError", result.stderr)

    def test_manifest_generation_checks_app_before_reading_assets(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "work.12306.xstats.app",
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "100"}))
        result = subprocess.run(self.command, cwd=self.work, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("ValueError", result.stderr)
        self.assertNotIn("FileNotFoundError", result.stderr)

    def test_matching_app_generates_manifest_accepted_by_archive_validation(self):
        info = {"CFBundleIdentifier": "work.12306.xstats.app",
                "CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "200"}
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        (self.work / "CHANGELOG.md").write_text("## 2.0.0 · 2026-10-22\n- release\n", encoding="utf-8")
        with zipfile.ZipFile(self.archive, "w") as bundle:
            bundle.writestr("XStats.app/Contents/Info.plist", plistlib.dumps(info))
        result = subprocess.run(self.command, cwd=self.work, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = json.loads(result.stdout)
        self.assertEqual((feed["version"], feed["build"], feed["notes"]), ("2.0.0", "200", ["release"]))
        manifest = self.work / "appcast.json"
        manifest.write_text(result.stdout)
        self.assertEqual(load_manifest(manifest, self.archive), feed)


if __name__ == "__main__":
    unittest.main()
