"""Create-only evidence pipeline for the fd-only DAYU200 decoder.

Archive acquisition is deliberately absent. The signed sandbox broker passes a
pre-opened descriptor directly to :func:`build_core_evidence_from_fd`. The
fresh-build collector publishes its in-memory core files, runtime receipt,
signed artifact manifest and platform attestation together in the same process.
"""

from __future__ import annotations

import hashlib
import json
import os
import re

import decode


CORE_OUTPUTS = (
    "partition-mapping.json",
    "member-reconciliation.json",
    "process-audit.json",
)
RUNTIME_RECEIPT = "broker-runtime-receipt.json"
PLATFORM_EVIDENCE = "broker-platform-evidence.json"
COLLECTOR_OUTPUTS = CORE_OUTPUTS + (RUNTIME_RECEIPT, PLATFORM_EVIDENCE)
PUBLISHED_OUTPUTS = COLLECTOR_OUTPUTS + ("summary.md",)

EXPECTED_BUNDLE_ID = "io.arkdeck.partition-decode-broker"
EXPECTED_PYTHON_LIBRARY = (
    "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/Python"
)
EXPECTED_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.user-selected.read-only": True,
    "com.apple.security.temporary-exception.files.absolute-path.read-only": [
        "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/"
    ],
}
EXPECTED_DEVICE_CHECKS = {
    "/dev/disk0": {"readDenied": True, "writeDenied": True},
    "/dev/rdisk0": {"readDenied": True, "writeDenied": True},
    "/dev/cu.usbserial-synthetic": {"readDenied": True, "writeDenied": True},
    "/dev/tty.usbserial-synthetic": {"readDenied": True, "writeDenied": True},
    "network-outbound": True,
    "process-exec": True,
}

_PARTITION_ROOT = os.path.dirname(os.path.abspath(__file__))
_BROKER_ROOT = os.path.join(_PARTITION_ROOT, "macos_input_broker")
_REPO_ROOT = os.path.dirname(os.path.dirname(_PARTITION_ROOT))
DEFAULT_INVENTORY_PATH = os.path.join(_REPO_ROOT, decode._INVENTORY_RELATIVE)
_SOURCE_FILES = {
    "Broker.entitlements": os.path.join(_BROKER_ROOT, "Broker.entitlements"),
    "Info.plist": os.path.join(_BROKER_ROOT, "Info.plist"),
    "broker_entry.py": os.path.join(_PARTITION_ROOT, "broker_entry.py"),
    "decode.py": os.path.join(_PARTITION_ROOT, "decode.py"),
    "evidence.py": os.path.join(_PARTITION_ROOT, "evidence.py"),
    "main.m": os.path.join(_BROKER_ROOT, "main.m"),
    "member-inventory.json": DEFAULT_INVENTORY_PATH,
    "policy.json": os.path.join(_BROKER_ROOT, "policy.json"),
}
_SIGNED_SOURCE_PATHS = {
    "Broker.entitlements": "Contents/Resources/Broker.entitlements",
    "Info.plist": "Contents/Info.plist",
    "broker_entry.py": "Contents/Resources/broker_entry.py",
    "decode.py": "Contents/Resources/decode.py",
    "evidence.py": "Contents/Resources/evidence.py",
    "main.m": "Contents/Resources/main.m",
    "member-inventory.json": "Contents/Resources/member-inventory.json",
    "policy.json": "Contents/Resources/policy.json",
}
_REQUIRED_ARTIFACT_PATHS = set(_SIGNED_SOURCE_PATHS.values()) | {
    "Contents/MacOS/ArkDeckPartitionDecodeBroker",
    "Contents/_CodeSignature/CodeResources",
    "Contents/Resources/member-inventory.json",
}


def _serialize(document: dict) -> bytes:
    return (
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1048576)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _is_hash(value: object, length: int = 64) -> bool:
    return isinstance(value, str) and re.fullmatch(
        rf"[0-9a-f]{{{length}}}", value
    ) is not None


def load_archived_inventory(path: str = DEFAULT_INVENTORY_PATH) -> tuple[dict, str]:
    with open(path, "rb") as handle:
        payload = handle.read()
    digest = _sha256_bytes(payload)
    if digest != decode.EXPECTED_INVENTORY_SHA256:
        raise decode.DecodeFailure(decode.PD011_INVENTORY_INVALID, "evidence hash mismatch")
    try:
        document = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise decode.DecodeFailure(
            decode.PD011_INVENTORY_INVALID, "evidence JSON invalid"
        ) from None
    decode._validate_inventory(document, require_pinned_count=True)
    return document, digest


