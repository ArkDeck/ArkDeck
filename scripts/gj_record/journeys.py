"""Each Journey's criteria, as the headless runbook states them, applied to
the Runtime's own answers.

Executions are found by the IDs the runbook gives them, with `<d>` the record
date without dashes (`gj1-20261005`):

| Journey | Execution IDs |
| --- | --- |
| GJ-1 | `gj1-<d>` (observe), `gj1-<d>-capture`, `gj1-<d>-har` |
| GJ-2 | `gj2-<d>` (debug.hap), `gj2-<d>-capture` (app-scoped HiLog, UI Dump, Trace) |
| GJ-3 | `gj3-<d>` (deploy), `gj3-<d>-rollback` (the rollback fixture) |
| GJ-4 | `gj4-<d>` (full restore), `gj4-<d>-postflight` (observe) |
| GJ-5 | `gj5-<d>-baseline`, `-repro`, `-repro-capture`, `-analyze`, `-isolate`, `-patch`, `-build`, `-sign`, `-verify`, `-verify-capture`, `-negative` |

Where the Rust Runtime publishes a fact through a different operation than
the runbook's prose assumes (the `debug.hap@1` Job publishes no UI Dump,
Trace, liveness or crash index), the criterion is read from the
`capture.diagnostics@1` execution the table names, as the 2026-09-09 macOS
round composed it. A criterion is never dropped for that.
"""

from __future__ import annotations

import json
import re

from .criteria import Judge
from .run import Run, Step

_VERIFIED = re.compile(r"^verified (\S+) (\[.*\])$")
_DISPATCHED = re.compile(r"^dispatched (\S+); awaiting readback$")
FLASH_STEP_KINDS = (
    "waitForReconnect",
    "probeDevice",
    "flashPartition",
    "verifyRemoteState",
    "rebootDevice",
    "captureRemoteStdout",
)


