"""M0B controlled read-only HDC capture harness (CHG-2026-006 / TASK-M0B-001).

Human-operated. The Agent drafts this script; a human maintainer runs it against
the physical DAYU200. It enforces the closed read-only command allowlist from
design.md: the operator can only choose *which* allowlisted command to run, never
compose an arbitrary one. Every command is spawned with an argv array and never a
host shell. For each command it captures stdout and stderr as separate byte-exact
files (per-stream retained bytes are capped at ``MAX_STREAM_BYTES``; overflow is
drained, counted and recorded truthfully in the ``truncated`` flag), records
exact argv, verbatim exit code, timeout state and duration, computes per-stream
SHA-256, runs a sensitive-content self-check (user paths / key material must
never appear), and writes both a full manifest and a redacted manifest (hashes +
counts, with the operator home path and the device connectkey masked) suitable
for the repo run.md. The redacted manifest additionally passes a final
output-side gate: if any sensitive value survives masking, the redacted manifest
is NOT written and the run fails loudly.

Safety properties enforced here (not just documented):
  * closed allowlist — argv is built only from a spec that IS the registered
    allowlist entry (identity check, not name check); no code path runs an
    operator-composed command string. The ``--hdc`` binary itself is trusted
    operator input: the arguments are closed, the executable is the operator's
    responsibility, and its SHA-256 is recorded for the evidence chain;
  * no shell — subprocess argv arrays only, never a host shell (asserted by an
    AST check in the tests, not a substring match);
  * output must live OUTSIDE any git repository — checked on the
    symlink-resolved real path, so serial-bearing bytes never land in the
    ArkDeck tree even through a symlinked out-dir;
  * read-only — the allowlist contains no install/uninstall/file/reboot/tmode/
    kill/start/flash verb; the only device-state change (on-device trust) is a
    human action outside this script.

This script only performs discovery/authorization/toolchain/hidumper-probe
capture. It makes no support or compatibility claim. Manifests are labeled
``controlledHumanCapture``: the ``realHardware`` classification of record can
only be made by the human-attested hardware-evidence record, never by this tool.
Its output supports at most an ``observed`` hardware-matrix row.

Exit codes: 0 = capture ok and self-check passed; 1 = capture ran but the
sensitive-content self-check failed; 2 = usage or harness error (including a
refused output location, an existing output file, an unexecutable hdc binary,
or a failed redaction gate).
"""

from __future__ import annotations

import argparse
import copy
import dataclasses
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import threading
import time
from typing import Callable, Optional

MANIFEST_SCHEMA = "arkdeck-m0b-capture-manifest-1.0.0"
REDACTED_SCHEMA = "arkdeck-m0b-capture-redacted-1.0.0"

# Per-stream retained-capture bound: at most this many bytes per stream are kept
# in memory and written to disk. The remainder of an oversized stream is still
# drained (so the child never blocks on a full pipe) and counted, and the
# overflow is recorded truthfully in the per-stream ``truncated`` flag.
MAX_STREAM_BYTES = 4 * 1_024 * 1_024
DEFAULT_TIMEOUT_SECONDS = 60

# After the client process exits, keep draining its pipes at most this long.
# hdc's first invocation forks a background host server that can inherit the
# pipe write-ends; without this cutoff the capture would stall until the full
# timeout even though the client already exited successfully.
PIPE_DRAIN_GRACE_SECONDS = 2.0


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


@dataclasses.dataclass(frozen=True)
class RunnerResult:
    """Outcome of one spawned command. ``exit_code`` is the verbatim subprocess
    returncode (negative = killed by that signal number) and is None when the
    harness timeout fired: timeout has its own channel and never masquerades as
    an exit code."""

    exit_code: Optional[int]
    timed_out: bool
    stdout: bytes
    stderr: bytes
    stdout_truncated: bool
    stderr_truncated: bool
    duration_ms: int


Runner = Callable[[list[str], int], RunnerResult]


def _drain_pipe(stream, sink: dict) -> None:
    """Read ``stream`` to EOF, retaining at most MAX_STREAM_BYTES but counting
    everything. ``read1`` returns whatever is available per call, so bytes the
    client wrote are captured even if a forked daemon keeps the pipe open."""
    try:
        while True:
            chunk = stream.read1(65536)
            if not chunk:
                return
            if sink["kept"] < MAX_STREAM_BYTES:
                take = chunk[: MAX_STREAM_BYTES - sink["kept"]]
                sink["chunks"].append(take)
                sink["kept"] += len(take)
            sink["total"] += len(chunk)
    except ValueError:
        return  # stream closed underneath us during teardown


