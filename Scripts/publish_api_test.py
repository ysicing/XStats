#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

import json
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import publish_api


class PublishAPITest(unittest.TestCase):
    def test_sends_manifest_with_bearer_token(self) -> None:
        received = {}

        class Handler(BaseHTTPRequestHandler):
            def do_PUT(self) -> None:
                received["path"] = self.path
                received["authorization"] = self.headers.get("Authorization")
                received["content_type"] = self.headers.get("Content-Type")
                received["body"] = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
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
                publish_api.publish(path, f"http://127.0.0.1:{server.server_port}/api/v1/releases/current", "release-secret")
        finally:
            server.shutdown()
            thread.join()
            server.server_close()

        self.assertEqual(received["path"], "/api/v1/releases/current")
        self.assertEqual(received["authorization"], "Bearer release-secret")
        self.assertEqual(received["content_type"], "application/json")
        self.assertEqual(received["body"], {"version": "2026.09.21.03"})


if __name__ == "__main__":
    unittest.main()