class Context:
    """What a Journey shares with the record: its Jobs and executions."""

    def __init__(self, run: Run, judge: Judge, date: str):
        self.run = run
        self.judge = judge
        self.compact = date.replace("-", "")
        self.jobs: list[str] = []
        self.job_execution: dict[str, str] = {}
        self.executions: list[str] = []

    def execution_id(self, prefix: str, suffix: str = "") -> str:
        return f"{prefix}-{self.compact}" + (f"-{suffix}" if suffix else "")

    # -- executions ---------------------------------------------------------

    def settled(self, execution: str, operation: str, *, completed: bool = True) -> tuple[str | None, Step | None]:
        """The execution's Job once it settled; `completed` asks that it
        completed (a Job that succeeded)."""
        steps = self.run.execution(execution)
        if not steps:
            self.judge.missing(f"{execution}: execution", f"agent run --execution-id {execution}")
            return None, None
        if execution not in self.executions:
            self.executions.append(execution)
        answered = [s for s in steps if s.ok]
        if not answered:
            last = steps[-1]
            self.judge.that(
                f"{execution}: execution answered",
                False,
                last.error.get("code"),
                last,
            )
            return None, None
        last = answered[-1]
        self.judge.expect(f"{execution}: operation", last.result.get("operation"), operation, last)
        if completed:
            self.judge.expect(f"{execution}: execution state", last.result.get("state"), "completed", last)
        job = last.result.get("jobId")
        if not isinstance(job, str):
            self.judge.that(f"{execution}: a Job", False, job, last)
            return None, last
        if job not in self.jobs:
            self.jobs.append(job)
            self.job_execution[job] = execution
        return job, last

    # -- Jobs ----------------------------------------------------------------

    def job(
        self,
        job: str,
        label: str,
        *,
        terminal: str = "succeeded",
        required: tuple[str, ...] = (),
        non_empty: tuple[str, ...] = (),
        count: int | None = None,
    ) -> tuple[Step | None, dict[str, bytes]]:
        """`job result` for the Job: its terminal state, no unknown, no
        blocker, no residue, and every Artifact read back whole and matching
        its published digest."""
        judge = self.judge
        step = self.run.job_result(job)
        if step is None:
            judge.missing(f"{label}: job result", f"job result --job {job}")
            return None, {}
        evidence = step.result.get("evidence") or {}
        record = step.result.get("job") or {}
        judge.expect(f"{label}: terminalState", evidence.get("terminalState"), terminal, step)
        judge.expect(f"{label}: outcomeUnknown", evidence.get("outcomeUnknown"), False, step)
        if terminal == "succeeded":
            judge.expect(f"{label}: blockers", evidence.get("blockers"), [], step)
            judge.expect(
                f"{label}: missingRequiredArtifacts", evidence.get("missingRequiredArtifacts"), [], step
            )
        judge.expect(f"{label}: outstandingResidueCount", record.get("outstandingResidueCount"), 0, step)
        artifacts = step.result.get("artifacts") or []
        if count is not None:
            judge.expect(f"{label}: Artifact count", len(artifacts), count, step)
        names = [a.get("name") for a in artifacts]
        for name in required:
            judge.that(f"{label}: Artifact {name} published", name in names, sorted(map(str, names)), step)
        contents: dict[str, bytes] = {}
        reads = self.run.of("artifact.read", lambda s: s.option("--job") == job)
        for artifact in artifacts:
            name = artifact.get("name")
            identifier = artifact.get("artifactId")
            judge.expect(f"{label}: {name} bytesVerified", artifact.get("bytesVerified"), True, step)
            data = self.run.artifact_bytes(identifier) if isinstance(identifier, str) else None
            if data is None and not any(s.result.get("artifactId") == identifier for s in reads):
                judge.missing(f"{label}: {name} read", f"artifact read --job {job} --artifact {identifier}")
                continue
            judge.that(f"{label}: {name} read whole and digest-checked", data is not None, None, *reads)
            if data is not None:
                contents[name] = data
        for name in non_empty:
            if name in contents:
                judge.that(f"{label}: {name} not empty", len(contents[name]) > 0, len(contents[name]), step)
        return step, contents

    def timeline(self, job: str, label: str) -> list[str] | None:
        show = self.run.last("job.show", lambda s: s.ok and (s.result.get("job") or {}).get("jobId") == job)
        if show is None:
            self.judge.missing(f"{label}: timeline", f"job show --job {job}")
            return None
        timeline = show.result.get("timeline") or {}
        if timeline.get("kind") != "snapshotPages":
            return [str(entry) for entry in timeline.get("entries") or []]
        pages = self.run.of("job.timeline", lambda s: s.ok and s.option("--job") == job)
        parts: dict[int, list[tuple[int, str]]] = {}
        for page in pages:
            for item in page.items:
                parts.setdefault(int(item["entryIndex"]), []).append((int(item["partIndex"]), item["text"]))
        if not pages or (pages[-1].result.get("hasMore") is not False):
            self.judge.missing(f"{label}: timeline", f"job timeline --job {job} (every page)")
            return None
        return ["".join(text for _, text in sorted(parts[index])) for index in sorted(parts)]

    def verified(self, entries: list[str], step_id: str, label: str, keys: tuple[str, ...] = ()) -> None:
        found = None
        for entry in entries:
            match = _VERIFIED.match(entry)
            if match and match.group(1) == step_id:
                found = json.loads(match.group(2))
        self.judge.that(f"{label}: {step_id} verified", found is not None, found)
        for key in keys:
            if found is not None:
                self.judge.that(f"{label}: {step_id} reports {key}", key in found, found)

    def dispatched(self, entries: list[str], step_id: str, label: str) -> None:
        holds = any((m := _DISPATCHED.match(e)) and m.group(1) == step_id for e in entries)
        self.judge.that(f"{label}: {step_id} dispatched and read back", holds, None)

    def document(self, contents: dict[str, bytes], name: str, label: str) -> dict | None:
        if name not in contents:
            return None
        try:
            value = json.loads(contents[name])
        except ValueError:
            self.judge.that(f"{label}: {name} is JSON", False, None)
            return None
        return value if isinstance(value, dict) else None

    def capture_complete(self, contents: dict[str, bytes], label: str) -> None:
        summary = self.document(contents, "capture-summary.json", label)
        if summary is None:
            return
        self.judge.expect(f"{label}: capture completeness", summary.get("completeness"), "complete")
        self.judge.expect(f"{label}: capture missingRequired", summary.get("missingRequired"), [])


