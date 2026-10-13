#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Exercise the signing policy without contacting Apple's timestamp service."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CodesignRetryTests(unittest.TestCase):
    def run_signing(self, failures, message, timestamp="--timestamp"):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            for name, source in {
                "codesign": '''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ["SIGN_TEST_LOG"])
rows = json.loads(p.read_text()) if p.exists() else []
rows.append(sys.argv[1:])
p.write_text(json.dumps(rows))
if len(rows) <= int(os.environ["SIGN_TEST_FAILURES"]):
    print(os.environ["SIGN_TEST_MESSAGE"], file=sys.stderr)
    sys.exit(34)
print("signed", file=sys.stderr)
''',
                "sleep": '''#!/bin/bash
printf '%s\n' "$1" >> "$SIGN_TEST_SLEEPS"
''',
            }.items():
                path = work / name
                path.write_text(source)
                path.chmod(0o755)
            log, sleeps = work / "calls.json", work / "sleeps"
            env = dict(os.environ, PATH=f"{work}:{os.environ['PATH']}",
                       SIGN_TEST_LOG=str(log), SIGN_TEST_SLEEPS=str(sleeps),
                       SIGN_TEST_FAILURES=str(failures), SIGN_TEST_MESSAGE=message)
            args = ["--force", "--sign", "Developer ID", timestamp, "--options", "runtime",
                    "--preserve-metadata=identifier,entitlements,flags", "App with spaces.app"]
            result = subprocess.run(
                ["bash", "-eu", "-c", 'source "$1"; shift; codesign_with_timestamp_retry "$@"',
                 "test", str(ROOT / "scripts/codesign_retry.sh"), *args],
                env=env, text=True, capture_output=True)
            return result, json.loads(log.read_text()) if log.exists() else [], \
                sleeps.read_text().splitlines() if sleeps.exists() else [], args

    def test_transient_error_recovers_without_changing_signing_arguments(self):
        result, calls, sleeps, args = self.run_signing(2, "app: The timestamp service is not available.")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [args, args, args])
        self.assertEqual(sleeps, ["2", "5"])
        self.assertIn("signed", result.stderr)

    def test_persistent_timestamp_error_stops_after_three_total_attempts(self):
        result, calls, sleeps, args = self.run_signing(10, "The timestamp service is not available.")
        self.assertEqual(result.returncode, 34, result.stderr)
        self.assertEqual(calls, [args, args, args])
        self.assertEqual(sleeps, ["2", "5"])

    def test_other_signing_failure_is_not_retried(self):
        for message in ["errSecInternalComponent", "User interaction is not allowed.",
                        "The specified item could not be found in the keychain."]:
            with self.subTest(message=message):
                result, calls, sleeps, args = self.run_signing(10, message)
                self.assertEqual(result.returncode, 34, result.stderr)
                self.assertEqual(calls, [args])
                self.assertEqual(sleeps, [])
                self.assertIn(message, result.stderr)

    def test_success_needs_no_retry(self):
        result, calls, sleeps, args = self.run_signing(0, "")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [args])
        self.assertEqual(sleeps, [])

    def test_disabled_timestamp_does_not_use_service_retry(self):
        result, calls, sleeps, args = self.run_signing(
            10, "The timestamp service is not available.", "--timestamp=none")
        self.assertEqual(result.returncode, 34, result.stderr)
        self.assertEqual(calls, [args])
        self.assertEqual(sleeps, [])


if __name__ == "__main__":
    unittest.main()
