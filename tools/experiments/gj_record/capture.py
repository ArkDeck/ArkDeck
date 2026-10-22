"""Run one published `arkdeck` command and keep what it printed.

Each call appends one line to `<out>/journal.jsonl` and writes the command's
stdout, byte for byte, to `<out>/<sequence>-<step>.json`. The journal holds
what stdout alone cannot: the exit code, the order, the CLI image that ran and
when. Nothing here interprets the output; `assemble` does.

A CREATE_NEW lock covers sequence allocation, command execution and committed
output. Only a completed capture removes its own lock. An exception or process
crash leaves it in place: a later caller refuses before running, without stale
PID/age recovery. Continue uncertain work in a fresh capture root, retaining the
original bytes and lock; never replay a command to repair a capture.

The raw outputs carry serials, connect keys and paths. They stay in `<out>`,
which must lie outside the repository; only the assembled record is redacted
for committing.
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import json
import os
import platform
import re
import stat
import subprocess
import sys
from pathlib import Path

JOURNAL = "journal.jsonl"
LOCK = ".capture.lock"
ENTRY_SCHEMA = "arkdeck.gj-capture/1"
_STEP = re.compile(r"^[a-z0-9][a-z0-9.-]{0,63}$")


class CaptureError(Exception):
    pass


class _CaptureGuard:
    """Persistent exclusive ownership, never automatically reclaimed on error."""

    def __init__(self, out: Path):
        self.path = out / LOCK
        self.bytes = json.dumps({
            "schemaVersion": "arkdeck.gj-capture-lock/1",
            "token": os.urandom(32).hex(),
            "createdAtUtc": utc_now(),
        }, sort_keys=True).encode("utf-8") + b"\n"
        try:
            handle = self.path.open("xb")
        except FileExistsError as error:
            raise CaptureError("capture is active or unfinished; no command was run; "
                               "retain this root and use a fresh root") from error
        # Even failure while writing the lock retains its exclusive name.
        with handle:
            handle.write(self.bytes)
            handle.flush()
            os.fsync(handle.fileno())
            metadata = os.fstat(handle.fileno())
            self.identity = (metadata.st_dev, metadata.st_ino)

    def release(self):
        # Never unlink a substituted lock, even after our capture committed.
        metadata = self.path.lstat()
        if (not stat.S_ISREG(metadata.st_mode)
                or getattr(metadata, "st_file_attributes", 0) & 0x400
                or metadata.st_nlink != 1
                or (metadata.st_dev, metadata.st_ino) != self.identity
                or self.path.read_bytes() != self.bytes):
            raise CaptureError("capture lock changed; retain this root; no lock was removed")
        self.path.unlink()


def utc_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        return False
    return True


def _output_mode(arguments: list[str]) -> str:
    for index, token in enumerate(arguments):
        if token == "--output" and index + 1 < len(arguments):
            return arguments[index + 1]
        if token.startswith("--output="):
            return token.split("=", 1)[1]
    return ""


def read_journal(out: Path) -> list[dict]:
    path = out / JOURNAL
    if not path.exists():
        return []
    entries = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        entry = json.loads(line)
        if entry.get("schemaVersion") != ENTRY_SCHEMA or entry.get("sequence") != number:
            raise CaptureError(f"{path}:{number} is not entry {number} of a capture journal")
        entries.append(entry)
    return entries


def host_facts() -> dict:
    facts = {"system": platform.system(), "release": platform.release(), "version": platform.version()}
    return facts


def capture(
    out: Path,
    step: str,
    command: list[str],
    *,
    repository: Path,
    quiet: bool = False,
    timeout: float | None = None,
    runner=subprocess.run,
) -> dict:
    """Run `command` (the `arkdeck` executable and its arguments)."""
    if not _STEP.match(step):
        raise CaptureError(f"step {step!r} must match {_STEP.pattern}")
    if not command:
        raise CaptureError("no command to run")
    if _output_mode(command[1:]) not in ("json", "jsonl"):
        raise CaptureError("the command must carry --output json or --output jsonl")
    if _inside(out, repository):
        raise CaptureError(f"{out} is inside the repository; raw outputs must stay outside it")
    executable = Path(command[0])
    if not executable.is_file():
        raise CaptureError(f"{command[0]} is not a file; give the arkdeck executable's path")
    out.mkdir(parents=True, exist_ok=True)
    guard = _CaptureGuard(out)
    sequence = len(read_journal(out)) + 1
    stdout_name = f"{sequence:04d}-{step}.json"
    try:
        output = (out / stdout_name).open("xb")
    except FileExistsError as error:
        raise CaptureError("capture stdout already exists; no command was run; "
                           "existing bytes and the lock were retained") from error
    # Reserve stdout before dispatch, so an old/orphan file cannot be overwritten.
    # Exceptions close only the handle; they retain both names and never unlock.
    with output:
        started = utc_now()
        completed = runner(
            [str(executable), *command[1:]],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=None,
            timeout=timeout,
            check=False,
        )
        finished = utc_now()
        stdout = completed.stdout or b""
        output.write(stdout)
        output.flush()
        os.fsync(output.fileno())
    entry = {
        "schemaVersion": ENTRY_SCHEMA,
        "sequence": sequence,
        "step": step,
        "arguments": list(command[1:]),
        "cliExecutableSHA256": sha256_file(executable),
        "exitCode": completed.returncode,
        "startedAtUtc": started,
        "finishedAtUtc": finished,
        "stdoutFile": stdout_name,
        "stdoutSHA256": hashlib.sha256(stdout).hexdigest(),
        "host": host_facts(),
    }
    entry.update(_daemon_image(stdout))
    with open(out / JOURNAL, "a", encoding="utf-8", newline="\n") as journal:
        journal.write(json.dumps(entry, sort_keys=True) + "\n")
        journal.flush()
        os.fsync(journal.fileno())
    guard.release()
    if not quiet:
        sys.stdout.buffer.write(stdout)
        sys.stdout.flush()
    print(
        f"gj_record: #{sequence} {step} exit {completed.returncode}"
        + (" (stdout kept in the journal only)" if quiet else ""),
        file=sys.stderr,
    )
    return entry


def _daemon_image(stdout: bytes) -> dict:
    """On Windows `runtime service status` names the installed daemon by path
    only, with no digest, so the image it names is hashed now, while it is the
    one that answered. (macOS prints `launchAgent.daemonSHA256` itself.)"""
    try:
        envelope = json.loads(stdout)
    except ValueError:
        return {}
    if not isinstance(envelope, dict) or envelope.get("command") != "runtime.service.status":
        return {}
    result = envelope.get("result")
    service = result.get("daemonService") if isinstance(result, dict) else None
    path = service.get("daemonPath") if isinstance(service, dict) else None
    if not isinstance(path, str) or not os.path.isfile(path):
        return {"daemonImageSHA256": None}
    return {"daemonImageSHA256": sha256_file(Path(path))}
