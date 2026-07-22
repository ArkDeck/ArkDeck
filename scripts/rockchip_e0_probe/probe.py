#!/usr/bin/env python3
"""Build and run the signed Sandbox RockUSB E0 probe without a shell."""

from __future__ import annotations

import argparse
import base64
import datetime
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import re
import subprocess
import sys
from typing import Any

PINNED_TOOL_SHA256 = "038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611"
PINNED_TOOL_VERSION = "rkdeveloptool ver 1.32"
PINNED_UPSTREAM_COMMIT = "304f073752fd25c854e1bcf05d8e7f925b1f4e14"
EXACT_ARGUMENTS = ["ld"]
EXPECTED_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.device.serial": True,
    "com.apple.security.device.usb": True,
    "com.apple.security.files.bookmarks.app-scope": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.network.client": True,
}
LINE_PATTERN = re.compile(
    rb"\ADevNo=([0-9]+)\tVid=0x([0-9A-Fa-f]{4}),Pid=0x([0-9A-Fa-f]{4}),"
    rb"LocationID=([0-9]+)\t([A-Za-z][A-Za-z0-9_-]{0,31})\Z"
)
PERMISSION_MARKERS = (b"permission denied", b"operation not permitted", b"libusb_error_access")
DRIVER_MARKERS = (b"driver unavailable", b"libusb_init failed", b"no libusb backend")
SWIFT_DEVICE_ACCESS_RESPONSIBILITY_RAW_VALUES = frozenset(
    {"user", "systemAdministrator", "deviceOrToolVendor"}
)
SWIFT_DEVICE_ACCESS_REMEDIATION_RAW_VALUES = frozenset(
    {
        "reconnectOrEnterLoader",
        "reviewDevicePermissionOutsideArkDeck",
        "repairDriverOutsideArkDeck",
        "selectPinnedUserApprovedTool",
        "chooseSupportedLoaderObservation",
        "inspectControlledDiagnostics",
    }
)
DEVICE_ACCESS_ADVICE = {
    "accessible": ("user", "chooseSupportedLoaderObservation"),
    "offlineOrUnauthorized": ("user", "reconnectOrEnterLoader"),
    "permissionDenied": ("systemAdministrator", "reviewDevicePermissionOutsideArkDeck"),
    "driverUnavailable": ("deviceOrToolVendor", "repairDriverOutsideArkDeck"),
    "protocolBlocked": ("user", "chooseSupportedLoaderObservation"),
    "toolBlocked": ("user", "selectPinnedUserApprovedTool"),
    "malformedOutput": ("deviceOrToolVendor", "inspectControlledDiagnostics"),
    "probeFailed": ("deviceOrToolVendor", "inspectControlledDiagnostics"),
}


class ProbeError(RuntimeError):
    pass


