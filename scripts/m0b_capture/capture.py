"""M0B controlled read-only HDC capture harness (CHG-2026-006 / TASK-M0B-001).

Human-operated. The Agent drafts this script; a human maintainer runs it against
the physical DAYU200. It enforces the closed read-only command allowlist from
design.md: the operator can only choose *which* allowlisted command to run, never
compose an arbitrary one. Every command is spawned with an argv array and never a
host shell. For each command it captures stdout and stderr as separate byte-exact
files, records exact argv, exit code and duration, computes per-stream SHA-256,
runs a sensitive-content self-check (user paths / key material must never appear),
and writes both a full manifest and a redacted manifest (hashes + counts, with the
operator home path and the device connectkey masked) suitable for the repo run.md.

Safety properties enforced here (not just documented):
  * closed allowlist — no code path runs an operator-supplied command string;
  * no shell — subprocess argv arrays only, never a host shell;
  * output must live OUTSIDE any git repository, so serial-bearing bytes never
    land in the ArkDeck tree;
  * read-only — the allowlist contains no install/uninstall/file/reboot/tmode/
    kill/start/flash verb; the only device-state change (on-device trust) is a
    human action outside this script.

This script only performs discovery/authorization/toolchain/hidumper-probe capture.
It makes no support or compatibility claim and its output supports at most an
`observed` hardware-matrix row.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
from typing import Callable, Optional

MANIFEST_SCHEMA = "arkdeck-m0b-capture-manifest-1.0.0"
REDACTED_SCHEMA = "arkdeck-m0b-capture-redacted-1.0.0"

# Per-stream retained-capture bound. Read-only probes are small; this only guards
# against an unexpectedly large stream, and a truncation is recorded, not silent.
MAX_STREAM_BYTES = 4 * 1_024 * 1_024
DEFAULT_TIMEOUT_SECONDS = 60


@dataclasses.dataclass(frozen=True)
class CommandSpec:
    """A single allowlisted read-only command. ``tokens`` are FIXED; the only
    operator-supplied value is the optional target connectkey, inserted only in
    the fixed ``-t <connectkey>`` slot before the subcommand when ``needs_target``."""

    ident: str
    tokens: tuple[str, ...]
    needs_target: bool
    purpose: str


# Closed allowlist (design.md "Read-only command allowlist"). No entry mutates
# device or host state. To change this set, amend design.md and this change first.
COMMAND_SPECS: tuple[CommandSpec, ...] = (
    CommandSpec("hdc-version-flag", ("-v",), False, "hdc client version"),
    CommandSpec("hdc-version-word", ("version",), False, "hdc client version (word form)"),
    CommandSpec("hdc-checkserver", ("checkserver",), False, "hdc server/daemon version"),
    CommandSpec("hdc-list-targets", ("list", "targets"), False, "device discovery"),
    CommandSpec(
        "hdc-list-targets-verbose", ("list", "targets", "-v"), False,
        "device discovery with detail"),
    CommandSpec(
        "hidumper-help", ("shell", "hidumper", "--help"), True,
        "read-only hidumper usage for the ui-dump wrapper facts"),
    CommandSpec(
        "hidumper-services", ("shell", "hidumper", "-ls"), True,
        "read-only hidumper service list for the ui-dump wrapper facts"),
)

SPECS_BY_ID = {spec.ident: spec for spec in COMMAND_SPECS}


class CaptureError(Exception):
    """A harness/usage error that is not a captured command failure."""


# --- runner injection (tests pass a fake; production spawns hdc) --------------

CommandResult = tuple[int, bytes, bytes, int]
Runner = Callable[[list[str], int], CommandResult]


def subprocess_runner(argv: list[str], timeout: int) -> CommandResult:
    started = _monotonic_ms()
    try:
        completed = subprocess.run(  # noqa: S603 - argv array, never shell
            argv, capture_output=True, timeout=timeout, check=False)
        return (
            completed.returncode,
            completed.stdout[:MAX_STREAM_BYTES],
            completed.stderr[:MAX_STREAM_BYTES],
            _monotonic_ms() - started,
        )
    except subprocess.TimeoutExpired as expired:
        out = (expired.stdout or b"")[:MAX_STREAM_BYTES]
        err = (expired.stderr or b"")[:MAX_STREAM_BYTES]
        return (-1, out, err, _monotonic_ms() - started)


def _monotonic_ms() -> int:
    import time

    return int(time.monotonic() * 1_000)


# --- argv construction (the only place a command line is built) ---------------


def build_argv(hdc_path: str, spec: CommandSpec, target: Optional[str]) -> list[str]:
    """Compose the argv for one allowlisted spec. The connectkey is placed only in
    the fixed pre-subcommand ``-t`` slot; it is never concatenated into a token."""
    if spec.ident not in SPECS_BY_ID:
        raise CaptureError(f"refusing command outside the closed allowlist: {spec.ident}")
    argv = [hdc_path]
    if spec.needs_target and target:
        argv += ["-t", target]
    argv += list(spec.tokens)
    return argv


# --- sensitive-content self-check ---------------------------------------------

_USER_PATH = re.compile(rb"/Users/[^/\s\x00]+/")
_USER_PATH_STR = re.compile(r"/Users/[^/\s]+/")
_KEY_MARKERS = (
    b"-----BEGIN",
    b"PRIVATE KEY",
    b"ssh-rsa ",
    b"ssh-ed25519 ",
    b"PuTTY-User-Key",
)


def self_check(stream_bytes: bytes, connectkey: Optional[str]) -> dict:
    """Sensitive-content gate. User paths and key material MUST NOT appear in
    captured output and fail the check. A device connectkey/serial MAY appear
    (it is device identity, kept only in the controlled location); its presence
    is recorded, not failed."""
    user_path = bool(_USER_PATH.search(stream_bytes))
    key_material = any(marker in stream_bytes for marker in _KEY_MARKERS)
    serial_present = bool(connectkey) and connectkey.encode("utf-8") in stream_bytes
    return {
        "userPathFound": user_path,
        "keyMaterialFound": key_material,
        "serialPresent": serial_present,
        "passed": not user_path and not key_material,
    }


# --- redaction helpers for the repo-safe manifest -----------------------------


def _mask_home(text: str, home: str) -> str:
    masked = text.replace(home.rstrip("/"), "~") if home else text
    return _USER_PATH_STR.sub("/Users/<redacted>/", masked)


def _mask_connectkey(argv: list[str], connectkey: Optional[str]) -> list[str]:
    if not connectkey:
        return list(argv)
    token = "<connectkey:%s>" % hashlib.sha256(connectkey.encode("utf-8")).hexdigest()[:12]
    return [token if part == connectkey else part for part in argv]


# --- output-location safety ---------------------------------------------------


def assert_outside_repository(path: str) -> None:
    """Refuse to write capture output anywhere inside a git working tree, so
    serial-bearing bytes cannot land in the ArkDeck repository."""
    current = os.path.abspath(path)
    while True:
        if os.path.exists(os.path.join(current, ".git")):
            raise CaptureError(
                "refusing to write captures inside a git repository "
                f"(.git found at {current}); choose a controlled location outside any repo")
        parent = os.path.dirname(current)
        if parent == current:
            return
        current = parent


# --- capture pipeline ---------------------------------------------------------


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _write_stream(out_dir: str, name: str, data: bytes) -> None:
    target = os.path.join(out_dir, name)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(target, flags, 0o600)
    try:
        os.write(descriptor, data)
    finally:
        os.close(descriptor)


def capture(
    hdc_path: str,
    out_dir: str,
    selected: list[CommandSpec],
    target: Optional[str],
    runner: Runner = subprocess_runner,
    timeout: int = DEFAULT_TIMEOUT_SECONDS,
    home: Optional[str] = None,
) -> dict:
    """Run each selected allowlisted spec, capture per stream, and return the full
    manifest dict. Writes per-stream files and both manifests into ``out_dir``."""
    assert_outside_repository(out_dir)
    home = home if home is not None else os.path.expanduser("~")

    resolved_hdc = os.path.abspath(hdc_path)
    if not os.path.isfile(resolved_hdc) or not os.access(resolved_hdc, os.X_OK):
        raise CaptureError(f"hdc binary is not an executable regular file: {resolved_hdc}")
    with open(resolved_hdc, "rb") as handle:
        hdc_sha256 = _sha256(handle.read())

    os.makedirs(out_dir, exist_ok=True)
    results: list[dict] = []
    overall_self_check_passed = True

    for index, spec in enumerate(selected):
        argv = build_argv(resolved_hdc, spec, target)
        exit_code, stdout, stderr, duration_ms = runner(argv, timeout)
        stdout_name = f"{index:02d}-{spec.ident}.stdout"
        stderr_name = f"{index:02d}-{spec.ident}.stderr"
        _write_stream(out_dir, stdout_name, stdout)
        _write_stream(out_dir, stderr_name, stderr)

        stdout_check = self_check(stdout, target)
        stderr_check = self_check(stderr, target)
        command_passed = stdout_check["passed"] and stderr_check["passed"]
        overall_self_check_passed = overall_self_check_passed and command_passed

        results.append(
            {
                "commandId": spec.ident,
                "purpose": spec.purpose,
                "argv": argv,
                "exitCode": exit_code,
                "timedOut": exit_code == -1,
                "durationMs": duration_ms,
                "stdout": {
                    "file": stdout_name, "sha256": _sha256(stdout), "bytes": len(stdout),
                    "truncated": len(stdout) >= MAX_STREAM_BYTES,
                },
                "stderr": {
                    "file": stderr_name, "sha256": _sha256(stderr), "bytes": len(stderr),
                    "truncated": len(stderr) >= MAX_STREAM_BYTES,
                },
                "selfCheck": {
                    "stdout": stdout_check, "stderr": stderr_check, "passed": command_passed,
                },
            }
        )

    manifest = {
        "schema": MANIFEST_SCHEMA,
        "change": "CHG-2026-006-dayu200-m0b-bringup",
        "task": "TASK-M0B-001",
        "evidenceClass": "realHardware",
        "toolchain": {
            "hdcPath": resolved_hdc,
            "hdcSha256": hdc_sha256,
            "transport": "usb",
        },
        "host": {
            "os": "macOS",
            "osVersion": platform.mac_ver()[0],
            "arch": platform.machine(),
        },
        "targetConnectkeyProvided": bool(target),
        "commands": results,
        "selfCheckPassed": overall_self_check_passed,
        "boundary": (
            "read-only capture; observed-only; not a support/compatibility claim; "
            "serial-bearing bytes remain in this controlled non-repository location; "
            "no capture is registered as a repository golden fixture by this change"),
    }
    redacted = _redacted_manifest(manifest, home, target)

    _write_json(out_dir, "manifest.json", manifest)
    _write_json(out_dir, "redacted-manifest.json", redacted)
    return manifest


def _redacted_manifest(manifest: dict, home: str, target: Optional[str]) -> dict:
    redacted_commands = []
    for command in manifest["commands"]:
        masked_argv = [_mask_home(part, home) for part in _mask_connectkey(command["argv"], target)]
        redacted_commands.append(
            {
                "commandId": command["commandId"],
                "purpose": command["purpose"],
                "argv": masked_argv,
                "exitCode": command["exitCode"],
                "timedOut": command["timedOut"],
                "durationMs": command["durationMs"],
                "stdout": command["stdout"],
                "stderr": command["stderr"],
                "selfCheck": command["selfCheck"],
            }
        )
    return {
        "schema": REDACTED_SCHEMA,
        "change": manifest["change"],
        "task": manifest["task"],
        "evidenceClass": manifest["evidenceClass"],
        "toolchain": {
            "hdcPath": _mask_home(manifest["toolchain"]["hdcPath"], home),
            "hdcSha256": manifest["toolchain"]["hdcSha256"],
            "transport": manifest["toolchain"]["transport"],
        },
        "host": manifest["host"],
        "targetConnectkeyProvided": manifest["targetConnectkeyProvided"],
        "commands": redacted_commands,
        "selfCheckPassed": manifest["selfCheckPassed"],
        "boundary": manifest["boundary"],
    }


def _write_json(out_dir: str, name: str, document: dict) -> None:
    payload = (json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(
        "utf-8")
    _write_stream(out_dir, name, payload)


# --- CLI ----------------------------------------------------------------------


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="capture.py",
        description="M0B controlled read-only HDC capture (human-operated).")
    parser.add_argument("--hdc", required=True, help="absolute path to the hdc binary")
    parser.add_argument(
        "--out-dir", required=True,
        help="controlled output directory OUTSIDE any git repository")
    parser.add_argument(
        "--target", default=None,
        help="optional device connectkey for hidumper shell probes (kept only in "
        "the controlled output; masked in the redacted manifest)")
    parser.add_argument(
        "--commands", default="all",
        help="comma-separated command ids, or 'all' (default). "
        f"ids: {', '.join(SPECS_BY_ID)}")
    parser.add_argument(
        "--timeout", type=int, default=DEFAULT_TIMEOUT_SECONDS,
        help="per-command timeout in seconds")
    return parser


def _select(commands: str) -> list[CommandSpec]:
    if commands.strip() == "all":
        return list(COMMAND_SPECS)
    selected: list[CommandSpec] = []
    for ident in (part.strip() for part in commands.split(",") if part.strip()):
        spec = SPECS_BY_ID.get(ident)
        if spec is None:
            raise CaptureError(f"unknown command id (outside allowlist): {ident}")
        selected.append(spec)
    if not selected:
        raise CaptureError("no commands selected")
    return selected


def main(argv: Optional[list[str]] = None) -> int:
    arguments = build_arg_parser().parse_args(argv)
    try:
        selected = _select(arguments.commands)
        manifest = capture(
            hdc_path=arguments.hdc, out_dir=arguments.out_dir, selected=selected,
            target=arguments.target, timeout=arguments.timeout)
    except CaptureError as error:
        print(f"capture error: {error}", file=sys.stderr)
        return 2
    ok = manifest["selfCheckPassed"]
    print(
        "capture complete:",
        f"{len(manifest['commands'])} commands,",
        "self-check PASSED" if ok else "self-check FAILED (user path or key material found)")
    print("full manifest + per-stream files:", os.path.abspath(arguments.out_dir))
    if not ok:
        print(
            "WARNING: sensitive content found in captured output; do not copy raw bytes "
            "into the repository — investigate before drafting evidence.",
            file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
