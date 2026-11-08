"""Tests for the Claude connection check that decides which repair the status line offers."""
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import test_claude_statusline as build

OUR = "'/Applications/Usage Meter Pure.app/Contents/MacOS/UsageMeter' --statusline"


class ClaudeHealthTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build.setUpModule()

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        self.support = self.dir / "support"
        self.claude = self.dir / ".claude"
        self.env = dict(os.environ, USAGE_METER_TEST_SUPPORT=str(self.support), USAGE_METER_TEST_CLAUDE=str(self.claude))

    def health(self, now=None):
        now = now or time.time()
        result = subprocess.run([build._build["binary"], "--claude-health", str(self.dir / "plan.json"), str(self.dir / "p"), str(now)],
                                capture_output=True, text=True, env=self.env, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_no_claude_folder_means_not_installed(self):
        self.assertEqual(self.health(), "notInstalled")

    def test_folder_without_settings_means_not_connected(self):
        self.claude.mkdir()
        self.assertEqual(self.health(), "notConnected")

    def test_broken_settings_are_never_touched(self):
        self.claude.mkdir()
        (self.claude / "settings.json").write_text("{ broken")
        self.assertEqual(self.health(), "settingsUnreadable")

    def test_connected_but_no_recent_reading(self):
        self.claude.mkdir()
        (self.claude / "settings.json").write_text(json.dumps({"statusLine": {"type": "command", "command": OUR}}))
        self.assertEqual(self.health(), "noRecentData")

    def test_fresh_status_line_reading_is_ok(self):
        self.claude.mkdir()
        (self.claude / "settings.json").write_text(json.dumps({"statusLine": {"type": "command", "command": OUR}}))
        self.support.mkdir()
        now = time.time()
        (self.support / "claude-statusline.json").write_text(json.dumps(
            {"observedAt": now, "fiveHour": {"usedPercent": 10, "resetsAt": now + 3600}}))
        self.assertEqual(self.health(now), "ok")


if __name__ == "__main__":
    unittest.main()