def _run(arguments: list[str], *, check: bool = False) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(arguments, check=check, capture_output=True)


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(64 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def parse_ld(stdout: bytes, stderr: bytes, termination: str | None, exit_code: int | None) -> dict[str, Any]:
    if len(stdout) + len(stderr) > 65_536:
        return {"verdict": "malformedOutput", "diagnostic": "outputTooLarge", "observations": []}
    lowered = (stdout + stderr).lower()
    if any(marker in lowered for marker in PERMISSION_MARKERS):
        return {"verdict": "permissionDenied", "diagnostic": "permissionDenied", "observations": []}
    if any(marker in lowered for marker in DRIVER_MARKERS):
        return {"verdict": "driverUnavailable", "diagnostic": "driverUnavailable", "observations": []}
    if b"unauthorized" in lowered:
        return {"verdict": "offlineOrUnauthorized", "diagnostic": "unauthorized", "observations": []}
    if termination != "exited" or exit_code != 0:
        return {"verdict": "probeFailed", "diagnostic": termination or "unknown", "observations": []}
    if stderr:
        return {"verdict": "malformedOutput", "diagnostic": "unexpectedStandardError", "observations": []}
    if not stdout:
        return {"verdict": "offlineOrUnauthorized", "diagnostic": "offline", "observations": []}
    if b"\r" in stdout:
        return {"verdict": "malformedOutput", "diagnostic": "invalidUTF8", "observations": []}
    try:
        stdout.decode("utf-8")
    except UnicodeDecodeError:
        return {"verdict": "malformedOutput", "diagnostic": "invalidUTF8", "observations": []}

    lines = stdout.split(b"\n")
    if lines[-1] == b"":
        lines.pop()
    if not lines or len(lines) > 64:
        return {"verdict": "malformedOutput", "diagnostic": "deviceCount", "observations": []}
    device_numbers: set[int] = set()
    location_ids: set[int] = set()
    observations: list[dict[str, Any]] = []
    for line_number, line in enumerate(lines, start=1):
        match = LINE_PATTERN.fullmatch(line)
        if not match:
            return {"verdict": "malformedOutput", "diagnostic": f"malformedLine:{line_number}", "observations": []}
        decimal_fields = (match.group(1), match.group(4))
        if any(value != b"0" and value.startswith(b"0") for value in decimal_fields):
            return {"verdict": "malformedOutput", "diagnostic": f"numberOutOfRange:{line_number}", "observations": []}
        device_number = int(match.group(1))
        location_id = int(match.group(4))
        if device_number > 0xFFFF_FFFF or location_id > 0xFFFF_FFFF_FFFF_FFFF:
            return {"verdict": "malformedOutput", "diagnostic": f"numberOutOfRange:{line_number}", "observations": []}
        if device_number in device_numbers:
            return {"verdict": "malformedOutput", "diagnostic": "duplicateDeviceNumber", "observations": []}
        if location_id in location_ids:
            return {"verdict": "malformedOutput", "diagnostic": "duplicateLocationID", "observations": []}
        device_numbers.add(device_number)
        location_ids.add(location_id)
        mode = match.group(5).decode("ascii")
        if mode not in ("Loader", "Maskrom"):
            return {"verdict": "malformedOutput", "diagnostic": f"unknownMode:{mode}", "observations": []}
        vendor = int(match.group(2), 16)
        product = int(match.group(3), 16)
        observations.append(
            {
                "deviceNumber": device_number,
                "usbVendorID": f"0x{vendor:04x}",
                "usbProductID": f"0x{product:04x}",
                "locationIDSummary": hashlib.sha256(str(location_id).encode()).hexdigest()[:12],
                "mode": mode,
                "providerDisposition": (
                    "applicableLoader"
                    if (vendor, product, mode) == (0x2207, 0x350A, "Loader")
                    else "blocked"
                ),
            }
        )
    verdict = "accessible" if any(item["providerDisposition"] == "applicableLoader" for item in observations) else "protocolBlocked"
    return {"verdict": verdict, "diagnostic": None, "observations": observations}


def classify_preflight_failure(failure: str | None) -> dict[str, Any] | None:
    if failure is None:
        return None
    if failure in (
        "securityScopedBookmarkStale",
        "securityScopedBookmarkPathMismatch",
        "bookmarkCreationOrResolutionFailed",
        "executableHashMismatch",
        "signatureIntegrityInvalid",
        "quarantinePresent",
    ):
        verdict = "toolBlocked"
    else:
        verdict = "probeFailed"
    return {"verdict": verdict, "diagnostic": failure, "observations": []}


def _make_info_plist(path: pathlib.Path) -> None:
    document = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "RockchipE0ProbeApp",
        "CFBundleIdentifier": "dev.arkdeck.rockchip-e0-probe",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "ArkDeck Rockchip E0 Probe",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSSupportsAutomaticGraphicsSwitching": True,
    }
    with path.open("wb") as handle:
        plistlib.dump(document, handle, sort_keys=True)


