"""Controlled ArkUI UI Dump capture harness for CHG-2026-008.

Human-operated only.  This module deliberately exposes a closed command surface:
the operator selects one approved command id and supplies only the typed values
required by that command.  It never accepts a free-form command, never invokes a
host shell, and never performs device discovery or capture on import or in tests.

Every invocation captures exactly one command.  Reusing the same controlled
``--out-dir`` builds a session in canonical order while preserving each stream as
an exclusive-created, owner-only file.  Targeted commands accept a connect key
only when the exact token occurs in the latest successful, untruncated HP-1/HP-2
capture from that same directory.

The full per-command manifest and raw streams remain outside every git repository.
The corresponding redacted manifest and ``capture-hashes.md`` contain hashes and
metadata only.  They are serialized deterministically and pass a final
output-side sensitive-data gate before being made available for repository
evidence.

Exit codes: 0 = capture completed without timeout/truncation/incomplete drain and
the sensitive gate passed; 1 = capture ran but timeout, truncation, incomplete
pipe drain, stream self-check, or output-side redaction requires the human run to
stop; 2 = pre-dispatch usage or harness refusal.
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
import stat
import subprocess
import sys
import threading
import time
import unicodedata
from typing import Callable, Optional


MANIFEST_SCHEMA = "arkdeck-ud-capture-manifest-1.1.0"
REDACTED_SCHEMA = "arkdeck-ud-capture-redacted-1.1.0"
CHANGE_ID = "CHG-2026-008-ui-dump-hidumper-wrapper"
TASK_ID = "TASK-UD-CAPTURE-HARNESS-001"

STRICT_SELF_CHECK_POLICY = "strict-sensitive-output-v1"
FX1_LOCAL_HAP_ECHO_POLICY = "fx1-stdout-exact-local-hap-v1"

MAX_STREAM_BYTES = 4 * 1_024 * 1_024
SIDECAR_SELF_CHECK_MAX_BYTES = 64 * 1_024 * 1_024
DEFAULT_TIMEOUT_SECONDS = 120
PIPE_DRAIN_GRACE_SECONDS = 2.0

REMOTE_SIDECAR = (
    "/data/app/el2/100/base/com.example.waterflowdemo/haps/entry/files/arkui.dump"
)

CONNECT_KEY = "CONNECT_KEY"
WINDOW_ID = "WINDOW_ID"
LOCAL_HAP_PATH = "LOCAL_HAP_PATH"
LOCAL_SIDECAR_DEST = "LOCAL_SIDECAR_DEST"
_PLACEHOLDERS = (CONNECT_KEY, WINDOW_ID, LOCAL_HAP_PATH, LOCAL_SIDECAR_DEST)

_REDACTED_VALUES = {
    CONNECT_KEY: "<connectkey>",
    WINDOW_ID: "<window-id>",
    LOCAL_HAP_PATH: "<local-hap-path>",
    LOCAL_SIDECAR_DEST: "<local-sidecar-dest>",
}


@dataclasses.dataclass(frozen=True)
class CommandSpec:
    ident: str
    tokens: tuple[str, ...]
    purpose: str

    @property
    def placeholders(self) -> frozenset[str]:
        return frozenset(
            placeholder
            for placeholder in _PLACEHOLDERS
            if any(placeholder in token for token in self.tokens)
        )


# This tuple is the closed command surface approved by TASK-UD-CAPTURE-HARNESS-001.
# R4 is intentionally absent: the approved task list omits it while the separate
# Phase-B task remains blocked on an output-family/component provenance revision.
COMMAND_SPECS: tuple[CommandSpec, ...] = (
    CommandSpec("HP-0", ("version",), "HDC version preflight"),
    CommandSpec("HP-1", ("list", "targets", "-v"), "same-session target inventory"),
    CommandSpec("HP-2", ("list", "targets", "-v"), "pre-dispatch target recheck"),
    CommandSpec(
        "INV-1",
        ("-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-a"),
        "all-window inventory and WINDOW_ID provenance",
    ),
    CommandSpec(
        "R1",
        (
            "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService",
            "-a", "-w WINDOW_ID -default",
        ),
        "nodeSummary candidate capture",
    ),
    CommandSpec(
        "R2",
        (
            "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService",
            "-a", "-w WINDOW_ID -element -c",
        ),
        "elementTree candidate capture",
    ),
    CommandSpec(
        "R3",
        (
            "-t", CONNECT_KEY, "shell", "hidumper", "-s", "WindowManagerService",
            "-a", "-w WINDOW_ID -default -all",
        ),
        "fullDefaultTree candidate capture",
    ),
    CommandSpec(
        "SC-1",
        ("-t", CONNECT_KEY, "shell", "ls", "-l", REMOTE_SIDECAR),
        "exact-path sidecar identity check",
    ),
    CommandSpec(
        "SC-2",
        ("-t", CONNECT_KEY, "file", "recv", REMOTE_SIDECAR, LOCAL_SIDECAR_DEST),
        "receive an owned new sidecar",
    ),
    CommandSpec(
        "SC-3",
        ("-t", CONNECT_KEY, "shell", "rm", REMOTE_SIDECAR),
        "remove the owned exact-path sidecar",
    ),
    CommandSpec(
        "FX-1",
        ("-t", CONNECT_KEY, "install", LOCAL_HAP_PATH),
        "install the pinned fixture HAP",
    ),
    CommandSpec(
        "FX-2",
        (
            "-t", CONNECT_KEY, "shell", "aa", "start", "-b",
            "com.example.waterflowdemo", "-a", "EntryAbility",
        ),
        "start the pinned fixture",
    ),
    CommandSpec(
        "FX-3",
        ("-t", CONNECT_KEY, "shell", "aa", "force-stop", "com.example.waterflowdemo"),
        "stop the pinned fixture",
    ),
    CommandSpec(
        "FX-4",
        ("-t", CONNECT_KEY, "uninstall", "com.example.waterflowdemo"),
        "uninstall the pinned fixture",
    ),
)

SPECS_BY_ID = {spec.ident: spec for spec in COMMAND_SPECS}


class CaptureError(Exception):
    """A usage or harness-integrity error."""


class StopRequired(CaptureError):
    """A post-dispatch fail-closed condition that maps to CLI exit status 1."""


@dataclasses.dataclass(frozen=True)
class CapturedStream:
    """Retained bytes plus observed-stream accounting from the runner."""

    data: bytes
    total_bytes: int
    sha256: str
    truncated: bool
    drain_incomplete: bool = False

    @classmethod
    def from_bytes(
        cls,
        data: bytes,
        *,
        truncated: bool = False,
        total_bytes: Optional[int] = None,
        sha256: Optional[str] = None,
        drain_incomplete: bool = False,
    ) -> "CapturedStream":
        total = len(data) if total_bytes is None else total_bytes
        digest = hashlib.sha256(data).hexdigest() if sha256 is None else sha256
        return cls(
            data=data,
            total_bytes=total,
            sha256=digest,
            truncated=truncated,
            drain_incomplete=drain_incomplete,
        )


@dataclasses.dataclass(frozen=True)
class RunnerResult:
    exit_code: Optional[int]
    timed_out: bool
    stdout: CapturedStream
    stderr: CapturedStream
    duration_ms: int


Runner = Callable[[list[str], int], RunnerResult]


def _new_sink() -> dict:
    return {
        "chunks": [],
        "kept": 0,
        "total": 0,
        "hasher": hashlib.sha256(),
        "accept": True,
        "lock": threading.Lock(),
    }


def _drain_pipe(stream, sink: dict) -> None:
    try:
        while True:
            chunk = stream.read1(65536)
            if not chunk:
                return
            with sink["lock"]:
                if not sink["accept"]:
                    continue
                if sink["kept"] < MAX_STREAM_BYTES:
                    take = chunk[: MAX_STREAM_BYTES - sink["kept"]]
                    sink["chunks"].append(take)
                    sink["kept"] += len(take)
                sink["total"] += len(chunk)
                sink["hasher"].update(chunk)
    except ValueError:
        return


def _freeze_sink(sink: dict, *, drain_incomplete: bool) -> CapturedStream:
    with sink["lock"]:
        sink["accept"] = False
        data = b"".join(sink["chunks"])
        total = sink["total"]
        digest = sink["hasher"].hexdigest()
    return CapturedStream(
        data=data,
        total_bytes=total,
        sha256=digest,
        truncated=total > len(data),
        drain_incomplete=drain_incomplete,
    )


def subprocess_runner(argv: list[str], timeout: int) -> RunnerResult:
    """Spawn one argv array and retain/hash stdout and stderr independently."""
    started = time.monotonic()
    process = subprocess.Popen(  # noqa: S603 - closed argv array, never a shell
        argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
    )
    sinks: dict[str, dict] = {}
    readers: list[tuple[str, threading.Thread, object, dict]] = []
    for name, stream in (("stdout", process.stdout), ("stderr", process.stderr)):
        sink = _new_sink()
        reader = threading.Thread(target=_drain_pipe, args=(stream, sink), daemon=True)
        reader.start()
        sinks[name] = sink
        readers.append((name, reader, stream, sink))

    timed_out = False
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        process.kill()
        process.wait()

    drain_deadline = time.monotonic() + PIPE_DRAIN_GRACE_SECONDS
    drain_incomplete: dict[str, bool] = {}
    for name, reader, stream, _sink in readers:
        reader.join(timeout=max(0.0, drain_deadline - time.monotonic()))
        drain_incomplete[name] = reader.is_alive()
        if not drain_incomplete[name]:
            stream.close()

    stdout = _freeze_sink(
        sinks["stdout"], drain_incomplete=drain_incomplete["stdout"]
    )
    stderr = _freeze_sink(
        sinks["stderr"], drain_incomplete=drain_incomplete["stderr"]
    )
    return RunnerResult(
        exit_code=None if timed_out else process.returncode,
        timed_out=timed_out,
        stdout=stdout,
        stderr=stderr,
        duration_ms=int((time.monotonic() - started) * 1_000),
    )


def _render_tokens(tokens: tuple[str, ...], values: dict[str, str]) -> list[str]:
    rendered: list[str] = []
    for template in tokens:
        token = template
        for placeholder in _PLACEHOLDERS:
            if placeholder in token:
                value = values.get(placeholder)
                if value is None:
                    raise CaptureError(f"missing required value for {placeholder}")
                token = token.replace(placeholder, value)
        if any(placeholder in token for placeholder in _PLACEHOLDERS):
            raise CaptureError(f"unresolved placeholder in command token: {template}")
        rendered.append(token)
    return rendered


def build_argv(hdc_path: str, spec: CommandSpec, values: dict[str, str]) -> list[str]:
    """Build argv only from the registered CommandSpec object."""
    if SPECS_BY_ID.get(spec.ident) is not spec:
        raise CaptureError(f"refusing command outside the closed allowlist: {spec.ident}")
    return [hdc_path, *_render_tokens(spec.tokens, values)]


_USER_PATH_PATTERN = r"/(?:Users|home)/[^/\s\x00:]+|/var/root"
_USER_PATH = re.compile(_USER_PATH_PATTERN.encode("ascii"), re.IGNORECASE)
_USER_PATH_STR = re.compile(_USER_PATH_PATTERN, re.IGNORECASE)
_KEY_MARKERS = (
    b"-----BEGIN",
    b"PRIVATE KEY",
    b"ssh-rsa ",
    b"ssh-ed25519 ",
    b"PuTTY-User-Key",
)

_PATH_SPAN_DELIMITERS = frozenset(b" \t\r\n\"'`()[]{}<>,;=:")


def _all_occurrences(payload: bytes, needle: bytes) -> list[tuple[int, int]]:
    if not needle:
        return []
    spans: list[tuple[int, int]] = []
    offset = 0
    while True:
        start = payload.find(needle, offset)
        if start < 0:
            return spans
        end = start + len(needle)
        spans.append((start, end))
        offset = start + 1


def _is_delimited_path_span(payload: bytes, start: int, end: int) -> bool:
    before_ok = start == 0 or payload[start - 1] in _PATH_SPAN_DELIMITERS
    after_ok = end == len(payload) or payload[end] in _PATH_SPAN_DELIMITERS
    return before_ok and after_ok


def _span_is_contained(
    span: tuple[int, int], allowed_spans: tuple[tuple[int, int], ...]
) -> bool:
    return any(
        allowed_start <= span[0] and span[1] <= allowed_end
        for allowed_start, allowed_end in allowed_spans
    )


def _normalized_casefold(value: str) -> str:
    return unicodedata.normalize("NFC", value).casefold()


def _related_local_path_variant_found(
    stream_bytes: bytes,
    expected_path: str,
    allowed_spans: tuple[tuple[int, int], ...],
) -> bool:
    """Detect path-shaped variants after removing every exact allowed span.

    The expected path's parent catches dirname, prefix and sibling variants.
    NFC + casefold catches Unicode-normalization and case variants. Exact
    symlink aliases are supplied separately in ``local_paths`` and therefore
    fail the ordinary outside-allowed-span check.
    """
    remainder = bytearray(stream_bytes)
    for start, end in allowed_spans:
        remainder[start:end] = b" " * (end - start)
    remaining_bytes = bytes(remainder)
    expected_bytes = expected_path.encode("utf-8")
    dirname = os.path.dirname(expected_path.rstrip(os.sep)) or os.sep
    dirname_bytes = dirname.encode("utf-8")
    if expected_bytes in remaining_bytes:
        return True
    if dirname != os.sep and dirname_bytes in remaining_bytes:
        return True
    remaining_text = remaining_bytes.decode("utf-8", errors="ignore")
    normalized = _normalized_casefold(remaining_text)
    if _normalized_casefold(expected_path) in normalized:
        return True
    return dirname != os.sep and _normalized_casefold(dirname) in normalized


def _self_check(
    stream_bytes: bytes,
    connect_key: Optional[str],
    local_paths: tuple[str, ...],
    *,
    complete: bool,
    expected_local_input_echo: Optional[str],
) -> dict:
    user_matches = tuple(
        (match.start(), match.end()) for match in _USER_PATH.finditer(stream_bytes)
    )
    user_path = bool(user_matches)
    key_material = any(marker in stream_bytes for marker in _KEY_MARKERS)
    local_matches = tuple(
        span
        for path in local_paths
        for span in _all_occurrences(stream_bytes, path.encode("utf-8"))
    )
    local_path = bool(local_matches)
    serial_present = connect_key.encode("utf-8") in stream_bytes if connect_key else None

    allowed_spans: tuple[tuple[int, int], ...] = ()
    policy_id = STRICT_SELF_CHECK_POLICY
    if expected_local_input_echo is not None:
        policy_id = FX1_LOCAL_HAP_ECHO_POLICY
        expected_bytes = expected_local_input_echo.encode("utf-8")
        allowed_spans = tuple(
            span
            for span in _all_occurrences(stream_bytes, expected_bytes)
            if _is_delimited_path_span(stream_bytes, *span)
        )

    unexpected_user_path = any(
        not _span_is_contained(match, allowed_spans) for match in user_matches
    )
    unexpected_local_path = any(
        not _span_is_contained(match, allowed_spans) for match in local_matches
    )
    if expected_local_input_echo is not None:
        unexpected_local_path = unexpected_local_path or _related_local_path_variant_found(
            stream_bytes, expected_local_input_echo, allowed_spans
        )
    expected_echo_found = bool(allowed_spans)
    passed = (
        complete
        and not key_material
        and not unexpected_user_path
        and not unexpected_local_path
    )
    return {
        "policyId": policy_id,
        "expectedLocalInputEchoFound": expected_echo_found,
        "unexpectedUserPathFound": unexpected_user_path,
        "unexpectedLocalInputPathFound": unexpected_local_path,
        "userPathFound": user_path,
        "keyMaterialFound": key_material,
        "localInputPathFound": local_path,
        "serialPresent": serial_present,
        "completeStreamScanned": complete,
        "passed": passed,
    }


def self_check(
    stream_bytes: bytes,
    connect_key: Optional[str],
    local_paths: tuple[str, ...] = (),
    *,
    complete: bool = True,
) -> dict:
    """Fail closed on user paths, key material, supplied local paths, or truncation."""
    return _self_check(
        stream_bytes,
        connect_key,
        local_paths,
        complete=complete,
        expected_local_input_echo=None,
    )


def _stream_self_check(
    stream_bytes: bytes,
    connect_key: Optional[str],
    local_paths: tuple[str, ...],
    *,
    spec: CommandSpec,
    stream_name: str,
    complete: bool,
    timed_out: bool,
    expected_local_hap_path: Optional[str],
) -> dict:
    """Select the narrow echo policy only from registered command identity."""
    expected_echo = None
    if (
        SPECS_BY_ID.get(spec.ident) is spec
        and spec.ident == "FX-1"
        and stream_name == "stdout"
        and complete
        and not timed_out
    ):
        expected_echo = expected_local_hap_path
    return _self_check(
        stream_bytes,
        connect_key,
        local_paths,
        complete=complete,
        expected_local_input_echo=expected_echo,
    )


def _home_pattern(home: str) -> Optional[re.Pattern]:
    root = home.rstrip("/") if home else ""
    if not root:
        return None
    return re.compile(re.escape(root) + r'(?=/|$|[\s:"])', re.IGNORECASE)


def _mask_home(text: str, home: str) -> str:
    pattern = _home_pattern(home)
    masked = pattern.sub("~", text) if pattern else text
    return _USER_PATH_STR.sub("<redacted-user-dir>", masked)


def _assert_redacted_clean(
    payload_text: str,
    *,
    home: str,
    connect_key: Optional[str],
    window_id: Optional[str],
    local_paths: tuple[str, ...],
) -> None:
    leaks: list[str] = []
    home_matcher = _home_pattern(home)
    if home_matcher and home_matcher.search(payload_text):
        leaks.append("operator home path")
    if connect_key and connect_key in payload_text:
        leaks.append("device connect key")
    if window_id and (
        f'"windowId": "{window_id}"' in payload_text
        or re.search(rf"-w\s+{re.escape(window_id)}(?:\s|\")", payload_text)
    ):
        leaks.append("window id")
    if any(path and path in payload_text for path in local_paths):
        leaks.append("local input path")
    if _USER_PATH_STR.search(payload_text):
        leaks.append("user directory path")
    if any(marker.decode("ascii") in payload_text for marker in _KEY_MARKERS):
        leaks.append("key material marker")
    if leaks:
        raise StopRequired(
            "redaction gate failed (" + ", ".join(leaks)
            + "); redacted manifest and capture-hashes summary were not published"
        )


def assert_outside_repository(path: str) -> None:
    current = os.path.realpath(path)
    while True:
        if os.path.exists(os.path.join(current, ".git")):
            raise CaptureError(
                "refusing a capture/local-input path inside a git repository "
                f"(.git found at {current})"
            )
        parent = os.path.dirname(current)
        if parent == current:
            return
        current = parent


def _ensure_controlled_directory(out_dir: str) -> str:
    assert_outside_repository(out_dir)
    if os.path.lexists(out_dir) and os.path.islink(out_dir):
        raise CaptureError("--out-dir must not be a symlink")
    os.makedirs(out_dir, mode=0o700, exist_ok=True)
    resolved = os.path.realpath(out_dir)
    info = os.stat(resolved)
    if not stat.S_ISDIR(info.st_mode):
        raise CaptureError("--out-dir is not a directory")
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise CaptureError("--out-dir must be owner-only (mode 0o700 or stricter)")
    return resolved


def _require_utf8(label: str, value: str) -> None:
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise CaptureError(f"{label} is not valid UTF-8: {error}") from None


_CONNECT_KEY_PATTERN = re.compile(
    r"(?:[A-Za-z0-9]|\[)[A-Za-z0-9._:%\[\]-]{0,255}\Z", re.ASCII
)
_WINDOW_ID_PATTERN = re.compile(r"[0-9]+\Z", re.ASCII)


def _validate_connect_key(value: str) -> str:
    _require_utf8("--connect-key", value)
    if not _CONNECT_KEY_PATTERN.fullmatch(value):
        raise CaptureError(
            "--connect-key must be a non-option printable ASCII HDC target token"
        )
    return value


def _validate_window_id(value: str) -> str:
    if not _WINDOW_ID_PATTERN.fullmatch(value):
        raise CaptureError("--window-id must contain ASCII decimal digits only")
    return value


def _sha256_file(path: str) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1_048_576), b""):
            digest.update(block)
            size += len(block)
    return digest.hexdigest(), size


def _validate_hap_path(path: str) -> tuple[str, dict, tuple[str, ...]]:
    _require_utf8("--local-hap-path", path)
    assert_outside_repository(path)
    supplied_absolute = os.path.abspath(path)
    resolved = os.path.realpath(path)
    if not os.path.isfile(resolved):
        raise CaptureError("--local-hap-path must resolve to an existing regular file")
    digest, size = _sha256_file(resolved)
    aliases = () if supplied_absolute == resolved else (supplied_absolute,)
    return resolved, {"path": resolved, "sha256": digest, "bytes": size}, aliases


def _validate_sidecar_dest(
    path: str, out_dir: str, expected_name: str
) -> tuple[str, dict]:
    _require_utf8("--local-sidecar-dest", path)
    assert_outside_repository(path)
    if os.path.lexists(path):
        raise CaptureError("--local-sidecar-dest must not already exist")
    parent = os.path.realpath(os.path.dirname(path) or ".")
    root = os.path.realpath(out_dir)
    try:
        inside = os.path.commonpath((parent, root)) == root
    except ValueError:
        inside = False
    if not inside:
        raise CaptureError("--local-sidecar-dest must be inside the controlled --out-dir")
    if not os.path.isdir(parent):
        raise CaptureError("--local-sidecar-dest parent directory does not exist")
    if stat.S_IMODE(os.stat(parent).st_mode) & 0o077:
        raise CaptureError("--local-sidecar-dest parent must be owner-only")
    resolved = os.path.join(parent, os.path.basename(path))
    if os.path.basename(resolved) != expected_name:
        raise CaptureError(
            f"--local-sidecar-dest must use the controlled name {expected_name}"
        )
    _write_exclusive(resolved, b"")
    return resolved, {
        "path": resolved,
        "file": expected_name,
        "exclusiveCreatedByHarness": True,
    }


def _next_sequence(out_dir: str) -> int:
    indices: list[int] = []
    for name in os.listdir(out_dir):
        match = re.match(r"^([0-9]{2,})-[A-Z0-9-]+\.", name)
        if match:
            indices.append(int(match.group(1)))
    return max(indices, default=-1) + 1


def _load_json(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CaptureError(f"cannot verify same-session HP manifest {path}: {error}") from None
    if not isinstance(document, dict):
        raise CaptureError(f"same-session HP manifest is not an object: {path}")
    return document


def _latest_hp_payload(
    out_dir: str, expected_hdc_path: str, expected_hdc_sha256: str
) -> tuple[int, bytes]:
    candidates: list[tuple[int, str]] = []
    for name in os.listdir(out_dir):
        match = re.fullmatch(r"([0-9]{2,})-(HP-[12])\.manifest\.json", name)
        if match:
            candidates.append((int(match.group(1)), name))
    if not candidates:
        raise CaptureError(
            "targeted command requires an earlier HP-1/HP-2 capture in the same --out-dir"
        )
    sequence, name = max(candidates)
    manifest = _load_json(os.path.join(out_dir, name))
    command_id = manifest.get("commandId")
    if (
        manifest.get("schema") != MANIFEST_SCHEMA
        or manifest.get("change") != CHANGE_ID
        or manifest.get("task") != TASK_ID
        or manifest.get("evidenceClass") != "controlledHumanCapture"
        or manifest.get("sequence") != sequence
        or command_id not in {"HP-1", "HP-2"}
        or manifest.get("timedOut") is not False
        or manifest.get("captureComplete") is not True
        or manifest.get("selfCheckPassed") is not True
    ):
        raise CaptureError("latest same-session HP capture is not trusted for target binding")
    toolchain = manifest.get("toolchain")
    if (
        not isinstance(toolchain, dict)
        or toolchain.get("hdcPath") != expected_hdc_path
        or toolchain.get("hdcSha256") != expected_hdc_sha256
        or manifest.get("argv") != [expected_hdc_path, "list", "targets", "-v"]
    ):
        raise CaptureError("latest same-session HP capture used a different HDC identity")

    payload = bytearray()
    streams = manifest.get("streams")
    if not isinstance(streams, dict):
        raise CaptureError("latest same-session HP manifest has no streams")
    for stream_name in ("stdout", "stderr"):
        record = streams.get(stream_name)
        if (
            not isinstance(record, dict)
            or record.get("truncated") is not False
            or record.get("drainIncomplete") is not False
        ):
            raise CaptureError(
                "latest same-session HP stream is missing, truncated, or drain-incomplete"
            )
        filename = record.get("file")
        expected_filename = f"{sequence:02d}-{command_id}.{stream_name}"
        if filename != expected_filename or os.path.basename(filename) != filename:
            raise CaptureError("latest same-session HP stream path is invalid")
        path = os.path.join(out_dir, filename)
        try:
            with open(path, "rb") as handle:
                data = handle.read(MAX_STREAM_BYTES + 1)
        except OSError as error:
            raise CaptureError(f"cannot read latest same-session HP stream: {error}") from None
        if len(data) > MAX_STREAM_BYTES:
            raise CaptureError("latest same-session HP stream exceeds the retained cap")
        if hashlib.sha256(data).hexdigest() != record.get("retainedSha256"):
            raise CaptureError("latest same-session HP stream hash does not match its manifest")
        if record.get("sha256") != record.get("retainedSha256"):
            raise CaptureError("latest same-session HP whole/retained hashes disagree")
        payload.extend(data)
        payload.extend(b"\n")
    return sequence, bytes(payload)


def _require_same_session_connect_key(
    out_dir: str,
    connect_key: str,
    expected_hdc_path: str,
    expected_hdc_sha256: str,
) -> int:
    sequence, payload = _latest_hp_payload(
        out_dir, expected_hdc_path, expected_hdc_sha256
    )
    needle = connect_key.encode("ascii")
    for line in payload.splitlines():
        fields = line.split()
        if (
            len(fields) >= 2
            and fields[0] == needle
            and any(field.lower() == b"connected" for field in fields[1:])
        ):
            return sequence
    raise CaptureError(
        "--connect-key is not the Connected target in the latest same-session "
        "HP-1/HP-2 output"
    )


@dataclasses.dataclass(frozen=True)
class PreparedInputs:
    actual: dict[str, str]
    redacted: dict[str, str]
    metadata: dict
    local_paths: tuple[str, ...]
    hp_sequence: Optional[int]


def _prepare_inputs(
    spec: CommandSpec,
    out_dir: str,
    sequence: int,
    hdc_path: str,
    hdc_sha256: str,
    *,
    connect_key: Optional[str],
    window_id: Optional[str],
    local_hap_path: Optional[str],
    local_sidecar_dest: Optional[str],
) -> PreparedInputs:
    supplied = {
        CONNECT_KEY: connect_key,
        WINDOW_ID: window_id,
        LOCAL_HAP_PATH: local_hap_path,
        LOCAL_SIDECAR_DEST: local_sidecar_dest,
    }
    for placeholder, value in supplied.items():
        if placeholder in spec.placeholders and value is None:
            option = "--" + placeholder.lower().replace("_", "-")
            raise CaptureError(f"{spec.ident} requires {option}")
        if placeholder not in spec.placeholders and value is not None:
            option = "--" + placeholder.lower().replace("_", "-")
            raise CaptureError(f"{spec.ident} does not accept {option}")

    actual: dict[str, str] = {}
    metadata: dict = {}
    local_paths: list[str] = []
    hp_sequence: Optional[int] = None

    if CONNECT_KEY in spec.placeholders:
        actual[CONNECT_KEY] = _validate_connect_key(connect_key or "")
        hp_sequence = _require_same_session_connect_key(
            out_dir, actual[CONNECT_KEY], hdc_path, hdc_sha256
        )
        metadata["connectKey"] = {
            "value": actual[CONNECT_KEY],
            "source": "latestSameSessionHP",
            "hpSequence": hp_sequence,
        }
    if WINDOW_ID in spec.placeholders:
        actual[WINDOW_ID] = _validate_window_id(window_id or "")
        metadata["windowId"] = actual[WINDOW_ID]
    if LOCAL_HAP_PATH in spec.placeholders:
        (
            actual[LOCAL_HAP_PATH],
            metadata["localHap"],
            supplied_aliases,
        ) = _validate_hap_path(local_hap_path or "")
        local_paths.append(actual[LOCAL_HAP_PATH])
        local_paths.extend(supplied_aliases)
    if LOCAL_SIDECAR_DEST in spec.placeholders:
        actual[LOCAL_SIDECAR_DEST], metadata["localSidecarDest"] = _validate_sidecar_dest(
            local_sidecar_dest or "", out_dir, f"{sequence:02d}-{spec.ident}.sidecar"
        )
        local_paths.append(actual[LOCAL_SIDECAR_DEST])

    redacted = {placeholder: _REDACTED_VALUES[placeholder] for placeholder in actual}
    return PreparedInputs(
        actual=actual,
        redacted=redacted,
        metadata=metadata,
        local_paths=tuple(local_paths),
        hp_sequence=hp_sequence,
    )


def _validate_stream(stream: CapturedStream, label: str) -> None:
    if len(stream.data) > MAX_STREAM_BYTES:
        raise CaptureError(f"runner returned {label} beyond the retained cap")
    if stream.total_bytes < len(stream.data):
        raise CaptureError(f"runner returned invalid {label} total byte count")
    if stream.truncated != (stream.total_bytes > len(stream.data)):
        raise CaptureError(f"runner returned inconsistent {label} truncation metadata")
    if not isinstance(stream.drain_incomplete, bool):
        raise CaptureError(f"runner returned invalid {label} drain state")
    if not re.fullmatch(r"[0-9a-f]{64}", stream.sha256):
        raise CaptureError(f"runner returned invalid {label} whole-stream SHA-256")
    if not stream.truncated and stream.sha256 != hashlib.sha256(stream.data).hexdigest():
        raise CaptureError(f"runner returned inconsistent {label} whole-stream SHA-256")


def _write_exclusive(path: str, data: bytes) -> None:
    def opener(name: str, flags: int) -> int:
        return os.open(name, flags, 0o600)

    try:
        with open(path, "xb", opener=opener) as handle:
            handle.write(data)
    except FileExistsError:
        raise CaptureError(f"refusing to overwrite existing capture artifact: {path}") from None


def _json_bytes(document: dict) -> bytes:
    return (json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(
        "utf-8"
    )


def _stream_record(filename: str, stream: CapturedStream) -> dict:
    return {
        "file": filename,
        "sha256": stream.sha256,
        "sha256Scope": (
            "observedBeforeDrainCutoff" if stream.drain_incomplete else "wholeStream"
        ),
        "retainedSha256": hashlib.sha256(stream.data).hexdigest(),
        "bytes": stream.total_bytes,
        "retainedBytes": len(stream.data),
        "truncated": stream.truncated,
        "drainIncomplete": stream.drain_incomplete,
    }


def _sidecar_record(path: str, command_may_be_partial: bool) -> dict:
    try:
        info = os.lstat(path)
    except OSError as error:
        raise CaptureError(f"cannot finalize reserved sidecar destination: {error}") from None
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise CaptureError("reserved sidecar destination is no longer a single regular file")
    os.chmod(path, 0o600)
    digest, size = _sha256_file(path)
    return {
        "file": os.path.basename(path),
        "origin": "remoteSidecar",
        "sha256": digest,
        "sha256Scope": "wholeFile",
        "retainedSha256": digest,
        "bytes": size,
        "retainedBytes": size,
        "truncated": False,
        "drainIncomplete": False,
        "possiblyPartial": command_may_be_partial,
    }


def _sidecar_self_check(
    path: str,
    expected_bytes: int,
    connect_key: Optional[str],
    local_paths: tuple[str, ...],
) -> dict:
    """Run the stream sensitive self-check over the received sidecar bytes.

    The scan is complete only when the whole file fits the scan cap and still
    matches the byte count recorded for it; any shortfall fails closed exactly
    like a truncated stdout/stderr stream.
    """
    try:
        with open(path, "rb") as handle:
            data = handle.read(SIDECAR_SELF_CHECK_MAX_BYTES + 1)
    except OSError as error:
        raise CaptureError(
            f"cannot self-check reserved sidecar destination: {error}"
        ) from None
    complete = len(data) <= SIDECAR_SELF_CHECK_MAX_BYTES and len(data) == expected_bytes
    return self_check(
        data[:SIDECAR_SELF_CHECK_MAX_BYTES],
        connect_key,
        local_paths,
        complete=complete,
    )


def _redacted_manifest(
    manifest: dict,
    prepared: PreparedInputs,
    redacted_argv: list[str],
    home: str,
) -> dict:
    redacted = copy.deepcopy(manifest)
    redacted["schema"] = REDACTED_SCHEMA
    redacted["argv"] = [_mask_home(token, home) for token in redacted_argv]
    redacted["toolchain"]["hdcPath"] = _mask_home(
        manifest["toolchain"]["hdcPath"], home
    )
    if "connectKey" in redacted["inputs"]:
        redacted["inputs"]["connectKey"]["value"] = _REDACTED_VALUES[CONNECT_KEY]
    if "windowId" in redacted["inputs"]:
        redacted["inputs"]["windowId"] = _REDACTED_VALUES[WINDOW_ID]
    if "localHap" in redacted["inputs"]:
        redacted["inputs"]["localHap"]["path"] = _REDACTED_VALUES[LOCAL_HAP_PATH]
    if "localSidecarDest" in redacted["inputs"]:
        redacted["inputs"]["localSidecarDest"]["path"] = _REDACTED_VALUES[
            LOCAL_SIDECAR_DEST
        ]
    return redacted


def _capture_hashes_bytes(out_dir: str) -> bytes:
    manifests: list[tuple[int, str, dict]] = []
    for name in sorted(os.listdir(out_dir)):
        match = re.fullmatch(
            r"([0-9]{2,})-[A-Z0-9-]+\.redacted-manifest\.json", name
        )
        if not match:
            continue
        document = _load_json(os.path.join(out_dir, name))
        if document.get("schema") != REDACTED_SCHEMA:
            raise CaptureError(f"unexpected redacted manifest schema in {name}")
        sequence = document.get("sequence")
        if type(sequence) is not int or sequence < 0 or sequence != int(match.group(1)):
            raise CaptureError(f"invalid or missing sequence in redacted manifest {name}")
        streams = document.get("streams")
        if not isinstance(streams, dict) or not {"stdout", "stderr"} <= streams.keys():
            raise CaptureError(f"invalid or missing streams in redacted manifest {name}")
        manifests.append((sequence, name, document))
    lines = [
        "# UD capture stream hashes",
        "",
        f"Schema: `{REDACTED_SCHEMA}`",
        "",
        "| Stream | SHA-256 | Scope | Bytes | Retained bytes | Truncated | Drain incomplete |",
        "| --- | --- | --- | ---: | ---: | --- | --- |",
    ]
    for _sequence, name, manifest in sorted(manifests):
        stream_names = ["stdout", "stderr"]
        if "sidecar" in manifest["streams"]:
            stream_names.append("sidecar")
        for stream_name in stream_names:
            stream = manifest["streams"][stream_name]
            if not isinstance(stream, dict):
                raise CaptureError(f"invalid {stream_name} record in redacted manifest {name}")
            required = {
                "file", "sha256", "sha256Scope", "bytes", "retainedBytes",
                "truncated", "drainIncomplete",
            }
            if not required <= stream.keys():
                raise CaptureError(
                    f"incomplete {stream_name} record in redacted manifest {name}"
                )
            lines.append(
                f"| `{stream['file']}` | `{stream['sha256']}` | "
                f"`{stream['sha256Scope']}` | {stream['bytes']} | "
                f"{stream['retainedBytes']} | `{str(stream['truncated']).lower()}` | "
                f"`{str(stream['drainIncomplete']).lower()}` |"
            )
    return ("\n".join(lines) + "\n").encode("utf-8")


def _replace_derived(path: str, data: bytes) -> None:
    if os.path.lexists(path) and os.path.islink(path):
        raise CaptureError(f"refusing to replace symlinked derived artifact: {path}")
    temp = f"{path}.{os.getpid()}.tmp"
    _write_exclusive(temp, data)
    try:
        os.replace(temp, path)
    except OSError:
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass
        raise


def capture_command(
    *,
    hdc_path: str,
    out_dir: str,
    spec: CommandSpec,
    connect_key: Optional[str] = None,
    window_id: Optional[str] = None,
    local_hap_path: Optional[str] = None,
    local_sidecar_dest: Optional[str] = None,
    runner: Runner = subprocess_runner,
    timeout: int = DEFAULT_TIMEOUT_SECONDS,
    home: Optional[str] = None,
) -> dict:
    """Capture one registered command and return its full controlled manifest."""
    if SPECS_BY_ID.get(spec.ident) is not spec:
        raise CaptureError(f"refusing command outside the closed allowlist: {spec.ident}")
    _require_utf8("--hdc", hdc_path)
    _require_utf8("--out-dir", out_dir)
    if timeout <= 0:
        raise CaptureError("--timeout must be a positive number of seconds")
    resolved_out = _ensure_controlled_directory(out_dir)
    home = os.path.expanduser("~") if home is None else home

    resolved_hdc = os.path.realpath(hdc_path)
    if not os.path.isfile(resolved_hdc) or not os.access(resolved_hdc, os.X_OK):
        raise CaptureError(f"hdc binary is not an executable regular file: {resolved_hdc}")
    hdc_sha256, hdc_bytes = _sha256_file(resolved_hdc)

    sequence = _next_sequence(resolved_out)
    prepared = _prepare_inputs(
        spec,
        resolved_out,
        sequence,
        resolved_hdc,
        hdc_sha256,
        connect_key=connect_key,
        window_id=window_id,
        local_hap_path=local_hap_path,
        local_sidecar_dest=local_sidecar_dest,
    )
    argv = build_argv(resolved_hdc, spec, prepared.actual)
    redacted_argv = build_argv(
        _mask_home(resolved_hdc, home), spec, prepared.redacted
    )
    prefix = f"{sequence:02d}-{spec.ident}"

    try:
        result = runner(argv, timeout)
    except OSError as error:
        raise CaptureError(f"failed to execute hdc for {spec.ident}: {error}") from None
    _validate_stream(result.stdout, "stdout")
    _validate_stream(result.stderr, "stderr")

    stdout_name = f"{prefix}.stdout"
    stderr_name = f"{prefix}.stderr"
    _write_exclusive(os.path.join(resolved_out, stdout_name), result.stdout.data)
    _write_exclusive(os.path.join(resolved_out, stderr_name), result.stderr.data)

    stdout_complete = not result.stdout.truncated and not result.stdout.drain_incomplete
    stderr_complete = not result.stderr.truncated and not result.stderr.drain_incomplete
    stdout_check = _stream_self_check(
        result.stdout.data,
        connect_key,
        prepared.local_paths,
        spec=spec,
        stream_name="stdout",
        complete=stdout_complete,
        timed_out=result.timed_out,
        expected_local_hap_path=prepared.actual.get(LOCAL_HAP_PATH),
    )
    stderr_check = _stream_self_check(
        result.stderr.data,
        connect_key,
        prepared.local_paths,
        spec=spec,
        stream_name="stderr",
        complete=stderr_complete,
        timed_out=result.timed_out,
        expected_local_hap_path=prepared.actual.get(LOCAL_HAP_PATH),
    )
    capture_complete = (
        not result.timed_out
        and not result.stdout.truncated
        and not result.stderr.truncated
        and not result.stdout.drain_incomplete
        and not result.stderr.drain_incomplete
    )
    streams = {
        "stdout": _stream_record(stdout_name, result.stdout),
        "stderr": _stream_record(stderr_name, result.stderr),
    }
    sidecar_check: Optional[dict] = None
    if LOCAL_SIDECAR_DEST in prepared.actual:
        sidecar_path = prepared.actual[LOCAL_SIDECAR_DEST]
        streams["sidecar"] = _sidecar_record(
            sidecar_path,
            command_may_be_partial=(
                result.timed_out
                or result.exit_code != 0
                or result.stdout.drain_incomplete
                or result.stderr.drain_incomplete
            ),
        )
        sidecar_check = _sidecar_self_check(
            sidecar_path,
            streams["sidecar"]["bytes"],
            connect_key,
            prepared.local_paths,
        )
    self_check_passed = (
        stdout_check["passed"]
        and stderr_check["passed"]
        and (sidecar_check is None or sidecar_check["passed"])
    )
    self_check_records = {"stdout": stdout_check, "stderr": stderr_check}
    if sidecar_check is not None:
        self_check_records["sidecar"] = sidecar_check

    manifest = {
        "schema": MANIFEST_SCHEMA,
        "change": CHANGE_ID,
        "task": TASK_ID,
        "evidenceClass": "controlledHumanCapture",
        "sequence": sequence,
        "commandId": spec.ident,
        "purpose": spec.purpose,
        "argv": argv,
        "timeoutSeconds": timeout,
        "exitCode": result.exit_code,
        "timedOut": result.timed_out,
        "durationMs": result.duration_ms,
        "captureComplete": capture_complete,
        "toolchain": {
            "hdcPath": resolved_hdc,
            "hdcSha256": hdc_sha256,
            "hdcBytes": hdc_bytes,
        },
        "host": {
            "os": platform.system(),
            "osVersion": platform.mac_ver()[0] or platform.release(),
            "arch": platform.machine(),
        },
        "inputs": prepared.metadata,
        "streams": streams,
        "selfCheck": self_check_records,
        "selfCheckPassed": self_check_passed,
        "boundary": (
            "human-operated controlled capture; raw bytes and full manifest remain outside "
            "git; no Recipe success, compatibility, support, or canonical AC PASS is claimed"
        ),
    }
    redacted = _redacted_manifest(manifest, prepared, redacted_argv, home)
    redacted_bytes = _json_bytes(redacted)

    full_name = f"{prefix}.manifest.json"
    redacted_name = f"{prefix}.redacted-manifest.json"
    _write_exclusive(os.path.join(resolved_out, full_name), _json_bytes(manifest))
    _assert_redacted_clean(
        redacted_bytes.decode("utf-8"),
        home=home,
        connect_key=connect_key,
        window_id=window_id,
        local_paths=prepared.local_paths,
    )
    _write_exclusive(os.path.join(resolved_out, redacted_name), redacted_bytes)

    summary = _capture_hashes_bytes(resolved_out)
    _assert_redacted_clean(
        summary.decode("utf-8"),
        home=home,
        connect_key=connect_key,
        window_id=window_id,
        local_paths=prepared.local_paths,
    )
    _replace_derived(os.path.join(resolved_out, "capture-hashes.md"), summary)
    return manifest


def _positive_int(value: str) -> int:
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not an integer: {value!r}") from None
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive number of seconds")
    return number


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="capture.py",
        description="CHG-2026-008 controlled UI Dump capture (human maintainer only)",
    )
    parser.add_argument("--hdc", required=True, help="absolute path to the pinned hdc binary")
    parser.add_argument(
        "--out-dir",
        required=True,
        help="owner-only controlled session directory outside every git repository",
    )
    parser.add_argument("--command", required=True, choices=tuple(SPECS_BY_ID))
    parser.add_argument("--connect-key")
    parser.add_argument("--window-id")
    parser.add_argument("--local-hap-path")
    parser.add_argument("--local-sidecar-dest")
    parser.add_argument(
        "--timeout",
        type=_positive_int,
        default=DEFAULT_TIMEOUT_SECONDS,
        help="per-command timeout in seconds (default 120; cannot be disabled)",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    arguments = build_arg_parser().parse_args(argv)
    try:
        manifest = capture_command(
            hdc_path=arguments.hdc,
            out_dir=arguments.out_dir,
            spec=SPECS_BY_ID[arguments.command],
            connect_key=arguments.connect_key,
            window_id=arguments.window_id,
            local_hap_path=arguments.local_hap_path,
            local_sidecar_dest=arguments.local_sidecar_dest,
            timeout=arguments.timeout,
        )
    except StopRequired as error:
        print(f"capture stop required: {error}", file=sys.stderr)
        return 1
    except CaptureError as error:
        print(f"capture error: {error}", file=sys.stderr)
        return 2
    safe = manifest["selfCheckPassed"] and manifest["captureComplete"]
    print(
        f"capture {manifest['commandId']} complete; "
        + (
            "checks PASSED"
            if safe
            else "STOP REQUIRED (timeout/truncation/drain/sensitive check)"
        )
    )
    print("controlled output:", os.path.abspath(arguments.out_dir))
    return 0 if safe else 1


if __name__ == "__main__":
    sys.exit(main())
