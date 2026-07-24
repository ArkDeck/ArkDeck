#!/usr/bin/env python3
"""One-run DAYU200 HDC -> RockUSB Loader E1 characterization.

The production CLI loads every authority and command token from the reviewed
integration registry. It accepts only a path to the already-pinned
``rkdeveloptool`` artifact and the fixed impact-confirmation token. It never
accepts an HDC target, HDC path, command, shell string, argv suffix, retry flag,
or server-lifecycle operation from the caller.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import fcntl
import hashlib
import json
import os
import pathlib
import platform
import re
import subprocess
import sys
import time
import uuid
from typing import Any, Callable, Optional


REGISTRY_RELATIVE_PATH = pathlib.Path(
    "openspec/integrations/rockchip/loader-transition/1.0.0/registry.yaml"
)
SOURCE_PROVENANCE_KIND = "protectedMainArtifactDigestToUpstreamCommit"
SOURCE_ACCEPTANCE_REF = "PR#445@cbad982cc211c7d8579a025b8c35f4ed1a519f16"
SOURCE_EVIDENCE_RELATIVE_PATH = (
    "openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/"
    "TASK-RKFUI-001/clean-discovery-repin-2026-07-24.md"
)
SOURCE_EVIDENCE_SHA256 = (
    "d0b5089954e19a4aba354846fe6108b2d5c89bfc12ab0396c2cd7eb4a082189a"
)
R6_AUTHORIZATION_REF = "PR#491@37e16c5dd42951c02422627b9f7ca0d72a5cdafc"
EXPECTED_AUTHORIZATION_REFS = (
    "PR#440@f4e901492e7d3b82f883424c756868fffa4946df",
    "PR#452@d22cdeeebc781b9c3a1b063dbee6631934c51ac0",
    "PR#481@0f0a79aff7ede1519b9fbc0cbdca12b5c687ef07",
    R6_AUTHORIZATION_REF,
)
EXPECTED_HDC = {
    "absoluteExecutable": (
        "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
    ),
    "reportedVersion": "Ver: 3.2.0f",
    "sha256": "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83",
    "serverRequirement": "preExistingExternalSameUIDPinnedExecutable",
    "serverLifecycleMutationAllowed": False,
}
EXPECTED_SOURCE_PROVENANCE = {
    "kind": SOURCE_PROVENANCE_KIND,
    "artifactSHA256": "bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923",
    "upstreamCommit": "304f073752fd25c854e1bcf05d8e7f925b1f4e14",
    "acceptedBy": SOURCE_ACCEPTANCE_REF,
    "evidencePath": SOURCE_EVIDENCE_RELATIVE_PATH,
    "evidenceSHA256": SOURCE_EVIDENCE_SHA256,
}
EXPECTED_ROCKUSB_OBSERVATION = {
    "reportedVersion": "rkdeveloptool ver 1.32",
    "sha256": "bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923",
    "upstreamCommit": "304f073752fd25c854e1bcf05d8e7f925b1f4e14",
    "sourceProvenance": EXPECTED_SOURCE_PROVENANCE,
    "signatureClass": "adHoc",
    "quarantineAllowed": False,
    "exactArgv": ["ld"],
    "expectedObservation": {
        "usbVendorID": "0x2207",
        "usbProductID": "0x350a",
        "mode": "Loader",
    },
}
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
LINE_PATTERN = re.compile(
    rb"\ADevNo=([0-9]+)\tVid=0x([0-9A-Fa-f]{4}),Pid=0x([0-9A-Fa-f]{4}),"
    rb"LocationID=([0-9]+)\t([A-Za-z][A-Za-z0-9_-]{0,31})\Z"
)
SERIAL_TOKEN = re.compile(rb"\A([0-9A-Fa-f]{16,64})(?:\s+.*)?\Z")
FORBIDDEN_E1_TOKENS = frozenset(
    {
        "ppt",
        "wlx",
        "rd",
        "flash",
        "erase",
        "format",
        "unlock",
        "update",
        "sudo",
        "kill",
        "killall",
        "start",
        "stop",
    }
)
MAX_RAW_BYTES = 65_536


class ProbeError(RuntimeError):
    """A fail-closed harness or readiness error."""


@dataclasses.dataclass(frozen=True)
class CommandResult:
    exit_code: Optional[int]
    timed_out: bool
    stdout: bytes
    stderr: bytes
    duration_ms: int
    output_truncated: bool = False


Runner = Callable[[list[str], int, pathlib.Path], CommandResult]
ServerInspector = Callable[[pathlib.Path], dict[str, Any]]
USBReader = Callable[[int, pathlib.Path], CommandResult]


@dataclasses.dataclass(frozen=True)
class SourceProvenance:
    kind: str
    artifact_sha256: str
    upstream_commit: str
    accepted_by: str
    evidence_path: str
    evidence_sha256: str

    def receipt(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "artifactSHA256": self.artifact_sha256,
            "upstreamCommit": self.upstream_commit,
            "acceptedBy": self.accepted_by,
            "evidence": {
                "path": self.evidence_path,
                "sha256": self.evidence_sha256,
            },
            "validationVerdict": "matchedProtectedMainRegistryAndEvidence",
        }


@dataclasses.dataclass(frozen=True)
class Config:
    repo_root: pathlib.Path
    state_root: pathlib.Path
    hdc_path: pathlib.Path
    rkdeveloptool_path: pathlib.Path
    authorization_refs: tuple[str, ...]
    valid_until: dt.datetime
    max_runs: int
    target_model: str
    target_soc: str
    serial_sha256: str
    firmware: str
    transport: str
    binding_revision: int
    hdc_version: str
    hdc_sha256: str
    rkdeveloptool_version: str
    rkdeveloptool_sha256: str
    rkdeveloptool_upstream_commit: str
    rkdeveloptool_source_provenance: SourceProvenance
    e1_arguments_template: tuple[str, ...]
    firmware_arguments_template: tuple[str, ...]
    impact_confirmation_token: str
    command_timeout_ms: int
    disconnect_deadline_ms: int
    loader_deadline_ms: int
    poll_interval_ms: int
    maximum_output_bytes: int

    def materialize_e1(self, connect_key: str) -> list[str]:
        arguments = [
            connect_key if token == "<durable-connect-key>" else token
            for token in self.e1_arguments_template
        ]
        expected = ["-t", connect_key, "shell", "reboot", "loader"]
        if arguments != expected:
            raise ProbeError("registry E1 argv is not the one closed reboot-loader shape")
        if FORBIDDEN_E1_TOKENS.intersection(arguments):
            # "reboot" and "loader" are intentionally absent from the forbidden set.
            raise ProbeError("registry E1 argv contains a forbidden token")
        return [str(self.hdc_path), *arguments]

    def materialize_firmware_readback(self, connect_key: str) -> list[str]:
        arguments = [
            connect_key if token == "<durable-connect-key>" else token
            for token in self.firmware_arguments_template
        ]
        expected = [
            "-t",
            connect_key,
            "shell",
            "param",
            "get",
            "const.product.software.version",
        ]
        if arguments != expected:
            raise ProbeError("registry firmware readback argv is not the fixed read-only shape")
        return [str(self.hdc_path), *arguments]


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso8601(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(64 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _source_evidence_path(repo_root: pathlib.Path, relative_path: str) -> pathlib.Path:
    if relative_path != SOURCE_EVIDENCE_RELATIVE_PATH:
        raise ProbeError("rkdeveloptool source evidence path drifted")
    pure_path = pathlib.PurePosixPath(relative_path)
    if pure_path.is_absolute() or any(part in ("", ".", "..") for part in pure_path.parts):
        raise ProbeError("rkdeveloptool source evidence path is not a safe repo-relative path")
    resolved_root = repo_root.resolve()
    resolved_evidence = resolved_root.joinpath(*pure_path.parts).resolve()
    try:
        resolved_evidence.relative_to(resolved_root)
    except ValueError as error:
        raise ProbeError("rkdeveloptool source evidence escapes the repository") from error
    if not resolved_evidence.is_file():
        raise ProbeError("rkdeveloptool source evidence is unavailable")
    return resolved_evidence


def validate_source_provenance(config: Config) -> dict[str, Any]:
    provenance = config.rkdeveloptool_source_provenance
    if provenance.kind != SOURCE_PROVENANCE_KIND:
        raise ProbeError("rkdeveloptool source provenance kind drifted")
    if provenance.artifact_sha256 != config.rkdeveloptool_sha256:
        raise ProbeError("rkdeveloptool artifact/source provenance SHA-256 tuple mismatch")
    if provenance.upstream_commit != config.rkdeveloptool_upstream_commit:
        raise ProbeError("rkdeveloptool artifact/source provenance commit tuple mismatch")
    if provenance.accepted_by != SOURCE_ACCEPTANCE_REF:
        raise ProbeError("rkdeveloptool source acceptance ref drifted")
    if provenance.evidence_sha256 != SOURCE_EVIDENCE_SHA256:
        raise ProbeError("rkdeveloptool source evidence SHA-256 pin drifted")
    if not re.fullmatch(r"[0-9a-f]{64}", provenance.artifact_sha256):
        raise ProbeError("rkdeveloptool source artifact SHA-256 is malformed")
    if not re.fullmatch(r"[0-9a-f]{40}", provenance.upstream_commit):
        raise ProbeError("rkdeveloptool source upstream commit is malformed")
    evidence_path = _source_evidence_path(config.repo_root, provenance.evidence_path)
    observed_evidence_sha256 = sha256_file(evidence_path)
    if observed_evidence_sha256 != provenance.evidence_sha256:
        raise ProbeError("rkdeveloptool reviewed source evidence bytes drifted")
    return provenance.receipt()


def canonical_json_bytes(document: Any) -> bytes:
    return (
        json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")


def argv_sha256(argv: list[str]) -> str:
    return sha256_bytes(
        json.dumps(argv, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    )


def assert_outside_repository(path: pathlib.Path) -> None:
    current = path.expanduser().resolve()
    while True:
        if (current / ".git").exists():
            raise ProbeError(
                f"controlled state must be outside every git repository (.git at {current})"
            )
        if current.parent == current:
            return
        current = current.parent


def _fsync_directory(path: pathlib.Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def ensure_private_directory(path: pathlib.Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def write_new_bytes(path: pathlib.Path, data: bytes) -> str:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        os.close(descriptor)
    _fsync_directory(path.parent)
    return sha256_bytes(data)


def write_new_json(path: pathlib.Path, document: Any) -> str:
    return write_new_bytes(path, canonical_json_bytes(document))


def replace_json(path: pathlib.Path, document: Any) -> str:
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    data = canonical_json_bytes(document)
    write_new_bytes(temporary, data)
    os.replace(temporary, path)
    _fsync_directory(path.parent)
    return sha256_bytes(data)


def subprocess_runner(argv: list[str], timeout_ms: int, cwd: pathlib.Path) -> CommandResult:
    started = time.monotonic()
    try:
        completed = subprocess.run(  # noqa: S603 - closed argv array, never a host shell
            argv,
            cwd=str(cwd),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=timeout_ms / 1_000,
            check=False,
        )
    except subprocess.TimeoutExpired as expired:
        stdout = expired.stdout or b""
        stderr = expired.stderr or b""
        truncated = len(stdout) + len(stderr) > MAX_RAW_BYTES
        bounded_stdout = stdout[:MAX_RAW_BYTES]
        bounded_stderr = stderr[: MAX_RAW_BYTES - len(bounded_stdout)]
        return CommandResult(
            exit_code=None,
            timed_out=True,
            stdout=bounded_stdout,
            stderr=bounded_stderr,
            duration_ms=int((time.monotonic() - started) * 1_000),
            output_truncated=truncated,
        )
    stdout = completed.stdout
    stderr = completed.stderr
    truncated = len(stdout) + len(stderr) > MAX_RAW_BYTES
    bounded_stdout = stdout[:MAX_RAW_BYTES]
    bounded_stderr = stderr[: MAX_RAW_BYTES - len(bounded_stdout)]
    return CommandResult(
        exit_code=completed.returncode,
        timed_out=False,
        stdout=bounded_stdout,
        stderr=bounded_stderr,
        duration_ms=int((time.monotonic() - started) * 1_000),
        output_truncated=truncated,
    )


def system_profiler_reader(timeout_ms: int, cwd: pathlib.Path) -> CommandResult:
    return subprocess_runner(
        ["/usr/sbin/system_profiler", "SPUSBDataType", "-json"], timeout_ms, cwd
    )


def load_config(
    rkdeveloptool_path: pathlib.Path,
    *,
    repo_root: Optional[pathlib.Path] = None,
    state_root: Optional[pathlib.Path] = None,
) -> Config:
    root = repo_root or pathlib.Path(__file__).resolve().parents[2]
    registry_path = root / REGISTRY_RELATIVE_PATH
    try:
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ProbeError(f"cannot load integration registry: {error}") from error

    if registry.get("schemaVersion") != "1.0.0":
        raise ProbeError("unexpected registry schemaVersion")
    if registry.get("registryId") != "ROCKCHIP-DAYU200-HDC-LOADER-TRANSITION":
        raise ProbeError("unexpected registryId")
    if registry.get("characterizationStatus") not in (
        "pending",
        "supported",
        "unsupported",
        "unknown",
    ):
        raise ProbeError("invalid characterizationStatus")

    authorization = registry["authorization"]
    target = registry["target"]
    hdc = registry["hdc"]
    rockusb = registry["rockUSBObservation"]
    operation = registry["operation"]
    if tuple(authorization.get("refs", ())) != EXPECTED_AUTHORIZATION_REFS:
        raise ProbeError("loader-transition authorization refs drifted")
    if hdc != EXPECTED_HDC:
        raise ProbeError("loader-transition HDC exact pin or server policy drifted")
    if not isinstance(rockusb, dict) or not isinstance(
        rockusb.get("sourceProvenance"), dict
    ):
        raise ProbeError("loader-transition RockUSB source provenance is missing")
    source_provenance = rockusb["sourceProvenance"]
    if (
        rockusb.get("sha256") != source_provenance.get("artifactSHA256")
        or rockusb.get("upstreamCommit") != source_provenance.get("upstreamCommit")
    ):
        raise ProbeError("loader-transition RockUSB top-level/provenance tuple mismatch")
    if rockusb != EXPECTED_ROCKUSB_OBSERVATION:
        raise ProbeError("loader-transition RockUSB exact pin or provenance drifted")
    valid_until = dt.datetime.fromisoformat(
        authorization["validUntil"].replace("Z", "+00:00")
    )
    default_state = (
        pathlib.Path.home()
        / "Library"
        / "Application Support"
        / "ArkDeck"
        / "Characterization"
        / "TASK-RKFUI-001A"
    )
    config = Config(
        repo_root=root.resolve(),
        state_root=(state_root or default_state).expanduser().resolve(),
        hdc_path=pathlib.Path(hdc["absoluteExecutable"]).resolve(),
        rkdeveloptool_path=rkdeveloptool_path.expanduser().resolve(),
        authorization_refs=tuple(authorization["refs"]),
        valid_until=valid_until,
        max_runs=authorization["maxRuns"],
        target_model=target["model"],
        target_soc=target["soc"],
        serial_sha256=target["serialSHA256"],
        firmware=target["firmware"],
        transport=target["transport"],
        binding_revision=target["requiredInitialBindingRevision"],
        hdc_version=hdc["reportedVersion"],
        hdc_sha256=hdc["sha256"],
        rkdeveloptool_version=rockusb["reportedVersion"],
        rkdeveloptool_sha256=rockusb["sha256"],
        rkdeveloptool_upstream_commit=rockusb["upstreamCommit"],
        rkdeveloptool_source_provenance=SourceProvenance(
            kind=source_provenance["kind"],
            artifact_sha256=source_provenance["artifactSHA256"],
            upstream_commit=source_provenance["upstreamCommit"],
            accepted_by=source_provenance["acceptedBy"],
            evidence_path=source_provenance["evidencePath"],
            evidence_sha256=source_provenance["evidenceSHA256"],
        ),
        e1_arguments_template=tuple(operation["exactArgvTemplate"]),
        firmware_arguments_template=tuple(operation["firmwareReadbackArgvTemplate"]),
        impact_confirmation_token=operation["impactConfirmationToken"],
        command_timeout_ms=operation["commandTimeoutMilliseconds"],
        disconnect_deadline_ms=operation["disconnectDeadlineMilliseconds"],
        loader_deadline_ms=operation["loaderDeadlineMilliseconds"],
        poll_interval_ms=operation["pollIntervalMilliseconds"],
        maximum_output_bytes=operation["maximumOutputBytes"],
    )
    validate_config(config)
    return config


def validate_config(config: Config) -> None:
    if config.max_runs != 1:
        raise ProbeError("registry maxRuns must be exactly 1")
    if config.binding_revision != 1:
        raise ProbeError("characterization requires initial binding revision 1")
    if config.transport != "usb":
        raise ProbeError("characterization transport must be usb")
    if config.hdc_path != pathlib.Path(
        "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
    ):
        raise ProbeError("HDC path differs from the approved absolute path")
    if len(config.serial_sha256) != 64 or len(config.hdc_sha256) != 64:
        raise ProbeError("registry SHA-256 field is malformed")
    if len(config.rkdeveloptool_sha256) != 64:
        raise ProbeError("registry rkdeveloptool SHA-256 is malformed")
    validate_source_provenance(config)
    if config.maximum_output_bytes != MAX_RAW_BYTES:
        raise ProbeError("registry maximumOutputBytes drifted")
    assert_outside_repository(config.state_root)
    # Exercise the exact materializers with a synthetic value. Caller data cannot alter tokens.
    config.materialize_e1("synthetic-connect-key")
    config.materialize_firmware_readback("synthetic-connect-key")


def inspect_hdc_server(
    hdc_path: pathlib.Path,
    *,
    command_runner: Runner = subprocess_runner,
) -> dict[str, Any]:
    scratch = pathlib.Path("/private/tmp")
    listener_result = command_runner(
        [
            "/usr/sbin/lsof",
            "-nP",
            "-a",
            "-iTCP:8710",
            "-sTCP:LISTEN",
            "-Fpu",
        ],
        5_000,
        scratch,
    )
    if (
        listener_result.exit_code != 0
        or listener_result.timed_out
        or listener_result.stderr
        or listener_result.output_truncated
    ):
        raise ProbeError("cannot inspect the pre-existing HDC listener")
    listeners: dict[int, int] = {}
    current_pid: Optional[int] = None
    for raw_line in listener_result.stdout.decode(
        "utf-8", errors="replace"
    ).splitlines():
        if raw_line.startswith("p"):
            try:
                current_pid = int(raw_line[1:])
            except ValueError as error:
                raise ProbeError("HDC listener PID is malformed") from error
        elif raw_line.startswith("u") and current_pid is not None:
            try:
                listeners[current_pid] = int(raw_line[1:])
            except ValueError as error:
                raise ProbeError("HDC listener UID is malformed") from error
    if len(listeners) != 1:
        raise ProbeError(
            f"expected exactly one pre-existing HDC listener, observed {len(listeners)}"
        )
    pid, listener_uid = next(iter(listeners.items()))
    if listener_uid != os.getuid():
        raise ProbeError("HDC listener is not owned by the current user")

    ps_result = command_runner(
        [
            "/bin/ps",
            "-p",
            str(pid),
            "-o",
            "pid=,ppid=,uid=,command=",
        ],
        5_000,
        scratch,
    )
    if (
        ps_result.exit_code != 0
        or ps_result.timed_out
        or ps_result.stderr
        or ps_result.output_truncated
    ):
        raise ProbeError("cannot inspect the pre-existing HDC server process")
    process_lines = [
        line
        for line in ps_result.stdout.decode(
            "utf-8", errors="replace"
        ).splitlines()
        if line.strip()
    ]
    if len(process_lines) != 1:
        raise ProbeError("HDC listener process identity is ambiguous")
    fields = process_lines[0].strip().split(maxsplit=3)
    if len(fields) != 4:
        raise ProbeError("HDC listener process record is malformed")
    try:
        observed_pid, ppid, uid = int(fields[0]), int(fields[1]), int(fields[2])
    except ValueError as error:
        raise ProbeError("HDC listener process fields are malformed") from error
    command = fields[3]
    if observed_pid != pid or uid != listener_uid:
        raise ProbeError("HDC listener identity changed during inspection")
    if uid != os.getuid():
        raise ProbeError("HDC server is not owned by the current user")
    if command != "hdc -m -s ::ffff:127.0.0.1:8710":
        raise ProbeError("HDC server command shape is unknown")

    lsof_result = command_runner(
        ["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "txt", "-Fn"], 5_000, scratch
    )
    if lsof_result.exit_code != 0 or lsof_result.timed_out:
        raise ProbeError("cannot resolve HDC server executable identity")
    names = [
        pathlib.Path(line[1:]).resolve()
        for line in lsof_result.stdout.decode("utf-8", errors="replace").splitlines()
        if line.startswith("n/")
    ]
    if hdc_path.resolve() not in names:
        raise ProbeError("HDC server executable does not match the pinned client")
    return {
        "pid": pid,
        "parentPID": ppid,
        "sameUIDAsExecutor": True,
        "ownership": "preExistingExternalSameUIDPinnedExecutable",
        "listener": "127.0.0.1:8710",
        "executableMatchedClient": True,
        "serverLifecycleMutationCount": 0,
    }


def parse_hdc_targets(stdout: bytes, stderr: bytes, result: CommandResult) -> list[bytes]:
    if result.output_truncated:
        raise ProbeError("HDC target output exceeded the bounded capture")
    if result.timed_out or result.exit_code != 0 or stderr:
        raise ProbeError("HDC target enumeration failed")
    targets: list[bytes] = []
    for line in stdout.splitlines():
        stripped = line.strip()
        if not stripped or stripped.lower() == b"[empty]":
            continue
        match = SERIAL_TOKEN.fullmatch(stripped)
        if not match:
            raise ProbeError("HDC target output contains an unknown line family")
        targets.append(match.group(1))
    if len(set(targets)) != len(targets):
        raise ProbeError("HDC target output contains a duplicate connect key")
    return targets


def target_summary(targets: list[bytes]) -> list[dict[str, str]]:
    return [{"connectKeySHA256": sha256_bytes(target)} for target in targets]


def require_exact_target(targets: list[bytes], serial_sha256: str) -> bytes:
    matching = [target for target in targets if sha256_bytes(target) == serial_sha256]
    if len(targets) != 1 or len(matching) != 1:
        raise ProbeError(
            "expected exactly one HDC target and one exact serial digest match"
        )
    return matching[0]


def parse_firmware(result: CommandResult, expected: str) -> str:
    if result.output_truncated or result.timed_out:
        raise ProbeError("firmware readback was truncated or timed out")
    if result.exit_code != 0 or result.stderr:
        raise ProbeError("firmware readback failed")
    try:
        value = result.stdout.decode("utf-8").strip()
    except UnicodeDecodeError as error:
        raise ProbeError("firmware readback is not UTF-8") from error
    if value != expected:
        raise ProbeError(f"firmware pin mismatch: observed {value!r}")
    return value


def parse_ld(result: CommandResult) -> dict[str, Any]:
    stdout, stderr = result.stdout, result.stderr
    if result.output_truncated or len(stdout) + len(stderr) > MAX_RAW_BYTES:
        return {"status": "blocked", "reason": "outputTooLarge", "observations": []}
    lowered = (stdout + stderr).lower()
    if any(
        marker in lowered
        for marker in (b"permission denied", b"operation not permitted", b"libusb_error_access")
    ):
        return {"status": "blocked", "reason": "permissionDenied", "observations": []}
    if any(
        marker in lowered
        for marker in (b"driver unavailable", b"libusb_init failed", b"no libusb backend")
    ):
        return {"status": "blocked", "reason": "driverUnavailable", "observations": []}
    if result.timed_out:
        return {"status": "blocked", "reason": "timeout", "observations": []}
    if result.exit_code != 0:
        return {
            "status": "offline",
            "reason": "nonzeroWithoutRegisteredOutput",
            "observations": [],
        }
    if stderr:
        return {"status": "blocked", "reason": "unexpectedStandardError", "observations": []}
    if not stdout:
        return {"status": "offline", "reason": "empty", "observations": []}
    try:
        stdout.decode("utf-8")
    except UnicodeDecodeError:
        return {"status": "blocked", "reason": "invalidUTF8", "observations": []}

    lines, line_termination_error = split_registered_ld_lines(stdout)
    if line_termination_error is not None:
        return {
            "status": "blocked",
            "reason": line_termination_error,
            "observations": [],
        }
    if not lines or len(lines) > 64:
        return {"status": "blocked", "reason": "deviceCount", "observations": []}
    device_numbers: set[int] = set()
    location_ids: set[int] = set()
    observations: list[dict[str, Any]] = []
    for line_number, line in enumerate(lines, start=1):
        match = LINE_PATTERN.fullmatch(line)
        if not match:
            return {
                "status": "blocked",
                "reason": f"malformedLine:{line_number}",
                "observations": [],
            }
        if any(
            value != b"0" and value.startswith(b"0")
            for value in (match.group(1), match.group(4))
        ):
            return {
                "status": "blocked",
                "reason": f"numberOutOfRange:{line_number}",
                "observations": [],
            }
        device_number = int(match.group(1))
        location_id = int(match.group(4))
        if device_number > 0xFFFF_FFFF or location_id > 0xFFFF_FFFF_FFFF_FFFF:
            return {
                "status": "blocked",
                "reason": f"numberOutOfRange:{line_number}",
                "observations": [],
            }
        if device_number in device_numbers:
            return {
                "status": "blocked",
                "reason": "duplicateDeviceNumber",
                "observations": [],
            }
        if location_id in location_ids:
            return {
                "status": "blocked",
                "reason": "duplicateLocationID",
                "observations": [],
            }
        device_numbers.add(device_number)
        location_ids.add(location_id)
        mode = match.group(5).decode("ascii")
        if mode not in ("Loader", "Maskrom"):
            return {
                "status": "blocked",
                "reason": f"unknownMode:{mode}",
                "observations": [],
            }
        vendor = int(match.group(2), 16)
        product = int(match.group(3), 16)
        observations.append(
            {
                "deviceNumber": device_number,
                "usbVendorID": f"0x{vendor:04x}",
                "usbProductID": f"0x{product:04x}",
                "locationIDSHA256": sha256_bytes(str(location_id).encode("ascii")),
                "mode": mode,
                "isExpectedLoader": (vendor, product, mode) == (0x2207, 0x350A, "Loader"),
            }
        )
    return {"status": "observations", "reason": None, "observations": observations}


def split_registered_ld_lines(stdout: bytes) -> tuple[list[bytes], str | None]:
    lines: list[bytes] = []
    line_start = 0
    line_number = 1
    registered_terminator_is_crlf: bool | None = None
    index = 0

    while index < len(stdout):
        byte = stdout[index]
        if byte == 0x0D:
            if index + 1 >= len(stdout) or stdout[index + 1] != 0x0A:
                return [], "unexpectedCarriageReturn"
        elif byte == 0x0A:
            terminator_is_crlf = index > line_start and stdout[index - 1] == 0x0D
            if (
                registered_terminator_is_crlf is not None
                and registered_terminator_is_crlf != terminator_is_crlf
            ):
                return [], "mixedLineTerminators"
            registered_terminator_is_crlf = terminator_is_crlf

            line_end = index - 1 if terminator_is_crlf else index
            if line_start == line_end:
                return [], f"emptyLine:{line_number}"
            lines.append(stdout[line_start:line_end])
            line_start = index + 1
            line_number += 1
        index += 1

    if line_start != len(stdout):
        return [], "missingFinalLineTerminator"
    return lines, None


def parse_usb_topology(system_profiler_json: bytes) -> list[dict[str, str]]:
    try:
        document = json.loads(system_profiler_json or b"{}")
    except (json.JSONDecodeError, ValueError):
        return []
    found: list[dict[str, str]] = []

    def leading_hex(value: object) -> Optional[int]:
        if not isinstance(value, str):
            return None
        match = re.match(r"\s*0x([0-9A-Fa-f]+)", value)
        return int(match.group(1), 16) if match else None

    def walk(node: object) -> None:
        if isinstance(node, dict):
            vendor = leading_hex(node.get("vendor_id"))
            product = leading_hex(node.get("product_id"))
            if vendor == 0x2207 and product is not None:
                location_material = "|".join(
                    str(node.get(key, ""))
                    for key in ("location_id", "_locationID", "serial_num")
                )
                found.append(
                    {
                        "usbVendorID": f"0x{vendor:04x}",
                        "usbProductID": f"0x{product:04x}",
                        "topologySHA256": sha256_bytes(location_material.encode("utf-8")),
                    }
                )
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(document)
    return found


def capture_command(
    *,
    runner: Runner,
    argv: list[str],
    timeout_ms: int,
    run_dir: pathlib.Path,
    stem: str,
    ordinal: int,
) -> tuple[CommandResult, dict[str, Any]]:
    result = runner(argv, timeout_ms, run_dir)
    stdout_name = f"{ordinal:03d}-{stem}.stdout"
    stderr_name = f"{ordinal:03d}-{stem}.stderr"
    stdout_sha = write_new_bytes(run_dir / stdout_name, result.stdout)
    stderr_sha = write_new_bytes(run_dir / stderr_name, result.stderr)
    receipt = {
        "ordinal": ordinal,
        "commandId": stem,
        "startedArgvSHA256": argv_sha256(argv),
        "exitCode": result.exit_code,
        "timedOut": result.timed_out,
        "durationMilliseconds": result.duration_ms,
        "outputTruncated": result.output_truncated,
        "stdout": {"file": stdout_name, "bytes": len(result.stdout), "sha256": stdout_sha},
        "stderr": {"file": stderr_name, "bytes": len(result.stderr), "sha256": stderr_sha},
    }
    return result, receipt


def inspect_rkdeveloptool(
    config: Config,
    *,
    runner: Runner,
    run_dir: pathlib.Path,
    ordinal: int,
) -> tuple[dict[str, Any], int]:
    source_provenance_receipt = validate_source_provenance(config)
    path = config.rkdeveloptool_path
    if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
        raise ProbeError("rkdeveloptool is not an executable absolute regular file")
    observed_hash = sha256_file(path)
    if observed_hash != config.rkdeveloptool_sha256:
        raise ProbeError("rkdeveloptool SHA-256 mismatch")

    version_result, version_receipt = capture_command(
        runner=runner,
        argv=[str(path), "-v"],
        timeout_ms=5_000,
        run_dir=run_dir,
        stem="rkdeveloptool-version",
        ordinal=ordinal,
    )
    ordinal += 1
    if (
        version_result.exit_code != 0
        or version_result.timed_out
        or version_result.stderr
        or version_result.stdout.decode("utf-8", errors="replace").strip()
        != config.rkdeveloptool_version
    ):
        raise ProbeError("rkdeveloptool reported version mismatch")

    signature_result, signature_receipt = capture_command(
        runner=runner,
        argv=["/usr/bin/codesign", "-dv", "--verbose=4", str(path)],
        timeout_ms=5_000,
        run_dir=run_dir,
        stem="rkdeveloptool-codesign",
        ordinal=ordinal,
    )
    ordinal += 1
    signature_text = (signature_result.stdout + signature_result.stderr).decode(
        "utf-8", errors="replace"
    )
    if (
        signature_result.exit_code != 0
        or signature_result.timed_out
        or "Signature=adhoc" not in signature_text
    ):
        raise ProbeError("rkdeveloptool is not the approved ad-hoc signed artifact")
    quarantine_result, quarantine_receipt = capture_command(
        runner=runner,
        argv=["/usr/bin/xattr", "-p", "com.apple.quarantine", str(path)],
        timeout_ms=5_000,
        run_dir=run_dir,
        stem="rkdeveloptool-quarantine",
        ordinal=ordinal,
    )
    ordinal += 1
    quarantine_missing = (
        quarantine_result.exit_code == 1
        and not quarantine_result.timed_out
        and not quarantine_result.stdout
        and b"No such xattr" in quarantine_result.stderr
    )
    if quarantine_result.exit_code == 0 and not quarantine_result.timed_out:
        raise ProbeError("rkdeveloptool quarantine is present")
    if not quarantine_missing:
        raise ProbeError("cannot prove rkdeveloptool quarantine is absent")

    return (
        {
            "basename": path.name,
            "reportedVersion": config.rkdeveloptool_version,
            "sha256": observed_hash,
            "upstreamCommit": config.rkdeveloptool_upstream_commit,
            "sourceProvenance": source_provenance_receipt,
            "signatureClass": "adHoc",
            "quarantinePresent": False,
            "versionReceipt": version_receipt,
            "signatureReceipt": signature_receipt,
            "quarantineReceipt": quarantine_receipt,
        },
        ordinal,
    )


def sanitized_command_receipt(receipt: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in receipt.items()
        if key not in {"stdout", "stderr"}
    } | {
        "stdout": {
            "bytes": receipt["stdout"]["bytes"],
            "sha256": receipt["stdout"]["sha256"],
        },
        "stderr": {
            "bytes": receipt["stderr"]["bytes"],
            "sha256": receipt["stderr"]["sha256"],
        },
    }


def _acquire_lane(state_root: pathlib.Path):
    lane_path = state_root / "device-mutation-lane.lock"
    descriptor = os.open(lane_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        os.close(descriptor)
        raise ProbeError("device mutation lane is already held") from error
    return descriptor


def characterize(
    config: Config,
    *,
    impact_confirmation: str,
    runner: Runner = subprocess_runner,
    server_inspector: ServerInspector = inspect_hdc_server,
    usb_reader: USBReader = system_profiler_reader,
    now: Callable[[], dt.datetime] = utc_now,
    monotonic: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> tuple[int, dict[str, Any], pathlib.Path]:
    if impact_confirmation != config.impact_confirmation_token:
        raise ProbeError("impact confirmation token mismatch")
    if now() >= config.valid_until:
        raise ProbeError("approved E1 window has expired")
    if not config.hdc_path.is_file() or not os.access(config.hdc_path, os.X_OK):
        raise ProbeError("pinned HDC executable is unavailable")
    if sha256_file(config.hdc_path) != config.hdc_sha256:
        raise ProbeError("HDC executable SHA-256 mismatch")

    assert_outside_repository(config.state_root)
    ensure_private_directory(config.state_root)
    runs_root = config.state_root / "runs"
    ensure_private_directory(runs_root)
    lane_descriptor = _acquire_lane(config.state_root)
    run_id = str(uuid.uuid4())
    captured_at = now()
    run_dir = runs_root / f"{captured_at.strftime('%Y%m%dT%H%M%SZ')}-{run_id}"
    ensure_private_directory(run_dir)

    usage_path = config.state_root / "usage.json"
    counters = {
        "e0ReadOnlyHDC": 0,
        "e0RockUSBList": 0,
        "e1DeviceMutation": 0,
        "e2Destructive": 0,
        "rebootLoader": 0,
        "pptWlxRd": 0,
        "flashEraseFormatUnlockUpdate": 0,
        "hdcServerLifecycleMutation": 0,
        "sudoHelperDriverSystemMutation": 0,
        "hostShell": 0,
        "retry": 0,
    }
    receipt: dict[str, Any] = {
        "schemaVersion": "1.0.0",
        "change": "CHG-2026-026",
        "task": "TASK-RKFUI-001A",
        "runId": run_id,
        "capturedAt": iso8601(captured_at),
        "evidenceClass": "realHardwareE1DeviceMutationCharacterization",
        "executor": "autonomousAgent",
        "authorizationRefs": list(config.authorization_refs),
        "window": {
            "validUntil": iso8601(config.valid_until),
            "maxRuns": config.max_runs,
        },
        "host": {
            "os": platform.system(),
            "osVersion": platform.mac_ver()[0],
            "arch": platform.machine(),
        },
        "target": {
            "model": config.target_model,
            "soc": config.target_soc,
            "transport": config.transport,
            "pinnedSerialSHA256": config.serial_sha256,
            "firmware": config.firmware,
        },
        "counters": counters,
        "rawEvidence": {
            "location": "controlled task state outside every git repository",
            "rawIdentityStoredInRepository": False,
        },
        "capabilityVerdict": "unknown",
        "autoRebindVerdict": "unknown",
    }
    ordinal = 0
    usage_reserved = False
    e1_dispatched = False
    command_receipt: Optional[dict[str, Any]] = None
    disconnect_observations: list[dict[str, Any]] = []
    loader_observations: list[dict[str, Any]] = []
    original_sha: Optional[str] = None
    binding_sha: Optional[str] = None
    confirmation_sha: Optional[str] = None
    intent_sha: Optional[str] = None
    usage_sha: Optional[str] = None
    try:
        if usage_path.exists():
            raise ProbeError("maxRuns=1 has already been reserved or consumed")

        server = server_inspector(config.hdc_path)
        receipt["hdcServer"] = server
        if server.get("ownership") != "preExistingExternalSameUIDPinnedExecutable":
            raise ProbeError("HDC server ownership does not match the r3 pin")
        if server.get("serverLifecycleMutationCount") != 0:
            raise ProbeError("HDC server lifecycle mutation count is not zero")

        hdc_version_result, hdc_version_receipt = capture_command(
            runner=runner,
            argv=[str(config.hdc_path), "-v"],
            timeout_ms=5_000,
            run_dir=run_dir,
            stem="hdc-version",
            ordinal=ordinal,
        )
        ordinal += 1
        if (
            hdc_version_result.exit_code != 0
            or hdc_version_result.timed_out
            or hdc_version_result.stderr
            or hdc_version_result.stdout.decode("utf-8", errors="replace").strip()
            != config.hdc_version
        ):
            raise ProbeError("HDC reported version mismatch")
        counters["e0ReadOnlyHDC"] += 1
        receipt["hdc"] = {
            "path": str(config.hdc_path),
            "reportedVersion": config.hdc_version,
            "sha256": config.hdc_sha256,
            "versionReceipt": sanitized_command_receipt(hdc_version_receipt),
        }

        check_result, check_receipt = capture_command(
            runner=runner,
            argv=[str(config.hdc_path), "checkserver"],
            timeout_ms=5_000,
            run_dir=run_dir,
            stem="hdc-checkserver",
            ordinal=ordinal,
        )
        ordinal += 1
        counters["e0ReadOnlyHDC"] += 1
        if check_result.exit_code != 0 or check_result.timed_out or check_result.stderr:
            raise ProbeError("existing HDC server check failed")
        receipt["hdc"]["checkserverReceipt"] = sanitized_command_receipt(check_receipt)

        targets_result, targets_receipt = capture_command(
            runner=runner,
            argv=[str(config.hdc_path), "list", "targets"],
            timeout_ms=5_000,
            run_dir=run_dir,
            stem="hdc-targets-preflight",
            ordinal=ordinal,
        )
        ordinal += 1
        counters["e0ReadOnlyHDC"] += 1
        targets = parse_hdc_targets(targets_result.stdout, targets_result.stderr, targets_result)
        connect_key_bytes = require_exact_target(targets, config.serial_sha256)
        connect_key = connect_key_bytes.decode("ascii")
        receipt["target"]["preflightTargets"] = target_summary(targets)
        receipt["target"]["serialMatched"] = True
        receipt["target"]["targetCount"] = len(targets)
        receipt["target"]["targetsReceipt"] = sanitized_command_receipt(targets_receipt)

        firmware_argv = config.materialize_firmware_readback(connect_key)
        firmware_result, firmware_receipt = capture_command(
            runner=runner,
            argv=firmware_argv,
            timeout_ms=5_000,
            run_dir=run_dir,
            stem="hdc-firmware-preflight",
            ordinal=ordinal,
        )
        ordinal += 1
        counters["e0ReadOnlyHDC"] += 1
        parse_firmware(firmware_result, config.firmware)
        receipt["target"]["firmwareReadback"] = sanitized_command_receipt(firmware_receipt)

        tool, ordinal = inspect_rkdeveloptool(
            config, runner=runner, run_dir=run_dir, ordinal=ordinal
        )
        receipt["rkdeveloptool"] = {
            key: (
                sanitized_command_receipt(value)
                if key.endswith("Receipt") and isinstance(value, dict)
                else value
            )
            for key, value in tool.items()
        }

        pre_ld_result, pre_ld_receipt = capture_command(
            runner=runner,
            argv=[str(config.rkdeveloptool_path), "ld"],
            timeout_ms=5_000,
            run_dir=run_dir,
            stem="rkdeveloptool-ld-preflight",
            ordinal=ordinal,
        )
        ordinal += 1
        counters["e0RockUSBList"] += 1
        pre_ld = parse_ld(pre_ld_result)
        receipt["preTransitionRockUSB"] = {
            "receipt": sanitized_command_receipt(pre_ld_receipt),
            "semantic": pre_ld,
        }
        if pre_ld["status"] == "blocked":
            raise ProbeError(f"pre-transition RockUSB observation blocked: {pre_ld['reason']}")
        if pre_ld["observations"]:
            raise ProbeError("a RockUSB candidate already exists while the pinned HDC target is online")

        pre_usb_result = usb_reader(30_000, run_dir)
        pre_usb_sha = write_new_bytes(run_dir / f"{ordinal:03d}-usb-topology-pre.json", pre_usb_result.stdout)
        pre_usb_stderr_sha = write_new_bytes(
            run_dir / f"{ordinal:03d}-usb-topology-pre.stderr", pre_usb_result.stderr
        )
        ordinal += 1
        pre_topology = parse_usb_topology(pre_usb_result.stdout)
        receipt["preTransitionUSBTopology"] = {
            "semantic": pre_topology,
            "exitCode": pre_usb_result.exit_code,
            "timedOut": pre_usb_result.timed_out,
            "stdoutSHA256": pre_usb_sha,
            "stderrSHA256": pre_usb_stderr_sha,
        }

        original = {
            "schemaVersion": "1.0.0",
            "kind": "OriginalTargetSnapshot",
            "createdAt": iso8601(now()),
            "model": config.target_model,
            "soc": config.target_soc,
            "transport": config.transport,
            "connectKey": connect_key,
            "serialSHA256": config.serial_sha256,
            "firmware": config.firmware,
            "hdcExecutable": str(config.hdc_path),
            "hdcSHA256": config.hdc_sha256,
            "serverPID": server["pid"],
        }
        original_sha = write_new_json(run_dir / "original-target.json", original)
        binding = {
            "schemaVersion": "1.0.0",
            "kind": "CurrentDeviceBinding",
            "createdAt": iso8601(now()),
            "revision": config.binding_revision,
            "connectKey": connect_key,
            "identitySnapshot": {
                "serialSHA256": config.serial_sha256,
                "model": config.target_model,
                "firmware": config.firmware,
            },
            "evidence": {
                "targetEnumerationSHA256": targets_receipt["stdout"]["sha256"],
                "firmwareReadbackSHA256": firmware_receipt["stdout"]["sha256"],
                "serverPID": server["pid"],
            },
            "confirmedBy": "exactR3MachineReadback",
            "channelProtection": "usbLocal",
        }
        binding_sha = write_new_json(run_dir / "current-binding-r1.json", binding)
        confirmation = {
            "schemaVersion": "1.0.0",
            "kind": "ModeTransitionImpactConfirmation",
            "confirmedAt": iso8601(now()),
            "token": impact_confirmation,
            "impact": "target will leave HDC and attempt to enter RockUSB Loader",
            "authorizationRefs": list(config.authorization_refs),
            "targetSerialSHA256": config.serial_sha256,
            "bindingRevision": config.binding_revision,
        }
        confirmation_sha = write_new_json(run_dir / "impact-confirmation.json", confirmation)

        usage = {
            "schemaVersion": "1.0.0",
            "task": "TASK-RKFUI-001A",
            "runId": run_id,
            "authorizationRefs": list(config.authorization_refs),
            "maxRuns": 1,
            "ordinal": 1,
            "reservedAt": iso8601(now()),
            "state": "reservedNoRefund",
        }
        usage_sha = write_new_json(usage_path, usage)
        usage_reserved = True

        e1_argv = config.materialize_e1(connect_key)
        intent = {
            "schemaVersion": "1.0.0",
            "kind": "stepIntent",
            "typedIntent": "enterUpdater",
            "providerOperationId": "rockusb.enter-loader",
            "effectClassification": "deviceMutation",
            "createdAt": iso8601(now()),
            "targetSerialSHA256": config.serial_sha256,
            "bindingRevision": config.binding_revision,
            "originalTargetSHA256": original_sha,
            "currentBindingSHA256": binding_sha,
            "impactConfirmationSHA256": confirmation_sha,
            "argv": e1_argv,
            "argumentsSHA256": argv_sha256(e1_argv),
            "authorizationRefs": list(config.authorization_refs),
            "attempt": 1,
        }
        intent_sha = write_new_json(run_dir / "enter-updater-intent.json", intent)

        # Post-intent/pre-launch revalidation. No caller state can change argv.
        if now() >= config.valid_until:
            raise ProbeError("approved E1 window expired after durable intent")
        revalidated_server = server_inspector(config.hdc_path)
        if revalidated_server["pid"] != server["pid"]:
            raise ProbeError("HDC server generation changed after durable intent")
        if sha256_file(config.hdc_path) != config.hdc_sha256:
            raise ProbeError("HDC executable drifted after durable intent")
        if sha256_file(config.rkdeveloptool_path) != config.rkdeveloptool_sha256:
            raise ProbeError("rkdeveloptool drifted after durable intent")

        targets_recheck_result, targets_recheck_receipt = capture_command(
            runner=runner,
            argv=[str(config.hdc_path), "list", "targets"],
            timeout_ms=5_000,
            run_dir=run_dir,
            stem="hdc-targets-pre-dispatch",
            ordinal=ordinal,
        )
        ordinal += 1
        counters["e0ReadOnlyHDC"] += 1
        recheck_targets = parse_hdc_targets(
            targets_recheck_result.stdout,
            targets_recheck_result.stderr,
            targets_recheck_result,
        )
        recheck_key = require_exact_target(recheck_targets, config.serial_sha256).decode("ascii")
        if recheck_key != connect_key:
            raise ProbeError("connect key changed after durable binding")

        firmware_recheck_result, firmware_recheck_receipt = capture_command(
            runner=runner,
            argv=config.materialize_firmware_readback(recheck_key),
            timeout_ms=5_000,
            run_dir=run_dir,
            stem="hdc-firmware-pre-dispatch",
            ordinal=ordinal,
        )
        ordinal += 1
        counters["e0ReadOnlyHDC"] += 1
        parse_firmware(firmware_recheck_result, config.firmware)
        receipt["preDispatchRevalidation"] = {
            "targets": sanitized_command_receipt(targets_recheck_receipt),
            "firmware": sanitized_command_receipt(firmware_recheck_receipt),
            "serverPIDMatched": True,
            "bindingRevision": config.binding_revision,
        }

        # Reservation and intent are already durable. Count the sole launch attempt before
        # entering the runner so a spawn/capture fault can never make the run look retryable.
        counters["e1DeviceMutation"] = 1
        counters["rebootLoader"] = 1
        e1_dispatched = True
        command_result, command_receipt = capture_command(
            runner=runner,
            argv=e1_argv,
            timeout_ms=config.command_timeout_ms,
            run_dir=run_dir,
            stem="hdc-enter-loader-e1",
            ordinal=ordinal,
        )
        ordinal += 1
        receipt["e1Command"] = {
            "argv": [
                str(config.hdc_path),
                "-t",
                "<redacted-connect-key>",
                "shell",
                "reboot",
                "loader",
            ],
            "argumentsSHA256": argv_sha256(e1_argv),
            "receipt": sanitized_command_receipt(command_receipt),
        }

        disconnect_deadline = monotonic() + config.disconnect_deadline_ms / 1_000
        disconnect_observed = False
        while monotonic() <= disconnect_deadline:
            observation_result, observation_receipt = capture_command(
                runner=runner,
                argv=[str(config.hdc_path), "list", "targets"],
                timeout_ms=5_000,
                run_dir=run_dir,
                stem=f"hdc-disconnect-{len(disconnect_observations):02d}",
                ordinal=ordinal,
            )
            ordinal += 1
            counters["e0ReadOnlyHDC"] += 1
            try:
                observed_targets = parse_hdc_targets(
                    observation_result.stdout,
                    observation_result.stderr,
                    observation_result,
                )
                matched = any(
                    sha256_bytes(target) == config.serial_sha256 for target in observed_targets
                )
                semantic = {
                    "targets": target_summary(observed_targets),
                    "pinnedTargetPresent": matched,
                }
                if not matched:
                    disconnect_observed = True
            except ProbeError as error:
                semantic = {"parseError": str(error), "pinnedTargetPresent": None}
            disconnect_observations.append(
                {
                    "observedAt": iso8601(now()),
                    "receipt": sanitized_command_receipt(observation_receipt),
                    "semantic": semantic,
                }
            )
            if disconnect_observed:
                break
            sleeper(config.poll_interval_ms / 1_000)

        loader_deadline = monotonic() + config.loader_deadline_ms / 1_000
        expected_loader: Optional[dict[str, Any]] = None
        terminal_loader_reason: Optional[str] = None
        while monotonic() <= loader_deadline:
            ld_result, ld_receipt = capture_command(
                runner=runner,
                argv=[str(config.rkdeveloptool_path), "ld"],
                timeout_ms=5_000,
                run_dir=run_dir,
                stem=f"rkdeveloptool-ld-{len(loader_observations):02d}",
                ordinal=ordinal,
            )
            ordinal += 1
            counters["e0RockUSBList"] += 1
            parsed = parse_ld(ld_result)
            loader_observations.append(
                {
                    "observedAt": iso8601(now()),
                    "receipt": sanitized_command_receipt(ld_receipt),
                    "semantic": parsed,
                }
            )
            if parsed["status"] == "blocked":
                terminal_loader_reason = parsed["reason"]
                break
            if parsed["observations"]:
                matches = [
                    item for item in parsed["observations"] if item["isExpectedLoader"]
                ]
                if len(parsed["observations"]) == 1 and len(matches) == 1:
                    expected_loader = matches[0]
                else:
                    terminal_loader_reason = (
                        "ambiguousOrWrongMode"
                        if len(parsed["observations"]) != 1
                        else "wrongMode"
                    )
                break
            sleeper(config.poll_interval_ms / 1_000)

        post_usb_result = usb_reader(30_000, run_dir)
        post_usb_sha = write_new_bytes(
            run_dir / f"{ordinal:03d}-usb-topology-post.json", post_usb_result.stdout
        )
        post_usb_stderr_sha = write_new_bytes(
            run_dir / f"{ordinal:03d}-usb-topology-post.stderr", post_usb_result.stderr
        )
        post_topology = parse_usb_topology(post_usb_result.stdout)
        receipt["postTransitionUSBTopology"] = {
            "semantic": post_topology,
            "exitCode": post_usb_result.exit_code,
            "timedOut": post_usb_result.timed_out,
            "stdoutSHA256": post_usb_sha,
            "stderrSHA256": post_usb_stderr_sha,
        }
        receipt["hdcDisconnectObservations"] = disconnect_observations
        receipt["loaderObservations"] = loader_observations

        command_semantically_accepted = (
            command_result.exit_code == 0
            and not command_result.timed_out
            and not command_result.output_truncated
            and not command_result.stderr
        )
        if command_semantically_accepted and disconnect_observed and expected_loader is not None:
            capability_verdict = "supported"
            capability_reason = "exit0PlusHDCDisconnectPlusExactSemanticLoader"
        elif terminal_loader_reason in ("wrongMode", "ambiguousOrWrongMode"):
            capability_verdict = "unsupported"
            capability_reason = terminal_loader_reason
        else:
            capability_verdict = "unknown"
            capability_reason = (
                "commandReceiptUncertain"
                if not command_semantically_accepted
                else "disconnectOrLoaderDeadline"
            )

        pre_topology_hashes = {item["topologySHA256"] for item in pre_topology}
        post_topology_hashes = {item["topologySHA256"] for item in post_topology}
        topology_continuity = bool(pre_topology_hashes & post_topology_hashes)
        auto_rebind_eligible = False
        auto_rebind_reason = (
            "missingCrossModeSerialOrDaemonFingerprint"
            if expected_loader is not None
            else "noExactLoaderCandidate"
        )
        if not topology_continuity:
            auto_rebind_reason += "AndNoTopologyContinuity"
        rebind_evaluation = {
            "evaluatedAt": iso8601(now()),
            "expectedModeTransition": True,
            "candidateCount": 1 if expected_loader is not None else 0,
            "preSerialSHA256": config.serial_sha256,
            "postSerialOrDaemonFingerprintAvailable": False,
            "topologyContinuity": topology_continuity,
            "coreAutoRebindEligible": auto_rebind_eligible,
            "reason": auto_rebind_reason,
            "nextState": "awaitingRebindConfirmation" if expected_loader else "blocked",
            "newBindingRevisionPersisted": False,
            "subsequentDeviceMutationDispatch": 0,
        }
        rebind_sha = write_new_json(run_dir / "rebind-evaluation.json", rebind_evaluation)
        receipt["rebindEvaluation"] = rebind_evaluation | {"sha256": rebind_sha}
        receipt["capabilityVerdict"] = capability_verdict
        receipt["capabilityReason"] = capability_reason
        receipt["autoRebindVerdict"] = (
            "manualConfirmationRequired" if expected_loader is not None else "unknown"
        )
        receipt["durability"] = {
            "originalTargetSHA256": original_sha,
            "currentBindingRevision1SHA256": binding_sha,
            "impactConfirmationSHA256": confirmation_sha,
            "enterUpdaterIntentSHA256": intent_sha,
            "usageReservationSHA256": usage_sha,
            "usageReservationPrecededIntentAndDispatch": True,
            "intentPrecededDispatch": True,
        }

        outcome = {
            "schemaVersion": "1.0.0",
            "kind": "stepOutcome",
            "typedIntent": "enterUpdater",
            "completedAt": iso8601(now()),
            "attempt": 1,
            "bindingRevision": config.binding_revision,
            "intentSHA256": intent_sha,
            "commandReceipt": command_receipt,
            "hdcDisconnectObserved": disconnect_observed,
            "expectedLoaderObserved": expected_loader is not None,
            "capabilityVerdict": capability_verdict,
            "capabilityReason": capability_reason,
        }
        outcome_sha = write_new_json(run_dir / "enter-updater-outcome.json", outcome)
        receipt["durability"]["enterUpdaterOutcomeSHA256"] = outcome_sha

        usage["completedAt"] = iso8601(now())
        usage["state"] = "consumedNoRetry"
        usage["capabilityVerdict"] = capability_verdict
        usage["runDirectoryName"] = run_dir.name
        usage_sha = replace_json(usage_path, usage)
        receipt["durability"]["finalUsageStateSHA256"] = usage_sha

        sanitized_path = run_dir / "sanitized-receipt.json"
        write_new_json(sanitized_path, receipt)
        # The receipt remains immutable; the external copier computes its final byte hash.
        exit_code = 0 if capability_verdict in ("supported", "unsupported") else 1
        return exit_code, receipt, sanitized_path

    except (ProbeError, OSError) as error:
        receipt["capabilityVerdict"] = "unknown"
        receipt["autoRebindVerdict"] = "unknown"
        receipt["blockedReason"] = str(error)
        receipt["e1Dispatched"] = e1_dispatched
        receipt["usageReserved"] = usage_reserved
        if command_receipt is not None:
            receipt["e1CommandReceipt"] = sanitized_command_receipt(command_receipt)
        if usage_reserved:
            try:
                existing_usage = json.loads(usage_path.read_text(encoding="utf-8"))
                existing_usage["completedAt"] = iso8601(now())
                existing_usage["state"] = "consumedNoRetry"
                existing_usage["capabilityVerdict"] = "unknown"
                existing_usage["blockedReason"] = str(error)
                replace_json(usage_path, existing_usage)
            except (OSError, UnicodeError, json.JSONDecodeError):
                pass
        sanitized_path = run_dir / "sanitized-receipt.json"
        write_new_json(sanitized_path, receipt)
        return 1, receipt, sanitized_path
    finally:
        fcntl.flock(lane_descriptor, fcntl.LOCK_UN)
        os.close(lane_descriptor)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    characterize_parser = subparsers.add_parser(
        "characterize", help="run the one authorized E1 characterization"
    )
    characterize_parser.add_argument(
        "--rkdeveloptool",
        required=True,
        type=pathlib.Path,
        help="absolute path to the exact pinned clean rkdeveloptool artifact",
    )
    characterize_parser.add_argument(
        "--impact-confirmation",
        required=True,
        help="must equal the fixed registry confirmation token",
    )
    subparsers.add_parser("selftest-host", help="validate registry/config without a device")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        if arguments.command == "selftest-host":
            config = load_config(pathlib.Path("/nonexistent/rkdeveloptool"))
            validate_config(config)
            print("host selftest PASS: registry and closed argv materializers are valid")
            return 0
        config = load_config(arguments.rkdeveloptool)
        exit_code, receipt, path = characterize(
            config, impact_confirmation=arguments.impact_confirmation
        )
        print(
            json.dumps(
                {
                    "task": receipt["task"],
                    "runId": receipt["runId"],
                    "capabilityVerdict": receipt["capabilityVerdict"],
                    "autoRebindVerdict": receipt["autoRebindVerdict"],
                    "e1DispatchCount": receipt["counters"]["e1DeviceMutation"],
                    "destructiveDispatchCount": receipt["counters"]["e2Destructive"],
                    "sanitizedReceipt": str(path.relative_to(config.state_root)),
                },
                sort_keys=True,
            )
        )
        return exit_code
    except ProbeError as error:
        print(f"fail closed before run: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