def crash_entries(text: bytes) -> int | None:
    """The fault-log ledger's entry count (`hidumper -s 1201 -a "-p
    Faultlogger -l"`), as `arkdeck-hoststore/src/crash_ledger.rs` reads it."""
    try:
        lines = text.decode("utf-8").splitlines()
    except UnicodeDecodeError:
        return None
    if any(line.strip() == "No fault log exist." for line in lines):
        return 0
    if not any(line.strip().startswith("Fault log list:") for line in lines):
        return None
    fences = [i for i, line in enumerate(lines) if line.strip().startswith("******")]
    if len(fences) < 2:
        return None
    return sum(1 for line in lines[fences[0] + 1 : fences[-1]] if line.strip() and not line.strip().startswith("******"))


# -- GJ-1 ---------------------------------------------------------------------


def gj1(context: Context) -> None:
    run, judge = context.run, context.judge
    observe_id = context.execution_id("gj1")
    observe, observed = context.settled(observe_id, "observe.device@1")
    if observe:
        context.job(
            observe,
            observe_id,
            required=("device-facts.json", "tool-facts.json", "binding-snapshot.json"),
            count=3,
        )
        verify = run.last("runtime.service.verify", lambda s: s.option("--job") == observe)
        if verify is None:
            judge.missing(f"{observe_id}: service verify", f"runtime service verify --job {observe}")
        else:
            judge.expect(f"{observe_id}: runtime service verify reads it back", verify.ok, True, verify)

    capture_id = context.execution_id("gj1", "capture")
    capture, _ = context.settled(capture_id, "capture.diagnostics@1")
    if capture:
        _, contents = context.job(
            capture,
            capture_id,
            required=("hilog.txt", "ui-dump.json", "capture-summary.json"),
            non_empty=("hilog.txt", "ui-dump.json"),
        )
        context.capture_complete(contents, capture_id)

    restart = run.last("runtime.service.restart", lambda s: s.ok)
    if restart is None:
        judge.missing("restart: runtime service restart", "runtime service restart")
    else:
        for job in (observe, capture):
            if not job:
                continue
            for command in ("job.show", "job.result"):
                after = run.last(
                    command,
                    lambda s, job=job: s.ok
                    and s.sequence > restart.sequence
                    and (s.result.get("job") or {}).get("jobId") == job,
                )
                if after is None:
                    judge.missing(f"restart: {command} {job}", f"{command.replace('.', ' ')} --job {job} after the restart")
                else:
                    judge.that(f"restart: {command} reads {job} after the restart", True, None, restart, after)

    _har(context, observed)


