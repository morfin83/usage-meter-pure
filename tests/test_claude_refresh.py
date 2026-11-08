"""Tests for the background Claude refresh (`--claude-refresh` hook) using a stand-in command, so no model request is made."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import test_claude_statusline as build

STANDIN = """#!/bin/sh
dir="${USAGE_METER_TEST_SUPPORT:?}"
mkdir -p "$dir"
now=$(date +%s)
printf '{"fiveHour":{"usedPercent":9},"observedAt":%s.0,"sevenDay":{"usedPercent":67}}' "$now" > "$dir/claude-statusline.json"
sleep 30
"""


class ClaudeRefreshTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build.setUpModule()

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        self.support = self.dir / "support"
        self.standin = self.dir / "claude"
        self.standin.write_text(STANDIN)
        self.standin.chmod(0o755)
        self.env = dict(os.environ, USAGE_METER_TEST_SUPPORT=str(self.support),
                        USAGE_METER_TEST_CLAUDE_BIN=str(self.standin))

    def test_fresh_status_line_reading_counts_as_success(self):
        result = subprocess.run([build._build["binary"], "--claude-refresh"], capture_output=True, text=True,
                                env=self.env, timeout=120)
        self.assertEqual(result.stdout.strip(), "ok")
        self.assertIn("status line updated", (self.support / "claude-refresh.log").read_text())

    def test_no_reading_within_the_timeout_is_a_failure(self):
        self.standin.write_text("#!/bin/sh\nsleep 30\n")
        result = subprocess.run([build._build["binary"], "--claude-refresh"], capture_output=True, text=True,
                                env=self.env, timeout=200)
        self.assertEqual(result.stdout.strip(), "failed")


if __name__ == "__main__":
    unittest.main()