def build(output_root: pathlib.Path, signing_identity: str) -> pathlib.Path:
    if not output_root.is_absolute():
        raise ProbeError("output root must be absolute")
    if output_root.exists() and any(output_root.iterdir()):
        raise ProbeError("output root must be absent or empty")
    output_root.mkdir(parents=True, exist_ok=True)
    script_root = pathlib.Path(__file__).resolve().parent
    app = output_root / "RockchipE0ProbeApp.app"
    macos = app / "Contents" / "MacOS"
    macos.mkdir(parents=True)
    _make_info_plist(app / "Contents" / "Info.plist")
    executable = macos / "RockchipE0ProbeApp"
    swiftc = _run(["/usr/bin/xcrun", "--find", "swiftc"], check=True).stdout.decode().strip()
    sdk = _run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], check=True).stdout.decode().strip()
    architecture = platform.machine()
    if architecture not in ("arm64", "x86_64"):
        raise ProbeError(f"unsupported macOS architecture: {architecture}")
    _run(
        [
            swiftc,
            "-parse-as-library",
            "-O",
            "-target",
            f"{architecture}-apple-macosx14.0",
            "-sdk",
            sdk,
            "-framework",
            "AppKit",
            "-framework",
            "Security",
            str(script_root / "RockchipE0ProbeApp.swift"),
            "-o",
            str(executable),
        ],
        check=True,
    )
    _run(
        [
            "/usr/bin/codesign",
            "--force",
            "--sign",
            signing_identity,
            "--options",
            "runtime",
            "--entitlements",
            str(script_root / "Probe.entitlements"),
            str(app),
        ],
        check=True,
    )
    _run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    entitlements = _run(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)], check=True
    ).stdout
    if plistlib.loads(entitlements) != EXPECTED_ENTITLEMENTS:
        raise ProbeError("signed entitlements differ from the frozen six-entitlement target")
    details = _run(["/usr/bin/codesign", "-dvvv", str(app)], check=True).stderr.decode(
        "utf-8", errors="replace"
    )
    receipt = {
        "schemaVersion": "1.0.0",
        "appExecutableSHA256": _sha256_file(executable),
        "signatureClass": "adHoc" if "Signature=adhoc" in details else "configuredIdentity",
        "signingIdentityRequested": "adHoc" if signing_identity == "-" else signing_identity,
        "hardenedRuntime": "flags=0x10000(runtime)" in details or "runtime" in details,
        "entitlements": EXPECTED_ENTITLEMENTS,
        "codesignVerified": True,
        "developerIDIdentityAvailableAtBuild": signing_identity != "-",
    }
    (output_root / "build-receipt.json").write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return app


def _platform_trust(path: pathlib.Path) -> dict[str, Any]:
    details = _run(["/usr/bin/codesign", "-dv", "--verbose=4", str(path)])
    text = details.stderr.decode("utf-8", errors="replace")
    if "Signature=adhoc" in text and details.returncode == 0:
        code_trust = "adHoc"
    elif "Authority=Developer ID" in text and details.returncode == 0:
        code_trust = "developerID"
    elif details.returncode != 0:
        code_trust = "unsignedOrInvalid"
    else:
        code_trust = "unknown"
    quarantine = _run(["/usr/bin/xattr", "-p", "com.apple.quarantine", str(path)])
    assessment = _run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", str(path)])
    assessment_text = assessment.stderr.decode("utf-8", errors="replace").lower()
    if assessment.returncode == 0:
        assessment_summary = "accepted"
    elif "rejected" in assessment_text:
        assessment_summary = "rejected"
    elif "internal error" in assessment_text:
        assessment_summary = "internalError"
    else:
        assessment_summary = "unavailable"
    return {
        "codeTrust": code_trust,
        "signatureIntegrityCheckExit": details.returncode,
        "quarantinePresent": quarantine.returncode == 0,
        "gatekeeperAssessmentExit": assessment.returncode,
        "gatekeeperAssessmentSummary": assessment_summary,
    }


def _access_advice(verdict: str) -> tuple[str, str]:
    try:
        responsibility, remediation = DEVICE_ACCESS_ADVICE[verdict]
    except KeyError as error:
        raise ProbeError(f"unmapped device access verdict: {verdict}") from error
    if responsibility not in SWIFT_DEVICE_ACCESS_RESPONSIBILITY_RAW_VALUES:
        raise ProbeError(f"responsibility is not a Swift raw value: {responsibility}")
    if remediation not in SWIFT_DEVICE_ACCESS_REMEDIATION_RAW_VALUES:
        raise ProbeError(f"remediation is not a Swift raw value: {remediation}")
    return responsibility, remediation