def _har(context: Context, observed: Step | None) -> None:
    run, judge = context.run, context.judge
    execution = context.execution_id("gj1", "har")
    steps = run.execution(execution)
    started = next((s for s in steps if s.command == "agent.run"), None)
    if started is None:
        judge.missing(f"{execution}: execution", f"agent run --execution-id {execution} without --target")
        return
    context.executions.append(execution)
    label = execution
    judge.that(f"{label}: started without --target", not started.has_flag("--target"), None, started)
    judge.expect(f"{label}: exit code", started.exit_code, 75, started)
    judge.expect(f"{label}: error code", started.error.get("code"), "humanActionRequired", started)
    held = ((started.error.get("details") or {}).get("execution") or {})
    action = held.get("humanAction") or {}
    judge.expect(f"{label}: newDispatchCount", action.get("newDispatchCount"), 0, started)
    judge.expect(f"{label}: execution state", held.get("state"), "waitingForHuman", started)
    action_id = action.get("actionId")

    status = next(
        (
            s
            for s in steps
            if s.command == "agent.status" and s.ok and s.sequence > started.sequence
            and (s.result.get("humanAction") or {}).get("status") == "waiting"
        ),
        None,
    )
    if status is None:
        judge.missing(f"{label}: agent status while waiting", f"agent status --execution-id {execution}")
        return
    reference = (status.result.get("nextAction") or {}).get("resumeReference")
    judge.that(f"{label}: agent status names the resumeReference", isinstance(reference, str), reference, status)
    action_id = (status.result.get("humanAction") or {}).get("actionId") or action_id
    show = run.last(
        "human-action.show",
        lambda s: s.ok and s.sequence > status.sequence and s.sequence < _first_resume(steps, status)
        and s.result.get("actionId") == action_id,
    )
    if show is None:
        judge.missing(f"{label}: human-action show", f"human-action show --human-action {action_id}")
    else:
        judge.expect(f"{label}: human-action show resumeReference", show.result.get("resumeReference"), reference, show)
    resumes = [s for s in steps if s.command == "agent.resume"]
    if not resumes:
        judge.missing(f"{label}: agent resume", "agent resume --resume-reference <ref>")
        return
    judge.expect(f"{label}: first resume consumes it", resumes[0].option("--resume-reference"), reference, resumes[0])
    job, settled = context.settled(execution, "observe.device@1")
    resolved = run.last(
        "human-action.show",
        lambda s: s.ok and s.sequence > resumes[0].sequence and s.result.get("actionId") == action_id,
    )
    if resolved is None:
        judge.missing(f"{label}: the action after resume", f"human-action show --human-action {action_id}")
    else:
        judge.expect(f"{label}: action status after resume", resolved.result.get("status"), "resolvedByFreshProbe", resolved)
    if job:
        step, _ = context.job(job, label)
        if step is not None and observed is not None:
            evidence = step.result.get("evidence") or {}
            judge.expect(f"{label}: same Target", evidence.get("targetId"), observed.result.get("targetId"), step, observed)
            judge.expect(
                f"{label}: same binding revision (no rebind on replug)",
                evidence.get("bindingRevision"),
                observed.result.get("bindingRevision"),
                step,
                observed,
            )
    target = (observed.result.get("targetId") if observed else None)
    shows = run.of("target.show", lambda s: s.ok and s.result.get("targetId") == target)
    after = [s for s in shows if s.sequence > started.sequence]
    if not shows or not after:
        judge.missing(f"{label}: target show before and after the replug", f"target show --target {target}")
    else:
        identities = {s.result.get("stablePhysicalIdentitySha256") for s in shows}
        revisions = {s.result.get("bindingRevision") for s in shows}
        judge.that(f"{label}: stable identity unchanged across the replug", len(identities) == 1, len(identities), *shows)
        judge.that(f"{label}: binding revision unchanged across the replug", len(revisions) == 1, sorted(revisions), *shows)


def human_action(step: Step) -> dict | None:
    """The human action an execution answer carries: in `result` when the
    command succeeded, in `error.details.execution` when it exited 75."""
    if step.ok:
        action = step.result.get("humanAction")
    else:
        action = ((step.error.get("details") or {}).get("execution") or {}).get("humanAction")
    return action if isinstance(action, dict) else None


def _first_resume(steps: list[Step], after: Step) -> int:
    for step in steps:
        if step.command == "agent.resume" and step.sequence > after.sequence:
            return step.sequence
    return 1 << 30


# -- GJ-2 ---------------------------------------------------------------------


