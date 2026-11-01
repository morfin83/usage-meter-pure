"""Tests for the local Claude sources read by macos/UsageMeter.swift.

The app is compiled once and run with `--claude-check <plan.json> <projects> <now>`,
which prints the parsed snapshot. Fixtures are written to a temporary folder.
"""
import datetime as dt
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "macos" / "UsageMeter.swift"
NOW = 1_800_000_000.0
_build = {}


def setUpModule():
    if shutil.which("xcrun") is None:
        raise unittest.SkipTest("xcrun is not available")
    temp = tempfile.mkdtemp(prefix="usage-meter-claude-")
    _build["dir"] = temp
    binary = Path(temp) / "UsageMeterClaude"
    result = subprocess.run(
        ["xcrun", "swiftc", "-target", "arm64-apple-macos13.0",
         "-module-cache-path", str(Path(temp) / "cache"),
         "-framework", "AppKit", "-framework", "IOKit", "-framework", "SystemConfiguration",
         str(SOURCE), "-o", str(binary)],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError("swiftc failed:\n" + result.stderr)
    _build["binary"] = str(binary)


def tearDownModule():
    shutil.rmtree(_build.get("dir", ""), ignore_errors=True)


def iso(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


class ClaudeSourceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        self.plan = self.dir / "plan-usage-history.json"
        self.projects = self.dir / "projects"
        self.projects.mkdir()

    def write_plan(self, body):
        self.plan.write_text(json.dumps(body))

    def check(self, now=NOW):
        env = dict(os.environ, USAGE_METER_TEST_SUPPORT=str(self.dir / "support"))
        result = subprocess.run([_build["binary"], "--claude-check", str(self.plan), str(self.projects), str(now)],
                                capture_output=True, text=True, timeout=60, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def write_record(self, name, records, age_days=0):
        path = self.projects / name
        lines = []
        for message_id, epoch, usage in records:
            obj = {"timestamp": iso(epoch), "type": "assistant"}
            if message_id is not None:
                obj["message"] = {"id": message_id, "usage": usage} if usage is not None else {"id": message_id}
            lines.append(json.dumps(obj))
        path.write_text("\n".join(lines) + "\n")
        mtime = NOW - age_days * 86400
        os.utime(path, (mtime, mtime))

    def test_newest_plan_sample_is_used_and_values_are_used_percent(self):
        self.write_plan({"version": 2, "samples": [
            {"t": int((NOW - 7200) * 1000), "org": "x", "u": {"fh": 10, "sd": 50}},
            {"t": int((NOW - 600) * 1000), "org": "x", "u": {"fh": 24, "sd": 93}},
        ]})
        data = self.check()
        self.assertAlmostEqual(data["planObservedAt"], NOW - 600, places=3)
        self.assertEqual(data["fiveHourUsed"], 24)
        self.assertEqual(data["weekUsed"], 93)

    def test_out_of_range_or_wrong_version_is_rejected(self):
        self.write_plan({"version": 2, "samples": [{"t": int(NOW * 1000), "u": {"fh": 150, "sd": -1}}]})
        data = self.check()
        self.assertNotIn("fiveHourUsed", data)
        self.assertNotIn("weekUsed", data)
        self.write_plan({"version": 3, "samples": [{"t": int(NOW * 1000), "u": {"fh": 5, "sd": 5}}]})
        self.assertNotIn("planObservedAt", self.check())

    def test_missing_files_give_no_values_and_no_crash(self):
        # No plan file: no limit values. An empty projects folder is a real zero, not a missing source.
        data = self.check()
        self.assertNotIn("planObservedAt", data)
        self.assertEqual(data["tokens5h"], 0)

    def test_token_windows_dedupe_by_message_and_skip_old_files(self):
        self.write_record("p1.jsonl", [
            ("m-recent", NOW - 3600, {"input_tokens": 100, "output_tokens": 50,
                                      "cache_creation_input_tokens": 10, "cache_read_input_tokens": 40}),
            ("m-streamed", NOW - 7200, {"input_tokens": 1, "output_tokens": 1,
                                        "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}),
            ("m-streamed", NOW - 7000, {"input_tokens": 400, "output_tokens": 100,
                                        "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}),
            ("m-no-usage", NOW - 60, None),
        ])
        self.write_record("p2.jsonl", [
            ("m-older", NOW - 3 * 86400, {"input_tokens": 300, "output_tokens": 0,
                                          "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}),
        ])
        self.write_record("old.jsonl", [
            ("m-ancient", NOW - 1000, {"input_tokens": 9999, "output_tokens": 0,
                                       "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}),
        ], age_days=8)
        data = self.check()
        # five hours: 200 (recent) + 500 (streamed, last record wins); week adds 300 (older).
        self.assertEqual(data["tokens5h"], 700)
        self.assertEqual(data["tokens7d"], 1000)

    def test_missing_projects_folder_gives_no_token_values(self):
        shutil.rmtree(self.projects)
        self.assertNotIn("tokens5h", self.check())


if __name__ == "__main__":
    unittest.main()
