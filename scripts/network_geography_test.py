#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""转换和发布边界回归；网络与对象存储仅在外部 I/O 边界替身。"""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest
from unittest.mock import patch

from build_network_geography import convert_country_csv
import sync_network_geography as sync


CSV = b"1.0.0.0,1.0.0.1,AU\n1.0.0.2,1.0.0.3,AU\n::1,::2,US\n"


class ConversionTests(unittest.TestCase):
    def test_merges_adjacent_country_and_encodes_ipv6_big_endian(self):
        files = convert_country_csv(CSV)
        self.assertEqual(files[4], bytes.fromhex("0100000001000003") + b"AU")
        self.assertEqual(files[6], bytes.fromhex("00" * 15 + "01" + "00" * 15 + "02") + b"US")

    def test_rejects_invalid_reversed_overlap_unsorted_and_mixed_family(self):
        invalid = [
            b"bad,1.0.0.1,AU\n", b"1.0.0.2,1.0.0.1,AU\n",
            b"1.0.0.0,::1,AU\n", b"1.0.0.0,1.0.0.1,au\n",
            b"1.0.0.0,1.0.0.1,A1\n", b"1.0.0.0,1.0.0.1,AUS\n",
            b"1.0.0.0,1.0.0.1,AU,extra\n",
            b"1.0.0.0,1.0.0.2,AU\n1.0.0.2,1.0.0.3,AU\n",
            b"::2,::3,AU\n::1,::1,AU\n", b"1.0.0.0,1.0.0.1,AU\n",
        ]
        for data in invalid:
            with self.subTest(data=data), self.assertRaises(ValueError):
                convert_country_csv(data)

    def test_binary_size_limit_applies_before_next_record(self):
        with self.assertRaises(ValueError):
            convert_country_csv(CSV, max_bytes=9)


class InputTests(unittest.TestCase):
    def test_gzip_and_decompressed_limits_are_independent(self):
        payload = gzip.compress(b"x" * 1024)
        with patch.object(sync, "MAX_SOURCE_BYTES", len(payload) - 1), self.assertRaises(ValueError):
            sync.inflate_source(payload)
        with patch.object(sync, "MAX_CSV_BYTES", 1023), self.assertRaises(ValueError):
            sync.inflate_source(payload)
        with patch.object(sync, "MAX_CSV_BYTES", 1024):
            self.assertEqual(sync.inflate_source(payload), b"x" * 1024)
        with self.assertRaises((ValueError, OSError, EOFError)):
            sync.inflate_source(payload[:-5])

    def test_http_read_does_not_accept_over_limit_response(self):
        with patch.object(sync.urllib.request, "urlopen", return_value=io.BytesIO(b"12345")):
            with self.assertRaises(ValueError):
                sync.download_bytes("https://example.test/file", 4)


class PublishingTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.output = Path(self.work.name)
        self.objects = {}
        self.events = []

    def run_mc(self, arguments, **kwargs):
        self.assertEqual(arguments[:3], ["mc", "cp", "--quiet"])
        cache = arguments[arguments.index("--attr") + 1]
        name = arguments[-1].split("/")[-1]
        expected_cache = "max-age=300" if name == "current.json" else "public,max-age=31536000,immutable"
        self.assertIn("Cache-Control=" + expected_cache, cache)
        self.objects[name] = Path(arguments[-2]).read_bytes()
        self.events.append(("upload", name))
        return subprocess.CompletedProcess(arguments, 0)

    def read_cdn(self, url, limit):
        name = url.split("?")[0].split("/")[-1]
        self.events.append(("verify", name))
        return self.objects[name]

    def prepare(self):
        # 测试发布交易的压缩边界使用固定内容；原生 LZFSE 单独实测。
        with patch.object(sync, "download_bytes", return_value=gzip.compress(CSV)), \
                patch.object(sync, "compress_lzfse", side_effect=lambda raw, compressed: compressed.write_bytes(b"lzfse" + raw.read_bytes())):
            return sync.prepare(self.output, "https://download.db-ip.com/free/dbip-country-lite-2026-10.csv.gz")

    def test_manifest_published_after_both_verified_immutable_objects(self):
        manifest = self.prepare()
        with patch.object(sync.subprocess, "run", side_effect=self.run_mc), \
                patch.object(sync, "download_bytes", side_effect=self.read_cdn):
            sync.publish(self.output, manifest)
        names = [item["file"] for item in manifest["files"]]
        self.assertEqual(self.events, [("upload", names[0]), ("verify", names[0]),
                                      ("upload", names[1]), ("verify", names[1]),
                                      ("upload", "current.json"), ("verify", "current.json")])
        online = json.loads(self.objects["current.json"])
        self.assertEqual(online, manifest)
        self.assertEqual(online["schemaVersion"], 1)
        self.assertEqual([file["name"] for file in online["files"]], ["country-ipv4.bin", "country-ipv6.bin"])
        self.assertEqual(online["files"][0]["sha256"], hashlib.sha256(bytes.fromhex("0100000001000003") + b"AU").hexdigest())
        self.assertEqual(online["files"][1]["bytes"], 34)

    def test_corrupt_cdn_or_upload_failure_never_updates_manifest(self):
        for failure in ("read", "upload"):
            with self.subTest(failure=failure):
                self.objects.clear()
                manifest = self.prepare()
                upload = self.run_mc if failure == "read" else subprocess.CalledProcessError(1, "mc")
                with patch.object(sync.subprocess, "run", side_effect=upload), \
                        patch.object(sync, "download_bytes", return_value=b"corrupt"):
                    with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                        sync.publish(self.output, manifest)
                self.assertNotIn("current.json", self.objects)

    def test_failed_source_does_not_replace_prepared_manifest(self):
        self.prepare()
        existing = (self.output / "current.json").read_bytes()
        with patch.object(sync, "download_bytes", return_value=gzip.compress(b"bad")):
            with self.assertRaises(ValueError):
                sync.prepare(self.output, "https://download.db-ip.com/free/dbip-country-lite-2026-10.csv.gz")
        self.assertEqual((self.output / "current.json").read_bytes(), existing)

    def test_prepare_fetches_fresh_source_on_every_invocation(self):
        with patch.object(sync, "download_bytes", return_value=gzip.compress(CSV)) as download, \
                patch.object(sync, "compress_lzfse", side_effect=lambda raw, compressed: compressed.write_bytes(b"lzfse" + raw.read_bytes())):
            sync.prepare(self.output, "https://example.test/source")
            sync.prepare(self.output, "https://example.test/source")
        self.assertEqual(download.call_count, 2)

    def test_compressor_output_changes_get_distinct_immutable_names(self):
        first = self.prepare()
        first_path = self.output / first["files"][0]["file"]
        first_bytes = first_path.read_bytes()
        with patch.object(sync, "download_bytes", return_value=gzip.compress(CSV)), \
                patch.object(sync, "compress_lzfse", side_effect=lambda raw, compressed: compressed.write_bytes(b"new-lzfse" + raw.read_bytes())):
            second = sync.prepare(self.output, "https://download.db-ip.com/free/dbip-country-lite-2026-10.csv.gz")
        self.assertEqual(first["files"][0]["sha256"], second["files"][0]["sha256"])
        self.assertNotEqual(first["files"][0]["file"], second["files"][0]["file"])
        self.assertEqual(first_path.read_bytes(), first_bytes)
        expected_sha = hashlib.sha256(b"new-lzfse" + bytes.fromhex("0100000001000003") + b"AU").hexdigest()
        self.assertEqual(second["files"][0]["file"], "country-ipv4-" + expected_sha + ".lzfse")

    def test_monthly_source_falls_back_to_previous_month_across_year(self):
        urls = sync.monthly_source_urls(sync.datetime(2027, 1, 1, tzinfo=sync.timezone.utc))
        self.assertEqual(urls, ["https://download.db-ip.com/free/dbip-country-lite-2027-01.csv.gz",
                                "https://download.db-ip.com/free/dbip-country-lite-2026-12.csv.gz"])

    def test_unpublished_month_uses_previous_and_other_errors_abort(self):
        urls = ["https://example.test/current", "https://example.test/previous"]
        def source(code):
            def download(url, limit):
                if url == urls[0]:
                    raise sync.urllib.error.HTTPError(url, code, "error", {}, None)
                return gzip.compress(CSV)
            return download
        lzfse = lambda raw, compressed: compressed.write_bytes(b"lzfse" + raw.read_bytes())
        with patch.object(sync, "download_bytes", side_effect=source(404)), \
                patch.object(sync, "compress_lzfse", side_effect=lzfse):
            self.assertEqual(sync.prepare_latest(self.output, urls)["sourceURL"], urls[1])
        with patch.object(sync, "download_bytes", side_effect=source(500)), \
                patch.object(sync, "compress_lzfse", side_effect=lzfse):
            with self.assertRaises(sync.urllib.error.HTTPError):
                sync.prepare_latest(self.output, urls)
        with patch.object(sync, "download_bytes", side_effect=source(404)):
            with self.assertRaises(sync.urllib.error.HTTPError):
                sync.prepare_latest(self.output, urls[:1])

    def test_system_lzfse_prepares_both_families_without_uploading(self):
        with patch.object(sync, "download_bytes", return_value=gzip.compress(CSV)):
            manifest = sync.prepare(self.output, "https://example.test/source")
        for item in manifest["files"]:
            compressed = (self.output / item["file"]).read_bytes()
            self.assertEqual(item["compressedSHA256"], hashlib.sha256(compressed).hexdigest())
            self.assertEqual(item["compressedBytes"], len(compressed))


