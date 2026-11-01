#!/usr/bin/env python3
"""Read-only Codex usage adapter. Python 3.9+, standard library only."""
import argparse
import datetime as dt
from decimal import Decimal, InvalidOperation
import json
import math
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import sys
import threading
import time


class UsageError(Exception):
    pass


def number(value):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value))


def snapshot(payload, now=None):
    """Whitelist display data. Never return account IDs, tokens or reset credits."""
    now = time.time() if now is None else now
    if not isinstance(payload, dict):
        raise UsageError("Invalid usage response")
    buckets = payload.get("rateLimitsByLimitId")
    if not isinstance(buckets, dict) or not buckets:
        legacy = payload.get("rateLimits")
        buckets = {"codex": legacy} if isinstance(legacy, dict) else {}
    result = {"source": "Codex account limits", "observedAt": now, "buckets": []}
    for key, bucket in buckets.items():
        if not isinstance(bucket, dict):
            continue
        out = {"id": str(key), "windows": [],
               "spendControlReached": bucket.get("spendControlReached") is True,
               "limitReached": bool(bucket.get("rateLimitReachedType"))}
        credits = bucket.get("credits")
        balance = credits.get("balance") if isinstance(credits, dict) else None
        try:
            amount = Decimal(str(balance))
            if amount.is_finite() and amount >= 0:
                out["creditBalance"] = str(amount)
        except (InvalidOperation, ValueError):
            pass
        for slot in ("primary", "secondary"):
            window = bucket.get(slot)
            if not isinstance(window, dict):
                continue
            used, mins, reset = (window.get(k) for k in
                                ("usedPercent", "windowDurationMins", "resetsAt"))
            valid_reset = number(reset) and 0 <= reset <= 253402300799
            out["windows"].append({
                "slot": slot,
                "remainingPercent": max(0, min(100, 100 - used)) if number(used) else None,
                "windowDurationMins": mins if number(mins) and mins > 0 else None,
                "resetsAt": reset if valid_reset else None,
                "resetPending": valid_reset and reset <= now,
            })
        result["buckets"].append(out)
    return result


def duration_label(minutes, fallback):
    if minutes is None:
        return fallback
    if minutes % 10080 == 0:
        return f"{minutes / 10080:g}w"
    if minutes % 1440 == 0:
        return f"{minutes / 1440:g}d"
    if minutes % 60 == 0:
        return f"{minutes / 60:g}h"
    return f"{minutes:g}m"


def footer(data):
    parts = []
    for bucket in data["buckets"]:
        for w in bucket["windows"]:
            label = duration_label(w["windowDurationMins"], w["slot"])
            pct = w["remainingPercent"]
            remaining = "unavailable" if pct is None else f"{pct:g}% remaining"
            reset = w["resetsAt"]
            reset_text = "reset unavailable" if reset is None else (
                "awaiting reset refresh" if w["resetPending"] else
                "reset " + dt.datetime.fromtimestamp(reset, dt.timezone.utc).strftime("%d %b %H:%M UTC"))
            parts.append(f"{bucket['id']} {label}: {remaining} ({reset_text})")
        if bucket["spendControlReached"] or bucket["limitReached"]:
            parts.append(f"{bucket['id']}: account restriction reported")
    stamp = dt.datetime.fromtimestamp(data["observedAt"], dt.timezone.utc).strftime("%H:%M UTC")
    return "Codex · " + (" · ".join(parts) if parts else "limits unavailable") + f" · checked {stamp}"


EXTRA_SEARCH_DIRS = ("/opt/homebrew/bin", "/usr/local/bin")


def search_path():
    """A Finder-launched app gets a minimal PATH, so Homebrew and npm locations are added."""
    dirs = [d for d in os.environ.get("PATH", "").split(os.pathsep) if d]
    dirs += [d for d in EXTRA_SEARCH_DIRS if d not in dirs]
    return os.pathsep.join(dirs)


def codex_binary():
    binary = shutil.which("codex", path=search_path())
    if binary:
        return binary
    candidates = [
        Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
    ]
    for app in ("ChatGPT", "Codex"):
        candidates.append(Path(f"/Applications/{app}.app/Contents/Resources/codex"))
    for path in candidates:
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    raise UsageError("Codex CLI not found; use the desktop built-in usage tool")


def read_live(timeout=12, command=None):
    """No thread/start or turn/start: this only performs a metadata read."""
    command = command or [codex_binary(), "app-server", "--stdio", "--disable", "hooks"]
    env = dict(os.environ, PATH=search_path())
    proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, encoding="utf-8", env=env)
    messages = queue.Queue(maxsize=128)

    def drain():
        try:
            for line in proc.stdout:
                if len(line) > 1_000_000:
                    continue
                try:
                    message = json.loads(line)
                    if isinstance(message, dict):
                        messages.put(message, timeout=0.1)
                except (ValueError, queue.Full):
                    pass
        finally:
            try:
                messages.put(None, timeout=0.1)
            except queue.Full:
                pass

    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    deadline = time.monotonic() + timeout

    def send(message):
        proc.stdin.write(json.dumps(message) + "\n")
        proc.stdin.flush()

    def receive(identifier):
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise UsageError("Usage read timed out")
            try:
                message = messages.get(timeout=remaining)
            except queue.Empty:
                raise UsageError("Usage read timed out") from None
            if message is None:
                raise UsageError("Codex app-server closed before returning usage")
            if message.get("id") == identifier and "method" not in message:
                if "error" in message:
                    # Raw server errors can contain private details; never print them.
                    raise UsageError("Codex could not read usage; check login and connectivity")
                if not isinstance(message.get("result"), dict):
                    raise UsageError("Invalid app-server response")
                return message["result"]
            if "id" in message and "method" in message:
                send({"id": message["id"], "error": {
                    "code": -32601, "message": "Usage Meter supports read-only usage queries"}})

    try:
        send({"id": 1, "method": "initialize", "params": {"clientInfo": {
            "name": "usage_meter", "title": "Usage Meter", "version": "0.2.0"}}})
        receive(1)
        send({"method": "initialized", "params": {}})
        send({"id": 2, "method": "account/rateLimits/read"})
        return receive(2)
    finally:
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)
        proc.stdin.close()
        reader.join(timeout=1)
        proc.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--live", action="store_true", help="Read the signed-in Codex account")
    source.add_argument("--stdin", action="store_true", help="Format a JSON usage response from stdin")
    parser.add_argument("--json", action="store_true", help="Output sanitized structured data")
    args = parser.parse_args()
    def stop(*_):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    try:
        payload = read_live() if args.live else json.load(sys.stdin)
        data = snapshot(payload)
        print(json.dumps(data, ensure_ascii=False) if args.json else footer(data))
        return 0
    except (UsageError, OSError, ValueError):
        # No raw error payload, credentials, account identifiers, or stderr log.
        print(json.dumps({"status": "unavailable"}) if args.json else "Codex · limits unavailable")
        return 1


if __name__ == "__main__":
    sys.exit(main())