def _preflight_create_only(out_dir: str, names: tuple[str, ...]) -> None:
    os.makedirs(out_dir, exist_ok=True)
    conflicts = [name for name in names if os.path.lexists(os.path.join(out_dir, name))]
    if conflicts:
        raise decode.DecodeToolError(
            "refusing mixed/partial evidence write; existing output: "
            + ", ".join(conflicts)
        )


def _write_create_only(out_dir: str, name: str, payload: bytes) -> None:
    try:
        with open(os.path.join(out_dir, name), "xb") as handle:
            handle.write(payload)
    except FileExistsError:
        raise decode.DecodeToolError(f"refusing to overwrite evidence: {name}") from None


def _write_set(out_dir: str, payloads: dict[str, bytes], names: tuple[str, ...]) -> None:
    if tuple(payloads) != names:
        raise decode.DecodeToolError("evidence payload set/order does not match allowlist")
    _preflight_create_only(out_dir, names)
    for name, payload in payloads.items():
        _write_create_only(out_dir, name, payload)


def _core_documents_from_fd(
    descriptor: int, inventory_document: dict, inventory_sha256: str
) -> tuple[dict, decode.DecodeAudit]:
    identity, device, partitions, audit = decode.decode_archive(descriptor)
    reconciliation = decode.reconcile_members(partitions, inventory_document)
    documents = {
        "partition-mapping.json": decode._partition_document(identity, device, partitions),
        "member-reconciliation.json": decode._reconciliation_document(
            reconciliation, inventory_sha256
        ),
        "process-audit.json": decode._audit_document(audit),
    }
    decode.validate_evidence_bundle(documents, inventory_document, inventory_sha256)
    return documents, audit


def build_core_evidence_from_fd(
    descriptor: int,
    out_dir: str,
    inventory_path: str = DEFAULT_INVENTORY_PATH,
) -> decode.DecodeAudit:
    """Broker entry point: consume an fd and write only the three core JSON files."""
    inventory_document, inventory_sha256 = load_archived_inventory(inventory_path)
    documents, audit = _core_documents_from_fd(
        descriptor, inventory_document, inventory_sha256
    )
    payloads = {name: _serialize(documents[name]) for name in CORE_OUTPUTS}
    _write_set(out_dir, payloads, CORE_OUTPUTS)
    return audit


def _document_from_payload(
    payload: bytes, label: str, require_canonical: bool = True
) -> dict:
    try:
        document = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise decode.EvidenceValidationError(f"invalid JSON evidence: {label}") from None
    if not isinstance(document, dict):
        raise decode.EvidenceValidationError(
            f"JSON evidence root is not object: {label}"
        )
    if require_canonical and payload != _serialize(document):
        raise decode.EvidenceValidationError(f"non-canonical JSON evidence: {label}")
    return document


def validate_runtime_receipt(document: dict) -> None:
    expected_keys = {
        "schema",
        "appSandboxPolicyVerified",
        "policyChecks",
        "deviceNamespacePathRejectedBeforeOpen",
        "archiveAcquisition",
        "archiveDescriptorOpenFlags",
        "descriptorTransfer",
        "archivePathPassedToDecoder",
        "subprocessUsed",
        "socketOrNetworkUsed",
        "realDeviceNodeOpenedForVerification",
        "existingArkDeckAppUsed",
        "runningCode",
        "embeddedPythonVersion",
        "coreOutputSha256",
        "decoderOutputs",
    }
    try:
        core_hashes = document["coreOutputSha256"]
        valid = (
            set(document) == expected_keys
            and document["schema"] == "arkdeck-dayu200-input-broker-runtime-1.0.0"
            and document["appSandboxPolicyVerified"] is True
            and document["policyChecks"] == EXPECTED_DEVICE_CHECKS
            and document["deviceNamespacePathRejectedBeforeOpen"] is True
            and document["archiveAcquisition"] == "NSOpenPanel user selection"
            and document["archiveDescriptorOpenFlags"]
            == ["O_RDONLY", "O_NONBLOCK", "O_NOFOLLOW", "O_CLOEXEC"]
            and document["descriptorTransfer"]
            == "same-process CPython C API call with integer fd only"
            and document["archivePathPassedToDecoder"] is False
            and document["subprocessUsed"] is False
            and document["socketOrNetworkUsed"] is False
            and document["realDeviceNodeOpenedForVerification"] is False
            and document["existingArkDeckAppUsed"] is False
            and set(document["runningCode"]) == {"identifier", "codeDirectoryHash"}
            and document["runningCode"]["identifier"] == EXPECTED_BUNDLE_ID
            and _is_hash(document["runningCode"]["codeDirectoryHash"], 40)
            and document["embeddedPythonVersion"] == decode.EXPECTED_PYTHON_VERSION
            and set(core_hashes) == set(CORE_OUTPUTS)
            and all(_is_hash(value) for value in core_hashes.values())
            and document["decoderOutputs"] == list(CORE_OUTPUTS)
        )
    except (KeyError, TypeError):
        valid = False
    if not valid:
        raise decode.EvidenceValidationError("closed broker runtime receipt invalid")


