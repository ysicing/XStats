#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

import contextlib
import io
import json
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import publish_api


class PublishAPITest(unittest.TestCase):
    def test_defaults_to_both_regional_endpoints(self) -> None:
        self.assertEqual(publish_api.configured_endpoints({}), [
            "https://xstats-apps.12306.work/api/v1/releases/current",
            "https://x-stats.china.12306.work/api/v1/releases/current",
        ])

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
                path = Path(directory) / "appcast.json"
                path.write_text('{"version":"2026.09.21.03"}', encoding="utf-8")
                base = f"http://127.0.0.1:{server.server_port}"
                with contextlib.redirect_stdout(io.StringIO()):
                    publish_api.publish(path, [f"{base}/global", f"{base}/china"], "release-secret")
        finally:
            server.shutdown()
            thread.join()
            server.server_close()

        self.assertEqual([item["path"] for item in received], ["/global", "/china"])
        for item in received:
            self.assertEqual(item["authorization"], "Bearer release-secret")
            self.assertEqual(item["content_type"], "application/json")
            self.assertEqual(item["body"], {"version": "2026.09.21.03"})


if __name__ == "__main__":
    unittest.main()