def gj2(context: Context) -> None:
    execution = context.execution_id("gj2")
    job, _ = context.settled(execution, "debug.hap@1")
    if job:
        context.job(job, execution, required=("install-readback.json", "process-readback.json"))
        entries = context.timeline(job, execution)
        if entries is not None:
            context.verified(entries, "send-hap", execution, ("stagedAt",))
            context.dispatched(entries, "install-hap", execution)
            context.verified(entries, "package-readback", execution, ("deployedArtifactSha256", "installed"))
            context.dispatched(entries, "start-ability", execution)
            context.verified(entries, "process-readback", execution, ("running",))
            context.verified(entries, "stop-ability", execution, ("stopped",))
            context.verified(entries, "cleanup-remote-staging", execution, ("cleaned",))
    capture_id = context.execution_id("gj2", "capture")
    capture, _ = context.settled(capture_id, "capture.diagnostics@1")
    if capture:
        _, contents = context.job(
            capture,
            capture_id,
            required=("hilog.txt", "ui-dump.json", "trace.htrace", "capture-summary.json"),
            non_empty=("hilog.txt", "ui-dump.json", "trace.htrace"),
        )
        context.capture_complete(contents, capture_id)


# -- GJ-3 ---------------------------------------------------------------------


def gj3(context: Context, fixture_sha256: str) -> None:
    judge = context.judge
    execution = context.execution_id("gj3")
    job, _ = context.settled(execution, "deploy.native-library.app-owned@1")
    report = None
    forward = None
    if job:
        forward, contents = context.job(job, execution, required=("publish-report.json", "verification-report.json"))
        entries = context.timeline(job, execution)
        if entries is not None:
            for host_step in ("verify-elf-locally", "hash-library"):
                judge.that(
                    f"{execution}: {host_step} checked ABI, build ID and hash",
                    any(e.startswith(f"{host_step} abi=") and " buildId=" in e and " sha256=" in e for e in entries),
                    None,
                )
            context.dispatched(entries, "send-to-staging", execution)
            context.verified(entries, "verify-remote-staging", execution, ("remoteSha256",))
            context.verified(entries, "backup-current-version", execution, ("backupSha256",))
            context.verified(entries, "atomic-publish", execution, ("publishedSha256",))
            context.verified(entries, "restart-target", execution, ("stopped",))
            context.verified(entries, "start-target", execution, ("started",))
            context.verified(entries, "verify-loaded-library", execution, ("loaderVerified",))
        report = context.document(contents, "verification-report.json", execution)
        if report is not None:
            judge.expect(f"{execution}: loaderVerified (hashProcessAndMaps)", report.get("loaderVerified"), "true")

    rollback_id = context.execution_id("gj3", "rollback")
    rollback, _ = context.settled(rollback_id, "deploy.native-library.app-owned@1", completed=False)
    if rollback:
        context.job(rollback, rollback_id, terminal="failed")
        rollback_fixture(context, rollback, rollback_id, fixture_sha256, forward, report)
        entries = context.timeline(rollback, rollback_id)
        if entries is not None:
            # A fixture refused before publication (an ABI mismatch at
            # admission, say) proves only that refusal, never the rollback.
            context.verified(entries, "atomic-publish", rollback_id, ("publishedSha256",))
            context.verified(entries, "rollback-native-library", rollback_id, ("restored", "restoredSha256"))
            judge.that(
                f"{rollback_id}: the previous library was restored",
                "native deployment failure restored previous library" in entries,
                None,
            )
            judge.that(
                f"{rollback_id}: no rollback failed closed",
                not any(e.startswith("native rollback failed closed") for e in entries),
                None,
            )


