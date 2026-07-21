#!/usr/bin/env python3
"""Validate the closed negative R2 decision without opening controlled raw."""

from __future__ import annotations

import json
import pathlib
import re


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_DIR.parents[5]
DECISION_PATH = (
    REPOSITORY_ROOT
    / "openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/decisions"
    / "r2-element-tree-v1.json"
)
SHA256 = re.compile(r"[0-9a-f]{64}")
GIT_OID = re.compile(r"[0-9a-f]{40}")


def require_keys(value: object, expected: set[str], location: str) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != expected:
        raise AssertionError(f"closed-key mismatch at {location}")
    return value


decision = json.loads(DECISION_PATH.read_text(encoding="utf-8"))
require_keys(
    decision,
    {
        "schema",
        "decisionId",
        "change",
        "task",
        "result",
        "recordedAt",
        "authority",
        "provenance",
        "redaction",
        "classification",
        "selection",
        "privacy",
        "consequences",
    },
    "$",
)
require_keys(decision["authority"], {"decisionMaker", "attestation"}, "$.authority")
provenance = require_keys(
    decision["provenance"],
    {
        "phaseACaptureEvidenceId",
        "phaseACaptureMergeOid",
        "phaseAStatusMergeOid",
        "commandId",
        "recipeId",
        "exactArgvTemplate",
        "targetTuple",
        "rawOrigin",
    },
    "$.provenance",
)
require_keys(
    provenance["targetTuple"],
    {"device", "firmware", "api", "hdcVersion", "hdcSha256", "transport"},
    "$.provenance.targetTuple",
)
raw_origin = require_keys(
    provenance["rawOrigin"],
    {
        "kind",
        "captureSequence",
        "sha256",
        "size",
        "complete",
        "truncated",
        "drainIncomplete",
        "controlledPathRecorded",
        "repositoryBytes",
    },
    "$.provenance.rawOrigin",
)
redaction = require_keys(
    decision["redaction"],
    {
        "algorithmId",
        "algorithmVersion",
        "sourceSha256",
        "manifestSha256",
        "safeLiteralsSha256",
        "receiptSchemaSha256",
        "result",
    },
    "$.redaction",
)
redaction_result = require_keys(
    redaction["result"],
    {
        "classification",
        "errorName",
        "exitCode",
        "derivedCreated",
        "receiptCreated",
        "derivedSha256",
        "receiptSha256",
    },
    "$.redaction.result",
)
classification = require_keys(
    decision["classification"],
    {
        "successStructuralFamilyRegistered",
        "successStructuralFamily",
        "positiveDerivedFixtureRegistered",
        "failurePrecedence",
        "otherwise",
        "exitCodeZeroIsSuccess",
        "digestOnlySuccess",
    },
    "$.classification",
)
failure = classification["failurePrecedence"]
if not isinstance(failure, list) or len(failure) != 1:
    raise AssertionError("failure precedence must contain exactly one rule")
require_keys(
    failure[0],
    {"priority", "classification", "condition", "exitCodeIndependent"},
    "$.classification.failurePrecedence[0]",
)
require_keys(
    decision["selection"],
    {
        "locatorRegistered",
        "locator",
        "candidateCardinality",
        "candidateFormat",
        "sameSessionSelectionRequirementPreserved",
        "phaseAExactTokenRecorded",
        "phaseAExactTokenReusable",
    },
    "$.selection",
)
require_keys(
    decision["privacy"],
    {
        "agentRawReadCount",
        "rawRepositoryBytes",
        "derivedRepositoryBytes",
        "exactComponentTokenRepositoryCount",
        "nonceRepositoryCount",
        "controlledRawPathRepositoryCount",
        "conversationPathDisclosureDeviationRecorded",
    },
    "$.privacy",
)
require_keys(
    decision["consequences"],
    {
        "taskClosure",
        "r2R4Seam",
        "r4Capture",
        "recipeSuccessClaim",
        "canonicalAcceptanceClaim",
        "compatibilitySupportConformanceReleaseClaim",
    },
    "$.consequences",
)

assert decision["schema"] == "arkdeck-ui-dump-r2-output-family-decision-1.0.0"
assert decision["decisionId"] == "r2-element-tree-v1"
assert decision["result"] == "negative"
assert provenance["exactArgvTemplate"] == [
    "<PINNED_HDC>",
    "-t",
    "<SAME_SESSION_CONNECT_KEY>",
    "shell",
    "hidumper",
    "-s",
    "WindowManagerService",
    "-a",
    "-w <ASCII_DECIMAL_WINDOW_ID> -element -c",
]
assert raw_origin == {
    "kind": "remoteSidecar",
    "captureSequence": 16,
    "sha256": "ec6663e6b7d42053ba089ccbfa89df74cb183a5a583f80a69f103b047014b077",
    "size": 866256,
    "complete": True,
    "truncated": False,
    "drainIncomplete": False,
    "controlledPathRecorded": False,
    "repositoryBytes": 0,
}
assert redaction_result == {
    "classification": "stableFailure",
    "errorName": "INVALID_UNICODE",
    "exitCode": 27,
    "derivedCreated": False,
    "receiptCreated": False,
    "derivedSha256": None,
    "receiptSha256": None,
}
assert classification["successStructuralFamilyRegistered"] is False
assert classification["successStructuralFamily"] is None
assert classification["positiveDerivedFixtureRegistered"] is False
assert classification["otherwise"] == "unknownOutput"
assert classification["exitCodeZeroIsSuccess"] is False
assert classification["digestOnlySuccess"] is False
assert decision["selection"] == {
    "locatorRegistered": False,
    "locator": None,
    "candidateCardinality": "notEvaluated",
    "candidateFormat": None,
    "sameSessionSelectionRequirementPreserved": True,
    "phaseAExactTokenRecorded": False,
    "phaseAExactTokenReusable": False,
}
assert decision["privacy"] == {
    "agentRawReadCount": 0,
    "rawRepositoryBytes": 0,
    "derivedRepositoryBytes": 0,
    "exactComponentTokenRepositoryCount": 0,
    "nonceRepositoryCount": 0,
    "controlledRawPathRepositoryCount": 0,
    "conversationPathDisclosureDeviationRecorded": True,
}
assert decision["consequences"]["r2R4Seam"] == "blocked"
assert decision["consequences"]["r4Capture"] == "blocked"
assert all(
    isinstance(value, str) and GIT_OID.fullmatch(value)
    for value in (
        provenance["phaseACaptureMergeOid"],
        provenance["phaseAStatusMergeOid"],
    )
)
assert all(
    isinstance(value, str) and SHA256.fullmatch(value)
    for value in (
        provenance["targetTuple"]["hdcSha256"],
        raw_origin["sha256"],
        redaction["sourceSha256"],
        redaction["manifestSha256"],
        redaction["safeLiteralsSha256"],
        redaction["receiptSchemaSha256"],
    )
)

serialized = DECISION_PATH.read_bytes()
for forbidden in (b"/Users/", b"/home/", b"/private/tmp/", b"PRIVATE KEY"):
    if forbidden in serialized:
        raise AssertionError("repository-sensitive literal found")

print("closed decision validation: PASS")
print("controlled raw reads: 0")
