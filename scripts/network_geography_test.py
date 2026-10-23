#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""转换和发布边界回归；网络与对象存储仅在外部 I/O 边界替身。"""
import gzip
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
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


class HeadOnlyResponse(io.BytesIO):
    """HEAD 回归禁止读取正文，并沿用真实上下文关闭行为。"""
    def __init__(self, headers, status=200):
        super().__init__()
        self.headers = headers
        self.status = status

    def read(self, *args, **kwargs):
        raise AssertionError("复用线上地图库时不应读取压缩文件正文")


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
        if name not in self.objects:
            raise sync.urllib.error.HTTPError(url, 404, "missing", {}, None)
        return self.objects[name]

    def head_cdn(self, request, timeout):
        self.assertEqual(request.get_method(), "HEAD")
        self.assertEqual(timeout, 30)
        name = request.full_url.split("/")[-1]
        self.events.append(("head", name))
        if name not in self.objects:
            error = sync.urllib.error.HTTPError(request.full_url, 404, "missing", {}, None)
            self.addCleanup(error.close)
            raise error
        return HeadOnlyResponse({"Content-Length": str(len(self.objects[name]))})

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

    def seed_publication(self, generated_at):
        manifest = self.prepare()
        manifest["generatedAt"] = generated_at
        self.objects = {item["file"]: (self.output / item["file"]).read_bytes() for item in manifest["files"]}
        self.objects["current.json"] = json.dumps(manifest).encode()
        return manifest

    def run_release_sync(self, now, age_limit=True):
        # 保留真实 CLI、转换及发布控制流，仅替换外部下载、压缩和对象存储。
        def download(url, limit):
            if url == "https://example.test/source":
                self.events.append(("source", url))
                return gzip.compress(CSV)
            return self.read_cdn(url, limit)

        arguments = ["sync_network_geography.py", "--publish", "--output", str(self.output),
                     "--source-url", "https://example.test/source"]
        if age_limit:
            arguments += ["--max-age-days", "7"]
        with patch.object(sys, "argv", arguments), patch.object(sync, "datetime", wraps=datetime) as clock, \
                patch.object(sync, "download_bytes", side_effect=download), \
                patch.object(sync.urllib.request, "urlopen", side_effect=self.head_cdn), \
                patch.object(sync, "compress_lzfse", side_effect=lambda raw, compressed: compressed.write_bytes(b"lzfse" + raw.read_bytes())), \
                patch.object(sync.subprocess, "run", side_effect=self.run_mc), redirect_stdout(io.StringIO()):
            clock.now.return_value = now
            sync.main()

    def test_release_reuses_online_data_through_seven_days_without_local_cache(self):
        now = datetime(2026, 10, 14, 12, tzinfo=timezone.utc)
        for age in (timedelta(days=1), timedelta(days=7)):
            with self.subTest(age=age):
                manifest = self.seed_publication((now - age).isoformat())
                for path in self.output.iterdir():
                    path.unlink()
                self.events.clear()
                self.run_release_sync(now)
                self.assertEqual(self.events, [("verify", "current.json")] +
                                 [("head", item["file"]) for item in manifest["files"]])
                self.assertFalse((self.output / "current.json").exists())

    def test_release_refreshes_stale_online_data_even_with_fresh_local_manifest(self):
        now = datetime(2026, 10, 14, 12, tzinfo=timezone.utc)
        self.seed_publication((now - timedelta(days=7, seconds=1)).isoformat())
        self.events.clear()
        self.run_release_sync(now)
        self.assertIn(("source", "https://example.test/source"), self.events)
        self.assertFalse(any(event[0] == "head" for event in self.events))
        self.assertEqual(self.events[-2:], [("upload", "current.json"), ("verify", "current.json")])
        self.assertEqual(json.loads(self.objects["current.json"])["generatedAt"], "2026-10-14T12:00:00Z")

    def test_missing_or_invalid_publication_refreshes_instead_of_skipping(self):
        now = datetime(2026, 10, 14, 12, tzinfo=timezone.utc)
        for timestamp in (None, "invalid", "2026-10-14T12:00:00", "2026-10-15T12:00:00Z"):
            with self.subTest(timestamp=timestamp):
                self.seed_publication(timestamp)
                if timestamp is None:
                    self.objects.clear()
                self.events.clear()
                self.run_release_sync(now)
                self.assertIn(("upload", "current.json"), self.events)

    def test_recent_publication_with_wrong_asset_size_refreshes_and_verifies_uploads(self):
        now = datetime(2026, 10, 14, 12, tzinfo=timezone.utc)
        manifest = self.seed_publication("2026-10-14T12:00:00Z")
        damaged = manifest["files"][0]["file"]
        self.objects[damaged] = b"corrupt"
        self.events.clear()
        self.run_release_sync(now)
        self.assertEqual(self.events[:3], [("verify", "current.json"), ("head", damaged),
                                          ("source", "https://example.test/source")])
        names = [item["file"] for item in manifest["files"]]
        self.assertEqual(self.events[3:], [("upload", names[0]), ("verify", names[0]),
                                          ("upload", names[1]), ("verify", names[1]),
                                          ("upload", "current.json"), ("verify", "current.json")])

    def test_recent_publication_rejects_invalid_head_headers_or_status_without_body_read(self):
        now = datetime(2026, 10, 14, 12, tzinfo=timezone.utc)
        cases = [({}, 200), ({"Content-Length": "-1"}, 200),
                 ({"Content-Length": "invalid"}, 200), ({"Content-Length": "1.5"}, 200),
                 ({"Content-Length": "15"}, 206)]
        for headers, status in cases:
            with self.subTest(headers=headers, status=status):
                self.seed_publication("2026-10-14T12:00:00Z")
                self.events.clear()
                response = HeadOnlyResponse(headers, status)
                with patch.object(self, "head_cdn", return_value=response), \
                        redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                    self.run_release_sync(now)
                self.assertEqual(error.exception.code, 1)
                self.assertTrue(response.closed)
                self.assertEqual(self.events, [("verify", "current.json")])

    def test_recent_publication_head_network_errors_do_not_download_or_publish(self):
        now = datetime(2026, 10, 14, 12, tzinfo=timezone.utc)
        failures = [sync.urllib.error.HTTPError("https://example.test/file", code, "error", {}, None)
                    for code in (403, 405, 500)]
        failures += [TimeoutError("timeout"), ConnectionResetError("reset")]
        for failure in failures:
            if isinstance(failure, sync.urllib.error.HTTPError):
                self.addCleanup(failure.close)
            with self.subTest(failure=failure):
                self.seed_publication("2026-10-14T12:00:00Z")
                self.events.clear()
                with patch.object(self, "head_cdn", side_effect=failure), \
                        redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                    self.run_release_sync(now)
                self.assertEqual(error.exception.code, 1)
                self.assertEqual(self.events, [("verify", "current.json")])

    def test_missing_online_asset_is_republished(self):
        now = datetime(2026, 10, 14, 12, tzinfo=timezone.utc)
        manifest = self.seed_publication("2026-10-14T12:00:00Z")
        missing = manifest["files"][1]["file"]
        del self.objects[missing]
        self.events.clear()
        self.run_release_sync(now)
        self.assertIn(("upload", missing), self.events)
        self.assertIn(("upload", "current.json"), self.events)

    def test_invalid_online_manifest_is_refreshed(self):
        now = datetime(2026, 10, 14, 12, tzinfo=timezone.utc)
        for overrides in ({"generatedAt": None}, {"files": []}, {"schemaVersion": 2}, {"version": ""}):
            with self.subTest(overrides=overrides):
                manifest = self.seed_publication("2026-10-14T12:00:00Z")
                manifest.update(overrides)
                self.objects["current.json"] = json.dumps(manifest).encode()
                self.events.clear()
                self.run_release_sync(now)
                self.assertIn(("upload", "current.json"), self.events)

    def test_publication_check_network_failure_does_not_publish(self):
        with patch.object(sync, "download_bytes", side_effect=sync.urllib.error.HTTPError(
                "https://example.test/current.json", 500, "server error", {}, None)):
            with self.assertRaises(sync.urllib.error.HTTPError):
                sync.published_data_is_recent(7, datetime(2026, 10, 14, tzinfo=timezone.utc))
        self.assertEqual(self.events, [])

    def test_manual_publish_without_age_limit_always_refreshes(self):
        now = datetime(2026, 10, 14, 12, tzinfo=timezone.utc)
        self.seed_publication("2026-10-14T12:00:00Z")
        self.events.clear()
        self.run_release_sync(now, age_limit=False)
        self.assertEqual(self.events[0], ("source", "https://example.test/source"))
        self.assertIn(("upload", "current.json"), self.events)


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
            (dist / "appcast.json").write_text(json.dumps({"version": "9.9.9", "build": "1", "notes": ["fixture"],
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
            self.assertEqual(log.read_text(), "geography scripts/sync_network_geography.py --publish --max-age-days 7\n")


if __name__ == "__main__":
    unittest.main()
