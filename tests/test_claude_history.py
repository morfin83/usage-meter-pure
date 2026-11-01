"""Tests for the local Claude history used by the 24-hour curves.

Each run records one reading from fixture files, then prints the stored samples.
"""
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import test_claude_statusline as build  # reuse the compiled binary helper

NOW = 1_800_000_000


class ClaudeHistoryTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        self.support = self.dir / "support"
        self.plan = self.dir / "plan.json"
        self.projects = self.dir / "projects"
        self.projects.mkdir()
        self.env = {"USAGE_METER_TEST_SUPPORT": str(self.support), "PATH": "/usr/bin:/bin"}
        if build._build.get("binary") is None:
            build.setUpModule()

    def reading(self, observed_ms, five, week):
        self.plan.write_text(json.dumps({"version": 2, "samples": [
            {"t": observed_ms, "u": {"fh": five, "sd": week}}]}))

    def record(self, now):
        result = subprocess.run([build._build["binary"], "--claude-history", str(self.plan), str(self.projects), str(now)],
                                capture_output=True, text=True, env=self.env, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_same_observation_is_stored_once(self):
        self.reading((NOW - 600) * 1000, 10, 50)
        self.record(NOW)
        self.assertEqual(len(self.record(NOW + 60)), 1)

    def test_new_observation_adds_a_sample(self):
        self.reading((NOW - 600) * 1000, 10, 50)
        self.record(NOW)
        self.reading((NOW - 60) * 1000, 12, 51)
        samples = self.record(NOW + 60)
        self.assertEqual(len(samples), 2)
        self.assertEqual(samples[-1]["five"], 12)
        self.assertEqual(samples[-1]["week"], 51)

    def test_samples_older_than_seven_days_are_dropped(self):
        self.reading((NOW - 8 * 86400) * 1000, 5, 5)
        self.record(NOW - 8 * 86400)
        self.reading((NOW - 60) * 1000, 12, 51)
        samples = self.record(NOW)
        self.assertTrue(all(NOW - s["t"] <= 7 * 86400 for s in samples))
        self.assertEqual(len(samples), 1)

    def test_no_plan_source_stores_nothing(self):
        self.assertEqual(self.record(NOW), [])


if __name__ == "__main__":
    unittest.main()