def rollback_fixture(
    context: Context,
    rollback: str,
    label: str,
    fixture_sha256: str,
    forward: Step | None,
    report: dict | None,
) -> None:
    """G3: the rollback fixture applies to the current Target.

    The fixture's own import (`gj3-<d>-fixture`) is read back with `artifact
    import inspect`, whose receipt carries the Runtime's ELF validation. It
    must be the pinned fixture, imported for this Target at the forward leg's
    binding revision, with the ABI the forward leg's library was verified
    loaded under in the target process. The rollback Job must have consumed
    exactly that import's lease.
    """
    run, judge = context.run, context.judge
    request = context.execution_id("gj3", "fixture")
    inspect = run.last(
        "artifact.import.inspect", lambda s: s.ok and s.option("--import-request-id") == request
    )
    if inspect is None:
        judge.missing(f"{label}: fixture import", f"artifact import inspect --import-request-id {request}")
        return
    # The published CLI returns ArtifactImportInspectionProjection, containing
    # the Import under `import`; a bare Import is not the current contract.
    imported = inspect.result.get("import")
    typed = (
        inspect.result.get("schemaVersion") == "arkdeck.import-inspection/1"
        and isinstance(imported, dict)
        and imported.get("schemaVersion") == "arkdeck.import/1"
        and isinstance(inspect.result.get("references"), dict)
        and isinstance(imported.get("metadata"), dict)
        and imported["metadata"].get("schemaVersion") == "arkdeck.import-intent/1"
        and isinstance(imported.get("receipt"), dict)
        and isinstance(imported["receipt"].get("validation"), dict)
    )
    judge.that(f"{label}: fixture inspection uses the current typed projection", typed, None, inspect)
    if not typed:
        return
    metadata = imported["metadata"]
    receipt = imported["receipt"]
    validation = receipt["validation"]
    judge.that(
        f"{label}: fixture import and receipt identities match",
        isinstance(imported.get("importId"), str) and bool(imported["importId"])
        and imported.get("importRequestId") == metadata.get("importRequestId")
        == receipt.get("importRequestId") == request
        and receipt.get("schemaVersion") == "arkdeck.import-receipt/1"
        and receipt.get("importId") == imported["importId"]
        and receipt.get("owner") == {"kind": "import", "id": imported["importId"]}
        and isinstance(receipt.get("artifactId"), str)
        and bool(receipt["artifactId"])
        and receipt.get("lease") == f"lease-v1:{imported['importId']}:{receipt['artifactId']}",
        None,
        inspect,
    )
    judge.that(
        f"{label}: fixture receipt matches the imported content and binding",
        metadata.get("kind") == validation.get("kind") == "native-library"
        and metadata.get("sha256") == receipt.get("artifactDigest")
        and all(metadata.get(key) == receipt.get(key) for key in ("targetId", "bindingRevision", "byteCount", "name")),
        None,
        inspect,
    )
    judge.that(
        f"{label}: fixture import committed",
        imported.get("state") in ("committed", "released"),
        imported.get("state"),
        inspect,
    )
    judge.expect(f"{label}: fixture is the pinned rollback fixture", metadata.get("sha256"), fixture_sha256, inspect)
    judge.that(f"{label}: fixture has a build ID", bool(validation.get("buildId")), None, inspect)
    if forward is not None:
        evidence = forward.result.get("evidence") or {}
        judge.expect(
            f"{label}: fixture imported for this Target",
            metadata.get("targetId"),
            evidence.get("targetId"),
            inspect,
            forward,
        )
        judge.expect(
            f"{label}: fixture imported at this binding revision",
            str(metadata.get("bindingRevision")),
            str(evidence.get("bindingRevision")),
            inspect,
            forward,
        )
    if report is not None:
        judge.expect(
            f"{label}: fixture ABI is the Target's loaded ABI", validation.get("abi"), report.get("abi"), inspect
        )
    show = run.last("job.show", lambda s: s.ok and (s.result.get("job") or {}).get("jobId") == rollback)
    if show is None:
        judge.missing(f"{label}: the rollback request", f"job show --job {rollback}")
        return
    inputs = (show.result.get("request") or {}).get("inputs") or {}
    judge.expect(
        f"{label}: the rollback Job consumed the fixture's lease",
        inputs.get("libraryArtifactLease"),
        receipt.get("lease"),
        show,
        inspect,
    )


