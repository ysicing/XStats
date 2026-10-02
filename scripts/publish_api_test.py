#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

import contextlib
import io
import json
import tempfile
import threading
import unittest
import urllib.error
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import appcast
import publish_api


class PublishAPITest(unittest.TestCase):
    def test_defaults_to_all_regional_endpoints(self) -> None:
        self.assertEqual(publish_api.configured_endpoints({}), [
            "https://apps.12306.work/api/v1/apps/xstats/releases/current",
            "https://apps-api.xiai.me/api/v1/apps/xstats/releases/current",
            "https://apps.china.12306.work/api/v1/apps/xstats/releases/current",
        ])

    def test_sparkle_feed_uses_fixed_xstats_path(self) -> None:
        endpoint = "https://example.test/api/v1/apps/xstats/releases/current?ignored=1#fragment"
        self.assertEqual(publish_api.sparkle_feed_url(endpoint, "current_version=release-probe"),
                         "https://example.test/api/v1/apps/xstats/update/appcast.xml?current_version=release-probe")

    def test_sparkle_feed_rejects_unrecognized_release_paths(self) -> None:
        for path in ("/releases/current", "/api/v1/releases/current",
                     "/api/v1/apps/another-app/releases/current", "/proxy/api/v1/apps/xstats/releases/current",
                     "/api/v1/apps/releases/current",
                     "/api/v1/apps/xstats/releases/current/", "/api/v1/apps/xstats/update/check",
                     "/api/v1/apps/UPPER/releases/current", "/api/v1/apps/xstats/other/releases/current"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                publish_api.sparkle_feed_url(f"https://example.test{path}")

    def test_sparkle_gate_checks_all_endpoints_without_installation_data(self) -> None:
        errors = [urllib.error.HTTPError(url, 400, "invalid request", {"Cache-Control": "no-store"}, io.BytesIO(b""))
                  for url in publish_api.DEFAULT_ENDPOINTS]
        with patch("publish_api.urllib.request.urlopen", side_effect=errors) as send:
            publish_api.check_sparkle_endpoints(list(publish_api.DEFAULT_ENDPOINTS))
        urls = [call.args[0].full_url for call in send.call_args_list]
        self.assertEqual(urls, [
            "https://apps.12306.work/api/v1/apps/xstats/update/appcast.xml",
            "https://apps-api.xiai.me/api/v1/apps/xstats/update/appcast.xml",
            "https://apps.china.12306.work/api/v1/apps/xstats/update/appcast.xml",
        ])
        for call in send.call_args_list:
            self.assertNotIn("installation_id", call.args[0].full_url)
            self.assertIsNone(call.args[0].data)
            self.assertFalse(call.args[0].has_header("Authorization"))

    def test_sparkle_gate_accepts_no_store_merged_by_proxy(self) -> None:
        errors = [urllib.error.HTTPError(url, 400, "invalid request", {"Cache-Control": "private, No-Store"}, io.BytesIO(b""))
                  for url in publish_api.DEFAULT_ENDPOINTS]
        with patch("publish_api.urllib.request.urlopen", side_effect=errors):
            publish_api.check_sparkle_endpoints(list(publish_api.DEFAULT_ENDPOINTS))

    def test_verify_fetches_each_region_with_release_probe_and_compares_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "XStats-1.0.0-AppleSilicon.xml"
            feed.write_bytes(b"<rss>signed</rss>")
            served = [b"<rss>signed</rss>"] * 3
            responses = [contextlib.nullcontext(type("Response", (), {"status": 200, "read": lambda self, limit, body=body: body})())
                         for body in served]
            with patch("publish_api.urllib.request.urlopen", side_effect=responses) as send, \
                    contextlib.redirect_stdout(io.StringIO()):
                publish_api.verify_sparkle_feeds(feed, list(publish_api.DEFAULT_ENDPOINTS))
            urls = [call.args[0].full_url for call in send.call_args_list]
            self.assertEqual(urls, [
                "https://apps.12306.work/api/v1/apps/xstats/update/appcast.xml?current_version=release-probe&installation_id=" + "0" * 64,
                "https://apps-api.xiai.me/api/v1/apps/xstats/update/appcast.xml?current_version=release-probe&installation_id=" + "0" * 64,
                "https://apps.china.12306.work/api/v1/apps/xstats/update/appcast.xml?current_version=release-probe&installation_id=" + "0" * 64,
            ])
            for call in send.call_args_list:
                self.assertFalse(call.args[0].has_header("Authorization"))

    def test_verify_rejects_region_serving_different_feed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "XStats-1.0.0-AppleSilicon.xml"
            feed.write_bytes(b"<rss>signed</rss>")
            stale = type("Response", (), {"status": 200, "read": lambda self, limit: b"<rss>previous</rss>"})()
            ok = type("Response", (), {"status": 200, "read": lambda self, limit: b"<rss>signed</rss>"})()
            with patch("publish_api.urllib.request.urlopen",
                       side_effect=[contextlib.nullcontext(ok), contextlib.nullcontext(ok), contextlib.nullcontext(stale)]), \
                    contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, "apps.china.12306.work"):
                    publish_api.verify_sparkle_feeds(feed, list(publish_api.DEFAULT_ENDPOINTS))

    def test_sparkle_gate_rejects_old_server_or_cached_validation(self) -> None:
        for status, headers in ((404, {}), (400, {}), (503, {"Cache-Control": "no-store"})):
            error = urllib.error.HTTPError("https://example.test", status, "error", headers, io.BytesIO(b""))
            with patch("publish_api.urllib.request.urlopen", side_effect=error):
                with self.assertRaises(RuntimeError):
                    publish_api.check_sparkle_endpoints(list(publish_api.DEFAULT_ENDPOINTS))

    def test_publish_validates_all_paths_before_sending_any_request(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.json"
            path.write_text(json.dumps({"version": "1.0.0"}), encoding="utf-8")
            valid = "https://example.test/api/v1/apps/xstats/releases/current"
            for invalid in ("/api/v1/releases/current", "/api/v1/apps/another-app/releases/current",
                            "/proxy/api/v1/apps/xstats/releases/current"):
                with self.subTest(path=invalid), patch("publish_api.urllib.request.urlopen") as send, \
                        contextlib.redirect_stdout(io.StringIO()):
                    send.return_value.__enter__.return_value.status = 204
                    with self.assertRaises(ValueError):
                        publish_api.publish(path, [valid, f"https://example.test{invalid}"], "release-secret")
                    send.assert_not_called()

    def test_sends_manifest_with_bearer_token(self) -> None:
        received = []

        class Handler(BaseHTTPRequestHandler):
            def do_PUT(self) -> None:
                received.append({
                    "path": self.path,
                    "authorization": self.headers.get("Authorization"),
                    "content_type": self.headers.get("Content-Type"),
                    "body": json.loads(self.rfile.read(int(self.headers["Content-Length"]))),
                })
                self.send_response(204)
                self.end_headers()

            def log_message(self, *_: object) -> None:
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                archive = Path(directory) / "XStats-0.14.1-AppleSilicon.zip"
                archive.write_bytes(b"legacy and Sparkle share the same archive")
                dmg = Path(directory) / "XStats-0.14.1-AppleSilicon.dmg"
                # JSON 顶层字段继续供旧客户端解码；Sparkle 元数据留在独立的 XML。
                manifest = {
                    "version": "0.14.1", "build": "126", "date": "2026-09-30",
                    "minimumSystem": "14.0",
                    **appcast.asset("https://example.test/download", str(archive), str(dmg)),
                    "notes": ["支持 Sparkle 更新"],
                    "changelog": "https://github.com/ysicing/xstats/blob/main/CHANGELOG.md",
                }
                path = Path(directory) / "appcast.json"
                path.write_text(json.dumps(manifest), encoding="utf-8")
                endpoints = [f"http://{host}:{server.server_port}/api/v1/apps/xstats/releases/current"
                             for host in ("127.0.0.1", "localhost", "127.0.0.1")]
                with contextlib.redirect_stdout(io.StringIO()):
                    publish_api.publish(path, endpoints, "release-secret")
        finally:
            server.shutdown()
            thread.join()
            server.server_close()

        self.assertEqual([item["path"] for item in received], ["/api/v1/apps/xstats/releases/current"] * 3)
        for item in received:
            self.assertEqual(item["authorization"], "Bearer release-secret")
            self.assertEqual(item["content_type"], "application/json")
            self.assertEqual(item["body"], manifest)
            self.assertTrue(item["body"]["url"].endswith("-AppleSilicon.zip"))
            self.assertEqual(len(item["body"]["sha256"]), 64)
            self.assertIsInstance(item["body"]["size"], int)
            self.assertIsInstance(item["body"]["build"], str)


if __name__ == "__main__":
    unittest.main()
