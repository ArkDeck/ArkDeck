"""TR-001 controlled trace-tool capture harness (CHG-2026-021 / TASK-TR-001).

Human-operated. The Agent drafts this script; a human maintainer runs it against
the physical DAYU200. It replicates the M0B capture.py trust chain onto the
trace probe/capture command surface from CHG-2026-021 design §0: the operator
can only choose *which* allowlisted command to run, never compose an arbitrary
one. Every command is spawned with an argv array and never a host shell. For
each command it captures stdout and stderr as separate byte-exact files,
records exact argv, verbatim exit code, timeout state and duration, computes
per-stream SHA-256, runs a sensitive-content self-check, and writes both a full
manifest and a redacted manifest (operator home and connectkey masked) with a
final output-side redaction gate.

Beyond the M0B properties, this harness adds two mechanical gates for the
capture phase (the trace surface is not read-only: a minimal capture writes an
owned file under /data/local/tmp on the device):

  * probe-only by default — the specs that touch device state
    (``device_write=True``: mkdir / minimal capture / file recv / rm / rmdir)
    are refused unless ``--allow-device-write`` is passed explicitly;
  * help-anchored capture gate — capture specs additionally require
    ``--gate-dir`` pointing at the *same-window* probe run's out-dir. The
    harness re-reads those captured probe bytes and requires every flag token
    used by the capture argv (``-t``, ``-b``, ``-o``) to appear in the captured
    hitrace help output and the ``sched`` tag to appear in the captured tag
    list. Missing evidence refuses the capture phase: the exact argv below is a
    pre-declared candidate whose in-window execution is authorized only by the
    device's own captured help surface, never by operator improvisation
    (design §0: exact argv is fixed by TR-001 provenance, not by prose).

The remote paths are fixed literals owned by this run
(``/data/local/tmp/arkdeck-trace/minimal.ftrace``); cleanup removes exactly
that literal file and then the empty owned directory (``rmdir`` refuses a
non-empty directory by design). No wildcard, recursive or discovered-path
cleanup exists here (CHG-008 lesson).

Exit codes: 0 = capture ok and self-check passed; 1 = capture ran but the
sensitive-content self-check failed; 2 = usage or harness error (refused
output location, existing output file, unexecutable hdc, failed redaction or
capture gate).
"""

from __future__ import annotations

import argparse
import copy
import dataclasses
import glob
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

MANIFEST_SCHEMA = "arkdeck-trace-capture-manifest-1.0.0"
REDACTED_SCHEMA = "arkdeck-trace-capture-redacted-1.0.0"

MAX_STREAM_BYTES = 4 * 1_024 * 1_024
DEFAULT_TIMEOUT_SECONDS = 60
PIPE_DRAIN_GRACE_SECONDS = 2.0

# Fixed owned remote surface (design §0; integration profile recommends the
# /data/local/tmp/arkdeck/<job> shape — TR-001 uses a task-owned literal).
REMOTE_TRACE_DIR = "/data/local/tmp/arkdeck-trace"
REMOTE_TRACE_FILE = "/data/local/tmp/arkdeck-trace/minimal.ftrace"
RECV_LOCAL_NAME = "minimal.ftrace"

# Tokens that must be evidenced by the same-window captured probe output before
# the capture phase may run (see the capture gate above).
GATE_HELP_TOKENS = (b"-t", b"-b", b"-o")
GATE_TAG_TOKEN = b"sched"
GATE_HELP_GLOB = "*hitrace-help*.stdout"
GATE_TAG_GLOB = "*hitrace-tag-list*.stdout"


@dataclasses.dataclass(frozen=True)
class CommandSpec:
    """One allowlisted command. ``tokens`` are FIXED; the operator supplies only
    the connectkey (fixed ``-t`` slot) and, for the recv spec, the harness (not
    the operator) supplies the local destination inside the controlled
    out-dir. ``device_write`` marks the capture-phase specs that are refused
    without ``--allow-device-write`` and a passing ``--gate-dir`` gate."""

    ident: str
    tokens: tuple[str, ...]
    needs_target: bool
    device_write: bool
    recv_to_local: bool
    purpose: str


