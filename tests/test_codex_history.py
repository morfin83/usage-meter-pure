"""Tests for the Codex history behind the Codex curves and gauges.

Fixture payloads use the same shape as the account/rateLimits/read result.
"""
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import test_claude_statusline as build

NOW = 1_800_000_000


class CodexHistoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build.setUpModule()

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        self.support = self.dir / "support"
        self.env = {"USAGE_METER_TEST_SUPPORT": str(self.support), "PATH": "/usr/bin:/bin"}

    def record(self, used5, used_week, now):
        payload = {"rateLimitsByLimitId": {"codex": {
            "primary": {"usedPercent": used5, "windowDurationMins": 300, "resetsAt": now + 3600},
            "secondary": {"usedPercent": used_week, "windowDurationMins": 10080, "resetsAt": now + 86400}}}}
        path = self.dir / f"payload-{now}-{used5}.json"
        path.write_text(json.dumps(payload))
        result = subprocess.run([build._build["binary"], "--codex-history", str(path), str(now)],
                                capture_output=True, text=True, env=self.env, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_used_percent_is_stored_for_both_windows(self):
        samples = self.record(24, 80, NOW)
        self.assertEqual(samples[-1]["five"], 24)
        self.assertEqual(samples[-1]["week"], 80)

    def test_unchanged_values_within_five_minutes_are_not_repeated(self):
        self.record(24, 80, NOW)
        self.assertEqual(len(self.record(24, 80, NOW + 120)), 1)

    def test_a_changed_value_adds_a_sample(self):
        self.record(24, 80, NOW)
        samples = self.record(30, 80, NOW + 120)
        self.assertEqual(len(samples), 2)
        self.assertEqual(samples[-1]["five"], 30)


if __name__ == "__main__":
    unittest.main()
