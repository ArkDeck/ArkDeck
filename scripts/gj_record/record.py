"""Assemble the redacted `arkdeck.gj-headless-rerun/1` record.

The record holds the facts the headless runbook §7 names, each copied from a
Runtime answer (never typed), and per Journey the criteria that were applied,
whether each held and which captured output it was read from.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from . import catalog, journeys, redact
from .criteria import NOT_STARTED, Judge
from .run import RefusedInput, Run, Step

SCHEMA = "arkdeck.gj-headless-rerun/1"
EVIDENCE_KIND = "redacted-metadata-derived-from-real-runtime"
RUNBOOK = "docs/design/cli-golden-journey-headless-runbook.md"
GENERATOR = "scripts/gj_record"
JOURNEYS = ("GJ-1", "GJ-2", "GJ-3", "GJ-4", "GJ-5")
# The GJ-3 rollback fixture the macOS rounds published and pinned
# (`libarkdeck_gj-rollback-ghost.signed.so`, an armeabi-v7a library whose
# DT_NEEDED cannot resolve; TASK-XPA-003 run.md). Another fixture is a reviewed
# change here, never a value typed at assembly.
ROLLBACK_FIXTURE_SHA256 = "260a533ae2b02e23810aa5ab6ea9c1a5cf4524b19484ede66cb4dc0b7bb86d3a"
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_SAFE_RAW = re.compile(r"^[A-Za-z0-9._:@+\- ]{0,120}$")


class AssemblyError(Exception):
    pass


def _one(run: Run, command: str, what: str) -> Step:
    step = run.last(command, lambda s: s.ok)
    if step is None:
        raise AssemblyError(f"no successful `{what}` was captured; it is a fixed fact of every record")
    return step


def fixed_facts(run: Run, expected: catalog.Catalog) -> dict:
    version = _one(run, "version", "arkdeck --version --output json")
    cli = run.steps[0].entry["cliExecutableSHA256"]
    if version.result.get("buildIdentity") != f"sha256:{cli}":
        raise AssemblyError("`--version` names a different CLI image than the one the journal ran")
    health = _one(run, "runtime.health", "runtime health --output json")
    if health.result.get("catalogDigest") != expected.digest:
        raise AssemblyError("the Runtime's health names a different Catalog digest")
    listed = _one(run, "operation.list", "operation list --output json")
    canonical = sorted(
        item.get("canonicalReference") or item.get("reference")
        for item in listed.items
        if item.get("aliasFor") is None
    )
    if tuple(canonical) != expected.operations:
        raise AssemblyError("`operation list` is not the expected Catalog's canonical operation set")
    service = _one(run, "runtime.service.status", "runtime service status --output json")
    windows = service.result.get("daemonService")
    if isinstance(windows, dict):
        daemon = service.entry.get("daemonImageSHA256")
    else:
        daemon = (service.result.get("launchAgent") or {}).get("daemonSHA256")
    if not isinstance(daemon, str):
        raise AssemblyError("the installed daemon image could not be hashed when its status was read")
    hdc = _one(run, "runtime.hdc.status", "runtime hdc status --output json").result
    if hdc.get("availability") != "available" or not hdc.get("executableSHA256"):
        raise AssemblyError("`runtime hdc status` does not show an available registered HDC")
    if hdc.get("executableSHA256") != hdc.get("configuredExecutableSHA256"):
        raise AssemblyError("the HDC in use is not the configured one")
    return {
        "cliBuildIdentity": version.result["buildIdentity"],
        "runtimeExecutableSHA256": daemon,
        "hdcExecutableSHA256": hdc["executableSHA256"],
        "hdcVersion": hdc.get("clientVersion"),
        "operations": listed.items,
        "host": run.steps[0].entry.get("host") or {},
    }


def _refuse_foreign_hdc(run: Run, hdc: str) -> None:
    """A Job observed through any other HDC (a fake or fixture tool among
    them) is never real-device evidence."""
    for step in run.steps:
        for observation in _observations(step):
            evidence = step.result if step.command == "job.evidence" else step.result.get("evidence") or {}
            if observation.get("providerId") == "arkforge" or evidence.get("providerId") == "arkforge":
                # The published flash provider reports its own tool, not HDC.
                # Keep this restricted to its exact operation and original
                # provider/target provenance; Runtime still owns bundle,
                # Campaign and capability verification.
                tool = observation.get("toolSha256")
                if not (evidence.get("operationReference") == "flash.full-restore@1"
                        and evidence.get("actualEffect") == "destructive"
                        and evidence.get("providerId") == observation.get("providerId") == "arkforge"
                        and isinstance(tool, str) and re.fullmatch(r"[0-9a-f]{64}", tool)
                        and isinstance(observation.get("toolVersion"), str) and bool(observation["toolVersion"])
                        and isinstance(evidence.get("targetId"), str) and bool(evidence["targetId"])
                        and observation.get("targetId") == evidence.get("targetId")
                        and type(observation.get("bindingRevision")) is int
                        and observation["bindingRevision"] == evidence.get("bindingRevision")):
                    raise RefusedInput(f"{step.file}: flash observation has inconsistent ArkForge provenance")
                continue
            tool = observation.get("toolSha256")
            if tool is not None and tool != hdc:
                raise RefusedInput(f"{step.file}: a Job was observed through HDC {tool}, not {hdc}")


def _observations(step: Step):
    evidence = step.result.get("evidence")
    if isinstance(evidence, dict) and isinstance(evidence.get("observation"), dict):
        yield evidence["observation"]
    if step.command == "job.evidence" and isinstance(step.result.get("observation"), dict):
        yield step.result["observation"]


def _raw(value):
    if value is None or isinstance(value, (bool, int)):
        return value
    if isinstance(value, str) and _SAFE_RAW.match(value):
        return value
    if isinstance(value, list) and all(isinstance(v, (bool, int)) or (isinstance(v, str) and _SAFE_RAW.match(v)) for v in value):
        return value
    return "withheld (not a plain identifier, state or count)"


def _job_row(run: Run, job: str, execution: str | None) -> dict | None:
    step = run.job_result(job)
    if step is None:
        return None
    evidence = step.result.get("evidence") or {}
    record = step.result.get("job") or {}
    actions = []
    # A human action belongs to the execution, raised before its Job exists.
    for execution_step in run.execution(execution) if execution else []:
        action = journeys.human_action(execution_step)
        if action and action.get("actionId") not in [a["actionId"] for a in actions]:
            actions.append({"actionId": action.get("actionId"), "category": action.get("category")})
    for action in actions:
        shown = run.last("human-action.show", lambda s, a=action: s.ok and s.result.get("actionId") == a["actionId"])
        action["status"] = shown.result.get("status") if shown else None
    return {
        "jobID": job,
        "operationReference": evidence.get("operationReference"),
        "terminalState": evidence.get("terminalState"),
        "outcomeUnknown": evidence.get("outcomeUnknown"),
        "evidenceBlockers": [_raw(b) for b in evidence.get("blockers") or []],
        "humanActions": actions,
        "artifactCount": len(step.result.get("artifacts") or []),
        "startedAtUTC": evidence.get("startedAtUtc"),
        "finishedAtUTC": evidence.get("finishedAtUtc"),
        "actualEffect": evidence.get("actualEffect"),
        "actualStepKinds": evidence.get("actualStepKinds"),
        "outstandingResidueCount": record.get("outstandingResidueCount"),
        "targetID": evidence.get("targetId"),
        "bindingRevision": evidence.get("bindingRevision"),
    }


def _journey(name: str, run: Run, date: str, facts: dict, revision: str, digest: str) -> dict:
    judge = Judge(run)
    context = journeys.Context(run, judge, date)
    if name == "GJ-1":
        journeys.gj1(context)
    elif name == "GJ-2":
        journeys.gj2(context)
    elif name == "GJ-3":
        journeys.gj3(context, ROLLBACK_FIXTURE_SHA256)
    elif name == "GJ-4":
        journeys.gj4(context)
    else:
        journeys.gj5(context)
    started = bool(context.executions)
    state, failing = judge.state()
    if not started:
        state, failing = NOT_STARTED, None
    rows = [row for row in (_job_row(run, job, context.job_execution.get(job)) for job in context.jobs) if row]
    targets = sorted({r["targetID"] for r in rows if r["targetID"]})
    revisions = sorted({r["bindingRevision"] for r in rows if r["bindingRevision"] is not None})
    document = {
        "date": date,
        "goldenJourney": name,
        "state": state,
        "evidenceKind": EVIDENCE_KIND,
        "catalogDigest": digest,
        "runtimeSourceRevision": revision,
        "runtimeExecutableSHA256": facts["runtimeExecutableSHA256"],
        "cliBuildIdentity": facts["cliBuildIdentity"],
        "hdcExecutableSHA256": facts["hdcExecutableSHA256"],
        "hdcVersion": facts["hdcVersion"],
        "targetID": targets[0] if len(targets) == 1 else targets,
        "bindingRevision": revisions[0] if len(revisions) == 1 else revisions,
        "executionIDs": context.executions,
        "jobs": rows,
        "zeroDispatchChecks": [
            c.document() for c in judge.checks if "newDispatchCount" in c.criterion or "Job count" in c.criterion or "Job set" in c.criterion
        ],
        "criteria": [c.document() for c in judge.checks],
        "notes": "",
    }
    if name == "GJ-4" and context.flash_image is not None:
        document["flashImage"] = context.flash_image
    if failing:
        document["firstFailingCriterion"] = {
            "criterion": failing["criterion"],
            "raw": _raw(failing["raw"]),
            "sources": failing["sources"],
        }
    return document


def _coverage(run: Run, facts: dict, digest: str) -> dict:
    passed: dict[str, list[str]] = {}
    for step in run.of("job.result", lambda s: s.ok):
        evidence = step.result.get("evidence") or {}
        if (
            evidence.get("terminalState") == "succeeded"
            and evidence.get("outcomeUnknown") is False
            and evidence.get("catalogDigest") == digest
            and evidence.get("executionMode") == "execute"
        ):
            jobs = passed.setdefault(evidence.get("operationReference"), [])
            job = evidence.get("jobId")
            if job not in jobs:
                jobs.append(job)
    operations = []
    for item in sorted(facts["operations"], key=lambda i: i.get("reference", "")):
        if item.get("aliasFor") is not None:
            continue
        reference = item.get("canonicalReference") or item.get("reference")
        jobs = passed.get(reference, [])
        row = {
            "operationReference": reference,
            "state": "realDevicePass" if jobs else "notExercised",
            "jobIDs": jobs,
            "availability": item.get("availability"),
        }
        if item.get("availability") != "available":
            row["reasonCodes"] = [_raw(code) for code in item.get("reasonCodes") or []]
        operations.append(row)
    return {
        "catalogDigest": digest,
        "canonicalOperationCount": len(operations),
        "realDevicePass": sum(1 for o in operations if o["state"] == "realDevicePass"),
        "operations": operations,
    }


def assemble(
    out: Path,
    *,
    date: str,
    runtime_source_revision: str,
    protected_main: str,
    repository: Path,
    names: list[str],
) -> dict:
    if not _DATE.match(date):
        raise AssemblyError("--date must be YYYY-MM-DD")
    try:
        built = catalog.at_revision(repository, runtime_source_revision)
        if not catalog.on_protected_main(repository, built.revision, protected_main):
            raise AssemblyError(f"{built.revision} is not on {protected_main}; only a protected-main build is evidence")
        current = catalog.at_revision(repository, protected_main)
        if current.digest != built.digest:
            raise AssemblyError(
                f"the Runtime was built on Catalog {built.digest}, but {protected_main} now publishes "
                f"{current.digest}; its results are stale"
            )
        run = Run.load(out)
        run.refuse_non_evidence(built.digest)
        facts = fixed_facts(run, built)
        _refuse_foreign_hdc(run, facts["hdcExecutableSHA256"])
    except (catalog.CatalogError, RefusedInput) as error:
        raise AssemblyError(str(error)) from error
    document = {
        "schemaVersion": SCHEMA,
        "date": date,
        "catalogDigest": built.digest,
        "runbook": RUNBOOK,
        "generator": GENERATOR,
        "host": {"system": facts["host"].get("system"), "osBuild": facts["host"].get("version")},
        "journeys": [_journey(name, run, date, facts, built.revision, built.digest) for name in names],
        "operationRealDeviceCoverage": _coverage(run, facts, built.digest),
    }
    try:
        redact.check(render(document), redact.sensitive_literals(run))
    except redact.RedactionError as error:
        raise AssemblyError(str(error)) from error
    return document


def render(document: dict) -> str:
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


def write(path: Path, document: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(render(document), encoding="utf-8", newline="\n")
