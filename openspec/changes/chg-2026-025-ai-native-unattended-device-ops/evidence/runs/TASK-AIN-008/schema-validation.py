#!/usr/bin/env python3
"""Offline Draft 2020-12 positive/negative checks for TASK-AIN-008."""

from __future__ import annotations

import copy
import json
import warnings
from pathlib import Path

warnings.filterwarnings("ignore", category=DeprecationWarning)
from jsonschema import Draft202012Validator, FormatChecker, RefResolver, ValidationError


CHANGE_ROOT = Path(__file__).resolve().parents[3]
OPENSPEC_ROOT = CHANGE_ROOT.parent.parent


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


manifest_schema = load(CHANGE_ROOT / "contracts/manifest.schema.v2.1-draft.json")
journal_schema = load(CHANGE_ROOT / "contracts/journal-event.schema.v2.1-draft.json")
base_manifest = load(OPENSPEC_ROOT / "contracts/manifest.schema.json")
base_journal = load(OPENSPEC_ROOT / "contracts/journal-event.schema.json")
workflow_step = load(OPENSPEC_ROOT / "contracts/workflow-step.schema.json")

for schema in [manifest_schema, journal_schema]:
    Draft202012Validator.check_schema(schema)

store = {
    base_manifest["$id"]: base_manifest,
    base_journal["$id"]: base_journal,
    workflow_step["$id"]: workflow_step,
    "https://arkdeck.dev/contracts/manifest.schema.json": base_manifest,
    "https://arkdeck.dev/contracts/journal-event.schema.json": base_journal,
}


def validator(schema: dict) -> Draft202012Validator:
    return Draft202012Validator(
        schema,
        resolver=RefResolver.from_schema(schema, store=store),
        format_checker=FormatChecker(),
    )


manifest_validator = validator(manifest_schema)
journal_validator = validator(journal_schema)

authorization_ref = {
    "authorizationId": "authorization-rockchip",
    "mainCommitOID": "a" * 40,
    "authorizationBlobOID": "b" * 40,
    "approvalPRNumber": 311,
}
rockchip_toolchain = {
    "kind": "rockchip",
    "profileIdentifier": "ROCKCHIP-ROCKUSB-DISCOVERY@1.0.0",
    "reportedVersion": "rkdeveloptool ver 1.32",
    "sha256": "038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611",
    "pathSource": "userSelectedSecurityScopedBookmark",
    "descriptorIdentity": {
        "device": 17,
        "inode": 29,
        "fileSize": 4096,
        "mode": 0o100755,
    },
}
manifest = {
    "schemaVersion": "2.1.0",
    "appVersion": "1.0.0-test",
    "coreSpecBaseline": "CORE-2.1.0",
    "platformProfile": "macos-1.0.0",
    "sessionId": "session-rockchip-v21",
    "jobId": "job-rockchip-v21",
    "status": "succeeded",
    "executionMode": "execute",
    "executionAuthority": "authorizedAgent",
    "authorization": {
        "authorizationRef": authorization_ref,
        "usageReservationId": "reservation-1",
        "destructiveIntentEventIds": [],
    },
    "outcomeCertainty": "confirmed",
    "sessionDisposition": "finalized",
    "createdAt": "2026-07-22T12:00:00Z",
    "completedAt": "2026-07-22T12:00:00Z",
    "archivedAt": None,
    "originalTarget": {
        "kind": "real",
        "connectKey": "usb-fixture",
        "transport": "usb",
        "identitySnapshot": {"serial": "fixture-serial"},
    },
    "bindingHistory": [
        {
            "revision": 1,
            "connectKey": "usb-fixture",
            "transport": "usb",
            "identitySnapshot": {"serial": "fixture-serial"},
            "evidence": ["fixture-binding"],
            "confirmedBy": "corePolicy",
            "channelProtection": "unverifiedAssumeUnprotected",
        }
    ],
    "toolchain": rockchip_toolchain,
    "workflow": {
        "kind": "rockchipFlash",
        "profileVersion": "1.0.0",
        "providerIdentity": "rockchip-rockusb-flash@1.0.0",
    },
    "steps": [],
    "parameters": [],
    "compensations": [],
    "confirmations": [],
    "artifacts": [],
    "warnings": [],
    "failure": None,
    "recovery": None,
}
manifest_validator.validate(manifest)

manifest_negative_count = 0
for field in ["profileIdentifier", "reportedVersion", "sha256", "pathSource"]:
    candidate = copy.deepcopy(manifest)
    del candidate["toolchain"][field]
    try:
        manifest_validator.validate(candidate)
    except ValidationError:
        manifest_negative_count += 1
    else:
        raise AssertionError(f"missing toolchain {field} was accepted")

for field in ["device", "inode", "fileSize", "mode"]:
    candidate = copy.deepcopy(manifest)
    candidate["toolchain"]["descriptorIdentity"][field] = 0
    try:
        manifest_validator.validate(candidate)
    except ValidationError:
        manifest_negative_count += 1
    else:
        raise AssertionError(f"invalid descriptor {field} was accepted")

for field, value in {
    "device": 18_446_744_073_709_551_616,
    "inode": 18_446_744_073_709_551_616,
    "fileSize": 9_223_372_036_854_775_808,
    "mode": 4_294_967_296,
}.items():
    candidate = copy.deepcopy(manifest)
    candidate["toolchain"]["descriptorIdentity"][field] = value
    try:
        manifest_validator.validate(candidate)
    except ValidationError:
        manifest_negative_count += 1
    else:
        raise AssertionError(f"oversized descriptor {field} was accepted")

for field in ["path", "bookmarkData", "stableDescriptorPath", "callerLabel", "argv", "environment"]:
    candidate = copy.deepcopy(manifest)
    candidate["toolchain"][field] = "forged"
    try:
        manifest_validator.validate(candidate)
    except ValidationError:
        manifest_negative_count += 1
    else:
        raise AssertionError(f"forbidden toolchain {field} was accepted")

candidate = copy.deepcopy(manifest)
candidate["schemaVersion"] = "2.0.0"
try:
    manifest_validator.validate(candidate)
except ValidationError:
    manifest_negative_count += 1
else:
    raise AssertionError("v2 rockchip Manifest was accepted by the v2.1 schema")

journal = {
    "schemaVersion": "2.1.0",
    "eventId": "created-1",
    "sequence": 0,
    "sessionId": "session-rockchip-v21",
    "jobId": "job-rockchip-v21",
    "timestamp": "2026-07-22T12:00:00Z",
    "kind": "jobCreated",
    "payload": {
        "executionMode": "execute",
        "executionAuthority": "authorizedAgent",
        "initialState": "queued",
        "coreBaseline": "CORE-2.1.0",
        "authorizationRef": authorization_ref,
        "usageReservationId": "reservation-1",
    },
}
journal_validator.validate(journal)

journal_negative_count = 0
for mutation in ["wrongVersion", "callerField", "missingUsage"]:
    candidate = copy.deepcopy(journal)
    if mutation == "wrongVersion":
        candidate["schemaVersion"] = "2.0.0"
    elif mutation == "callerField":
        candidate["payload"]["argv"] = ["ld"]
    else:
        del candidate["payload"]["usageReservationId"]
    try:
        journal_validator.validate(candidate)
    except ValidationError:
        journal_negative_count += 1
    else:
        raise AssertionError(f"journal negative {mutation} was accepted")

print(
    "SCHEMA-AIN-008 PASS draft=2020-12 manifest-positive=1 "
    f"manifest-negative={manifest_negative_count} journal-positive=1 "
    f"journal-negative={journal_negative_count} network=0"
)
