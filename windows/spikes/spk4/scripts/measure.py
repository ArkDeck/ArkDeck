#!/usr/bin/env python3
"""SPK-4 measurement driver (design §H.4 (a)-(c), (e) partial). Standard library only.

Runs, in order, and writes everything under --out:
  1. the in-app benchmark (`ArkDeck.Spk4.exe --bench DIR`) --bench-runs times;
  2. `ArkDeck.Spk4.Probe startup` against the unpackaged exe and, with --aumid, the
     registered package;
  3. `ArkDeck.Spk4.Probe uia` against the same targets;
then prints a summary (also saved as summary.json).

Needs an interactive desktop session. The keyboard step of `uia` additionally needs an
unlocked session (SendInput). Every process is started by this script or the probe, and the
probe closes or kills only the processes it launched.

Example (from windows/spikes/spk4):
  python scripts/measure.py --exe out/unpackaged-x64/ArkDeck.Spk4.exe \
      --probe ArkDeck.Spk4.Probe/bin/Release/net10.0-windows10.0.26100.0/win-x64/ArkDeck.Spk4.Probe.exe \
      --aumid ArkDeck.Spk4_jj88tn1d1ahgg!App --out out/run
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path


def bench(exe: Path, runs: int, out: Path) -> list[dict]:
    results = []
    for i in range(runs):
        d = out / f"bench-{i + 1:02d}"
        d.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(exe), "--bench", str(d.resolve())], timeout=240, check=True)
        files = sorted(d.glob("bench-*.json"))
        if not files:
            raise SystemExit(f"bench run {i + 1}: no JSON written")
        results.append(json.loads(files[-1].read_text(encoding="utf-8")))
        time.sleep(2)
    return results


def probe(probe_exe: Path, command: str, target: list[str], out_file: Path, extra: list[str]) -> dict:
    subprocess.run([str(probe_exe), command, *target, "--out", str(out_file.resolve()), *extra],
                   timeout=900, check=True, stdout=subprocess.DEVNULL)
    return json.loads(out_file.read_text(encoding="utf-8"))


def summarize_bench(runs: list[dict]) -> dict:
    summary: dict = {"runs": len(runs), "firstFrameMs": [r["firstFrameMs"] for r in runs]}
    for surface in ("history", "viewer"):
        s: dict = {}
        for key in ("generateMs", "bindToRowsOnScreenMs", "navigateToRowsOnScreenMs"):
            s[key] = [r[surface][key] for r in runs]
        if surface == "viewer":
            s["treeViewNodeBuildMs"] = [r[surface].get("treeViewNodeBuildMs") for r in runs]
        for mode in ("steadyScroll", "pageJumpScroll"):
            p95 = [r[surface][mode]["p95Ms"] for r in runs]
            s[mode] = {
                "p50Ms": [r[surface][mode]["p50Ms"] for r in runs],
                "p95Ms": p95,
                "p99Ms": [r[surface][mode]["p99Ms"] for r in runs],
                "maxMs": [r[surface][mode]["maxMs"] for r in runs],
                "over33": [r[surface][mode]["over33Ms"] for r in runs],
                "over100": [r[surface][mode]["over100Ms"] for r in runs],
                "worstRunP95Ms": max(p95),
                "passesH4a": max(p95) <= 33.0,
            }
        s["workingSetAfterScrollMiB"] = [r[surface]["memoryAfterScroll"]["workingSetMiB"] for r in runs]
        s["privateAfterScrollMiB"] = [r[surface]["memoryAfterScroll"]["privateMiB"] for r in runs]
        summary[surface] = s
    summary["medianFirstFrameMs"] = statistics.median(summary["firstFrameMs"])
    return summary


def main() -> int:
    ap = argparse.ArgumentParser(description="SPK-4 measurement driver")
    ap.add_argument("--exe", type=Path, required=True, help="unpackaged ArkDeck.Spk4.exe")
    ap.add_argument("--probe", type=Path, required=True, help="ArkDeck.Spk4.Probe.exe")
    ap.add_argument("--aumid", help="AUMID of the registered package (PackageFamilyName!App)")
    ap.add_argument("--bench-runs", type=int, default=5)
    ap.add_argument("--startup-runs", type=int, default=10)
    ap.add_argument("--skip-bench", action="store_true")
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)

    summary: dict = {}
    if not a.skip_bench:
        summary["bench"] = summarize_bench(bench(a.exe, a.bench_runs, a.out))
    targets = [("unpackaged", ["--exe", str(a.exe.resolve())])]
    if a.aumid:
        targets.append(("packaged", ["--aumid", a.aumid]))
    for name, target in targets:
        st = probe(a.probe, "startup", target, a.out / f"startup-{name}.json", ["--runs", str(a.startup_runs)])
        summary[f"startup-{name}"] = {k: st[k] for k in ("runs", "medianMs", "p95Ms", "maxMs", "passesH4b")}
        summary[f"startup-{name}"]["samplesMs"] = [s["launchToNavInteractiveMs"] for s in st["samples"]]
        uia = probe(a.probe, "uia", target, a.out / f"uia-{name}.json", [])
        summary[f"uia-{name}"] = {
            "navigation": [(n["automationId"], n["name"], n["controlType"], n["selectionItem"]) for n in uia["navigation"]],
            "liveRegionEvents": uia["jobLiveRegion"]["liveRegionChangedEvents"],
            "liveSetting": uia["jobLiveRegion"]["liveSetting"],
            "keyboard": uia["keyboard"],
            "visibleDisabledButtons": uia["visibleDisabledButtons"],
            "layout": {p["nav"]: p["layout"] for p in uia["pages"]},
            "accessibilitySettings": uia["accessibilitySettings"],
        }
    (a.out / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
