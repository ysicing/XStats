#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""ip2region 固定源校验、发布隔离与清单提交顺序回归。"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import sync_ip2region as regions


class IPRegionCDNTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)
        self.payloads = {}
        self.assets = []
        for family in (4, 6):
            raw = bytearray(256)
            raw[0:2] = (3).to_bytes(2, "little")
            raw[16:18] = family.to_bytes(2, "little")
            raw[18:20] = (4).to_bytes(2, "little")
            self.payloads[f"ip2region_v{family}.xdb"] = bytes(raw)
            self.assets.append({"family": family, "bytes": len(raw),
                                "sha256": hashlib.sha256(raw).hexdigest()})

    def prepare(self, corrupt=False):
        def download(url, limit):
            self.assertTrue(url.startswith(
                f"https://raw.githubusercontent.com/lionsoul2014/ip2region/{regions.VERSION}/data/"))
            raw = self.payloads[url.split("/")[-1]]
            return raw[:-1] if corrupt else raw

        with patch.object(regions, "ASSETS", self.assets), \
                patch.object(regions.common, "download_bytes", side_effect=download), \
                patch.object(regions.common, "compress_lzfse",
                             side_effect=lambda raw, output: output.write_bytes(b"compressed" + raw.read_bytes())):
            return regions.prepare(self.output)

    def test_source_pins_match_client(self):
        swift = (regions.common.ROOT / "Packages/XStatsKit/Sources/XStatsUI/NetworkObservation/IPRegionDatabase.swift").read_text()
        self.assertIn(regions.VERSION, swift)
        for asset in regions.ASSETS:
            self.assertIn(asset["sha256"], swift)
            self.assertIn(str(asset["bytes"]), swift.replace("_", ""))

    def test_prepares_compressed_hash_names_and_preserves_existing_manifest_on_failure(self):
        manifest = self.prepare()
        self.assertEqual(manifest["version"], regions.VERSION)
        self.assertEqual(manifest["license"], "Apache-2.0")
        self.assertEqual({item["name"] for item in manifest["files"]},
                         {"ip2region_v4.xdb", "ip2region_v6.xdb"})
        for item in manifest["files"]:
            self.assertEqual(item["file"], item["name"].replace(".xdb", "-")
                             + item["compressedSHA256"] + ".lzfse")
        previous = (self.output / "current.json").read_bytes()
        with self.assertRaises(ValueError):
            self.prepare(corrupt=True)
        self.assertEqual((self.output / "current.json").read_bytes(), previous)
        self.assertFalse(any(item.name.startswith(".prepare-") for item in self.output.iterdir()))

    def test_publishes_only_version_namespace_and_commits_manifest_last(self):
        manifest = self.prepare()
        uploaded = {}
        events = []

        def upload(arguments, **kwargs):
            self.assertTrue(arguments[-1].startswith(regions.MC_TARGET + "/"))
            name = arguments[-1].split("/")[-1]
            uploaded[name] = Path(arguments[-2]).read_bytes()
            events.append(("upload", name))
            return subprocess.CompletedProcess(arguments, 0)

        def read(url, maximum):
            self.assertTrue(url.startswith(regions.DOWNLOAD_BASE + "/"))
            name = url.split("?")[0].split("/")[-1]
            events.append(("read", name))
            return uploaded[name]

        with patch.object(regions.common.subprocess, "run", side_effect=upload), \
                patch.object(regions.common, "download_bytes", side_effect=read):
            regions.publish(self.output, manifest)
        names = [item["file"] for item in manifest["files"]]
        self.assertEqual(events, [("upload", names[0]), ("read", names[0]),
                                  ("upload", names[1]), ("read", names[1]),
                                  ("upload", "current.json"), ("read", "current.json")])
        self.assertEqual(json.loads(uploaded["current.json"]), manifest)

    def test_bad_cdn_never_publishes_manifest(self):
        manifest = self.prepare()
        uploads = []
        with patch.object(regions.common.subprocess, "run",
                          side_effect=lambda arguments, **kwargs: uploads.append(arguments[-1])), \
                patch.object(regions.common, "download_bytes", return_value=b"corrupt"):
            with self.assertRaises(ValueError):
                regions.publish(self.output, manifest)
        self.assertFalse(any(item.endswith("/current.json") for item in uploads))


if __name__ == "__main__":
    unittest.main()