def validate_platform_evidence(
    document: dict,
    runtime_document: dict,
    runtime_payload: bytes,
    core_payloads: dict[str, bytes],
) -> None:
    """Validate artifact, runtime identity and exact output bytes as one closed bundle."""
    try:
        environment = document["environment"]
        fresh = document["freshCollector"]
        broker = document["sandboxBroker"]
        artifact = broker["artifact"]
        policy = broker["policy"]
        transfer = broker["descriptorTransfer"]
        binding = document["runtimeBinding"]
        manifest = artifact["fileManifest"]
        source_hashes = artifact["sourceSha256"]
        manifest_by_path = {row["path"]: row for row in manifest}
        actual_source_hashes = {
            name: _sha256_file(path) for name, path in sorted(_SOURCE_FILES.items())
        }
        actual_core_hashes = {
            name: _sha256_bytes(core_payloads[name]) for name in CORE_OUTPUTS
        }
        manifest_valid = (
            isinstance(manifest, list)
            and bool(manifest)
            and len(manifest_by_path) == len(manifest)
            and all(
                set(row) == {"path", "sizeBytes", "sha256"}
                and isinstance(row["path"], str)
                and row["path"]
                and not row["path"].startswith("/")
                and isinstance(row["sizeBytes"], int)
                and row["sizeBytes"] >= 0
                and _is_hash(row["sha256"])
                for row in manifest
            )
            and _REQUIRED_ARTIFACT_PATHS <= set(manifest_by_path)
        )
        sources_bound = (
            source_hashes == actual_source_hashes
            and all(
                manifest_by_path[signed_path]["sha256"] == source_hashes[name]
                for name, signed_path in _SIGNED_SOURCE_PATHS.items()
            )
        )
        valid = (
            set(document)
            == {
                "schema",
                "evidenceClass",
                "scope",
                "environment",
                "freshCollector",
                "sandboxBroker",
                "runtimeBinding",
            }
            and document["schema"]
            == "arkdeck-dayu200-input-broker-platform-2.0.0"
            and document["evidenceClass"] == "platform"
            and document["scope"] == decode._scope()
            and set(environment)
            == {
                "osProductVersion",
                "osBuildVersion",
                "architecture",
                "xcodeVersion",
                "swiftVersion",
                "pythonVersion",
                "pythonVersionProvenance",
            }
            and all(
                isinstance(environment[name], str) and environment[name]
                for name in (
                    "osProductVersion",
                    "osBuildVersion",
                    "xcodeVersion",
                    "swiftVersion",
                )
            )
            and environment["architecture"] == "arm64"
            and environment["pythonVersion"] == decode.EXPECTED_PYTHON_VERSION
            and environment["pythonVersion"] == runtime_document["embeddedPythonVersion"]
            and environment["pythonVersionProvenance"]
            == "sys.version_info in verified embedded CPython child"
            and fresh
            == {
                "callerSuppliedArtifact": False,
                "callerSuppliedRuntimeReceipt": False,
                "callerSuppliedCoreOutputs": False,
                "artifactBuiltFromReviewedSource": True,
                "artifactVerifiedBeforeAndAfterRun": True,
                "runtimeReceiptCapturedFromVerifiedChildStdoutPipe": True,
            }
            and set(broker) == {"artifact", "policy", "descriptorTransfer"}
            and set(artifact)
            == {
                "bundleIdentifier",
                "signatureIdentity",
                "signatureVerifiedStrict",
                "codeDirectoryHash",
                "candidateCodeDirectoryHashFull",
                "executableSha256",
                "bundleTreeSha256",
                "bundleTreeHashMethod",
                "fileManifest",
                "sourceSha256",
                "signedEntitlements",
                "linkedLibraries",
            }
            and artifact["bundleIdentifier"] == EXPECTED_BUNDLE_ID
            and artifact["signatureIdentity"] == "adhoc"
            and artifact["signatureVerifiedStrict"] is True
            and _is_hash(artifact["codeDirectoryHash"], 40)
            and _is_hash(artifact["candidateCodeDirectoryHashFull"])
            and _is_hash(artifact["executableSha256"])
            and _is_hash(artifact["bundleTreeSha256"])
            and artifact["bundleTreeHashMethod"]
            == "SHA-256 over sorted relative-path NUL size NUL file-SHA256 LF rows"
            and manifest_valid
            and sources_bound
            and artifact["signedEntitlements"] == EXPECTED_ENTITLEMENTS
            and isinstance(artifact["linkedLibraries"], list)
            and EXPECTED_PYTHON_LIBRARY in artifact["linkedLibraries"]
            and policy
            == {
                "sha256": source_hashes["policy.json"],
                "appSandboxPolicyVerified": True,
                "deviceNamespace": "/dev",
                "deviceNamespacePathRejectedBeforeOpen": True,
                "deviceChecks": EXPECTED_DEVICE_CHECKS,
                "networkDenied": True,
                "processExecDenied": True,
            }
            and transfer
            == {
                "archiveAcquisition": "NSOpenPanel user selection",
                "archiveDescriptorOpenFlags": [
                    "O_RDONLY",
                    "O_NONBLOCK",
                    "O_NOFOLLOW",
                    "O_CLOEXEC",
                ],
                "decoderInvocation": (
                    "same-process CPython C API call with integer fd only"
                ),
                "archivePathPassedToDecoder": False,
                "subprocessUsedByBrokerRuntime": False,
                "socketOrNetworkUsed": False,
                "realDeviceNodeOpenedForVerification": False,
                "existingArkDeckAppUsed": False,
            }
            and binding
            == {
                "receiptSha256": _sha256_bytes(runtime_payload),
                "runningCodeIdentifier": EXPECTED_BUNDLE_ID,
                "runningCodeDirectoryHash": artifact["codeDirectoryHash"],
                "coreOutputSha256": actual_core_hashes,
            }
            and runtime_document["runningCode"]["identifier"]
            == artifact["bundleIdentifier"]
            and runtime_document["runningCode"]["codeDirectoryHash"]
            == artifact["codeDirectoryHash"]
            and runtime_document["coreOutputSha256"] == actual_core_hashes
        )
    except (KeyError, TypeError):
        valid = False
    if not valid:
        raise decode.EvidenceValidationError("closed broker platform evidence invalid")


