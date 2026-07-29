#!/usr/bin/env python3
"""Deterministic stdlib-only hardware-evidence V3 contract validator.

Run from the repository root:
  python3 openspec/changes/chg-2026-051-agent-hardware-evidence/evidence/runs/TASK-AHE-001/validate_v3.py
  python3 .../validate_v3.py path/to/instance.json

This is a closed assertion set for the checked-in schema, not a general
JSON Schema implementation. The self-test contains positive and negative
vectors for the executor/effect/authority matrix and required privacy
fields.
"""

from copy import deepcopy
from datetime import datetime
import json
from pathlib import Path
import re
import sys

SHA = re.compile(r"^[0-9a-f]{64}$")
EVIDENCE_ID = re.compile(r"^EVD-[A-Z0-9._-]+$")
ACCEPTANCE_ID = re.compile(r"^[A-Z][A-Z0-9]*-[A-Z0-9-]+$")
OPERATION = re.compile(r"^[a-z][a-z0-9.-]*@[1-9][0-9]*$")

TOP_REQUIRED = {
    "schemaVersion", "evidenceId", "executor", "targetConfirmation",
    "device", "toolchain", "transport", "provider", "effectLevel",
    "stepKinds", "acceptanceIds", "executedAt", "artifacts",
}
TOP_ALLOWED = TOP_REQUIRED | {"runtime", "validUntil", "deviations", "notes"}


def _object(errors, value, where, required, allowed):
    if not isinstance(value, dict):
        errors.append(f"{where}: expected object")
        return False
    missing = set(required) - set(value)
    extra = set(value) - set(allowed)
    if missing:
        errors.append(f"{where}: missing {sorted(missing)}")
    if extra:
        errors.append(f"{where}: additional properties {sorted(extra)}")
    return not missing and not extra


def _string(errors, value, where, pattern=None):
    if not isinstance(value, str) or not value:
        errors.append(f"{where}: expected non-empty string")
    elif pattern and not pattern.fullmatch(value):
        errors.append(f"{where}: pattern mismatch")


def _date(errors, value, where):
    _string(errors, value, where)
    if isinstance(value, str):
        try:
            datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            errors.append(f"{where}: invalid date-time")


def _unique_strings(errors, value, where, pattern=None):
    if not isinstance(value, list) or not value:
        errors.append(f"{where}: expected non-empty array")
        return
    if len(value) != len(set(value)):
        errors.append(f"{where}: duplicate items")
    for index, item in enumerate(value):
        _string(errors, item, f"{where}[{index}]", pattern)