# -- GJ-4 ---------------------------------------------------------------------


def gj4(context: Context, expected_firmware: str) -> None:
    run, judge = context.run, context.judge
    execution = context.execution_id("gj4")
    job, _ = context.settled(execution, "flash.full-restore@1")
    if job:
        step, contents = context.job(job, execution, required=("flash-report.json", "post-flash-facts.json"))
        if step is not None:
            evidence = step.result.get("evidence") or {}
            kinds = evidence.get("actualStepKinds") or []
            for kind in FLASH_STEP_KINDS:
                judge.that(f"{execution}: actualStepKinds has {kind}", kind in kinds, kinds, step)
            observation = evidence.get("observation") or {}
            judge.expect(f"{execution}: machine readback firmware", observation.get("firmware"), expected_firmware, step)
            judge.expect(
                f"{execution}: readback method", observation.get("confirmationMethod"), "machineReadback", step
            )
        held = [s for s in run.execution(execution) if human_action(s)]
        judge.that(f"{execution}: humanActions", not held, len(held), *held)
        facts = context.document(contents, "post-flash-facts.json", execution)
        if facts is not None:
            judge.expect(f"{execution}: post-flash-facts firmware", facts.get("firmware"), expected_firmware)
        report = context.document(contents, "flash-report.json", execution)
        if report is not None:
            judge.expect(f"{execution}: flash-report completeness", report.get("completeness"), "complete")
            judge.expect(f"{execution}: flash-report missingRequired", report.get("missingRequired"), [])
    postflight = context.execution_id("gj4", "postflight")
    job, _ = context.settled(postflight, "observe.device@1")
    if job:
        context.job(job, postflight)


# -- GJ-5 ---------------------------------------------------------------------


def gj5(context: Context) -> None:
    run, judge = context.run, context.judge

    def leg(suffix: str, operation: str, required: tuple[str, ...] = (), **kwargs):
        execution = context.execution_id("gj5", suffix)
        job, _ = context.settled(execution, operation)
        if not job:
            return None, {}
        step, contents = context.job(job, execution, required=required, **kwargs)
        return step, contents

    _, baseline = leg("baseline", "capture.diagnostics@1", ("crash-index.txt",))
    leg("repro", "debug.hap@1", ("install-readback.json",))
    _, repro = leg("repro-capture", "capture.diagnostics@1", ("application-liveness.json", "crash-index.txt"))
    before = crash_entries(baseline["crash-index.txt"]) if "crash-index.txt" in baseline else None
    after_repro = crash_entries(repro["crash-index.txt"]) if "crash-index.txt" in repro else None
    if before is not None or after_repro is not None:
        judge.that(
            "repro: exactly one new crash-index entry",
            before is not None and after_repro is not None and after_repro == before + 1,
            [before, after_repro],
        )
    liveness = context.document(repro, "application-liveness.json", "repro")
    if liveness is not None:
        judge.expect("repro: liveness state", liveness.get("state"), "UNHEALTHY")
        judge.expect("repro: liveness reasonCode", liveness.get("reasonCode"), "targetProcessNotRunning")
    _, analyzed = leg("analyze", "analyzer.extract-crash-signature@1", ("crash-signature.json",))
    signature = context.document(analyzed, "crash-signature.json", "analyze")
    if signature is not None:
        judge.expect("analyze: crash signature status", signature.get("status"), "answered")

    _, isolated = leg("isolate", "workspace.prepare-isolated-copy@1", ("isolated-workspace.json",))
    _, patched = leg("patch", "workspace.apply-patch@1", ("applied-patch.json",))
    copy = context.document(isolated, "isolated-workspace.json", "isolate")
    applied = context.document(patched, "applied-patch.json", "patch")
    if applied is not None:
        judge.that(
            "patch: previousWorkspaceRevision -> a new revision",
            bool(applied.get("previousWorkspaceRevision"))
            and applied.get("previousWorkspaceRevision") != applied.get("workspaceRevision"),
            [applied.get("previousWorkspaceRevision"), applied.get("workspaceRevision")],
        )
        if copy is not None:
            judge.expect(
                "patch: applied to the isolated copy's revision",
                applied.get("previousWorkspaceRevision"),
                copy.get("workspaceRevision"),
            )
    leg("build", "workspace.build-openharmony@1", ("build.log", "unsigned.hap"))
    signed_step, _ = leg("sign", "workspace.sign-openharmony-hap@1", ("signed.hap",))
    _, verified = leg("verify", "debug.hap@1", ("install-readback.json",))
    readback = context.document(verified, "install-readback.json", "verify")
    if readback is not None and signed_step is not None:
        signed = next((a for a in signed_step.result.get("artifacts") or [] if a.get("name") == "signed.hap"), {})
        judge.expect(
            "verify: deployed bytes are the signed HAP",
            readback.get("deployedArtifactSha256"),
            signed.get("sha256"),
        )
    _, healthy = leg("verify-capture", "capture.diagnostics@1", ("application-liveness.json", "crash-index.txt"))
    liveness = context.document(healthy, "application-liveness.json", "verify")
    if liveness is not None:
        judge.expect("verify: liveness state after the crash window", liveness.get("state"), "HEALTHY")
    after_fix = crash_entries(healthy["crash-index.txt"]) if "crash-index.txt" in healthy else None
    if after_fix is not None or after_repro is not None:
        judge.that(
            "verify: crash-index count unchanged since the repro",
            after_fix is not None and after_fix == after_repro,
            [after_repro, after_fix],
        )
    _negative(context)