def build_sanitized_receipt(
    *,
    envelope: dict[str, Any],
    captured_at: str,
    executor: str,
    app_executable_sha256: str,
    entitlements: dict[str, Any],
    build_receipt: dict[str, Any],
    selected_basename: str | None,
    tool_hash: str | None,
    trust: dict[str, Any],
    stdout: bytes,
    stderr: bytes,
    parsed: dict[str, Any],
    execute_readiness_passed: bool,
) -> dict[str, Any]:
    """Build the repository-safe receipt without I/O or device interaction."""

    launch_attempted = bool(envelope.get("childLaunchAttempted"))
    responsibility, remediation = _access_advice(parsed["verdict"])
    if launch_attempted:
        usb_access_result = (
            "applicableLoaderObserved"
            if execute_readiness_passed
            else "attemptedWithoutApplicableLoader"
        )
        raw_artifacts = "operatorControlledOutsideRepository"
    elif parsed["verdict"] == "toolBlocked":
        usb_access_result = "notAttemptedBecauseToolTrustBlockedBeforeChildLaunch"
        raw_artifacts = "emptyBecauseChildLaunchWasBlocked"
    else:
        usb_access_result = "notAttemptedBecausePreflightBlockedBeforeChildLaunch"
        raw_artifacts = "emptyBecauseChildLaunchWasBlocked"

    return {
        "schemaVersion": "1.0.0",
        "capturedAt": captured_at,
        "evidenceClass": "realHardwareE0ReadOnly" if launch_attempted else "signedSandboxHostOnly",
        "executor": executor,
        "app": {
            "bundleIdentifier": "dev.arkdeck.rockchip-e0-probe",
            "executableSHA256": app_executable_sha256,
            "signatureClass": build_receipt["signatureClass"],
            "developerIDIdentityAvailable": build_receipt[
                "developerIDIdentityAvailableAtBuild"
            ],
            "hardenedRuntime": build_receipt["hardenedRuntime"],
            "codesignVerified": True,
            "entitlements": entitlements,
        },
        "tool": {
            "basename": selected_basename,
            "pathSource": "userSelectedSecurityScopedBookmark",
            "bookmarkCreated": envelope.get("bookmarkCreated"),
            "securityScopeStarted": envelope.get("securityScopeStarted"),
            "reportedVersion": PINNED_TOOL_VERSION,
            "versionEvidence": "approvedRegistryPinBoundByExactExecutableSHA256",
            "sha256": tool_hash,
            "upstreamCommit": PINNED_UPSTREAM_COMMIT,
            "platformTrust": {
                "codeTrust": trust["codeTrust"],
                "signatureIntegrityValid": trust["signatureIntegrityCheckExit"] == 0,
                "quarantinePresent": trust["quarantinePresent"],
                "gatekeeperAssessment": trust["gatekeeperAssessmentSummary"],
            },
        },
        "invocation": {
            "arguments": EXACT_ARGUMENTS,
            "environmentOverrideCount": 0,
            "preflightFailure": envelope.get("preflightFailure"),
            "childLaunchAttempted": launch_attempted,
            "termination": envelope.get("termination"),
            "exitCode": envelope.get("exitCode"),
            "stdout": {"sha256": _sha256(stdout), "sizeBytes": len(stdout)},
            "stderr": {"sha256": _sha256(stderr), "sizeBytes": len(stderr)},
        },
        "deviceAccessAdvisor": {
            "verdict": parsed["verdict"],
            "diagnostic": parsed.get("diagnostic"),
            "responsibility": responsibility,
            "remediation": remediation,
        },
        "usbAccessResult": usb_access_result,
        "executeReadinessGate": "passed" if execute_readiness_passed else "blocked",
        "dispatchCounters": {
            "ldReadOnly": 1 if launch_attempted else 0,
            "versionDuringDeviceWindow": 0,
            "hdcModeSwitch": 0,
            "deviceMutation": 0,
            "destructive": 0,
            "sudoOrPrivilegeElevation": 0,
            "helperOrDriverInstall": 0,
            "systemRuleGroupOrACLMutation": 0,
            "network": 0,
        },
        "privacy": {
            "fullToolPathRecorded": False,
            "rawQuarantinePayloadRecorded": False,
            "deviceSerialRecorded": False,
            "locationIDRecorded": False,
            "rawArtifacts": raw_artifacts,
        },
    }