def validate(doc):
    errors = []
    if not _object(errors, doc, "$", TOP_REQUIRED, TOP_ALLOWED):
        return errors
    if doc["schemaVersion"] != "3.0.0":
        errors.append("schemaVersion: expected 3.0.0")
    _string(errors, doc["evidenceId"], "evidenceId", EVIDENCE_ID)

    executor = doc["executor"]
    if _object(
        errors, executor, "executor", {"kind", "id"}, {"kind", "id", "authority"}
    ):
        if executor["kind"] not in {"human", "agent"}:
            errors.append("executor.kind: invalid enum")
        _string(errors, executor["id"], "executor.id")
        authority = executor.get("authority")
        if executor["kind"] == "agent" and authority is None:
            errors.append("executor.authority: required for agent")
        if executor["kind"] == "human" and authority is not None:
            errors.append("executor.authority: forbidden for human")
        if authority is not None and _object(
            errors, authority, "executor.authority",
            {"kind", "reference"}, {"kind", "reference"},
        ):
            if authority["kind"] not in {
                "defaultReadOnlyPolicy", "runtimeCapability", "standingAuthorization"
            }:
                errors.append("executor.authority.kind: invalid enum")
            _string(errors, authority["reference"], "executor.authority.reference")

    runtime = doc.get("runtime")
    if executor.get("kind") == "agent" and runtime is None:
        errors.append("runtime: required for agent")
    if runtime is not None and _object(
        errors, runtime, "runtime",
        {
            "operationReference", "jobId", "catalogDigest", "terminalState",
            "startedAt", "finishedAt",
        },
        {
            "operationReference", "jobId", "catalogDigest", "terminalState",
            "startedAt", "finishedAt",
        },
    ):
        _string(errors, runtime["operationReference"], "runtime.operationReference", OPERATION)
        _string(errors, runtime["jobId"], "runtime.jobId")
        _string(errors, runtime["catalogDigest"], "runtime.catalogDigest", SHA)
        if runtime["terminalState"] not in {
            "succeeded", "partial", "failed", "cancelled", "outcomeUnknown"
        }:
            errors.append("runtime.terminalState: invalid enum")
        _date(errors, runtime["startedAt"], "runtime.startedAt")
        _date(errors, runtime["finishedAt"], "runtime.finishedAt")

    confirmation = doc["targetConfirmation"]
    if _object(
        errors, confirmation, "targetConfirmation",
        {"confirmedDeviceIdentitySHA256", "bindingRevision", "confirmedAt", "method"},
        {"confirmedDeviceIdentitySHA256", "bindingRevision", "confirmedAt", "method"},
    ):
        _string(
            errors, confirmation["confirmedDeviceIdentitySHA256"],
            "targetConfirmation.confirmedDeviceIdentitySHA256", SHA,
        )
        if not isinstance(confirmation["bindingRevision"], int) \
                or isinstance(confirmation["bindingRevision"], bool) \
                or confirmation["bindingRevision"] < 1:
            errors.append("targetConfirmation.bindingRevision: expected integer >= 1")
        _date(errors, confirmation["confirmedAt"], "targetConfirmation.confirmedAt")
        if confirmation["method"] not in {"humanPhysical", "machineReadback"}:
            errors.append("targetConfirmation.method: invalid enum")

    device = doc["device"]
    if _object(
        errors, device, "device",
        {"model", "serialSHA256", "firmware", "bindingRevision"},
        {"model", "serialSHA256", "firmware", "bindingRevision"},
    ):
        _string(errors, device["model"], "device.model")
        _string(errors, device["serialSHA256"], "device.serialSHA256", SHA)
        _string(errors, device["firmware"], "device.firmware")
        if not isinstance(device["bindingRevision"], int) \
                or isinstance(device["bindingRevision"], bool) \
                or device["bindingRevision"] < 1:
            errors.append("device.bindingRevision: expected integer >= 1")

    toolchain = doc["toolchain"]
    if _object(
        errors, toolchain, "toolchain",
        {"hdcVersion", "hdcSHA256"}, {"hdcVersion", "hdcSHA256", "otherTools"},
    ):
        _string(errors, toolchain["hdcVersion"], "toolchain.hdcVersion")
        _string(errors, toolchain["hdcSHA256"], "toolchain.hdcSHA256", SHA)

    if doc["transport"] not in {"usb", "tcp", "uart"}:
        errors.append("transport: invalid enum")
    _string(errors, doc["provider"], "provider")
    if doc["effectLevel"] not in {"E0", "E1", "E2"}:
        errors.append("effectLevel: invalid enum")
    _unique_strings(errors, doc["stepKinds"], "stepKinds")
    _unique_strings(errors, doc["acceptanceIds"], "acceptanceIds", ACCEPTANCE_ID)
    _date(errors, doc["executedAt"], "executedAt")
    if "validUntil" in doc:
        _date(errors, doc["validUntil"], "validUntil")

    artifacts = doc["artifacts"]
    if not isinstance(artifacts, list):
        errors.append("artifacts: expected array")
    else:
        for index, artifact in enumerate(artifacts):
            where = f"artifacts[{index}]"
            if _object(
                errors, artifact, where,
                {"reference", "sha256"}, {"reference", "sha256", "note"},
            ):
                _string(errors, artifact["reference"], f"{where}.reference")
                _string(errors, artifact["sha256"], f"{where}.sha256", SHA)

    if executor.get("kind") == "agent":
        expected = {
            "E0": "defaultReadOnlyPolicy",
            "E1": "runtimeCapability",
            "E2": "standingAuthorization",
        }.get(doc["effectLevel"])
        if executor.get("authority", {}).get("kind") != expected:
            errors.append("executor.authority.kind: effect mismatch")
    return errors


