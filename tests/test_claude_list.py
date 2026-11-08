"""Tests for the Claude Code session list behind the Claude drawer (`--claude-list` hook)."""
import datetime as dt
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import test_claude_statusline as build

NOW = 1_800_000_000
UUID = "11111111-2222-4333-8444-555555555555"


def iso(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


class ClaudeListTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build.setUpModule()

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / "projects"
        (self.root / "-Users-x-proj").mkdir(parents=True)

    def write(self, rel, lines, modified):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(json.dumps(l) for l in lines) + "\n")
        os.utime(path, (modified, modified))

    def list(self):
        result = subprocess.run([build._build["binary"], "--claude-list", str(self.root), str(NOW)],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_title_model_steps_and_state(self):
        self.write(f"-Users-x-proj/{UUID}.jsonl", [
            {"type": "user", "timestamp": iso(NOW - 200), "message": {"role": "user", "content": "Oprav build v Xcode"}},
            {"type": "assistant", "timestamp": iso(NOW - 190), "message": {"model": "claude-opus-5-5", "content": [
                {"type": "tool_use", "name": "Bash", "input": {"command": "swift build"}}]}},
        ], NOW - 150)
        item = self.list()[0]
        self.assertEqual(item["id"], UUID)
        self.assertEqual(item["title"], "Oprav build v Xcode")
        self.assertEqual(item["model"], "claude-opus-5-5")
        self.assertEqual(item["kind"], "Claude Code")
        self.assertIn("Bash: swift build", item["last"])
        self.assertEqual(item["state"], "done")

    def test_recent_write_means_running(self):
        self.write(f"-Users-x-proj/{UUID}.jsonl", [
            {"type": "user", "timestamp": iso(NOW - 20), "message": {"role": "user", "content": "Test"}}], NOW - 10)
        self.assertEqual(self.list()[0]["state"], "running")

    def test_subagent_logs_are_not_listed(self):
        self.write(f"-Users-x-proj/{UUID}/subagents/agent-1.jsonl", [
            {"type": "user", "timestamp": iso(NOW - 20), "message": {"role": "user", "content": "Vnitřní"}}], NOW - 10)
        self.assertEqual(self.list(), [])


if __name__ == "__main__":
    unittest.main()
