"""Tests for the Codex activity reader (`--codex-activity` hook) on fixture session logs."""
import datetime as dt
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import test_claude_statusline as build

NOW = 1_800_000_000
UUID = "01a1b7bd-dfa0-7182-a60c-8a6d67966d09"


def line(epoch, kind, payload):
    stamp = dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    return json.dumps({"timestamp": stamp, "type": kind, "payload": payload})


class CodexActivityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build.setUpModule()

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / "sessions"
        self.root.mkdir()
        self.env = {"PATH": "/usr/bin:/bin"}

    def session(self, lines, now=NOW):
        path = self.root / f"rollout-2026-11-07T21-00-00-{UUID}.jsonl"
        path.write_text("\n".join(lines) + "\n")
        os.utime(path, (now - 5, now - 5))   # the reader uses the file time as "last activity"
        result = subprocess.run([build._build["binary"], "--codex-activity", str(self.root), str(now)],
                                capture_output=True, text=True, env=self.env, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_running_task_with_pending_command(self):
        data = self.session([
            line(NOW - 60, "event_msg", {"type": "task_started"}),
            line(NOW - 50, "response_item", {"type": "function_call", "name": "exec",
                                             "arguments": json.dumps({"cmd": "swift build"}), "call_id": "c1"}),
        ])
        self.assertEqual(data["id"], UUID)
        self.assertEqual(data["state"], "running")
        self.assertIn("spouští kód: swift build", data["steps"][-1]["text"])

    def test_finished_task_marks_steps_done(self):
        data = self.session([
            line(NOW - 60, "event_msg", {"type": "task_started"}),
            line(NOW - 55, "response_item", {"type": "function_call", "name": "exec", "arguments": "{}", "call_id": "c1"}),
            line(NOW - 54, "response_item", {"type": "function_call_output", "call_id": "c1", "output": "ok"}),
            line(NOW - 40, "event_msg", {"type": "task_complete"}),
        ])
        self.assertEqual(data["state"], "done")
        self.assertEqual(data["steps"][1]["kind"], "done")

    def test_aborted_turn_is_an_error_state(self):
        data = self.session([
            line(NOW - 60, "event_msg", {"type": "task_started"}),
            line(NOW - 30, "event_msg", {"type": "turn_aborted"}),
        ])
        self.assertEqual(data["state"], "aborted")
        self.assertEqual(data["steps"][-1]["kind"], "error")

    def test_call_without_result_after_twenty_seconds_is_waiting(self):
        data = self.session([
            line(NOW - 120, "event_msg", {"type": "task_started"}),
            line(NOW - 100, "response_item", {"type": "function_call", "name": "exec",
                                              "arguments": json.dumps({"cmd": "rm -rf build"}), "call_id": "c9"}),
        ])
        self.assertEqual(data["steps"][-1]["kind"], "waiting")

    def test_internal_agent_messages_are_hidden(self):
        data = self.session([
            line(NOW - 60, "event_msg", {"type": "task_started"}),
            line(NOW - 50, "response_item", {"type": "agent_message",
                                             "content": [{"text": "Message Type: MESSAGE Task name: /root"}]}),
            line(NOW - 40, "response_item", {"type": "message", "role": "assistant",
                                             "content": [{"text": "Hotovo, opravil jsem chybu."}]}),
        ])
        texts = [step["text"] for step in data["steps"]]
        self.assertFalse(any(t.startswith("Message Type:") for t in texts))
        self.assertIn("Hotovo, opravil jsem chybu.", texts)

    def test_raw_code_of_exec_is_not_shown(self):
        data = self.session([
            line(NOW - 60, "event_msg", {"type": "task_started"}),
            line(NOW - 50, "response_item", {"type": "custom_tool_call", "name": "exec",
                                             "input": "const x = await tools.web__run({open: []});", "call_id": "c2"}),
        ])
        text = data["steps"][-1]["text"]
        self.assertEqual(text, "spouští kód")
        self.assertNotIn("tools.", text)

    def test_no_sessions_gives_no_activity(self):
        result = subprocess.run([build._build["binary"], "--codex-activity", str(self.root), str(NOW)],
                                capture_output=True, text=True, env=self.env, timeout=60)
        self.assertEqual(json.loads(result.stdout), {})


if __name__ == "__main__":
    unittest.main()