COMMAND_SPECS: tuple[CommandSpec, ...] = (
    # --- host/device discovery (M0B-proven read-only surface) ---
    CommandSpec(
        "hdc-list-targets", ("list", "targets"), False, False, False,
        "device discovery"),
    CommandSpec(
        "hdc-list-targets-verbose", ("list", "targets", "-v"), False, False, False,
        "device discovery with detail"),
    # --- trace tool probes (read-only; help/tag surface for family registration) ---
    CommandSpec(
        "hitrace-help-long", ("shell", "hitrace", "--help"), True, False, False,
        "hitrace help family (long form; error-line-with-exit-0 shapes are captured too)"),
    CommandSpec(
        "hitrace-help-short", ("shell", "hitrace", "-h"), True, False, False,
        "hitrace help family (short form)"),
    CommandSpec(
        "hitrace-tag-list", ("shell", "hitrace", "-l"), True, False, False,
        "hitrace tag/category list"),
    CommandSpec(
        "bytrace-help-long", ("shell", "bytrace", "--help"), True, False, False,
        "bytrace help family (long form; absence/error shape is a valid observation)"),
    CommandSpec(
        "bytrace-help-short", ("shell", "bytrace", "-h"), True, False, False,
        "bytrace help family (short form)"),
    CommandSpec(
        "bytrace-tag-list", ("shell", "bytrace", "-l"), True, False, False,
        "bytrace tag/category list"),
    # --- owned-path inventory (read-only, fixed literal) ---
    CommandSpec(
        "trace-remote-stat", ("shell", "ls", "-l", REMOTE_TRACE_FILE), True, False, False,
        "owned trace file inventory (fixed literal path; pre/post capture)"),
    # --- capture phase (device_write; gated) ---
    CommandSpec(
        "trace-remote-mkdir", ("shell", "mkdir", "-p", REMOTE_TRACE_DIR), True, True, False,
        "create the owned remote trace directory (fixed literal)"),
    CommandSpec(
        "hitrace-capture-minimal",
        ("shell", "hitrace", "-t", "5", "-b", "2048", "sched", "-o", REMOTE_TRACE_FILE),
        True, True, False,
        "minimal 5s sched-tag capture to the owned remote file (argv is the "
        "pre-declared candidate; execution requires the help-anchored gate)"),
    CommandSpec(
        "trace-recv-minimal", ("file", "recv", REMOTE_TRACE_FILE), True, True, True,
        "receive the owned trace file into the controlled out-dir"),
    CommandSpec(
        "trace-remote-rm", ("shell", "rm", REMOTE_TRACE_FILE), True, True, False,
        "remove exactly the owned trace file (fixed literal; no wildcard)"),
    CommandSpec(
        "trace-remote-rmdir", ("shell", "rmdir", REMOTE_TRACE_DIR), True, True, False,
        "remove the owned directory only when empty (rmdir refuses otherwise)"),
)

SPECS_BY_ID = {spec.ident: spec for spec in COMMAND_SPECS}

PROBE_COMMAND_IDS = tuple(
    spec.ident for spec in COMMAND_SPECS if not spec.device_write)
CAPTURE_COMMAND_IDS = tuple(
    spec.ident for spec in COMMAND_SPECS if spec.device_write)


class CaptureError(Exception):
    """A harness/usage error that is not a captured command failure."""


@dataclasses.dataclass(frozen=True)
class RunnerResult:
    exit_code: Optional[int]
    timed_out: bool
    stdout: bytes
    stderr: bytes
    stdout_truncated: bool
    stderr_truncated: bool
    duration_ms: int


Runner = Callable[[list[str], int], RunnerResult]


