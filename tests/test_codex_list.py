"""Tests for the list of recent Codex items behind the drawer (`--codex-list` hook)."""
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


def line(epoch, kind, payload):
    return json.dumps({"timestamp": iso(epoch), "type": kind, "payload": payload})


class CodexListTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build.setUpModule()

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / "sessions"
        self.root.mkdir()

    def session(self, uid, lines, modified, title_text=None):
        path = self.root / f"rollout-2026-11-07T10-00-00-{uid}.jsonl"
        content = list(lines)
        if title_text is not None:
            content.insert(0, line(modified - 100, "response_item", {"type": "message", "role": "user",
                                                                   "content": [{"type": "input_text", "text": title_text}]}))
        path.write_text("\n".join(content) + "\n")
        os.utime(path, (modified, modified))

    def list(self, now=NOW):
        result = subprocess.run([build._build["binary"], "--codex-list", str(self.root), str(now)],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_newest_first_with_titles_and_last_step(self):
        self.session("00000000-0000-4000-8000-000000000001",
                     [line(NOW - 300, "event_msg", {"type": "task_started"}),
                      line(NOW - 290, "event_msg", {"type": "task_complete"})],
                     NOW - 290, title_text="Oprav chybu v panelu")
        self.session("00000000-0000-4000-8000-000000000002",
                     [line(NOW - 60, "event_msg", {"type": "task_started"})],
                     NOW - 10, title_text="Napiš test pro okno")
        items = self.list()
        self.assertEqual([i["id"] for i in items],
                         ["00000000-0000-4000-8000-000000000002", "00000000-0000-4000-8000-000000000001"])
        self.assertEqual(items[0]["title"], "Napiš test pro okno")
        self.assertEqual(items[0]["state"], "running")
        self.assertEqual(items[1]["state"], "done")

    def test_items_older_than_a_day_are_left_out(self):
        self.session("00000000-0000-4000-8000-000000000003",
                     [line(NOW - 2 * 86400, "event_msg", {"type": "task_started"})],
                     NOW - 2 * 86400, title_text="Starý úkol")
        self.assertEqual(self.list(), [])

    def test_missing_user_text_gets_a_neutral_title(self):
        self.session("00000000-0000-4000-8000-000000000004",
                     [line(NOW - 50, "event_msg", {"type": "task_started"})], NOW - 5)
        self.assertEqual(self.list()[0]["title"], "Bez názvu")


if __name__ == "__main__":
    unittest.main()
