"""Tests for the Codex token totals read from local session logs (`--codex-tokens` hook)."""
import datetime as dt
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import test_claude_statusline as build

NOW = 1_800_000_000


def iso(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def event(epoch, tokens):
    return json.dumps({"timestamp": iso(epoch), "type": "event_msg", "payload": {
        "type": "token_count", "info": {"last_token_usage": {"total_tokens": tokens}}}})


class CodexTokenTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build.setUpModule()

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / "sessions"
        (self.root / "2026/11/07").mkdir(parents=True)
        self.env = {"PATH": "/usr/bin:/bin"}

    def write(self, name, lines, age_days=0):
        path = self.root / "2026/11/07" / name
        path.write_text("\n".join(lines) + "\n")
        mtime = NOW - age_days * 86400
        os.utime(path, (mtime, mtime))

    def totals(self):
        result = subprocess.run([build._build["binary"], "--codex-tokens", str(self.root), str(NOW)],
                                capture_output=True, text=True, env=self.env, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_five_hour_and_week_windows(self):
        self.write("a.jsonl", [event(NOW - 3600, 500), event(NOW - 3 * 86400, 300)])
        self.assertEqual(self.totals(), {"fiveHour": 500, "week": 800})

    def test_same_event_in_two_files_is_counted_once(self):
        self.write("a.jsonl", [event(NOW - 3600, 500)])
        self.write("b.jsonl", [event(NOW - 3600, 500)])
        self.assertEqual(self.totals(), {"fiveHour": 500, "week": 500})

    def test_files_older_than_a_week_are_skipped(self):
        self.write("old.jsonl", [event(NOW - 10 * 86400, 9999)], age_days=10)
        self.assertEqual(self.totals(), {"fiveHour": 0, "week": 0})

    def test_missing_folder_reports_no_records(self):
        self.root = self.root.parent / "missing"
        self.assertEqual(self.totals(), {"fiveHour": -1, "week": -1})


if __name__ == "__main__":
    unittest.main()