def _drain_pipe(stream, sink: dict) -> None:
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
    return RunnerResult(
        exit_code=None if timed_out else process.returncode,
        timed_out=timed_out,
        stdout=b"".join(sinks["stdout"]["chunks"]),
        stderr=b"".join(sinks["stderr"]["chunks"]),
        stdout_truncated=sinks["stdout"]["total"] > MAX_STREAM_BYTES,
        stderr_truncated=sinks["stderr"]["total"] > MAX_STREAM_BYTES,
        duration_ms=int((time.monotonic() - started) * 1_000),
    )


def build_argv(
    hdc_path: str, spec: CommandSpec, target: Optional[str],
    recv_local_path: Optional[str] = None,
) -> list[str]:
    """Compose the argv for one allowlisted spec. The spec must BE the registered
    allowlist object (identity, not name). The connectkey goes only into the
    fixed pre-subcommand ``-t`` slot. For the recv spec the local destination is
    appended by the harness from the controlled out-dir; it is never an
    operator-typed token."""
    if SPECS_BY_ID.get(spec.ident) is not spec:
        raise CaptureError(f"refusing command outside the closed allowlist: {spec.ident}")
    argv = [hdc_path]
    if spec.needs_target and target:
        argv += ["-t", target]
    argv += list(spec.tokens)
    if spec.recv_to_local:
        if not recv_local_path:
            raise CaptureError(f"{spec.ident} requires a harness-supplied local path")
        argv.append(recv_local_path)
    return argv


# --- sensitive-content self-check (M0B pattern, byte/str kept in lockstep) ----

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
    """User paths and key material MUST NOT appear and fail the check. A device
    connectkey/serial MAY appear (device identity, controlled location only);
    its presence is recorded, not failed. On discovery runs (no --target) the
    connectkey is unknown and ``serialPresent`` is None. Device-side trace
    content (process names, /data/... paths) is not sensitive host content and
    passes; the host-path pattern also covers a device build that unexpectedly
    reports /home paths, which would fail closed for review."""
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


_REDACTED_CONNECTKEY = "<connectkey>"
_REDACTED_USER_DIR = "<redacted-user-dir>"


def _home_pattern(home: str) -> Optional[re.Pattern]:
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


def assert_outside_repository(path: str) -> None:
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


# --- capture gate (help-anchored authorization of the capture phase) ----------


def assert_capture_gate(gate_dir: str) -> dict:
    """Mechanical in-window gate: the capture-phase argv may execute only when
    the same-window probe run captured (a) a hitrace help output containing
    every flag token the capture argv uses and (b) a hitrace tag list containing
    the ``sched`` tag. The gate reads the probe run's byte-exact stdout files;
    absence of either evidence refuses the capture phase (the runbook then
    records a blocked-attempt instead of improvising argv)."""

    def _read_matches(pattern: str) -> bytes:
        joined = b""
        for path in sorted(glob.glob(os.path.join(gate_dir, pattern))):
            with open(path, "rb") as handle:
                joined += handle.read()
        return joined

    if not os.path.isdir(gate_dir):
        raise CaptureError(f"--gate-dir is not a directory: {gate_dir}")
    help_bytes = _read_matches(GATE_HELP_GLOB)
    tag_bytes = _read_matches(GATE_TAG_GLOB)
    if not help_bytes:
        raise CaptureError(
            "capture gate failed: no captured hitrace help stdout found in --gate-dir; "
            "run the probe phase first in this same window")
    missing = [token.decode() for token in GATE_HELP_TOKENS if token not in help_bytes]
    if missing:
        raise CaptureError(
            "capture gate failed: captured hitrace help does not evidence flag(s) "
            + ", ".join(missing)
            + "; the pre-declared capture argv is not authorized on this build — "
            "record a blocked-attempt, do not improvise argv")
    if GATE_TAG_TOKEN not in tag_bytes:
        raise CaptureError(
            "capture gate failed: captured hitrace tag list does not evidence the "
            "'sched' tag; record a blocked-attempt, do not substitute another tag")
    return {
        "gateDir": gate_dir,
        "helpTokensEvidenced": [token.decode() for token in GATE_HELP_TOKENS],
        "tagEvidenced": GATE_TAG_TOKEN.decode(),
    }


