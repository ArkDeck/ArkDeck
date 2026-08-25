#!/usr/bin/env python3
"""Persistent `hdc shell` round-trip latency (data/persistent-shell.json).

One long-lived `hdc -t <key> shell` over a PTY. The sentinel token is split by
quoting (`echo D_"c0"`) so the PTY's echo of our own input can never match it —
the first version of this measurement matched the input echo and reported a
3.8 ms "click", faster than `echo`, which is how the flaw was caught.
"""

import json
import os
import pty
import select
import signal
import subprocess
import time
from pathlib import Path

HDC = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
KEY = "5SM0125725000252"
TAP_X, TAP_Y = 640, 1500
DATA = Path(__file__).resolve().parent.parent / "data"

signal.alarm(100)
master, slave = pty.openpty()
proc = subprocess.Popen([HDC, "-t", KEY, "shell"], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
buf = b""


def read_until(token, deadline):
    global buf
    end = time.time() + deadline
    while time.time() < end:
        ready, _, _ = select.select([master], [], [], 0.05)
        if ready:
            try:
                buf += os.read(master, 4096)
            except OSError:
                break
            if token.encode() in buf:
                buf = b""
                return True
    return False


def round_trip(cmd, marker, deadline=10):
    t0 = time.perf_counter()
    os.write(master, (cmd + ' && echo D_"' + marker + '"\r\n').encode())
    ok = read_until("D_" + marker, deadline)
    return ok, (time.perf_counter() - t0) * 1000.0


def summarize(xs):
    xs = sorted(xs)
    n = len(xs)
    if not n:
        return {"n": 0}
    return {
        "n": n,
        "p50_ms": round(xs[n // 2], 1),
        "p95_ms": round(xs[min(n - 1, int(n * 0.95))], 1),
        "min_ms": round(xs[0], 1),
        "max_ms": round(xs[-1], 1),
    }


time.sleep(1.2)
read_until("#", 2)
round_trip("true", "w0")
round_trip("true", "w1")
echo = [ms for i in range(20) if (r := round_trip("echo ok", f"e{i}"))[0] and (ms := r[1])]
click = [
    ms
    for i in range(15)
    if (r := round_trip(f"uitest uiInput click {TAP_X} {TAP_Y}", f"c{i}"))[0] and (ms := r[1])
]
try:
    os.write(master, b"exit\r\n")
    time.sleep(0.5)
finally:
    proc.terminate()

out = {
    "persistent_shell_echo": summarize(echo),
    "persistent_shell_uiinput_click": summarize(click),
    "note": "one long-lived `hdc -t K shell` over a PTY; sentinel token split by quoting so "
    "the PTY input echo cannot match; round trip = command completion",
}
print(json.dumps(out, indent=1))
(DATA / "persistent-shell.json").write_text(json.dumps(out, indent=1) + "\n")
