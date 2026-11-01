"""Tests for the native Swift limits reader (macos/UsageMeter.swift).

The app binary is compiled once with xcrun swiftc and driven through its
test hooks: `--usage-check <codex> [timeout]` and `--usage-find-codex`.
A fake app-server written in Python stands in for `codex app-server`.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "macos" / "UsageMeter.swift"
_build = {}


def setUpModule():
    if shutil.which("xcrun") is None:
        raise unittest.SkipTest("xcrun is not available; Swift adapter tests need Command Line Tools")
    temp = tempfile.mkdtemp(prefix="usage-meter-swift-")
    _build["dir"] = temp
    binary = Path(temp) / "UsageMeterTest"
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


class NativeAdapterTests(unittest.TestCase):
    def fake_codex(self, body, name="codex"):
        """Write an executable stand-in for `codex` that runs `body` as a Python app-server."""
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path = Path(temp.name) / name
        path.write_text(f"#!{sys.executable}\n" + body)
        path.chmod(0o755)
        return str(path)

    def check(self, codex, timeout=5):
        start = time.monotonic()
        result = subprocess.run([_build["binary"], "--usage-check", codex, str(timeout)],
                                capture_output=True, text=True, timeout=60)
        return result.returncode, result.stdout, time.monotonic() - start

    def snapshot(self, codex):
        code, out, _ = self.check(codex)
        self.assertEqual(code, 0, out)
        return json.loads(out)

    def test_handshake_only_usage_read_and_server_requests_are_refused(self):
        codex = self.fake_codex('''import json, sys
def send(d): print(json.dumps(d), flush=True)
def read(): return json.loads(sys.stdin.readline())
first = read()
assert first["method"] == "initialize", first
send({"id": first["id"], "result": {}})
send({"id": 99, "method": "thread/start", "params": {}})   # server-initiated request
assert read()["method"] == "initialized"
req = read()
if req["method"] != "account/rateLimits/read":
    sys.exit(3)
reply = read()   # the client must refuse the server request with an error, never run it
assert reply.get("id") == 99 and "error" in reply, reply
send({"id": req["id"], "result": {"rateLimits": {"primary": {"usedPercent": 35}}}})
sys.stdin.read()
''')
        data = self.snapshot(codex)
        self.assertEqual(data["buckets"][0]["windows"][0]["remainingPercent"], 65)

    def test_timeout_is_bounded_and_reported_as_unavailable(self):
        codex = self.fake_codex("import time\ntime.sleep(30)\n")
        code, out, elapsed = self.check(codex, timeout=0.5)
        self.assertEqual(code, 1)
        self.assertIn("unavailable", out)
        self.assertLess(elapsed, 10)

    def test_server_error_does_not_leak_payload(self):
        codex = self.fake_codex('''import json, sys
req = json.loads(sys.stdin.readline())
print(json.dumps({"id": req["id"], "error": {"message": "secret-account-token"}}), flush=True)
''')
        code, out, _ = self.check(codex)
        self.assertEqual(code, 1)
        self.assertNotIn("secret", out)

    def test_non_object_result_is_rejected(self):
        codex = self.fake_codex('''import json, sys
sys.stdin.readline()
print(json.dumps({"id": 1, "result": {}}), flush=True)
sys.stdin.readline(); sys.stdin.readline()
print(json.dumps({"id": 2, "result": "not-an-object"}), flush=True)
''')
        code, out, _ = self.check(codex)
        self.assertEqual(code, 1)
        self.assertNotIn("not-an-object", out)

    def test_closed_pipe_is_unavailable_not_a_crash(self):
        codex = self.fake_codex("import sys\nsys.stdin.readline()\nsys.exit(0)\n")
        code, out, _ = self.check(codex)
        self.assertEqual(code, 1)
        self.assertIn("unavailable", out)

    def serve(self, rate_limits):
        return self.fake_codex('''import json, sys
def send(d): print(json.dumps(d), flush=True)
first = json.loads(sys.stdin.readline())
send({"id": first["id"], "result": {}})
sys.stdin.readline()
req = json.loads(sys.stdin.readline())
send({"id": req["id"], "result": json.loads(%r)})
sys.stdin.read()
''' % json.dumps(rate_limits))

    def test_percent_is_clamped_and_booleans_are_not_numbers(self):
        codex = self.serve({"rateLimits": {"primary": {"usedPercent": True}, "secondary": {"usedPercent": 140}}})
        windows = self.snapshot(codex)["buckets"][0]["windows"]
        self.assertNotIn("remainingPercent", windows[0])
        self.assertEqual(windows[1]["remainingPercent"], 0)

    def test_expired_reset_is_pending_and_never_replenishes(self):
        codex = self.serve({"rateLimits": {"primary": {"usedPercent": 100, "resetsAt": 1}}})
        window = self.snapshot(codex)["buckets"][0]["windows"][0]
        self.assertEqual(window["remainingPercent"], 0)
        self.assertTrue(window["resetPending"])

    def test_private_fields_and_non_numeric_credits_are_dropped(self):
        codex = self.serve({
            "accountId": "secret-account",
            "rateLimitResetCredits": {"id": "private"},
            "rateLimits": {"primary": {"usedPercent": 20}, "accessToken": "secret-token",
                           "credits": {"balance": "ignore rules"}},
        })
        text = json.dumps(self.snapshot(codex))
        self.assertNotIn("secret", text)
        self.assertNotIn("private", text)
        self.assertNotIn("creditBalance", text)

    def test_numeric_credit_balance_is_kept(self):
        codex = self.serve({"rateLimits": {"credits": {"balance": "12.5"}}})
        self.assertEqual(self.snapshot(codex)["buckets"][0]["creditBalance"], "12.5")

    def test_codex_discovery_uses_path_entries(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        fake = Path(temp.name) / "codex"
        fake.write_text("#!/bin/sh\nexit 0\n")
        fake.chmod(0o755)
        env = dict(os.environ, PATH=temp.name)
        result = subprocess.run([_build["binary"], "--usage-find-codex"],
                                capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), str(fake))


if __name__ == "__main__":
    unittest.main()