# --- capture pipeline ---------------------------------------------------------


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: str) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1_048_576), b""):
            digest.update(block)
            total += len(block)
    return digest.hexdigest(), total


def _write_stream(out_dir: str, name: str, data: bytes) -> None:
    target = os.path.join(out_dir, name)

    def _opener(path: str, flags: int) -> int:
        return os.open(path, flags, 0o600)

    try:
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
    allow_device_write: bool = False,
    gate_dir: Optional[str] = None,
) -> dict:
    _require_utf8("--hdc path", hdc_path)
    _require_utf8("--out-dir path", out_dir)
    if target is not None:
        _require_utf8("--target connectkey", target)
    if timeout <= 0:
        raise CaptureError(f"--timeout must be a positive number of seconds, got {timeout}")
    assert_outside_repository(out_dir)
    home = home if home is not None else os.path.expanduser("~")

    wants_write = [spec.ident for spec in selected if spec.device_write]
    gate_facts: Optional[dict] = None
    if wants_write:
        if not allow_device_write:
            raise CaptureError(
                "capture-phase command(s) selected without --allow-device-write: "
                + ", ".join(wants_write)
                + "; the default invocation is probe-only")
        if not gate_dir:
            raise CaptureError(
                "capture-phase command(s) require --gate-dir pointing at this "
                "window's probe run out-dir")
        gate_facts = assert_capture_gate(gate_dir)
        if not target:
            raise CaptureError("capture-phase command(s) require --target")

    resolved_hdc = os.path.realpath(hdc_path)
    if not os.path.isfile(resolved_hdc) or not os.access(resolved_hdc, os.X_OK):
        raise CaptureError(f"hdc binary is not an executable regular file: {resolved_hdc}")
    hdc_hash = hashlib.sha256()
    with open(resolved_hdc, "rb") as handle:
        for block in iter(lambda: handle.read(1_048_576), b""):
            hdc_hash.update(block)
    hdc_sha256 = hdc_hash.hexdigest()

    os.makedirs(out_dir, mode=0o700, exist_ok=True)
    recv_local_path = os.path.join(out_dir, RECV_LOCAL_NAME)
    if any(spec.recv_to_local for spec in selected) and os.path.exists(recv_local_path):
        raise CaptureError(
            f"refusing to overwrite existing received file: {recv_local_path}; "
            "use a fresh --out-dir per run")

    results: list[dict] = []
    overall_self_check_passed = True

    for index, spec in enumerate(selected):
        argv = build_argv(
            resolved_hdc, spec, target,
            recv_local_path=recv_local_path if spec.recv_to_local else None)
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

        received: Optional[dict] = None
        if spec.recv_to_local:
            if os.path.isfile(recv_local_path):
                os.chmod(recv_local_path, 0o600)
                file_sha256, file_bytes = _sha256_file(recv_local_path)
                with open(recv_local_path, "rb") as handle:
                    file_check = self_check(handle.read(MAX_STREAM_BYTES), target)
                received = {
                    "file": RECV_LOCAL_NAME,
                    "sha256": file_sha256,
                    "bytes": file_bytes,
                    "present": True,
                    "selfCheck": file_check,
                }
                command_passed = command_passed and file_check["passed"]
            else:
                received = {"file": RECV_LOCAL_NAME, "present": False}
        overall_self_check_passed = overall_self_check_passed and command_passed

        entry = {
            "commandId": spec.ident,
            "purpose": spec.purpose,
            "deviceWrite": spec.device_write,
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
        if received is not None:
            entry["receivedFile"] = received
        results.append(entry)

    manifest = {
        "schema": MANIFEST_SCHEMA,
        "change": "CHG-2026-021-trace-adapter-capture",
        "task": "TASK-TR-001",
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
        "deviceWriteEnabled": bool(wants_write),
        "captureGate": gate_facts,
        "remoteOwnedSurface": {
            "directory": REMOTE_TRACE_DIR,
            "file": REMOTE_TRACE_FILE,
        },
        "commands": results,
        "selfCheckPassed": overall_self_check_passed,
        "boundary": (
            "controlled trace probe/minimal-capture; observed-only; not a "
            "support/compatibility claim; classified controlledHumanCapture — a "
            "registry/golden registration of record happens only through the "
            "maintainer-reviewed TR-001 evidence PR; serial-bearing and raw trace "
            "bytes remain in this controlled non-repository location"),
    }
    redacted = _redacted_manifest(manifest, home, target)
    redacted_bytes = _json_bytes(redacted)

    _write_json(out_dir, "manifest.json", manifest)
    _assert_redacted_clean(redacted_bytes.decode("utf-8"), home, target)
    _write_stream(out_dir, "redacted-manifest.json", redacted_bytes)
    return manifest


def _redacted_manifest(manifest: dict, home: str, target: Optional[str]) -> dict:
    """Deep copy with exactly four transforms: schema id, masked hdc path,
    masked gate dir, per-command masked argv. Everything else flows through and
    the serialized result must still pass ``_assert_redacted_clean``."""
    redacted = copy.deepcopy(manifest)
    redacted["schema"] = REDACTED_SCHEMA
    redacted["toolchain"]["hdcPath"] = _mask_home(manifest["toolchain"]["hdcPath"], home)
    if redacted.get("captureGate"):
        redacted["captureGate"]["gateDir"] = _mask_home(
            manifest["captureGate"]["gateDir"], home)
    for command in redacted["commands"]:
        command["argv"] = [
            _mask_home(part, home) for part in _mask_connectkey(command["argv"], target)]
    return redacted


def _json_bytes(document: dict) -> bytes:
    # Byte-identical to scripts/m0b_capture/capture.py::_json_bytes — the repo's
    # deterministic-evidence-bytes convention; test_capture.py pins the parity.
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
        description="TR-001 controlled trace probe/minimal-capture (human-operated).",
        allow_abbrev=False)
    parser.add_argument("--hdc", required=True, help="absolute path to the hdc binary")
    parser.add_argument(
        "--out-dir", required=True,
        help="controlled output directory OUTSIDE any git repository")
    parser.add_argument(
        "--target", default=None,
        help="device connectkey (required for shell/file specs; kept only in the "
        "controlled output; masked in the redacted manifest)")
    parser.add_argument(
        "--commands", default="probe",
        help="comma-separated command ids, 'probe' (default: all read-only probes) "
        "or 'capture' (the gated device-write sequence). "
        f"ids: {', '.join(SPECS_BY_ID)}")
    parser.add_argument(
        "--allow-device-write", action="store_true",
        help="explicitly enable the capture-phase specs (default is probe-only)")
    parser.add_argument(
        "--gate-dir", default=None,
        help="out-dir of this window's probe run; required by the capture phase "
        "(the captured help/tag bytes must evidence the capture argv)")
    parser.add_argument(
        "--timeout", type=_positive_int, default=DEFAULT_TIMEOUT_SECONDS,
        help="per-command timeout in seconds (must be positive)")
    return parser


CAPTURE_SEQUENCE = (
    "trace-remote-mkdir",
    "trace-remote-stat",
    "hitrace-capture-minimal",
    "trace-remote-stat",
    "trace-recv-minimal",
    "trace-remote-rm",
    "trace-remote-stat",
    "trace-remote-rmdir",
)


def _select(commands: str) -> list[CommandSpec]:
    stripped = commands.strip()
    if stripped == "probe":
        return [SPECS_BY_ID[ident] for ident in PROBE_COMMAND_IDS]
    if stripped == "capture":
        return [SPECS_BY_ID[ident] for ident in CAPTURE_SEQUENCE]
    selected: list[CommandSpec] = []
    for ident in (part.strip() for part in stripped.split(",") if part.strip()):
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
            target=arguments.target, timeout=arguments.timeout,
            allow_device_write=arguments.allow_device_write,
            gate_dir=arguments.gate_dir)
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
