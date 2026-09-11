#!/usr/bin/env python3
"""Run the bounded macOS Artifact read-owner fixture checks (no device operations)."""
from pathlib import Path
import subprocess
import sys

if sys.platform != "darwin":
    raise SystemExit("Artifact owner migration checks currently require macOS")
root = Path(__file__).resolve().parents[1]
for args in [
    ["cargo", "test", "-p", "arkdeck-hoststore", "--test", "artifact_read_owner"],
    ["cargo", "test", "-p", "arkdeck-platform", "--lib", "artifact_range_tests"],
    ["cargo", "test", "-p", "arkdeck-hoststore", "--lib", "artifact_date_tests"],
    ["cargo", "clippy", "-p", "arkdeck-hoststore", "--test", "artifact_read_owner", "--", "-D", "warnings"],
]:
    subprocess.run(args, cwd=root, check=True)