class ReleaseHookTests(unittest.TestCase):
    def test_failed_geography_sync_blocks_application_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts, dist, tools = root / "scripts", root / "dist", root / "bin"
            for path in (scripts, dist, tools):
                path.mkdir()
            for name in ("publish_release.sh", "object_storage.sh"):
                (scripts / name).write_bytes((sync.ROOT / "scripts" / name).read_bytes())
            (root / "project.yml").write_text('MARKETING_VERSION: "9.9.9"\nCURRENT_PROJECT_VERSION: "1"\n')
            (root / "CHANGELOG.md").write_text("## 9.9.9 · fixture\n")
            for ext in ("dmg", "zip", "xml"):
                (dist / f"XStats-9.9.9-AppleSilicon.{ext}").write_bytes(b"app")
            digest = hashlib.sha256(b"app").hexdigest()
            (dist / "xstats.rb").write_text('version "9.9.9"\n' + digest)
            (dist / "appcast.json").write_text(json.dumps({"version": "9.9.9", "notes": ["fixture"],
                                                         "sha256": digest, "url": "XStats-9.9.9-AppleSilicon.zip"}))
            log = root / "events"
            commands = {
                "git": '#!/bin/sh\n[ "$1" != rev-parse ] || echo head\n',
                "xcrun": '#!/bin/sh\nexit 0\n',
                # 发布前只读查询源站：版本包尚不存在；其余操作都视为上传
                "mc": '#!/bin/sh\nif [ "$1" = stat ]; then\n'
                      '  echo \'{"status":"error","error":{"cause":{"message":"Object does not exist"}}}\'; exit 1\nfi\n'
                      'echo app-upload >> "$GEOGRAPHY_TEST_LOG"\nexit 73\n',
                "python3": '#!/bin/sh\nif [ "$1" = - ]; then exec "$GEOGRAPHY_TEST_PYTHON" "$@"; fi\n'
                           'case "$1" in *sync_network_geography.py) echo "geography $*" >> "$GEOGRAPHY_TEST_LOG"; exit 42;; esac\n'
                           'echo fixture\n',
            }
            for name, content in commands.items():
                path = tools / name
                path.write_text(content)
                path.chmod(0o755)
            result = subprocess.run(["bash", str(scripts / "publish_release.sh")], cwd=root, capture_output=True,
                                    env={**os.environ, "PATH": str(tools) + ":" + os.environ["PATH"],
                                         "GEOGRAPHY_TEST_LOG": str(log), "GEOGRAPHY_TEST_PYTHON": sys.executable})
            self.assertEqual(result.returncode, 42, result.stderr.decode())
            self.assertEqual(log.read_text(), "geography scripts/sync_network_geography.py --publish\n")


if __name__ == "__main__":
    unittest.main()