def _negative(context: Context) -> None:
    run, judge = context.run, context.judge
    execution = context.execution_id("gj5", "negative")
    refused = next((s for s in run.execution(execution) if s.command == "agent.run"), None)
    if refused is None:
        judge.missing(f"{execution}: execution", f"agent run --execution-id {execution}")
        return
    context.executions.append(execution)
    details = refused.error.get("details") or {}
    judge.expect(f"{execution}: named refusal", refused.error.get("code"), "admissionDenied", refused)
    judge.that(
        f"{execution}: refused for the superseded revision",
        "workspace.revisionConflict" in str(refused.error.get("message", "")),
        None,
        refused,
    )
    judge.expect(f"{execution}: phase", details.get("phase"), "preAdmission", refused)
    judge.expect(f"{execution}: newDispatchCount", details.get("newDispatchCount"), 0, refused)
    before = _ledger(run, refused, -1)
    after = _ledger(run, refused, +1)
    if before is None or after is None:
        judge.missing(f"{execution}: Job ledger before and after", "job list --page-size 1000, every page, before and after")
        return
    judge.that(f"{execution}: Job count unchanged", len(before) == len(after), [len(before), len(after)], refused)
    judge.that(f"{execution}: Job set unchanged", before == after, None, refused)


def _ledger(run: Run, around: Step, direction: int) -> frozenset[str] | None:
    """The complete `job list` read right before (-1) or after (+1) a step:
    the consecutive `job list` pages next to it, chained by cursor."""
    index = run.steps.index(around)
    pages: list[Step] = []
    cursor = index + direction
    while 0 <= cursor < len(run.steps) and run.steps[cursor].command == "job.list":
        pages.append(run.steps[cursor])
        cursor += direction
    if direction < 0:
        pages.reverse()
    if not pages or any(not p.ok for p in pages):
        return None
    if pages[0].option("--cursor") is not None:
        return None
    for previous, page in zip(pages, pages[1:]):
        if page.option("--cursor") != previous.result.get("nextCursor"):
            return None
    if pages[-1].result.get("hasMore") is not False:
        return None
    jobs = [item.get("jobId") for page in pages for item in page.items]
    if any(not isinstance(job, str) for job in jobs):
        return None
    return frozenset(jobs) if len(set(jobs)) == len(jobs) else None
