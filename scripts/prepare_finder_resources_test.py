#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later

"""验证 Finder 资源精简不改变译文、不修改其他宿主，并在资源缺失时停止。"""

import importlib.util
import plistlib
import shutil
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "prepare_finder_resources", ROOT / "scripts/prepare_finder_resources.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FinderResourcesTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.app = Path(self.work.name) / "XStats.app"
        self.extension = self.app / "Contents/PlugIns/XStatsFinderExtension.appex"
        self.resources = self.extension / "Contents/Resources"
        self.catalogs = self.resources / "XStatsKit_Localization.bundle/Contents/Resources"
        self.catalogs.mkdir(parents=True)
        self.templates = self.resources / "XStatsKit_FinderDocuments.bundle"
        self.templates.mkdir()
        (self.templates / "template").write_bytes(b"preserve source templates")
        for bundle, identifier in (
            (self.app, "work.12306.xstats.app"),
            (self.extension, "work.12306.xstats.app.finder"),
        ):
            (bundle / "Contents/Info.plist").write_bytes(
                plistlib.dumps({"CFBundleIdentifier": identifier})
            )
        for source in (ROOT / "Packages/XStatsKit/Sources/Localization/Resources").glob("*.tsv"):
            shutil.copy2(source, self.catalogs / source.name)
        self.other = self.app / "Contents/Resources/keep"
        self.other.parent.mkdir(parents=True)
        self.other.write_bytes(b"main app resources")
        self.widget = self.app / "Contents/PlugIns/XStatsWidget.appex/Contents/Resources/keep"
        self.widget.parent.mkdir(parents=True)
        self.widget.write_bytes(b"widget resources")

    def test_preserves_all_finder_translations_and_other_hosts(self):
        originals = {path.name: path.read_text() for path in self.catalogs.glob("*.tsv")}
        keys = MODULE.finder_keys(ROOT)
        MODULE.prepare(self.app)
        self.assertFalse(self.templates.exists())
        self.assertEqual(set(originals), {path.name for path in self.catalogs.glob("*.tsv")})
        for path in self.catalogs.glob("*.tsv"):
            expected = [
                line for line in originals[path.name].splitlines()
                if line.split("\t", 1)[0] in keys
            ]
            self.assertEqual(path.read_text().splitlines(), expected)
            self.assertEqual({line.split("\t", 1)[0] for line in expected}, keys)
        self.assertEqual(self.other.read_bytes(), b"main app resources")
        self.assertEqual(self.widget.read_bytes(), b"widget resources")

    def test_repeated_preparation_is_idempotent(self):
        MODULE.prepare(self.app)
        before = {path.name: path.read_bytes() for path in self.catalogs.glob("*.tsv")}
        MODULE.prepare(self.app)
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.catalogs.glob("*.tsv")})

    def test_missing_translation_fails_before_any_mutation(self):
        catalog = self.catalogs / "ar.tsv"
        catalog.write_text("\n".join(
            line for line in catalog.read_text().splitlines()
            if not line.startswith("新建文档\t")
        ) + "\n")
        before = {path.name: path.read_bytes() for path in self.catalogs.glob("*.tsv")}
        with self.assertRaisesRegex(ValueError, "ar.tsv"):
            MODULE.prepare(self.app)
        self.assertTrue(self.templates.is_dir())
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.catalogs.glob("*.tsv")})

    def test_missing_language_fails_before_any_mutation(self):
        (self.catalogs / "ar.tsv").unlink()
        with self.assertRaisesRegex(ValueError, "ar.tsv"):
            MODULE.prepare(self.app)
        self.assertTrue(self.templates.is_dir())

    def test_rejects_other_application_identity(self):
        (self.app / "Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleIdentifier": "work.12306.xstats.capture"})
        )
        with self.assertRaisesRegex(ValueError, "Bundle ID"):
            MODULE.prepare(self.app)
        self.assertTrue(self.templates.is_dir())

    def test_rejects_linked_resources_without_modifying_the_target(self):
        catalog = self.catalogs / "ar.tsv"
        external = Path(self.work.name) / "external.tsv"
        catalog.rename(external)
        original = external.read_bytes()
        catalog.symlink_to(external)
        with self.assertRaisesRegex(ValueError, "符号链接"):
            MODULE.prepare(self.app)
        self.assertEqual(external.read_bytes(), original)
        self.assertTrue(self.templates.is_dir())

    def test_rejects_new_finder_text_without_catalog_membership(self):
        root = Path(self.work.name) / "source"
        translation = Path("Packages/XStatsKit/Sources/Localization/FinderDocumentTranslations.swift")
        (root / translation).parent.mkdir(parents=True)
        shutil.copy2(ROOT / translation, root / translation)
        for relative in MODULE.FINDER_SOURCES:
            source = root / relative
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text('let title = "新增菜单"\n' if relative.endswith("FinderExtension.swift") else "")
        with self.assertRaisesRegex(ValueError, "新增菜单"):
            MODULE.finder_keys(root)


if __name__ == "__main__":
    unittest.main()
