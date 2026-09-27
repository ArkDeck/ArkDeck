#!/usr/bin/env python3
"""Carrier failure-path checks; no arkforged, Swift build, or device access."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "spk9", Path(__file__).with_name("run-spk9-preview-missing.py"))
carrier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(carrier)


class CarrierTests(unittest.TestCase):
    def test_snapshot_detects_changed_bytes_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / "journal"
            file.write_bytes(b"before")
            before = carrier.snapshot(root)
            file.write_bytes(b"after!")
            self.assertNotEqual(before, carrier.snapshot(root))
            (root / "link").symlink_to(file)
            with self.assertRaisesRegex(RuntimeError, "file type"):
                carrier.snapshot(root)

    def test_ambiguous_executable_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "build.log"
            log.write_text("\n".join(json.dumps({
                "reason": "compiler-artifact", "target": {"name": "probe", "kind": ["test"]},
                "executable": str(Path(directory) / name),
            }) for name in ("one", "two")))
            with self.assertRaisesRegex(RuntimeError, "expected one"):
                carrier.artifact(log, "probe", "test")

    def test_deadline_reaps_the_child(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pidfile = root / "pid"
            code = "import os,time,pathlib; pathlib.Path(__import__('sys').argv[1]).write_text(str(os.getpid())); time.sleep(30)"
            with self.assertRaises(subprocess.TimeoutExpired):
                carrier.run([sys.executable, "-c", code, str(pidfile)],
                            root / "child.log", dict(os.environ), timeout=1)
            pid = int(pidfile.read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)


if __name__ == "__main__":
    unittest.main()