def run_probe(
    app: pathlib.Path,
    initial_directory: pathlib.Path,
    receipt_path: pathlib.Path,
    raw_root: pathlib.Path,
) -> dict[str, Any]:
    if not app.is_absolute() or not initial_directory.is_absolute() or not receipt_path.is_absolute() or not raw_root.is_absolute():
        raise ProbeError("app, initial directory, receipt, and raw root must be absolute")
    verify = _run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    if verify.returncode != 0:
        raise ProbeError("probe app signature verification failed")
    entitlements_bytes = _run(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)], check=True
    ).stdout
    entitlements = plistlib.loads(entitlements_bytes)
    if entitlements != EXPECTED_ENTITLEMENTS:
        raise ProbeError("probe app entitlement set drifted")

    executable = app / "Contents" / "MacOS" / "RockchipE0ProbeApp"
    completed = _run([str(executable), str(initial_directory)])
    if completed.returncode != 0:
        raise ProbeError(f"probe host exited {completed.returncode}")
    try:
        envelope = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise ProbeError("probe host did not emit one JSON envelope") from error
    if envelope.get("schemaVersion") != "1.0.0" or envelope.get("exactArguments") != EXACT_ARGUMENTS:
        raise ProbeError("probe envelope contract mismatch")

    stdout = base64.b64decode(envelope.get("stdoutBase64", ""), validate=True)
    stderr = base64.b64decode(envelope.get("stderrBase64", ""), validate=True)
    raw_root.mkdir(parents=True, exist_ok=False)
    (raw_root / "ld.stdout.bin").write_bytes(stdout)
    (raw_root / "ld.stderr.bin").write_bytes(stderr)

    selected_path_value = envelope.get("selectedPath")
    selected_path = pathlib.Path(selected_path_value) if selected_path_value else None
    tool_hash = _sha256_file(selected_path) if selected_path and selected_path.is_file() else None
    trust = _platform_trust(selected_path) if selected_path and selected_path.is_file() else {
        "codeTrust": "unknown",
        "signatureIntegrityCheckExit": None,
        "quarantinePresent": None,
        "gatekeeperAssessmentExit": None,
        "gatekeeperAssessmentSummary": "notAssessed",
    }
    parsed = classify_preflight_failure(envelope.get("preflightFailure")) or parse_ld(
        stdout, stderr, envelope.get("termination"), envelope.get("exitCode")
    )
    exact_loader = (
        parsed["verdict"] == "accessible"
        and len(parsed["observations"]) == 1
        and parsed["observations"][0]["providerDisposition"] == "applicableLoader"
    )
    identity_gate = (
        envelope.get("preflightFailure") is None
        and envelope.get("executableSHA256") == PINNED_TOOL_SHA256
        and tool_hash == PINNED_TOOL_SHA256
        and trust["codeTrust"] in ("adHoc", "developerID")
        and trust["quarantinePresent"] is False
    )
    build_receipt = json.loads((app.parent / "build-receipt.json").read_text())
    captured_at = (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
    receipt = build_sanitized_receipt(
        envelope=envelope,
        captured_at=captured_at,
        executor="agent",
        app_executable_sha256=_sha256_file(executable),
        entitlements=entitlements,
        build_receipt=build_receipt,
        selected_basename=selected_path.name if selected_path else None,
        tool_hash=tool_hash,
        trust=trust,
        stdout=stdout,
        stderr=stderr,
        parsed=parsed,
        execute_readiness_passed=identity_gate and exact_loader,
    )
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return receipt


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    build_parser = subparsers.add_parser("build")
    build_parser.add_argument("--output-root", type=pathlib.Path, required=True)
    build_parser.add_argument("--signing-identity", default="-")
    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--app", type=pathlib.Path, required=True)
    run_parser.add_argument("--initial-directory", type=pathlib.Path, required=True)
    run_parser.add_argument("--receipt", type=pathlib.Path, required=True)
    run_parser.add_argument("--raw-root", type=pathlib.Path, required=True)
    arguments = parser.parse_args(argv)
    if arguments.command == "build":
        app = build(arguments.output_root.resolve(), arguments.signing_identity)
        print(json.dumps({"app": str(app), "status": "built"}, sort_keys=True))
        return 0
    receipt = run_probe(
        arguments.app.resolve(),
        arguments.initial_directory.resolve(),
        arguments.receipt.resolve(),
        arguments.raw_root.resolve(),
    )
    print(
        json.dumps(
            {
                "advisorVerdict": receipt["deviceAccessAdvisor"]["verdict"],
                "executeReadinessGate": receipt["executeReadinessGate"],
                "receipt": str(arguments.receipt.resolve()),
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ProbeError, subprocess.CalledProcessError, ValueError) as error:
        print(f"rockchip-e0-probe: {error}", file=sys.stderr)
        raise SystemExit(1)
