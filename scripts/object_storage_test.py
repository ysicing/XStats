# SPDX-License-Identifier: AGPL-3.0-or-later
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest


@unittest.skipUnless(shutil.which("mc"), "需要本机 mc；所有请求仅发往回环 S3 夹具")
class ImmutableUploadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="xstats-immutable-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.payload = self.root / "payload"
        self.payload.write_bytes(b"release fixture")
        self.object = None
        self.competitor = None
        self.upload_error = None
        self.read_error = False
        self.put_headers = []
        self.object_reads = 0
        owner = self

        class S3Fixture(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, data=b""):
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("ETag", '"fixture"')
                self.send_header("Last-Modified", "Thu, 22 Oct 2026 12:00:00 GMT")
                self.end_headers()
                self.wfile.write(data)

            def fail(self, status, code):
                self.reply(status, f"<Error><Code>{code}</Code><Message>fixture-secret-must-not-leak</Message></Error>".encode())

            def do_HEAD(self):
                if owner.object is None:
                    self.reply(404)
                else:
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(owner.object)))
                    self.send_header("ETag", '"fixture"')
                    self.send_header("Last-Modified", "Thu, 22 Oct 2026 12:00:00 GMT")
                    self.end_headers()

            def do_GET(self):
                if "?" in self.path:
                    if "location=" in self.path:
                        self.reply(200, b'<LocationConstraint xmlns="http://s3.amazonaws.com/doc/2006-03-01/">us-east-1</LocationConstraint>')
                    else:
                        self.reply(200, b"<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>")
                else:
                    owner.object_reads += 1
                    if owner.read_error:
                        self.fail(403, "AccessDenied")
                    elif owner.object is None:
                        self.fail(404, "NoSuchKey")
                    else:
                        self.reply(200, owner.object)

            def do_PUT(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                if self.headers.get("X-Amz-Decoded-Content-Length") is not None:
                    decoded = bytearray()
                    while body:
                        header, body = body.split(b"\r\n", 1)
                        length = int(header.split(b";")[0], 16)
                        if length == 0:
                            break
                        decoded.extend(body[:length])
                        body = body[length + 2:]
                    body = bytes(decoded)
                owner.put_headers.append(self.headers.get("If-None-Match"))
                if owner.competitor is not None:
                    owner.object = owner.competitor
                if owner.upload_error:
                    self.fail(403, owner.upload_error)
                elif self.headers.get("If-None-Match") == "*" and owner.object is not None:
                    self.fail(412, "PreconditionFailed")
                else:
                    owner.object = body
                    self.reply(200)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), S3Fixture)
        self.addCleanup(self.server.server_close)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.shutdown)
        config = {"version": "10", "aliases": {"fixture": {
            "url": f"http://127.0.0.1:{self.server.server_port}",
            "accessKey": "fixture", "secretKey": "fixture-secret",
            "api": "S3v4", "path": "on",
        }}}
        (self.root / "config.json").write_text(json.dumps(config))

    def upload(self):
        result = subprocess.run(
            ["bash", "-c", 'set -euo pipefail; source "$1"; object_upload_immutable "$2" fixture/bucket/object',
             "fixture", str(Path(__file__).with_name("object_storage.sh")), str(self.payload)],
            env={**os.environ, "MC_CONFIG_DIR": str(self.root)},
            capture_output=True, text=True, timeout=20,
        )
        self.assertNotIn("fixture-secret-must-not-leak", result.stdout + result.stderr)
        return result

    def test_real_mc_sends_conditional_single_put(self):
        result = self.upload()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.put_headers, ["*"])
        self.assertEqual(self.object, b"release fixture")

    def test_same_content_concurrent_create_succeeds_without_overwrite(self):
        self.competitor = b"release fixture"
        result = self.upload()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.put_headers, ["*"])
        self.assertEqual(self.object, b"release fixture")
        self.assertEqual(self.object_reads, 1)

    def test_different_content_concurrent_create_fails_without_overwrite(self):
        self.competitor = b"first publisher"
        result = self.upload()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.object, b"first publisher")

    def test_permission_or_unknown_errors_fail_closed_even_when_object_matches(self):
        for code in ("AccessDenied", "ConditionalRequestConflict"):
            with self.subTest(code=code):
                self.object = None
                self.competitor = b"release fixture"
                self.upload_error = code
                result = self.upload()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.object_reads, 0)

    def test_failed_conflict_readback_does_not_allow_continuation(self):
        self.competitor = b"release fixture"
        self.read_error = True
        self.assertNotEqual(self.upload().returncode, 0)


if __name__ == "__main__":
    unittest.main()