def base_vector():
    return {
        "schemaVersion": "3.0.0",
        "evidenceId": "EVD-AHE-VECTOR-001",
        "executor": {
            "kind": "agent",
            "id": "arkdeck-device-runtime-agent",
            "authority": {
                "kind": "defaultReadOnlyPolicy",
                "reference": "default-read-only-policy",
            },
        },
        "runtime": {
            "operationReference": "observe.device@1",
            "jobId": "job-vector",
            "catalogDigest": "c" * 64,
            "terminalState": "succeeded",
            "startedAt": "2026-07-29T00:00:01Z",
            "finishedAt": "2026-07-29T00:00:03Z",
        },
        "targetConfirmation": {
            "confirmedDeviceIdentitySHA256": "b" * 64,
            "bindingRevision": 7,
            "confirmedAt": "2026-07-29T00:00:02Z",
            "method": "machineReadback",
        },
        "device": {
            "model": "DAYU200",
            "serialSHA256": "b" * 64,
            "firmware": "OpenHarmony-4.1-release",
            "bindingRevision": 7,
        },
        "toolchain": {"hdcVersion": "3.2.0f", "hdcSHA256": "a" * 64},
        "transport": "usb",
        "provider": "hdc",
        "effectLevel": "E0",
        "stepKinds": ["probeHostTool", "probeHDCServer", "probeDevice"],
        "acceptanceIds": ["AC-WF-004-01"],
        "executedAt": "2026-07-29T00:00:03Z",
        "artifacts": [{
            "reference": "arkdeck-artifact://job-vector/ART-001",
            "sha256": "d" * 64,
        }],
    }


def self_test():
    cases = []
    e0 = base_vector()
    cases.append(("pos-agent-e0", True, e0))
    for level, kind in (("E1", "runtimeCapability"), ("E2", "standingAuthorization")):
        vector = deepcopy(e0)
        vector["effectLevel"] = level
        vector["executor"]["authority"] = {"kind": kind, "reference": "CAP-RT-001"}
        cases.append((f"pos-agent-{level.lower()}", True, vector))
    human = deepcopy(e0)
    human["executor"] = {"kind": "human", "id": "lvye"}
    human["targetConfirmation"]["method"] = "humanPhysical"
    cases.append(("pos-human", True, human))

    missing_model = deepcopy(e0)
    del missing_model["device"]["model"]
    cases.append(("neg-missing-model", False, missing_model))
    wrong_authority = deepcopy(e0)
    wrong_authority["executor"]["authority"]["kind"] = "runtimeCapability"
    cases.append(("neg-effect-authority", False, wrong_authority))
    no_runtime = deepcopy(e0)
    del no_runtime["runtime"]
    cases.append(("neg-agent-no-runtime", False, no_runtime))
    raw_serial = deepcopy(e0)
    raw_serial["device"]["serialSHA256"] = "150100424A544E4600"
    cases.append(("neg-raw-serial", False, raw_serial))
    duplicate_steps = deepcopy(e0)
    duplicate_steps["stepKinds"].append("probeDevice")
    cases.append(("neg-duplicate-step", False, duplicate_steps))
    extra = deepcopy(e0)
    extra["schemaValid"] = True
    cases.append(("neg-caller-schema-valid", False, extra))

    ok = True
    for name, expected, vector in cases:
        errors = validate(vector)
        accepted = not errors
        matched = accepted == expected
        ok = ok and matched
        print(
            f"{'PASS' if matched else 'FAIL'} {name}: "
            f"{'accept' if accepted else 'reject'}"
        )
        if not matched:
            for error in errors:
                print(f"  {error}")
    print(f"AHE-SCHEMA-V3:{'PASS' if ok else 'FAIL'} ({len(cases)} vectors)")
    return 0 if ok else 1


def assert_schema_shape():
    schema = json.loads(
        Path("openspec/contracts/hardware-evidence.schema.json").read_text(encoding="utf-8")
    )
    assert schema["$id"] == "arkdeck://contracts/hardware-evidence/3.0.0"
    assert set(schema["required"]) == TOP_REQUIRED
    assert schema["properties"]["device"]["required"] == [
        "model", "serialSHA256", "firmware", "bindingRevision"
    ]
    assert schema["properties"]["effectLevel"]["enum"] == ["E0", "E1", "E2"]


def main(argv):
    assert_schema_shape()
    if len(argv) == 1:
        return self_test()
    if len(argv) == 2:
        errors = validate(json.loads(Path(argv[1]).read_text(encoding="utf-8")))
        for error in errors:
            print(f"reject: {error}")
        return 1 if errors else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
