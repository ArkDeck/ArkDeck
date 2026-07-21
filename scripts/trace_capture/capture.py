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
    harness validates that manifest's exact HDC path/hash, target, closed
    command sequence, per-stream byte hashes and self-check before requiring
    every flag token used by the capture argv (``-t``, ``-b``, ``-o``) and the
    ``sched`` tag. Missing or mismatched evidence refuses the capture phase: the
    exact argv below is a pre-declared candidate whose in-window execution is
    authorized only by the device's own captured help surface, never by
    operator improvisation (design §0: exact argv is fixed by TR-001
    provenance, not by prose).

The harness generates a fresh UUID-isolated remote directory under
``/data/local/tmp/arkdeck/<uuid>/``. Cleanup removes exactly that generated
file and then the empty owned directory (``rmdir`` refuses a non-empty
directory). No wildcard, recursive or discovered-path cleanup exists. If the
received file is missing, empty, truncated or fails the sensitive self-check,
cleanup is not dispatched and the manifest records the retained remote hazard.

Exit codes: 0 = probe recorded, or capture reached non-empty verified receive
and cleanup, with self-check passed; 1 = sensitive-content self-check failed or
capture remained partial/cleanup-incomplete; 2 = usage or harness error
(refused output location, pin drift, existing output file, unexecutable hdc,
failed redaction or capture gate).
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
import uuid
from typing import Callable, Optional

MANIFEST_SCHEMA = "arkdeck-trace-capture-manifest-1.1.0"
REDACTED_SCHEMA = "arkdeck-trace-capture-redacted-1.1.0"

MAX_STREAM_BYTES = 4 * 1_024 * 1_024
DEFAULT_TIMEOUT_SECONDS = 60
PIPE_DRAIN_GRACE_SECONDS = 2.0

# The readiness pin is a dispatch gate, not merely metadata. Version is checked
# from the same probe manifest before capture is allowed.
PINNED_HDC_SHA256 = "48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260"
PINNED_HDC_VERSION_MARKER = b"Ver: 3.2.0d"

# REQ-TRACE-006 requires a per-run UUID-isolated remote path. These sentinels
# are replaced only by the harness with a freshly generated canonical UUID;
# the operator cannot supply a remote path.
REMOTE_TRACE_ROOT = "/data/local/tmp/arkdeck"
REMOTE_TRACE_DIR_TOKEN = "{remoteTraceDir}"
REMOTE_TRACE_FILE_TOKEN = "{remoteTraceFile}"
RECV_LOCAL_NAME = "minimal.ftrace"

# Tokens that must be evidenced by the same-window captured probe output before
# the capture phase may run (see the capture gate above).
GATE_HELP_TOKENS = (b"-t", b"-b", b"-o")
GATE_TAG_TOKEN = b"sched"


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
        "hdc-version", ("-v",), False, False, False,
        "pinned HDC client version"),
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
    # --- owned-path inventory (read-only, harness-generated UUID literal) ---
    CommandSpec(
        "trace-remote-stat", ("shell", "ls", "-l", REMOTE_TRACE_FILE_TOKEN),
        True, False, False,
        "owned trace file inventory (harness-generated UUID path; pre/post capture)"),
    # --- capture phase (device_write; gated) ---
    CommandSpec(
        "trace-remote-mkdir", ("shell", "mkdir", "-p", REMOTE_TRACE_DIR_TOKEN),
        True, True, False,
        "create the owned UUID-isolated remote trace directory"),
    CommandSpec(
        "hitrace-capture-minimal",
        ("shell", "hitrace", "-t", "5", "-b", "2048", "sched", "-o",
         REMOTE_TRACE_FILE_TOKEN),
        True, True, False,
        "minimal 5s sched-tag capture to the owned remote file (argv is the "
        "pre-declared candidate; execution requires the help-anchored gate)"),
    CommandSpec(
        "trace-recv-minimal", ("file", "recv", REMOTE_TRACE_FILE_TOKEN),
        True, True, True,
        "receive the owned trace file into the controlled out-dir"),
    CommandSpec(
        "trace-remote-rm", ("shell", "rm", REMOTE_TRACE_FILE_TOKEN),
        True, True, False,
        "remove exactly the owned UUID-isolated trace file (no wildcard)"),
    CommandSpec(
        "trace-remote-rmdir", ("shell", "rmdir", REMOTE_TRACE_DIR_TOKEN),
        True, True, False,
        "remove the owned UUID directory only when empty (rmdir refuses otherwise)"),
)

SPECS_BY_ID = {spec.ident: spec for spec in COMMAND_SPECS}