def subprocess_runner(argv: list[str], timeout: int) -> RunnerResult:
    started = time.monotonic()
    process = subprocess.Popen(  # noqa: S603 - argv array, never shell
        argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL)
    sinks: dict[str, dict] = {}
    readers: list[tuple[threading.Thread, object]] = []
    for name, stream in (("stdout", process.stdout), ("stderr", process.stderr)):
        sink = {"chunks": [], "kept": 0, "total": 0}
        reader = threading.Thread(target=_drain_pipe, args=(stream, sink), daemon=True)
        reader.start()
        sinks[name] = sink
        readers.append((reader, stream))
    timed_out = False
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        process.kill()
        process.wait()
    drain_deadline = time.monotonic() + PIPE_DRAIN_GRACE_SECONDS
    for reader, stream in readers:
        reader.join(timeout=max(0.0, drain_deadline - time.monotonic()))
        if not reader.is_alive():
            stream.close()
        # else: a forked daemon still holds the pipe write-end; leave the fd to
        # the lingering daemon reader thread rather than yanking it mid-read.
    return RunnerResult(
        exit_code=None if timed_out else process.returncode,
        timed_out=timed_out,
        stdout=b"".join(sinks["stdout"]["chunks"]),
        stderr=b"".join(sinks["stderr"]["chunks"]),
        stdout_truncated=sinks["stdout"]["total"] > MAX_STREAM_BYTES,
        stderr_truncated=sinks["stderr"]["total"] > MAX_STREAM_BYTES,
        duration_ms=int((time.monotonic() - started) * 1_000),
    )


# --- argv construction (the only place a command line is built) ---------------


def build_argv(hdc_path: str, spec: CommandSpec, target: Optional[str]) -> list[str]:
    """Compose the argv for one allowlisted spec. The spec must BE the registered
    allowlist object (identity, not name): a look-alike carrying a known ident
    with different tokens is refused. The connectkey is placed only in the fixed
    pre-subcommand ``-t`` slot; it is never concatenated into a token."""
    if SPECS_BY_ID.get(spec.ident) is not spec:
        raise CaptureError(f"refusing command outside the closed allowlist: {spec.ident}")
    argv = [hdc_path]
    if spec.needs_target and target:
        argv += ["-t", target]
    argv += list(spec.tokens)
    return argv


# --- sensitive-content self-check ---------------------------------------------

