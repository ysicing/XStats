#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

import contextlib
import io
import json
import re
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import perf


class PerformanceReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "docs").mkdir()
        (self.root / "Packages/XStatsKit").mkdir(parents=True)
        (self.root / perf.REPORT).write_text("previous successful report\n")

    @staticmethod
    def capture(args, **kwargs):
        if args == ("sysctl", "-n", "hw.memsize"):
            return str(16 * 1024 ** 3)
        if args[:3] == ("git", "status", "--porcelain"):
            return ""
        return "fixture"

    @staticmethod
    def write_reports(env):
        for name, _, variable, count in perf.GROUPS:
            values = {"cpuSeconds": 0.125, "snapshots": 0}
            if name == "monitoring":
                data = [{"name": f"phase-{i}", **values, "cpuSamples": 0} for i in range(count)]
            else:
                if name == "battery":
                    values.update(wallSeconds=3, batterySamples=0, powerSamples=0, appEnergySamples=0)
                data = {f"phase-{i}": values for i in range(count)}
            Path(env[variable]).write_text(json.dumps(data))

    def run_fixture(self, run):
        with patch.object(perf.subprocess, "check_output", side_effect=self.capture), \
             patch.object(perf.subprocess, "run", side_effect=run), \
             contextlib.redirect_stdout(io.StringIO()):
            perf.run_performance(self.root)

    def test_success_then_missing_report_does_not_reuse_previous_run(self):
        commands = []

        def run(command, **kwargs):
            commands.append(command)
            if command[1] == "test":
                self.write_reports(kwargs["env"])

        self.run_fixture(run)
        self.assertEqual([command[1] for command in commands], ["build", "test"])
        self.assertIn("--no-parallel", commands[1])
        self.assertIn("release", commands[0])
        pattern = commands[1][commands[1].index("--filter") + 1]
        self.assertIsNotNone(re.search(pattern,
            "XStatsUITests.MonitoringResourceTests/batteryPowerSamplingStopsAfterRepeatedPageCloses()"))
        summary = (self.root / perf.REPORT).read_text()
        self.assertIn("0.125000", summary)
        self.assertIn("三组测试通过", summary)
        self.assertNotIn(str(self.root), summary)
        with self.assertRaises(FileNotFoundError):
            self.run_fixture(lambda *args, **kwargs: None)
        self.assertEqual((self.root / perf.REPORT).read_text(), summary)
        statuses = sorted(json.loads(path.read_text())["status"]
                          for path in self.root.glob("build/performance/*/environment.json"))
        self.assertEqual(statuses, ["failed", "passed"])

    def test_failed_test_keeps_previous_summary_even_if_json_was_written(self):
        def run(command, **kwargs):
            if command[1] == "test":
                self.write_reports(kwargs["env"])
                raise subprocess.CalledProcessError(1, command)

        with self.assertRaises(subprocess.CalledProcessError):
            self.run_fixture(run)
        self.assertEqual((self.root / perf.REPORT).read_text(), "previous successful report\n")

    def test_invalid_metric_cannot_be_published_as_success(self):
        def run(command, **kwargs):
            if command[1] == "test":
                self.write_reports(kwargs["env"])
                path = Path(kwargs["env"][perf.GROUPS[0][2]])
                data = json.loads(path.read_text())
                data[0]["cpuSeconds"] = float("nan")
                path.write_text(json.dumps(data))

        with self.assertRaises(ValueError):
            self.run_fixture(run)
        self.assertEqual((self.root / perf.REPORT).read_text(), "previous successful report\n")


if __name__ == "__main__":
    unittest.main()
