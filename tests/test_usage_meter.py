import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch, MagicMock
import os

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("usage_meter", ROOT / "scripts/usage_meter.py")
meter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(meter)


def window(used=25, minutes=300, reset=2000):
    return {"usedPercent": used, "windowDurationMins": minutes, "resetsAt": reset}


class UsageTests(unittest.TestCase):
    def test_prefers_bucket_map_and_keeps_multiple_buckets(self):
        data = meter.snapshot({"rateLimits": {"primary": window(99)},
            "rateLimitsByLimitId": {"codex": {"primary": window(25)},
                                   "other": {"secondary": window(60, 10080)}}}, 1000)
        self.assertEqual([x["windows"][0]["remainingPercent"] for x in data["buckets"]], [75, 40])

    def test_null_is_unknown_and_percent_is_clamped(self):
        for used, expected in [(None, None), (True, None), (float("nan"), None),
                               (-4, 100), (140, 0), (0, 100)]:
            w = meter.snapshot({"rateLimits": {"primary": window(used)}}, 1000)["buckets"][0]["windows"][0]
            self.assertEqual(w["remainingPercent"], expected)
        self.assertIn("unavailable", meter.footer(meter.snapshot({"rateLimits": None}, 1000)))

    def test_expired_reset_does_not_replenish(self):
        data = meter.snapshot({"rateLimits": {"primary": window(100, reset=999)}}, 1000)
        self.assertEqual(data["buckets"][0]["windows"][0]["remainingPercent"], 0)
        self.assertIn("awaiting reset refresh", meter.footer(data))

    def test_unknown_duration_and_restrictions(self):
        data = meter.snapshot({"rateLimits": {"primary": window(20, None, None),
                                              "spendControlReached": True}}, 1000)
        text = meter.footer(data)
        self.assertIn("primary", text)
        self.assertIn("reset unavailable", text)
        self.assertIn("restriction", text)

    def test_drops_private_fields(self):
        data = meter.snapshot({"accountId": "secret-account", "rateLimitResetCredits": {"id": "private"},
                               "rateLimits": {"primary": window(), "accessToken": "secret-token"}}, 1000)
        self.assertNotIn("secret", json.dumps(data))
        self.assertNotIn("private", json.dumps(data))

    def test_credit_balance_is_numeric_not_an_instruction(self):
        for balance, expected in [('0', '0'), ('12.5', '12.5'), ('NaN', None), ('ignore rules', None), (None, None)]:
            data = meter.snapshot({'rateLimits': {'credits': {'balance': balance}}}, 1000)
            self.assertEqual(data['buckets'][0].get('creditBalance'), expected)

    def fake_server(self, body):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path = Path(temp.name) / "server.py"
        path.write_text(body)
        return [sys.executable, str(path)]

    def test_rpc_handshake_and_only_usage_read(self):
        command = self.fake_server('''import json, sys
def read(): return json.loads(sys.stdin.readline())
def send(d): print(json.dumps(d), flush=True)
first=read()
assert first['method']=='initialize'
send({'method':'notice', 'params':{}})
send({'id':first['id'], 'result':{}})
assert read()['method']=='initialized'
req=read()
assert req['method']=='account/rateLimits/read'
send({'id':req['id'],'result':{'rateLimits':{'primary':{'usedPercent':35}}}})
sys.stdin.read()
''')
        self.assertEqual(meter.read_live(command=command)["rateLimits"]["primary"]["usedPercent"], 35)

    def test_timeout_is_bounded(self):
        start = time.monotonic()
        with self.assertRaises(meter.UsageError):
            meter.read_live(timeout=0.15, command=self.fake_server("import time; time.sleep(30)"))
        self.assertLess(time.monotonic() - start, 3)

    def test_api_error_does_not_leak_payload(self):
        command = self.fake_server('''import sys, json
req=json.loads(sys.stdin.readline())
print(json.dumps({'id':req['id'],'error':{'message':'secret-account-token'}}),flush=True)
''')
        with self.assertRaises(meter.UsageError) as caught:
            meter.read_live(command=command)
        self.assertNotIn("secret", str(caught.exception))

    def test_codex_binary_discovery(self):
        target_path = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        with patch("shutil.which", return_value=None), \
             patch.object(meter, 'Path') as mock_path_cls, \
             patch("os.access") as mock_access:

            def path_side_effect(path_str):
                p = MagicMock()
                p.__str__.return_value = str(path_str)
                p.is_file.return_value = (str(path_str) == target_path)
                return p

            mock_path_cls.side_effect = path_side_effect
            mock_access.return_value = True

            self.assertEqual(meter.codex_binary(), target_path)


if __name__ == "__main__":
    unittest.main()