def _summary(documents: dict, platform: dict, payloads: dict[str, bytes]) -> bytes:
    mapping = documents["partition-mapping.json"]
    reconciliation = documents["member-reconciliation.json"]
    audit = documents["process-audit.json"]
    artifact = platform["sandboxBroker"]["artifact"]
    lines = [
        "# DAYU200 pinned-image partition decode r2 summary",
        "",
        "**Fresh r2 task result: BLOCKED.**",
        "",
        "`TEST-DECODE-DAYU200-INPUT-BOUNDARY-001` and",
        "`TEST-DECODE-DAYU200-RECONCILE-001` pass in isolation. The separately",
        "built and verified App Sandbox broker is bound by CDHash, signed bundle",
        "manifest, reviewed-source hashes and a runtime receipt to these exact core",
        "outputs. No real device node was opened.",
        "",
        "`TEST-DECODE-DAYU200-PARTITION-001` remains **FAILED / BLOCKED**. The",
        "application-visible discard loop releases each non-target output chunk before",
        "requesting the next chunk, but zlib necessarily retains opaque DEFLATE sliding",
        "history across calls. Revision r2 does not say whether that mandatory codec",
        "state is exempt from its literal no-retention-across-chunks requirement, so this",
        "run does not claim the acceptance boundary is satisfied.",
        "",
        "This is non-authoritative evidence valid only for pinned archive identity",
        f"`{decode.EXPECTED_RAW_SHA256}`. The original `parameter.txt` text and archive",
        "locator are omitted. Encoded offsets are decoded table fields only: no flash",
        "address, protocol, compatibility, executable profile or hardware support is",
        "derived or claimed.",
        "",
        "| Evidence file | SHA-256 |",
        "| --- | --- |",
    ]
    for name in COLLECTOR_OUTPUTS:
        lines.append(f"| `{name}` | `{_sha256_bytes(payloads[name])}` |")
    lines += [
        "",
        "## Acceptance conclusions",
        "",
        "| Test ID | Conclusion |",
        "| --- | --- |",
        "| `TEST-DECODE-DAYU200-PARTITION-001` | **FAILED / BLOCKED** — mandatory DEFLATE history makes literal cross-chunk zero-retention unproven |",
        "| `TEST-DECODE-DAYU200-INPUT-BOUNDARY-001` | PASS in isolation — fresh signed broker/platform/runtime binding validated |",
        "| `TEST-DECODE-DAYU200-RECONCILE-001` | PASS in isolation — every inventory member and partition accounted for by exact-name rules |",
        "",
        "## Acceptance metrics",
        "",
        f"- Identity pass bytes: {audit['identityPassRawBytesRead']}; gzip pass bytes: {audit['gzipPassRawBytesRead']}.",
        f"- Tar headers: {audit['tarHeadersInspected']}; preceding bodies: {audit['nonParameterMemberContentsRead']}; discarded body bytes: {audit['nonParameterMemberContentBytesReadAndDiscarded']}.",
        f"- Maximum application-visible chunk: {audit['maxObservedReadChunkBytes']} bytes; application reference retained into next read: {audit['applicationChunkReferenceRetainedAcrossNextReadBytes']} bytes.",
        f"- DEFLATE internal history: {audit['deflateInternalHistoryRetention']}; upper bound {audit['deflateWindowUpperBoundBytes']} bytes.",
        "- Parameter raw text persisted: no; archive locator persisted: no; member extraction: none.",
        "- Production decoder subprocess/network/device-mutation dispatch counters: all zero.",
        f"- Broker: `{artifact['bundleIdentifier']}`; CDHash `{artifact['codeDirectoryHash']}`; bundle tree SHA-256 `{artifact['bundleTreeSha256']}`.",
        f"- Embedded Python: `{platform['environment']['pythonVersion']}` from `{platform['environment']['pythonVersionProvenance']}`.",
        "",
        "## Decoded mapping",
        "",
        "| Partition | Size token | Offset token | Attribute |",
        "| --- | ---: | ---: | --- |",
    ]
    for row in mapping["partitions"]:
        attribute = row["attribute"] if row["attribute"] is not None else "none"
        lines.append(
            f"| `{row['name']}` | `{row['size']['encoded']}` | "
            f"`{row['offset']['encoded']}` | `{attribute}` |"
        )
    lines += [
        "",
        "## Image-member reconciliation",
        "",
        f"- Inventory members: {reconciliation['inventoryMemberCount']}; `.img` members: {reconciliation['imageMemberCount']}.",
        f"- Exact-stem mapped: {reconciliation['mappedImageCount']}; image orphans: {reconciliation['orphanImageCount']}; partition orphans: {reconciliation['orphanPartitionCount']}.",
        "- Exact case-sensitive matching only; aliases and address inference are forbidden.",
        "",
        "## S2 citations",
        "",
        f"Source-selection policy: `{decode._ROUTE_PLAN_REFERENCE}`.",
        "",
    ]
    for source in decode.S2_SOURCE_CITATIONS:
        lines.append(f"- [{source['title']}]({source['url']}) — {source['scope']}.")
    lines += [
        "",
        "All S2 citations are contextual; decoded values come only from the pinned member.",
        "",
    ]
    return "\n".join(lines).encode("utf-8")


