"""Tests for the Claude Code status line integration in macos/UsageMeter.swift.

The app binary is compiled once. Storage is redirected with USAGE_METER_TEST_SUPPORT and
USAGE_METER_TEST_CLAUDE, so nothing in the real home folder is touched.
"""
import json
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "macos" / "UsageMeter.swift"
BINARY_PATH = "/Applications/Usage Meter Pure.app/Contents/MacOS/UsageMeter"
OUR_COMMAND = "'" + BINARY_PATH + "' --statusline"
_build = {}


def setUpModule():
    if shutil.which("xcrun") is None:
        raise unittest.SkipTest("xcrun is not available")
    temp = tempfile.mkdtemp(prefix="usage-meter-statusline-")
    _build["dir"] = temp
    binary = Path(temp) / "UsageMeterStatusline"
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


class StatuslineTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.support = self.root / "support"
        self.claude = self.root / ".claude"
        self.claude.mkdir()
        self.settings = self.claude / "settings.json"
        self.env = {"USAGE_METER_TEST_SUPPORT": str(self.support),
                    "USAGE_METER_TEST_CLAUDE": str(self.claude),
                    "PATH": "/usr/bin:/bin"}

    def run_app(self, args, stdin=b""):
        return subprocess.run([_build["binary"], *args], input=stdin, capture_output=True, env=self.env, timeout=60)

    def setup_cmd(self, action, binary=BINARY_PATH):
        result = self.run_app(["--claude-setup", action, binary])
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(self.settings.read_text()) if self.settings.exists() else {}

    def test_statusline_stores_only_four_numbers_per_window(self):
        payload = {
            "session_id": "secret-session", "cwd": "/Users/someone/private", "transcript_path": "/tmp/t.jsonl",
            "rate_limits": {
                "five_hour": {"used_percentage": 24, "resets_at": int(time.time()) + 3600},
                "seven_day": {"used_percentage": 93, "resets_at": int(time.time()) + 86400},
            }}
        result = self.run_app(["--statusline"], stdin=json.dumps(payload).encode())
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        stored = (self.support / "claude-statusline.json").read_text()
        self.assertNotIn("secret-session", stored)
        self.assertNotIn("private", stored)
        self.assertNotIn("transcript", stored)
        record = json.loads(stored)
        self.assertEqual(record["fiveHour"]["usedPercent"], 24)
        self.assertEqual(record["sevenDay"]["usedPercent"], 93)

    def test_out_of_range_percent_is_dropped(self):
        payload = {"rate_limits": {"five_hour": {"used_percentage": 150}, "seven_day": {"used_percentage": 40}}}
        self.run_app(["--statusline"], stdin=json.dumps(payload).encode())
        record = json.loads((self.support / "claude-statusline.json").read_text())
        self.assertNotIn("usedPercent", record["fiveHour"])
        self.assertEqual(record["sevenDay"]["usedPercent"], 40)

    def test_previous_status_line_is_chained_and_its_output_printed(self):
        self.support.mkdir()
        (self.support / "claude-setup.json").write_text(json.dumps({"previousCommand": "echo previous-line"}))
        result = self.run_app(["--statusline"], stdin=b'{"rate_limits": {}}')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"previous-line\n")

    def test_install_creates_settings_when_only_claude_folder_exists(self):
        settings = self.setup_cmd("install")
        self.assertEqual(settings["statusLine"], {"type": "command", "command": OUR_COMMAND})

    def test_install_keeps_other_keys_chains_existing_line_and_backs_up(self):
        original = {"theme": "dark", "model": "opus",
                    "statusLine": {"type": "command", "command": "echo mine", "padding": 2}}
        self.settings.write_text(json.dumps(original))
        settings = self.setup_cmd("install")
        self.assertEqual(settings["theme"], "dark")
        self.assertEqual(settings["model"], "opus")
        self.assertEqual(settings["statusLine"], {"type": "command", "command": OUR_COMMAND, "padding": 2})
        backup = json.loads((self.claude / "settings.json.usage-meter-backup.json").read_text())
        self.assertEqual(backup, original)
        config = json.loads((self.support / "claude-setup.json").read_text())
        self.assertEqual(config["previousCommand"], "echo mine")

    def test_install_is_idempotent_and_keeps_the_original_chain(self):
        self.settings.write_text(json.dumps({"statusLine": {"type": "command", "command": "echo mine"}}))
        self.setup_cmd("install")
        before = self.settings.read_text()
        self.setup_cmd("install")
        self.assertEqual(self.settings.read_text(), before)
        config = json.loads((self.support / "claude-setup.json").read_text())
        self.assertEqual(config["previousCommand"], "echo mine")

    def test_invalid_settings_file_is_never_overwritten(self):
        self.settings.write_text("{ not json")
        result = self.run_app(["--claude-setup", "install", BINARY_PATH])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.settings.read_text(), "{ not json")

    def test_missing_claude_folder_creates_nothing(self):
        shutil.rmtree(self.claude)
        self.run_app(["--claude-setup", "install", BINARY_PATH])
        self.assertFalse(self.claude.exists())

    def test_uninstall_restores_the_previous_status_line(self):
        original = {"theme": "dark", "statusLine": {"type": "command", "command": "echo mine", "padding": 2}}
        self.settings.write_text(json.dumps(original))
        self.setup_cmd("install")
        restored = self.setup_cmd("uninstall")
        self.assertEqual(restored, original)
        self.assertFalse((self.support / "claude-setup.json").exists())

    def test_uninstall_removes_key_when_there_was_no_previous_line(self):
        self.settings.write_text(json.dumps({"theme": "dark"}))
        self.setup_cmd("install")
        restored = self.setup_cmd("uninstall")
        self.assertEqual(restored, {"theme": "dark"})

    def test_path_with_shell_metacharacters_is_quoted_literally(self):
        binary = "/Users/x/$(touch pwned)/Usage Meter Pure.app/Contents/MacOS/UsageMeter"
        settings = self.setup_cmd("install", binary=binary)
        command = settings["statusLine"]["command"]
        self.assertEqual(command, "'" + binary + "' --statusline")
        self.assertFalse((self.root / "pwned").exists())

    def test_relative_binary_path_is_refused(self):
        result = self.run_app(["--claude-setup", "install", "UsageMeter"])
        self.assertEqual(result.returncode, 0)
        self.assertFalse(self.settings.exists())

    def test_settings_keep_private_permissions(self):
        self.settings.write_text(json.dumps({"env": {"TOKEN": "x"}}))
        self.settings.chmod(0o600)
        self.setup_cmd("install")
        self.assertEqual(self.settings.stat().st_mode & 0o777, 0o600)

    def test_moved_app_updates_the_command_path(self):
        self.setup_cmd("install", binary="/Applications/Usage Meter Pure.app/Contents/MacOS/UsageMeter")
        settings = self.setup_cmd("install", binary="/Users/x/Apps/Usage Meter Pure.app/Contents/MacOS/UsageMeter")
        self.assertIn("/Users/x/Apps/", settings["statusLine"]["command"])
        self.assertNotIn("/Applications/", settings["statusLine"]["command"])

    def test_statusline_limits_feed_the_claude_reader_with_reset_times(self):
        now = int(time.time())
        payload = {"rate_limits": {"five_hour": {"used_percentage": 24, "resets_at": now + 1800},
                                   "seven_day": {"used_percentage": 93, "resets_at": now + 86400}}}
        self.run_app(["--statusline"], stdin=json.dumps(payload).encode())
        result = subprocess.run([_build["binary"], "--claude-check", "/nonexistent/plan.json", "/nonexistent/projects", str(now)],
                                capture_output=True, text=True, env=self.env, timeout=60)
        data = json.loads(result.stdout)
        self.assertEqual(data["fiveHourUsed"], 24)
        self.assertEqual(data["weekUsed"], 93)
        self.assertEqual(data["fiveHourResetsAt"], now + 1800)


if __name__ == "__main__":
    unittest.main()