DISCOVERY_COMMAND_IDS = (
    "hdc-version",
    "hdc-list-targets",
    "hdc-list-targets-verbose",
)
TRACE_PROBE_COMMAND_IDS = (
    "hitrace-help-long",
    "hitrace-help-short",
    "hitrace-tag-list",
    "bytrace-help-long",
    "bytrace-help-short",
    "bytrace-tag-list",
)
PROBE_COMMAND_IDS = DISCOVERY_COMMAND_IDS + TRACE_PROBE_COMMAND_IDS
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
    remote_trace_dir: Optional[str] = None,
    remote_trace_file: Optional[str] = None,
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
    replacements = {
        REMOTE_TRACE_DIR_TOKEN: remote_trace_dir,
        REMOTE_TRACE_FILE_TOKEN: remote_trace_file,
    }
    for token in spec.tokens:
        if token in replacements:
            replacement = replacements[token]
            if not replacement:
                raise CaptureError(
                    f"{spec.ident} requires a harness-generated UUID remote path")
            argv.append(replacement)
        else:
            argv.append(token)
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


def assert_capture_gate(
    gate_dir: str,
    resolved_hdc: str,
    hdc_sha256: str,
    target: str,
) -> dict:
    """Bind capture authorization to one complete probe manifest.

    The exact HDC path/hash, target, closed probe sequence, self-check and each
    stream's size/hash are revalidated before help/tag bytes can authorize a
    device-write dispatch. Loose lookalike files or a probe for another target
    therefore fail closed.
    """

    def _unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise CaptureError(
                    f"capture gate failed: duplicate JSON member in probe manifest: {key}")
            result[key] = value
        return result

    def _read_verified_stream(command: dict, stream_name: str) -> bytes:
        stream = command.get(stream_name)
        if not isinstance(stream, dict):
            raise CaptureError(
                f"capture gate failed: {command.get('commandId')} lacks {stream_name} metadata")
        name = stream.get("file")
        if not isinstance(name, str) or os.path.basename(name) != name:
            raise CaptureError(
                f"capture gate failed: invalid stream path for {command.get('commandId')}")
        if stream.get("truncated") is not False:
            raise CaptureError(
                f"capture gate failed: truncated stream for {command.get('commandId')}")
        path = os.path.join(gate_dir, name)
        try:
            with open(path, "rb") as handle:
                data = handle.read(MAX_STREAM_BYTES + 1)
        except OSError as error:
            raise CaptureError(
                f"capture gate failed: cannot read probe stream {name}: {error}") from None
        if len(data) > MAX_STREAM_BYTES:
            raise CaptureError(f"capture gate failed: oversized probe stream {name}")
        if (
            stream.get("bytes") != len(data)
            or stream.get("sha256") != hashlib.sha256(data).hexdigest()
        ):
            raise CaptureError(
                f"capture gate failed: probe stream size/hash mismatch for {name}")
        return data

    if not os.path.isdir(gate_dir):
        raise CaptureError(f"--gate-dir is not a directory: {gate_dir}")
    manifest_path = os.path.join(gate_dir, "manifest.json")
    try:
        with open(manifest_path, "rb") as handle:
            manifest_bytes = handle.read(MAX_STREAM_BYTES + 1)
        if len(manifest_bytes) > MAX_STREAM_BYTES:
            raise CaptureError("capture gate failed: oversized probe manifest")
        manifest = json.loads(manifest_bytes, object_pairs_hook=_unique_object)
    except CaptureError:
        raise
    except (OSError, json.JSONDecodeError) as error:
        raise CaptureError(
            f"capture gate failed: invalid or missing probe manifest: {error}") from None
    if not isinstance(manifest, dict):
        raise CaptureError("capture gate failed: probe manifest root is not an object")

    expected_identity = {
        "schema": MANIFEST_SCHEMA,
        "change": "CHG-2026-021-trace-adapter-capture",
        "task": "TASK-TR-001",
        "evidenceClass": "controlledHumanCapture",
        "deviceWriteEnabled": False,
        "targetConnectkeyProvided": True,
        "selfCheckPassed": True,
    }
    for key, expected in expected_identity.items():
        if manifest.get(key) != expected:
            raise CaptureError(
                f"capture gate failed: probe manifest {key} is not {expected!r}")
    toolchain = manifest.get("toolchain")
    if not isinstance(toolchain, dict):
        raise CaptureError("capture gate failed: probe manifest lacks toolchain identity")
    if (
        toolchain.get("hdcPath") != resolved_hdc
        or toolchain.get("hdcSha256") != hdc_sha256
    ):
        raise CaptureError(
            "capture gate failed: probe HDC path/hash does not match this invocation")

    commands = manifest.get("commands")
    if not isinstance(commands, list):
        raise CaptureError("capture gate failed: probe manifest commands is not an array")
    command_ids = [
        command.get("commandId") for command in commands if isinstance(command, dict)
    ]
    if command_ids != list(PROBE_COMMAND_IDS) or len(commands) != len(PROBE_COMMAND_IDS):
        raise CaptureError(
            "capture gate failed: command sequence is not the closed 'probe' sequence")

    streams: dict[str, bytes] = {}
    for command, ident in zip(commands, PROBE_COMMAND_IDS):
        if not isinstance(command, dict):
            raise CaptureError("capture gate failed: malformed probe command entry")
        expected_argv = build_argv(resolved_hdc, SPECS_BY_ID[ident], target)
        if command.get("argv") != expected_argv:
            raise CaptureError(
                f"capture gate failed: probe argv/target mismatch for {ident}")
        if command.get("timedOut") is not False:
            raise CaptureError(f"capture gate failed: probe command timed out: {ident}")
        command_self_check = command.get("selfCheck")
        if (
            not isinstance(command_self_check, dict)
            or command_self_check.get("passed") is not True
        ):
            raise CaptureError(f"capture gate failed: probe self-check failed: {ident}")
        streams[ident] = (
            _read_verified_stream(command, "stdout")
            + _read_verified_stream(command, "stderr")
        )

    version_lines = {line.strip() for line in streams["hdc-version"].splitlines()}
    if PINNED_HDC_VERSION_MARKER not in version_lines:
        raise CaptureError(
            "capture gate failed: probe version does not match pinned Ver: 3.2.0d")
    inventory_bytes = streams["hdc-list-targets"] + streams["hdc-list-targets-verbose"]
    if target.encode("utf-8") not in re.split(rb"\s+", inventory_bytes):
        raise CaptureError(
            "capture gate failed: operator-confirmed target is absent from probe inventory")
    help_bytes = streams["hitrace-help-long"] + streams["hitrace-help-short"]
    tag_bytes = streams["hitrace-tag-list"]
    def _has_exact_token(data: bytes, token: bytes) -> bool:
        pattern = (
            rb"(?<![A-Za-z0-9_-])" + re.escape(token) + rb"(?![A-Za-z0-9_-])")
        return re.search(pattern, data) is not None

    missing = [
        token.decode() for token in GATE_HELP_TOKENS
        if not _has_exact_token(help_bytes, token)
    ]
    if missing:
        raise CaptureError(
            "capture gate failed: captured hitrace help does not evidence flag(s) "
            + ", ".join(missing)
            + "; record a blocked-attempt, do not improvise argv")
    if not _has_exact_token(tag_bytes, GATE_TAG_TOKEN):
        raise CaptureError(
            "capture gate failed: captured hitrace tag list does not evidence the "
            "'sched' tag; record a blocked-attempt, do not substitute another tag")
    return {
        "gateDir": gate_dir,
        "probeManifestSha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "probeCommandCount": len(commands),
        "probeTargetMatched": True,
        "probeHdcSha256": hdc_sha256,
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
    remote_run_id: Optional[str] = None,
) -> dict:
    _require_utf8("--hdc path", hdc_path)
    _require_utf8("--out-dir path", out_dir)
    if target is not None:
        _require_utf8("--target connectkey", target)
    if gate_dir is not None:
        _require_utf8("--gate-dir path", gate_dir)
    if timeout <= 0:
        raise CaptureError(f"--timeout must be a positive number of seconds, got {timeout}")
    assert_outside_repository(out_dir)
    home = home if home is not None else os.path.expanduser("~")

    missing_target = [spec.ident for spec in selected if spec.needs_target and not target]
    if missing_target:
        raise CaptureError(
            "target-bound command(s) require --target: " + ", ".join(missing_target))

    resolved_hdc = os.path.realpath(hdc_path)
    if not os.path.isfile(resolved_hdc) or not os.access(resolved_hdc, os.X_OK):
        raise CaptureError(f"hdc binary is not an executable regular file: {resolved_hdc}")
    hdc_hash = hashlib.sha256()
    with open(resolved_hdc, "rb") as handle:
        for block in iter(lambda: handle.read(1_048_576), b""):
            hdc_hash.update(block)
    hdc_sha256 = hdc_hash.hexdigest()
    if hdc_sha256 != PINNED_HDC_SHA256:
        raise CaptureError(
            "pinned HDC SHA-256 mismatch; expected "
            f"{PINNED_HDC_SHA256}, observed {hdc_sha256}; STOP this capture window")

    needs_remote_path = any(
        token in (REMOTE_TRACE_DIR_TOKEN, REMOTE_TRACE_FILE_TOKEN)
        for spec in selected for token in spec.tokens)
    normalized_run_id: Optional[str] = None
    remote_trace_dir: Optional[str] = None
    remote_trace_file: Optional[str] = None
    if needs_remote_path:
        candidate = remote_run_id or str(uuid.uuid4())
        try:
            parsed = uuid.UUID(candidate)
        except (ValueError, AttributeError):
            raise CaptureError("remote run id is not a canonical UUID") from None
        normalized_run_id = str(parsed)
        if candidate.lower() != normalized_run_id:
            raise CaptureError("remote run id must use canonical UUID text")
        remote_trace_dir = f"{REMOTE_TRACE_ROOT}/{normalized_run_id}"
        remote_trace_file = f"{remote_trace_dir}/{RECV_LOCAL_NAME}"

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
        gate_facts = assert_capture_gate(
            os.path.realpath(gate_dir), resolved_hdc, hdc_sha256, target)

    os.makedirs(out_dir, mode=0o700, exist_ok=True)
    recv_local_path = os.path.join(out_dir, RECV_LOCAL_NAME)
    if any(spec.recv_to_local for spec in selected) and os.path.exists(recv_local_path):
        raise CaptureError(
            f"refusing to overwrite existing received file: {recv_local_path}; "
            "use a fresh --out-dir per run")

    results: list[dict] = []
    overall_self_check_passed = True
    received_artifact_verified = False
    cleanup_attempts: list[dict] = []
    sequence_stopped_reason: Optional[str] = None
    cleanup_ids = {"trace-remote-rm", "trace-remote-rmdir"}

    for index, spec in enumerate(selected):
        if spec.ident in cleanup_ids and not received_artifact_verified:
            sequence_stopped_reason = (
                "received artifact was not non-empty and self-check verified; "
                "owned remote path retained")
            break
        argv = build_argv(
            resolved_hdc, spec, target,
            recv_local_path=recv_local_path if spec.recv_to_local else None,
            remote_trace_dir=remote_trace_dir,
            remote_trace_file=remote_trace_file)
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
                received_artifact_verified = bool(
                    file_bytes > 0
                    and file_bytes <= MAX_STREAM_BYTES
                    and command_passed
                    and result.exit_code == 0
                    and not result.timed_out
                    and not result.stdout_truncated
                    and not result.stderr_truncated)
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
        if spec.ident in cleanup_ids:
            cleanup_attempts.append({
                "commandId": spec.ident,
                "completed": bool(result.exit_code == 0 and not result.timed_out),
            })

    cleanup_complete = (
        [attempt["commandId"] for attempt in cleanup_attempts]
        == ["trace-remote-rm", "trace-remote-rmdir"]
        and all(attempt["completed"] for attempt in cleanup_attempts)
    )
    if not wants_write:
        capture_outcome = "probeCaptured"
    elif not received_artifact_verified:
        capture_outcome = "partialRemoteRetained"
    elif cleanup_complete:
        capture_outcome = "receivedNonEmptyCleanupComplete"
    else:
        capture_outcome = "receivedNonEmptyCleanupIncomplete"

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
        "captureOutcome": capture_outcome,
        "remoteOwnedSurface": {
            "runId": normalized_run_id,
            "directory": remote_trace_dir,
            "file": remote_trace_file,
        },
        "receiveVerification": {
            "nonEmptySelfChecked": received_artifact_verified,
        },
        "remoteCleanup": {
            "eligible": received_artifact_verified,
            "attempts": cleanup_attempts,
            "complete": cleanup_complete,
            "retainedReason": sequence_stopped_reason,
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
        help="comma-separated command ids, 'discover' (HDC version/target inventory), "
        "'probe' (default: pinned target trace probes), or 'capture' "
        "(the gated device-write sequence). "
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
    if stripped == "discover":
        return [SPECS_BY_ID[ident] for ident in DISCOVERY_COMMAND_IDS]
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
    capture_complete = (
        not manifest["deviceWriteEnabled"]
        or manifest["captureOutcome"] == "receivedNonEmptyCleanupComplete")
    ok = manifest["selfCheckPassed"] and capture_complete
    commands = manifest["commands"]
    timed_out_count = sum(1 for command in commands if command["timedOut"])
    print(
        "capture recorded:",
        f"{len(commands)} commands, {timed_out_count} timed out,",
        f"outcome={manifest['captureOutcome']},",
        "self-check PASSED" if manifest["selfCheckPassed"]
        else "self-check FAILED (user path or key material found)")
    print("full manifest + per-stream files:", os.path.abspath(arguments.out_dir))
    if timed_out_count == len(commands):
        print(
            "WARNING: every command timed out; this run captured nothing usable.",
            file=sys.stderr)
    if not ok:
        if not manifest["selfCheckPassed"]:
            print(
                "WARNING: sensitive content found in captured output; do not copy raw bytes "
                "into the repository — investigate before drafting evidence.",
                file=sys.stderr)
        if not capture_complete:
            print(
                "WARNING: capture did not reach verified receive + cleanup; the owned "
                "remote path was retained or cleanup is incomplete. Record a blocked/partial "
                "attempt and do not improvise cleanup.",
                file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