def publish_collector_validated_evidence(
    core_payloads: dict[str, bytes],
    runtime_document: dict,
    runtime_payload: bytes,
    platform_document: dict,
    platform_payload: bytes,
    out_dir: str,
    inventory_path: str = DEFAULT_INVENTORY_PATH,
) -> None:
    """Publish only in-memory outputs from the fresh-build collector process.

    This function deliberately has no staging paths or standalone CLI. The
    collector invokes it only after independently verifying the artifact before
    and after the broker run and capturing the runtime receipt from that child.
    """
    if tuple(core_payloads) != CORE_OUTPUTS:
        raise decode.EvidenceValidationError(
            "collector core payload set/order does not match allowlist"
        )
    documents = {
        name: _document_from_payload(core_payloads[name], name)
        for name in CORE_OUTPUTS
    }
    inventory_document, inventory_sha256 = load_archived_inventory(inventory_path)
    decode.validate_evidence_bundle(documents, inventory_document, inventory_sha256)
    if _document_from_payload(
        runtime_payload, RUNTIME_RECEIPT, require_canonical=False
    ) != runtime_document:
        raise decode.EvidenceValidationError("runtime receipt object/bytes mismatch")
    validate_runtime_receipt(runtime_document)
    if _document_from_payload(platform_payload, PLATFORM_EVIDENCE) != platform_document:
        raise decode.EvidenceValidationError("platform evidence object/bytes mismatch")
    validate_platform_evidence(
        platform_document, runtime_document, runtime_payload, core_payloads
    )
    payloads = dict(core_payloads)
    payloads[RUNTIME_RECEIPT] = runtime_payload
    payloads[PLATFORM_EVIDENCE] = platform_payload
    payloads["summary.md"] = _summary(documents, platform_document, payloads)
    _write_set(out_dir, payloads, PUBLISHED_OUTPUTS)
