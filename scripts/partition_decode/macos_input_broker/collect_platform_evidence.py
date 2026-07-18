"""Build, run, attest and stage fresh TASK-PD-001 broker evidence.

The collector accepts no prebuilt artifact, runtime receipt, core output, tool
version or PASS marker from its caller. It builds the reviewed source in a new
private temporary directory, independently verifies and inspects the resulting
artifact before launch, captures the runtime receipt from the verified child's
stdout pipe, validates output hashes, and repeats artifact inspection after the
child exits. Only then does it create the requested evidence directory.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from typing import Optional, Sequence


EXPECTED_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.user-selected.read-only": True,
    "com.apple.security.temporary-exception.files.absolute-path.read-only": [
        "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/"
    ],
}
EXPECTED_SCOPE = {
    "archiveLocatorIncluded": False,
    "authoritative": False,
    "compatibilityClaim": False,
    "flashAddressDerived": False,
    "flashProtocolClaim": False,
    "hardwareSupportClaim": False,
    "nonAuthoritative": True,
    "parameterRawTextIncluded": False,
    "validOnlyForPinnedArchive": True,
}
CORE_OUTPUTS = (
    "partition-mapping.json",
    "member-reconciliation.json",
    "process-audit.json",
)
RUNTIME_RECEIPT = "broker-runtime-receipt.json"
PLATFORM_EVIDENCE = "broker-platform-evidence.json"
EXPECTED_BUNDLE_ID = "io.arkdeck.partition-decode-broker"
EXPECTED_PYTHON_VERSION = "3.14.6"
PYTHON_INCLUDE = (
    "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/"
    "include/python3.14"
)
PYTHON_LIBRARY = (
    "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/lib"
)
ALLOWED_VERIFICATION_EXECUTABLES = frozenset(
    {
        "/usr/bin/codesign",
        "/usr/bin/otool",
        "/usr/bin/sw_vers",
        "/usr/bin/uname",
        "/usr/bin/xcodebuild",
        "/usr/bin/swift",
    }
)

_BROKER_ROOT = os.path.dirname(os.path.abspath(__file__))
_PARTITION_ROOT = os.path.dirname(_BROKER_ROOT)
_REPO_ROOT = os.path.dirname(os.path.dirname(_PARTITION_ROOT))
_BUILD_SCRIPT = os.path.join(_BROKER_ROOT, "build_and_sign.zsh")
_SOURCE_POLICY = os.path.join(_BROKER_ROOT, "policy.json")
_SOURCE_INVENTORY = os.path.join(
    _REPO_ROOT,
    "openspec/changes/archive/2026-07-18-chg-2026-003-dayu200-image-"
    "characterization/evidence/member-inventory.json",
)
sys.path.insert(0, _PARTITION_ROOT)
import evidence

_SOURCE_FILES = {
    "Broker.entitlements": os.path.join(_BROKER_ROOT, "Broker.entitlements"),
    "Info.plist": os.path.join(_BROKER_ROOT, "Info.plist"),
    "broker_entry.py": os.path.join(_PARTITION_ROOT, "broker_entry.py"),
    "decode.py": os.path.join(_PARTITION_ROOT, "decode.py"),
    "evidence.py": os.path.join(_PARTITION_ROOT, "evidence.py"),
    "main.m": os.path.join(_BROKER_ROOT, "main.m"),
    "member-inventory.json": _SOURCE_INVENTORY,
    "policy.json": _SOURCE_POLICY,
}


class CollectionError(Exception):
    pass


def _serialize(document: dict) -> bytes:
    return (
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def _read(path: str) -> bytes:
    with open(path, "rb") as handle:
        return handle.read()


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1048576)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _json_bytes(payload: bytes, label: str) -> dict:
    try:
        document = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise CollectionError(f"invalid JSON: {label}") from None
    if not isinstance(document, dict):
        raise CollectionError(f"JSON root is not an object: {label}")
    return document


def _run_fixed(arguments: list[str]) -> subprocess.CompletedProcess:
    if not arguments or arguments[0] not in ALLOWED_VERIFICATION_EXECUTABLES:
        raise CollectionError("verification executable is not allowlisted")
    result = subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        shell=False,
        check=False,
    )
    if result.returncode != 0:
        raise CollectionError(
            f"verification command failed: {os.path.basename(arguments[0])}"
        )
    return result


def _build_fresh_artifact(output_root: str) -> str:
    result = subprocess.run(
        [_BUILD_SCRIPT, output_root, PYTHON_INCLUDE, PYTHON_LIBRARY],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        shell=False,
        check=False,
    )
    if result.returncode != 0:
        raise CollectionError("fresh broker build/sign failed")
    app = os.path.join(output_root, "ArkDeckPartitionDecodeBroker.app")
    if not os.path.isdir(app):
        raise CollectionError("fresh broker artifact missing")
    return app


def _bundle_tree(app_path: str) -> tuple[str, list[dict]]:
    rows = []
    for root, directories, filenames in os.walk(app_path):
        directories.sort()
        filenames.sort()
        for filename in filenames:
            path = os.path.join(root, filename)
            relative = os.path.relpath(path, app_path)
            file_stat = os.stat(path, follow_symlinks=False)
            if not stat.S_ISREG(file_stat.st_mode):
                raise CollectionError(f"non-regular artifact entry: {relative}")
            rows.append(
                {
                    "path": relative,
                    "sizeBytes": file_stat.st_size,
                    "sha256": _sha256(path),
                }
            )
    digest = hashlib.sha256()
    for row in rows:
        digest.update(row["path"].encode("utf-8"))
        digest.update(b"\x00")
        digest.update(str(row["sizeBytes"]).encode("ascii"))
        digest.update(b"\x00")
        digest.update(row["sha256"].encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest(), rows


def _source_hashes() -> dict[str, str]:
    return {name: _sha256(path) for name, path in sorted(_SOURCE_FILES.items())}


def _inspect_artifact(app_path: str) -> dict:
    info_path = os.path.join(app_path, "Contents", "Info.plist")
    with open(info_path, "rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != EXPECTED_BUNDLE_ID:
        raise CollectionError("broker bundle identifier mismatch")
    executable_name = info.get("CFBundleExecutable")
    if executable_name != "ArkDeckPartitionDecodeBroker":
        raise CollectionError("broker executable name mismatch")
    executable = os.path.join(app_path, "Contents", "MacOS", executable_name)

    _run_fixed(["/usr/bin/codesign", "--verify", "--strict", "--verbose=4", app_path])
    entitlement_result = _run_fixed(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", app_path]
    )
    try:
        entitlements = plistlib.loads(entitlement_result.stdout)
    except Exception:
        raise CollectionError("signed entitlement payload is not a plist") from None
    if entitlements != EXPECTED_ENTITLEMENTS:
        raise CollectionError("signed entitlements differ from closed allowlist")

    metadata_result = _run_fixed(
        ["/usr/bin/codesign", "-d", "--verbose=4", app_path]
    )
    metadata = metadata_result.stderr.decode("utf-8", errors="strict")
    fields = {}
    prefixes = {
        "Identifier=": "Identifier",
        "CDHash=": "CDHash",
        "CandidateCDHashFull sha256=": "CandidateCDHashFull",
        "Signature=": "Signature",
    }
    for line in metadata.splitlines():
        for prefix, key in prefixes.items():
            if line.startswith(prefix):
                fields[key] = line[len(prefix) :]
    required = ("Identifier", "CDHash", "CandidateCDHashFull", "Signature")
    if any(not fields.get(key) for key in required):
        raise CollectionError("code-signing metadata incomplete")
    if fields["Identifier"] != EXPECTED_BUNDLE_ID or fields["Signature"] != "adhoc":
        raise CollectionError("code-signing identity mismatch")

    linked_result = _run_fixed(["/usr/bin/otool", "-L", executable])
    linked_lines = linked_result.stdout.decode("utf-8", errors="strict").splitlines()[1:]
    linked_libraries = [line.strip().split(" (", 1)[0] for line in linked_lines if line.strip()]
    expected_python = (
        "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/Python"
    )
    if expected_python not in linked_libraries:
        raise CollectionError("artifact is not linked to readiness-pinned CPython")

    tree_sha256, manifest = _bundle_tree(app_path)
    manifest_by_path = {row["path"]: row for row in manifest}
    source_hashes = _source_hashes()
    resource_names = {
        "Broker.entitlements": "Contents/Resources/Broker.entitlements",
        "Info.plist": "Contents/Info.plist",
        "broker_entry.py": "Contents/Resources/broker_entry.py",
        "decode.py": "Contents/Resources/decode.py",
        "evidence.py": "Contents/Resources/evidence.py",
        "main.m": "Contents/Resources/main.m",
        "member-inventory.json": "Contents/Resources/member-inventory.json",
        "policy.json": "Contents/Resources/policy.json",
    }
    for source_name, resource_path in resource_names.items():
        row = manifest_by_path.get(resource_path)
        if row is None or row["sha256"] != source_hashes[source_name]:
            raise CollectionError(f"signed source resource mismatch: {source_name}")

    return {
        "bundleIdentifier": fields["Identifier"],
        "signatureIdentity": fields["Signature"],
        "signatureVerifiedStrict": True,
        "codeDirectoryHash": fields["CDHash"],
        "candidateCodeDirectoryHashFull": fields["CandidateCDHashFull"],
        "executableSha256": _sha256(executable),
        "bundleTreeSha256": tree_sha256,
        "bundleTreeHashMethod": (
            "SHA-256 over sorted relative-path NUL size NUL file-SHA256 LF rows"
        ),
        "fileManifest": manifest,
        "sourceSha256": source_hashes,
        "signedEntitlements": entitlements,
        "linkedLibraries": linked_libraries,
    }


def _launch_verified_broker(app_path: str, preflight: dict) -> tuple[dict, bytes, str]:
    executable = os.path.join(
        app_path, "Contents", "MacOS", "ArkDeckPartitionDecodeBroker"
    )
    if _sha256(executable) != preflight["executableSha256"]:
        raise CollectionError("broker executable changed before launch")
    process = subprocess.Popen(
        [executable],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        shell=False,
    )
    stdout, stderr = process.communicate()
    if process.returncode != 0:
        raise CollectionError(
            "verified broker run failed: "
            + stderr.decode("utf-8", errors="replace").strip()[:300]
        )
    receipt_encoded = None
    output_dir = None
    for line in stdout.decode("utf-8", errors="strict").splitlines():
        if line.startswith("BROKER_RECEIPT_B64="):
            receipt_encoded = line.partition("=")[2]
        elif line.startswith("BROKER_OUTPUT_DIR="):
            output_dir = line.partition("=")[2]
        elif line:
            raise CollectionError("unexpected broker stdout")
    if receipt_encoded is None or output_dir is None:
        raise CollectionError("broker stdout receipt/output binding missing")
    try:
        receipt_payload = base64.b64decode(receipt_encoded, validate=True)
    except (ValueError, binascii.Error):
        raise CollectionError("broker receipt base64 invalid") from None
    receipt = _json_bytes(receipt_payload, "broker stdout receipt")
    return receipt, receipt_payload, output_dir


def _validate_runtime_receipt(
    receipt: dict, receipt_payload: bytes, output_dir: str, artifact: dict
) -> dict[str, bytes]:
    expected_device_paths = (
        "/dev/disk0",
        "/dev/rdisk0",
        "/dev/cu.usbserial-synthetic",
        "/dev/tty.usbserial-synthetic",
    )
    try:
        device_checks = receipt["policyChecks"]
        core_hashes = receipt["coreOutputSha256"]
        valid = (
            receipt["schema"] == "arkdeck-dayu200-input-broker-runtime-1.0.0"
            and receipt["appSandboxPolicyVerified"] is True
            and receipt["deviceNamespacePathRejectedBeforeOpen"] is True
            and all(
                device_checks[path] == {"readDenied": True, "writeDenied": True}
                for path in expected_device_paths
            )
            and device_checks["network-outbound"] is True
            and device_checks["process-exec"] is True
            and receipt["archiveAcquisition"] == "NSOpenPanel user selection"
            and receipt["archiveDescriptorOpenFlags"]
            == ["O_RDONLY", "O_NONBLOCK", "O_NOFOLLOW", "O_CLOEXEC"]
            and receipt["descriptorTransfer"]
            == "same-process CPython C API call with integer fd only"
            and receipt["archivePathPassedToDecoder"] is False
            and receipt["subprocessUsed"] is False
            and receipt["socketOrNetworkUsed"] is False
            and receipt["realDeviceNodeOpenedForVerification"] is False
            and receipt["existingArkDeckAppUsed"] is False
            and receipt["runningCode"]["identifier"] == artifact["bundleIdentifier"]
            and receipt["runningCode"]["codeDirectoryHash"]
            == artifact["codeDirectoryHash"]
            and receipt["embeddedPythonVersion"] == EXPECTED_PYTHON_VERSION
            and set(core_hashes) == set(CORE_OUTPUTS)
            and all(re.fullmatch(r"[0-9a-f]{64}", value) for value in core_hashes.values())
        )
    except (KeyError, TypeError):
        valid = False
    if not valid:
        raise CollectionError("runtime receipt failed closed validation")

    receipt_file = os.path.join(output_dir, RUNTIME_RECEIPT)
    if _read(receipt_file) != receipt_payload:
        raise CollectionError("stdout receipt and broker receipt file differ")
    payloads = {}
    for name in CORE_OUTPUTS:
        payload = _read(os.path.join(output_dir, name))
        if _sha256_bytes(payload) != receipt["coreOutputSha256"][name]:
            raise CollectionError(f"runtime-bound core hash mismatch: {name}")
        payloads[name] = payload
    payloads[RUNTIME_RECEIPT] = receipt_payload
    return payloads


def _parse_sw_vers(payload: str) -> tuple[str, str]:
    values = {}
    for line in payload.splitlines():
        key, separator, value = line.partition(":")
        if separator:
            values[key.strip()] = value.strip()
    try:
        return values["ProductVersion"], values["BuildVersion"]
    except KeyError:
        raise CollectionError("sw_vers output incomplete") from None


def _environment(receipt: dict) -> dict:
    sw_vers = _run_fixed(["/usr/bin/sw_vers"]).stdout.decode("utf-8", errors="strict")
    product, build = _parse_sw_vers(sw_vers)
    swift_result = _run_fixed(["/usr/bin/swift", "--version"])
    swift_version = (swift_result.stderr + swift_result.stdout).decode(
        "utf-8", errors="strict"
    ).strip()
    return {
        "osProductVersion": product,
        "osBuildVersion": build,
        "architecture": _run_fixed(["/usr/bin/uname", "-m"])
        .stdout.decode("utf-8", errors="strict")
        .strip(),
        "xcodeVersion": _run_fixed(["/usr/bin/xcodebuild", "-version"])
        .stdout.decode("utf-8", errors="strict")
        .strip(),
        "swiftVersion": swift_version,
        "pythonVersion": receipt["embeddedPythonVersion"],
        "pythonVersionProvenance": "sys.version_info in verified embedded CPython child",
    }


def collect_fresh(out_dir: str) -> None:
    if os.path.lexists(out_dir):
        raise CollectionError("refusing existing output directory")
    with tempfile.TemporaryDirectory(prefix="arkdeck-pd001-broker-") as temporary:
        build_root = os.path.join(temporary, "build")
        app = _build_fresh_artifact(build_root)
        before = _inspect_artifact(app)
        receipt, receipt_payload, output_dir = _launch_verified_broker(app, before)
        core_payloads = _validate_runtime_receipt(
            receipt, receipt_payload, output_dir, before
        )
        after = _inspect_artifact(app)
        if before != after:
            raise CollectionError("signed broker artifact changed across runtime")

        policy = _json_bytes(_read(_SOURCE_POLICY), "source policy")
        if policy.get("allowedEntitlements") != EXPECTED_ENTITLEMENTS:
            raise CollectionError("source policy entitlement allowlist drift")
        runtime_receipt_sha256 = _sha256_bytes(receipt_payload)
        platform = {
            "schema": "arkdeck-dayu200-input-broker-platform-2.0.0",
            "evidenceClass": "platform",
            "scope": EXPECTED_SCOPE,
            "environment": _environment(receipt),
            "freshCollector": {
                "callerSuppliedArtifact": False,
                "callerSuppliedRuntimeReceipt": False,
                "callerSuppliedCoreOutputs": False,
                "artifactBuiltFromReviewedSource": True,
                "artifactVerifiedBeforeAndAfterRun": True,
                "runtimeReceiptCapturedFromVerifiedChildStdoutPipe": True,
            },
            "sandboxBroker": {
                "artifact": before,
                "policy": {
                    "sha256": _sha256(_SOURCE_POLICY),
                    "appSandboxPolicyVerified": receipt[
                        "appSandboxPolicyVerified"
                    ],
                    "deviceNamespace": "/dev",
                    "deviceNamespacePathRejectedBeforeOpen": receipt[
                        "deviceNamespacePathRejectedBeforeOpen"
                    ],
                    "deviceChecks": receipt["policyChecks"],
                    "networkDenied": receipt["policyChecks"]["network-outbound"],
                    "processExecDenied": receipt["policyChecks"]["process-exec"],
                },
                "descriptorTransfer": {
                    "archiveAcquisition": receipt["archiveAcquisition"],
                    "archiveDescriptorOpenFlags": receipt[
                        "archiveDescriptorOpenFlags"
                    ],
                    "decoderInvocation": receipt["descriptorTransfer"],
                    "archivePathPassedToDecoder": receipt[
                        "archivePathPassedToDecoder"
                    ],
                    "subprocessUsedByBrokerRuntime": receipt["subprocessUsed"],
                    "socketOrNetworkUsed": receipt["socketOrNetworkUsed"],
                    "realDeviceNodeOpenedForVerification": receipt[
                        "realDeviceNodeOpenedForVerification"
                    ],
                    "existingArkDeckAppUsed": receipt["existingArkDeckAppUsed"],
                },
            },
            "runtimeBinding": {
                "receiptSha256": runtime_receipt_sha256,
                "runningCodeIdentifier": receipt["runningCode"]["identifier"],
                "runningCodeDirectoryHash": receipt["runningCode"][
                    "codeDirectoryHash"
                ],
                "coreOutputSha256": receipt["coreOutputSha256"],
            },
        }
        platform_payload = _serialize(platform)

        evidence.publish_collector_validated_evidence(
            {name: core_payloads[name] for name in CORE_OUTPUTS},
            receipt,
            receipt_payload,
            platform,
            platform_payload,
            out_dir,
        )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Build/run/attest fresh TASK-PD-001 broker evidence."
    )
    parser.add_argument("--out-dir", required=True)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        collect_fresh(arguments.out_dir)
    except (
        CollectionError,
        OSError,
        plistlib.InvalidFileException,
        evidence.decode.DecodeFailure,
        evidence.decode.DecodeToolError,
        evidence.decode.EvidenceValidationError,
    ) as error:
        print(f"platform evidence collection failed: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
