#!/usr/bin/env python3
"""Run directories of the isolated host checks under /private/tmp.

Each isolated host check (`check-*-register.py`, `check-*-list.py`,
`check-*-retirement.py`) starts real daemons in one fresh private directory and
keeps their logs, frames and reports there. A passing run removes it; a failed
run keeps it and names it on stderr so the logs can be read; `--keep-run-dir`
keeps a passing one too, for example to read a retained registry back natively.
The check scripts load this module by file name, as they load one another.
"""
from __future__ import annotations
import argparse
from pathlib import Path
import shutil
import sys
import tempfile

PARENT = "/private/tmp"


def add_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--keep-run-dir", action="store_true",
                        help="keep the run directory after a passing run; a failed run always keeps it")


class RunDirectory:
    """One check's private run directory; `passed` decides whether it survives the run."""

    def __init__(self, prefix: str, keep: bool = False, parent: str | Path = PARENT):
        self.path = Path(tempfile.mkdtemp(prefix=prefix, dir=str(parent))).resolve()
        self.keep = keep
        self.passed = False

    def __enter__(self) -> RunDirectory:
        return self

    def __exit__(self, kind, error, traceback) -> bool:
        if kind is None and self.passed and not self.keep:
            shutil.rmtree(self.path)
        else:
            reason = "kept by --keep-run-dir" if kind is None and self.passed else "retained after a failed run"
            print(f"run directory {reason}: {self.path}", file=sys.stderr, flush=True)
        return False