# One pattern literal, compiled for both bytes (self-check) and str (redaction),
# so the two can never drift. No trailing-slash requirement: a bare home path at
# end of line ("HOME=/Users/alice") must be caught too. ``:`` is excluded from
# the name class so redaction does not eat message punctuation, and /home and
# /var/root are covered alongside macOS /Users.
_USER_PATH_PATTERN = r"/(?:Users|home)/[^/\s\x00:]+|/var/root"
_USER_PATH = re.compile(_USER_PATH_PATTERN.encode("ascii"))
_USER_PATH_STR = re.compile(_USER_PATH_PATTERN)
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
    is recorded, not failed. ``serialPresent`` is True/False only when a
    connectkey was supplied; on discovery runs (no ``--target``) it is None —
    the connectkey is not yet known, and discovery output must be presumed
    serial-bearing."""
    user_path = bool(_USER_PATH.search(stream_bytes))
    key_material = any(marker in stream_bytes for marker in _KEY_MARKERS)
    serial_present = (
        connectkey.encode("utf-8") in stream_bytes if connectkey else None)
    return {
        "userPathFound": user_path,
        "keyMaterialFound": key_material,
        "serialPresent": serial_present,
        "passed": not user_path and not key_material,
    }


# --- redaction helpers for the repo-safe manifest -----------------------------

_REDACTED_CONNECTKEY = "<connectkey>"
_REDACTED_USER_DIR = "<redacted-user-dir>"


def _home_pattern(home: str) -> Optional[re.Pattern]:
    """Segment-anchored, case-insensitive matcher for the operator home path.
    Anchoring prevents '/Users/tester' from eating into '/Users/tester2';
    IGNORECASE covers macOS's case-insensitive filesystem (an operator may type
    '/users/...' and the path still resolves). Returns None when the home
    root is empty (e.g. HOME=/), which must disable the replacement instead of
    degenerating into an empty-needle substitution."""
    root = home.rstrip("/") if home else ""
    if not root:
        return None
    return re.compile(re.escape(root) + r'(?=/|$|[\s:"])', re.IGNORECASE)


def _mask_home(text: str, home: str) -> str:
    pattern = _home_pattern(home)
    masked = pattern.sub("~", text) if pattern else text
    return _USER_PATH_STR.sub(_REDACTED_USER_DIR, masked)


def _mask_connectkey(argv: list[str], connectkey: Optional[str]) -> list[str]:
    if not connectkey:
        return list(argv)
    return [_REDACTED_CONNECTKEY if part == connectkey else part for part in argv]


def _assert_redacted_clean(payload_text: str, home: str, connectkey: Optional[str]) -> None:
    """Final output-side gate for the repo-facing artifact: re-scan the fully
    serialized redacted manifest so no masking hole can ship silently."""
    leaks = []
    home_pattern = _home_pattern(home)
    if home_pattern and home_pattern.search(payload_text):
        leaks.append("operator home path")
    if connectkey and connectkey in payload_text:
        leaks.append("device connectkey")
    if _USER_PATH_STR.search(payload_text):
        leaks.append("user directory path")
    if leaks:
        raise CaptureError(
            "redaction gate failed (" + ", ".join(leaks) + " present in the "
            "redacted manifest); redacted-manifest.json NOT written — investigate "
            "before referencing anything from this run")


# --- output-location safety ---------------------------------------------------


def assert_outside_repository(path: str) -> None:
    """Refuse to write capture output anywhere inside a git working tree, so
    serial-bearing bytes cannot land in the ArkDeck repository. The walk uses
    the symlink-resolved real path: a symlinked out-dir pointing into a checkout
    is refused too. (A bare repository has no ``.git`` entry and is not
    detected; do not point the out-dir at one.)"""
    current = os.path.realpath(path)
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

    def _opener(path: str, flags: int) -> int:
        return os.open(path, flags, 0o600)

    try:
        # "x" keeps O_EXCL (never overwrite evidence); the buffered writer
        # retries partial os.write so a short write cannot silently truncate.
        with open(target, "xb", opener=_opener) as handle:
            handle.write(data)
    except FileExistsError:
        raise CaptureError(
            f"refusing to overwrite existing capture file: {target}; "
            "use a fresh --out-dir per run") from None


def _require_utf8(label: str, value: str) -> None:
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise CaptureError(f"{label} contains non-UTF-8 bytes: {error}") from None


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
    _require_utf8("--hdc path", hdc_path)
    _require_utf8("--out-dir path", out_dir)
    if target is not None:
        _require_utf8("--target connectkey", target)
    if timeout <= 0:
        raise CaptureError(f"--timeout must be a positive number of seconds, got {timeout}")
    assert_outside_repository(out_dir)
    home = home if home is not None else os.path.expanduser("~")

    resolved_hdc = os.path.realpath(hdc_path)
    if not os.path.isfile(resolved_hdc) or not os.access(resolved_hdc, os.X_OK):
        raise CaptureError(f"hdc binary is not an executable regular file: {resolved_hdc}")
    hdc_hash = hashlib.sha256()
    with open(resolved_hdc, "rb") as handle:
        for block in iter(lambda: handle.read(1_048_576), b""):
            hdc_hash.update(block)
    hdc_sha256 = hdc_hash.hexdigest()

    os.makedirs(out_dir, mode=0o700, exist_ok=True)
    results: list[dict] = []
    overall_self_check_passed = True

    for index, spec in enumerate(selected):
        argv = build_argv(resolved_hdc, spec, target)
        try:
            result = runner(argv, timeout)
        except OSError as error:
            raise CaptureError(
                f"failed to execute hdc for {spec.ident}: {error}") from None
        stdout_name = f"{index:02d}-{spec.ident}.stdout"
        stderr_name = f"{index:02d}-{spec.ident}.stderr"
        _write_stream(out_dir, stdout_name, result.stdout)
        _write_stream(out_dir, stderr_name, result.stderr)

        stdout_check = self_check(result.stdout, target)
        stderr_check = self_check(result.stderr, target)
        command_passed = stdout_check["passed"] and stderr_check["passed"]
        overall_self_check_passed = overall_self_check_passed and command_passed

        results.append(
            {
                "commandId": spec.ident,
                "purpose": spec.purpose,
                "argv": argv,
                "exitCode": result.exit_code,
                "timedOut": result.timed_out,
                "durationMs": result.duration_ms,
                "stdout": {
                    "file": stdout_name, "sha256": _sha256(result.stdout),
                    "bytes": len(result.stdout), "truncated": result.stdout_truncated,
                },
                "stderr": {
                    "file": stderr_name, "sha256": _sha256(result.stderr),
                    "bytes": len(result.stderr), "truncated": result.stderr_truncated,
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
        "evidenceClass": "controlledHumanCapture",
        "toolchain": {
            "hdcPath": resolved_hdc,
            "hdcSha256": hdc_sha256,
            "transport": "usb",
        },
        "host": {
            "os": platform.system(),
            "osVersion": platform.mac_ver()[0] or platform.release(),
            "arch": platform.machine(),
        },
        "targetConnectkeyProvided": bool(target),
        "commands": results,
        "selfCheckPassed": overall_self_check_passed,
        "boundary": (
            "read-only capture; observed-only; not a support/compatibility claim; "
            "classified controlledHumanCapture — a realHardware classification of "
            "record can only be made by the human-attested hardware-evidence record; "
            "serial-bearing bytes remain in this controlled non-repository location; "
            "no capture is registered as a repository golden fixture by this change"),
    }
    redacted = _redacted_manifest(manifest, home, target)
    redacted_bytes = _json_bytes(redacted)

    _write_json(out_dir, "manifest.json", manifest)
    _assert_redacted_clean(redacted_bytes.decode("utf-8"), home, target)
    _write_stream(out_dir, "redacted-manifest.json", redacted_bytes)
    return manifest


def _redacted_manifest(manifest: dict, home: str, target: Optional[str]) -> dict:
    """The redacted manifest is a deep copy of the full manifest with exactly
    three transforms: the schema id, the masked hdc path, and per-command masked
    argv. Every other field flows through unchanged — and the serialized result
    must still pass ``_assert_redacted_clean`` before it is written, so a field
    added later cannot silently smuggle a sensitive value past redaction."""
    redacted = copy.deepcopy(manifest)
    redacted["schema"] = REDACTED_SCHEMA
    redacted["toolchain"]["hdcPath"] = _mask_home(manifest["toolchain"]["hdcPath"], home)
    for command in redacted["commands"]:
        command["argv"] = [
            _mask_home(part, home) for part in _mask_connectkey(command["argv"], target)]
    return redacted


def _json_bytes(document: dict) -> bytes:
    # Byte-identical to scripts/archive_characterization/scan.py::_serialize —
    # the repo's deterministic-evidence-bytes convention. test_capture.py pins
    # the two serializers against each other so they cannot drift.
    return (json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(
        "utf-8")


def _write_json(out_dir: str, name: str, document: dict) -> None:
    _write_stream(out_dir, name, _json_bytes(document))


# --- CLI ----------------------------------------------------------------------


def _positive_int(value: str) -> int:
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not an integer: {value!r}") from None
    if number <= 0:
        raise argparse.ArgumentTypeError(
            f"must be a positive number of seconds, got {number}")
    return number


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
        "--timeout", type=_positive_int, default=DEFAULT_TIMEOUT_SECONDS,
        help="per-command timeout in seconds (must be positive)")
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
    commands = manifest["commands"]
    timed_out_count = sum(1 for command in commands if command["timedOut"])
    print(
        "capture complete:",
        f"{len(commands)} commands, {timed_out_count} timed out,",
        "self-check PASSED" if ok else "self-check FAILED (user path or key material found)")
    print("full manifest + per-stream files:", os.path.abspath(arguments.out_dir))
    if timed_out_count == len(commands):
        print(
            "WARNING: every command timed out; this run captured nothing usable.",
            file=sys.stderr)
    if not ok:
        print(
            "WARNING: sensitive content found in captured output; do not copy raw bytes "
            "into the repository — investigate before drafting evidence.",
            file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
