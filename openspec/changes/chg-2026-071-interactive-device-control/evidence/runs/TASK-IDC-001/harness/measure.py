#!/usr/bin/env python3
"""TASK-IDC-001 spike harness (read-mostly; lock-screen-safe inputs only).

Every device command is bound with `-t <connectKey>`. Inputs are injected on
the lock screen at inert coordinates (verified by before/after screenshots).
Raw trace dumps stay outside the repo (scratch dir); this harness records
summaries, digests and small excerpts only.

Usage: python3 measure.py <subcommand> [N]
Subcommands: latency | hash | ring | clocks | hilog | snapseries
"""

import hashlib
import json
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

HDC = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
KEY = "5SM0125725000252"
HERE = Path(__file__).resolve().parent
DATA = HERE.parent / "data"
SCRATCH = Path(
    "/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-"
    "worktrees-arkdeck-diagnostics-toolkit-review-637a5f/"
    "966aa01f-76a9-49c9-9f76-569d59b069a5/scratchpad/idc-spike"
)
SCRATCH.mkdir(parents=True, exist_ok=True)

# Inert lock-screen coordinates on the 1280x2832 panel (empty wallpaper area).
TAP_X, TAP_Y = 640, 1500
UIINPUT_FAIL = re.compile(r"illegal|fail|error|incorrect|please confirm", re.I)


def run(args, timeout=60):
    t0 = time.perf_counter()
    p = subprocess.run([HDC, "-t", KEY] + args, capture_output=True, text=True, timeout=timeout)
    ms = (time.perf_counter() - t0) * 1000.0
    return ms, p.returncode, (p.stdout or "") + (p.stderr or "")


def shell(cmd, timeout=60):
    return run(["shell", cmd], timeout=timeout)


def summarize(samples):
    s = sorted(samples)
    n = len(s)
    return {
        "n": n,
        "p50_ms": round(s[n // 2], 1),
        "p95_ms": round(s[min(n - 1, int(n * 0.95))], 1),
        "min_ms": round(s[0], 1),
        "max_ms": round(s[-1], 1),
        "mean_ms": round(statistics.fmean(s), 1),
    }


def save(name, obj):
    path = DATA / name
    path.write_text(json.dumps(obj, indent=1, ensure_ascii=False) + "\n")
    print(f"wrote {path.name}")


def ui_ok(out):
    return "No Error" in out and not UIINPUT_FAIL.search(out.replace("No Error", ""))


def measure_latency(n=50):
    out = {"note": "wall-clock around one hdc client invocation, hot shared hdc server, lock screen"}
    cases = {
        "shell_echo": lambda: shell("echo ok"),
        "shell_uptime": lambda: shell("uptime"),
        "uiinput_click": lambda: shell(f"uitest uiInput click {TAP_X} {TAP_Y}"),
    }
    small = {
        "uiinput_longclick": lambda: shell(f"uitest uiInput longClick {TAP_X} {TAP_Y}"),
        "uiinput_swipe_20px": lambda: shell(
            f"uitest uiInput swipe {TAP_X - 10} {TAP_Y} {TAP_X + 10} {TAP_Y} 600"
        ),
        "snapshot_png": lambda: shell(
            "snapshot_display -t png -f /data/local/tmp/idc-lat.png && rm -f /data/local/tmp/idc-lat.png"
        ),
        "snapshot_jpeg": lambda: shell(
            "snapshot_display -t jpeg -f /data/local/tmp/idc-lat.jpeg && rm -f /data/local/tmp/idc-lat.jpeg"
        ),
    }
    for name, fn in cases.items():
        samples, failures = [], 0
        for _ in range(n):
            ms, rc, text = fn()
            good = rc == 0 and (not name.startswith("uiinput") or ui_ok(text))
            samples.append(ms)
            failures += 0 if good else 1
        out[name] = summarize(samples) | {"failures": failures, "samples_ms": [round(x, 1) for x in samples]}
        print(name, out[name]["p50_ms"], "/", out[name]["p95_ms"], "p50/p95 ms")
    for name, fn in small.items():
        samples, failures = [], 0
        for _ in range(15):
            ms, rc, text = fn()
            good = rc == 0 and (not name.startswith("uiinput") or ui_ok(text))
            samples.append(ms)
            failures += 0 if good else 1
        out[name] = summarize(samples) | {"failures": failures, "samples_ms": [round(x, 1) for x in samples]}
        print(name, out[name]["p50_ms"], "/", out[name]["p95_ms"], "p50/p95 ms")
    # screenshot end-to-end: capture + ls readback + file recv + rm (the product's leg shape)
    for kind in ("png", "jpeg"):
        samples, sizes = [], []
        for i in range(10):
            remote = f"/data/local/tmp/idc-e2e-{i}.{kind}"
            local = SCRATCH / f"e2e-{i}.{kind}"
            t0 = time.perf_counter()
            shell(f"snapshot_display -t {kind} -f {remote}")
            shell(f"ls -l {remote}")
            run(["file", "recv", remote, str(local)])
            shell(f"rm -f {remote}")
            samples.append((time.perf_counter() - t0) * 1000.0)
            sizes.append(local.stat().st_size if local.exists() else 0)
            local.unlink(missing_ok=True)
        out[f"screenshot_e2e_{kind}"] = summarize(samples) | {"bytes_mean": int(statistics.fmean(sizes))}
        print(f"screenshot_e2e_{kind}", out[f"screenshot_e2e_{kind}"])
    save("latency.json", out)


def measure_hash(n=10):
    data = Path(HDC).read_bytes()
    samples = []
    for _ in range(n):
        t0 = time.perf_counter()
        hashlib.sha256(data).hexdigest()
        samples.append((time.perf_counter() - t0) * 1000.0)
    # cold-ish variant including the read
    samples_io = []
    for _ in range(n):
        t0 = time.perf_counter()
        hashlib.sha256(Path(HDC).read_bytes()).hexdigest()
        samples_io.append((time.perf_counter() - t0) * 1000.0)
    save(
        "hdc-hash.json",
        {
            "binary": HDC,
            "bytes": len(data),
            "sha256_only": summarize(samples),
            "read_plus_sha256": summarize(samples_io),
            "note": "per-spawn cost the production dispatcher pays today (no cache on the hdc path)",
        },
    )


def device_uptime():
    _, _, text = shell("cat /proc/uptime")
    return float(text.split()[0])


TS_RE = re.compile(r"\s(\d{4,7}\.\d{6}):")


def dump_span(path):
    first = last = None
    count = 0
    with open(path, errors="replace") as fh:
        for line in fh:
            m = TS_RE.search(line)
            if m:
                ts = float(m.group(1))
                first = ts if first is None else first
                last = ts
                count += 1
    return first, last, count


def measure_ring():
    cats = "sched freq graphic ace app ohos"
    out = {"categories": cats, "clock": "boot (explicit)"}
    ms, rc, text = shell(f"hitrace --trace_begin --trace_clock boot {cats}")
    out["begin"] = {"ms": round(ms, 1), "rc": rc, "stdout_tail": text.strip()[-200:]}
    time.sleep(5)
    shell(f"uitest uiInput click {TAP_X} {TAP_Y}")
    time.sleep(5)
    shell(f"uitest uiInput click {TAP_X} {TAP_Y}")
    time.sleep(5)
    up_at_dump1 = device_uptime()
    ms, rc, text = shell("hitrace --trace_dump -o /data/local/tmp/idc-ring1.txt", timeout=120)
    out["dump1"] = {"ms": round(ms, 1), "rc": rc, "device_uptime_at_dump": up_at_dump1}
    time.sleep(15)
    up_at_dump2 = device_uptime()
    ms, rc, text = shell("hitrace --trace_dump -o /data/local/tmp/idc-ring2.txt", timeout=120)
    out["dump2"] = {"ms": round(ms, 1), "rc": rc, "device_uptime_at_dump": up_at_dump2}
    ms, rc, text = shell("hitrace --trace_finish_nodump")
    out["finish_nodump"] = {"ms": round(ms, 1), "rc": rc, "stdout_tail": text.strip()[-200:]}
    for i, up in (("1", up_at_dump1), ("2", up_at_dump2)):
        local = SCRATCH / f"ring{i}.txt"
        run(["file", "recv", f"/data/local/tmp/idc-ring{i}.txt", str(local)], timeout=180)
        shell(f"rm -f /data/local/tmp/idc-ring{i}.txt")
        first, last, nts = dump_span(local)
        out[f"ring{i}_span"] = {
            "bytes": local.stat().st_size,
            "sha256": hashlib.sha256(local.read_bytes()).hexdigest(),
            "timestamped_lines": nts,
            "first_ts": first,
            "last_ts": last,
            "coverage_back_from_dump_s": round(up - first, 2) if first else None,
            "lag_last_to_dump_s": round(up - last, 2) if last else None,
        }
        print(f"ring{i}", out[f"ring{i}_span"])
    save("ring.json", out)


def measure_clocks():
    out = {}
    # host<->device RTT / offset stability (boot domain via /proc/uptime)
    pairs = []
    for _ in range(60):
        t0 = time.perf_counter()
        h0 = time.time()
        _, _, text = shell("cat /proc/uptime", timeout=15)
        rtt = (time.perf_counter() - t0) * 1000.0
        up = float(text.split()[0])
        pairs.append({"host_unix_mid": h0 + rtt / 2000.0, "device_uptime": up, "rtt_ms": round(rtt, 1)})
    rtts = [p["rtt_ms"] for p in pairs]
    offsets = [p["host_unix_mid"] - p["device_uptime"] for p in pairs]
    out["host_device"] = {
        "n": len(pairs),
        "rtt": summarize(rtts),
        "offset_jitter_ms": {
            "p95_abs_dev_ms": round(
                sorted(abs(o - statistics.median(offsets)) * 1000 for o in offsets)[int(len(offsets) * 0.95)], 1
            ),
            "spread_ms": round((max(offsets) - min(offsets)) * 1000, 1),
        },
        "note": "offset = host wall midpoint - device boottime; spread bounds calibration error (USB)",
    }
    print("host_device", out["host_device"])
    # device-internal bridge: trace_marker(boot, via ftrace) vs date(realtime) in one shell
    shell("hitrace --trace_begin --trace_clock boot ohos app")
    bridge = []
    for i in range(30):
        _, _, text = shell(
            f"echo idc_cal_{i} > /sys/kernel/tracing/trace_marker && date +%s.%N && cat /proc/uptime"
        )
        lines = [x.strip() for x in text.strip().splitlines() if x.strip()]
        if len(lines) >= 2:
            bridge.append({"i": i, "realtime": float(lines[0]), "uptime": float(lines[1].split()[0])})
        time.sleep(0.2)
    up_at_dump = device_uptime()
    shell("hitrace --trace_dump -o /data/local/tmp/idc-cal.txt", timeout=120)
    shell("hitrace --trace_finish_nodump")
    local = SCRATCH / "cal.txt"
    run(["file", "recv", "/data/local/tmp/idc-cal.txt", str(local)], timeout=180)
    shell("rm -f /data/local/tmp/idc-cal.txt")
    markers = {}
    with open(local, errors="replace") as fh:
        for line in fh:
            if "idc_cal_" in line:
                m = TS_RE.search(line)
                k = re.search(r"idc_cal_(\d+)", line)
                if m and k:
                    markers[int(k.group(1))] = float(m.group(1))
    deltas = []
    for b in bridge:
        ts = markers.get(b["i"])
        if ts is not None:
            deltas.append({"i": b["i"], "realtime_minus_boot_s": b["realtime"] - ts})
    series = [d["realtime_minus_boot_s"] for d in deltas]
    out["bridge"] = {
        "markers_found": len(markers),
        "pairs": len(deltas),
        "realtime_minus_boot": {
            "median_s": round(statistics.median(series), 6) if series else None,
            "spread_ms": round((max(series) - min(series)) * 1000, 2) if series else None,
        },
        "trace_bytes": local.stat().st_size,
        "trace_sha256": hashlib.sha256(local.read_bytes()).hexdigest(),
        "device_uptime_at_dump": up_at_dump,
        "note": "spread bounds (marker-write .. date) skew + ftrace stamping jitter on-device",
    }
    print("bridge", out["bridge"])
    save("clocks.json", out)


def measure_hilog():
    t0 = time.perf_counter()
    p = subprocess.run([HDC, "-t", KEY, "shell", "hilog", "-x"], capture_output=True, text=True, timeout=120)
    ms = (time.perf_counter() - t0) * 1000.0
    lines = p.stdout.splitlines()
    ts_re = re.compile(r"^(\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})")
    first = next((m.group(1) for line in lines if (m := ts_re.match(line))), None)
    last = next((m.group(1) for line in reversed(lines) if (m := ts_re.match(line))), None)
    save(
        "hilog.json",
        {
            "drain_ms": round(ms, 1),
            "bytes": len(p.stdout),
            "lines": len(lines),
            "first_ts": first,
            "last_ts": last,
            "buffers": "app 512K / core 512K / init 64K / only_prerelease 512K (hilog -g)",
            "note": "coverage span under idle lock-screen load; content not stored (sensitive)",
        },
    )
    print("hilog span", first, "..", last, len(lines), "lines")


def measure_snapseries():
    cats = "graphic ace ohos"
    shell(f"hitrace --trace_begin --trace_clock boot {cats}")
    moments = []
    for i in range(8):
        time.sleep(1)
        up0 = device_uptime()
        ms, rc, _ = shell(f"snapshot_display -t jpeg -f /data/local/tmp/idc-s{i}.jpeg")
        moments.append({"i": i, "device_uptime_before": up0, "cmd_ms": round(ms, 1), "rc": rc})
        shell(f"rm -f /data/local/tmp/idc-s{i}.jpeg")
    shell("hitrace --trace_dump -o /data/local/tmp/idc-snap.txt", timeout=120)
    shell("hitrace --trace_finish_nodump")
    local = SCRATCH / "snap.txt"
    run(["file", "recv", "/data/local/tmp/idc-snap.txt", str(local)], timeout=180)
    shell("rm -f /data/local/tmp/idc-snap.txt")
    save(
        "snapseries.json",
        {
            "snapshots": moments,
            "trace_bytes": local.stat().st_size,
            "trace_sha256": hashlib.sha256(local.read_bytes()).hexdigest(),
            "note": "lock screen is mostly static; scroll-load perturbation needs an unlocked "
            "supervised window and is recorded as a residual in run.md",
        },
    )
    print("snapseries", [m["cmd_ms"] for m in moments])


CLI = str(Path(__file__).resolve().parents[7] / "Packages/ArkDeckKit/.build/debug/arkdeck")
TARGET = "TGT-1a62a0dbedd6"  # the connected 7.0.0.39 device (adopted 2026-08-22, binding r1)


def cli(args, timeout=920):
    t0 = time.perf_counter()
    p = subprocess.run([CLI] + args, capture_output=True, text=True, timeout=timeout)
    ms = (time.perf_counter() - t0) * 1000.0
    return ms, p.returncode, (p.stdout or "") + (p.stderr or "")


def measure_daemon():
    out = {"target": TARGET, "daemon": "production com.arkdeck.agentd (catalog be7b7361…, matches HEAD)"}
    # Tier 2: probe-shaped path (TraceRuntimeProbe: daemon-owned lowering, no journal/capability)
    samples, fails = [], 0
    for _ in range(20):
        ms, rc, text = cli(["trace", "probe", "--target", TARGET, "--json"])
        samples.append(ms)
        fails += 0 if rc == 0 else 1
    out["tier2_trace_probe"] = summarize(samples) | {"failures": fails}
    print("tier2_trace_probe", out["tier2_trace_probe"])
    # Tier 3a: read-only full job (observe.device@1, 6 steps, no mutation lane)
    obs_inputs = HERE / "inputs-observe.json"
    obs_inputs.write_text("{}\n")
    samples, fails = [], 0
    for _ in range(8):
        ms, rc, text = cli(
            ["job", "submit", "--target", TARGET, "--operation", "observe.device@1",
             "--inputs-file", str(obs_inputs), "--expected-binding-revision", "1", "--wait", "--json"]
        )
        samples.append(ms)
        ok = rc == 0 and '"succeeded"' in text
        fails += 0 if ok else 1
    out["tier3_observe_device_full_job"] = summarize(samples) | {"failures": fails}
    print("tier3_observe", out["tier3_observe_device_full_job"])
    # Tier 3b: mutating full job with the screenshot leg (deviceMutation, mutation lane,
    # capability consumption) — today's closest stand-in for "one tap as a full Job".
    cap_inputs = HERE / "inputs-screenshot.json"
    cap_inputs.write_text(
        json.dumps({"durationSeconds": 1, "captureHilog": False, "uiDump": False, "uiScreenshot": True}) + "\n"
    )
    samples, fails = [], 0
    for _ in range(6):
        ms, rc, text = cli(
            ["job", "submit", "--target", TARGET, "--operation", "capture.diagnostics@1",
             "--inputs-file", str(cap_inputs), "--expected-binding-revision", "1", "--wait", "--json"]
        )
        samples.append(ms)
        ok = rc == 0 and '"succeeded"' in text
        fails += 0 if ok else 1
    out["tier3_screenshot_mutating_full_job"] = summarize(samples) | {"failures": fails}
    print("tier3_screenshot", out["tier3_screenshot_mutating_full_job"])
    save("daemon-tiers.json", out)


if __name__ == "__main__":
    sub = sys.argv[1] if len(sys.argv) > 1 else ""
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 50
    {
        "latency": lambda: measure_latency(n),
        "hash": measure_hash,
        "ring": measure_ring,
        "clocks": measure_clocks,
        "hilog": measure_hilog,
        "snapseries": measure_snapseries,
        "daemon": measure_daemon,
    }.get(sub, lambda: sys.exit(__doc__))()
