"""Real daemon restart over separate deterministic Journal and History inputs.

Timing includes spawn, contract handshake and completion verification. This is
an end-to-end recovery measurement, not an estimate of replay CPU time.
"""
from __future__ import annotations

import hashlib
import json
import math
import pathlib
import shutil
import subprocess

from . import clocks, control, harness

VERSION = "rust-recovery-fixture-v1"
COUNT = 10_000
PAGE_SIZE = 250
METRICS = {
    "journal": "daemon.warmStartRecovery",
    "history": "daemon.warmStartRecovery.history",
}


class RecoveryFailed(RuntimeError):
    """No sample is valid unless the entire required workload is verified."""


def clean_environment() -> dict[str, str]:
    import os
    return {key: value for key, value in os.environ.items() if not key.startswith("ARKDECK_")}


def seed(soak: pathlib.Path, root: pathlib.Path, workload: str) -> dict:
    completed = subprocess.run(
        [str(soak), "--seed-recovery", workload, str(COUNT), str(root)],
        env=clean_environment(), capture_output=True, text=True, timeout=300,
        check=False,
    )
    if completed.returncode:
        raise RecoveryFailed(f"{workload} seed failed: {completed.stderr.strip()}")
    manifest = json.loads((root / "recovery-fixture.json").read_text())
    expected = {
        "fixtureVersion": VERSION, "workload": workload,
        "jobCount": 1 if workload == "journal" else COUNT,
        "activeJobCount": 1 if workload == "journal" else 0,
        "journalEventCount": COUNT if workload == "journal" else 0,
        "seedTimestamp": "2026-09-26T00:00:00Z", "providerDispatchCount": 0,
    }
    if manifest != expected:
        raise RecoveryFailed("unexpected recovery fixture workload")
    return manifest


def validate_input(root: pathlib.Path, manifest: dict) -> dict:
    """Read actual input bytes/counts; never trust a static manifest as evidence."""
    jobs = sorted((root / "jobs-state/jobs").iterdir())
    expected_ids = [f"job-recovery-{i:05}" for i in range(manifest["jobCount"])]
    if [p.name for p in jobs] != expected_ids:
        raise RecoveryFailed("seed Job identities/count differ")
    journal_count = 0
    journal_bytes = 0
    journal_digest = hashlib.sha256()
    digest = hashlib.sha256()
    for job in jobs:
        record_bytes = (job / "job-record.json").read_bytes()
        record = json.loads(record_bytes)
        if record["jobID"] != job.name or record["timeline"] != [] or record["state"] != (
            "preflight" if manifest["workload"] == "journal" else "succeeded"
        ):
            raise RecoveryFailed("seed record already recovered or wrong state")
        digest.update(record_bytes)
        journal = job / "journal.jsonl"
        if journal.exists():
            data = journal.read_bytes()
            if not data.endswith(b"\n"):
                raise RecoveryFailed("seed journal has a torn tail")
            events = [json.loads(line) for line in data.splitlines()]
            for sequence, event in enumerate(events):
                if event["sequence"] != sequence or event["jobId"] != job.name:
                    raise RecoveryFailed("seed journal sequence/identity differs")
            journal_count += len(events)
            journal_bytes += len(data)
            digest.update(data)
            journal_digest.update(data)
    if journal_count != manifest["journalEventCount"]:
        raise RecoveryFailed("actual seed event count differs")
    return {"inputSha256": digest.hexdigest(), "journalSha256": journal_digest.hexdigest(), "journalBytes": journal_bytes,
            "actualJobCount": len(jobs), "actualJournalEventCount": journal_count}


def verify_completed(runtime, root: pathlib.Path, manifest: dict, deadline,
                     expected_input_sha256: str | None = None) -> dict:
    expected = {f"job-recovery-{i:05}" for i in range(manifest["jobCount"])}
    seen: set[str] = set()
    cursors: set[str] = set()
    cursor = None
    pages = 0
    while True:
        if deadline.expired():
            raise RecoveryFailed("recovery completion timed out")
        # A fresh, contract-verified connection per page stays below frame limits.
        with control.ControlClient(str(runtime.socket_path), timeout_seconds=max(0.001, min(1.0, deadline.remaining_seconds()))) as client:
            params = {"pageSize": PAGE_SIZE}
            if cursor is not None:
                params["cursor"] = cursor
            page = client.call("job.list", params)
        pages += 1
        for row in page["items"]:
            identity = row["jobId"]
            state = "preflight" if manifest["workload"] == "journal" else "succeeded"
            if identity not in expected or identity in seen or row["state"] != state:
                raise RecoveryFailed("recovery Job identity/state differs")
            seen.add(identity)
        cursor = page.get("nextCursor")
        if cursor is None:
            break
        if cursor in cursors or not page["items"]:
            raise RecoveryFailed("recovery pagination made no progress")
        cursors.add(cursor)
    if seen != expected:
        raise RecoveryFailed("recovery History is incomplete")
    # A socket or successful health response alone is insufficient: require
    # the production recovery's durable marker, absent in every fresh input.
    if manifest["workload"] == "journal":
        record = json.loads((root / "jobs-state/jobs/job-recovery-00000/job-record.json").read_text())
        if record["timeline"] != ["recovered: journal clean"] or record["state"] != "preflight":
            raise RecoveryFailed("daemon did not persist the required recovery marker")
    else:
        digest = hashlib.sha256()
        for identity in sorted(expected):
            data = (root / "jobs-state/jobs" / identity / "job-record.json").read_bytes()
            record = json.loads(data)
            digest.update(data)
            if record["timeline"] != [] or record["state"] != "succeeded":
                raise RecoveryFailed("terminal History unexpectedly entered recovery")
        if expected_input_sha256 and digest.hexdigest() != expected_input_sha256:
            raise RecoveryFailed("terminal History bytes changed during recovery")
    if deadline.expired():
        raise RecoveryFailed("recovery completion timed out")
    return {"verifiedJobs": len(seen), "verifiedPages": pages,
            "recoveryMarkers": 1 if manifest["workload"] == "journal" else 0}


class FixtureSet:
    """One pristine, never-started seed per workload per independent run."""

    def __init__(self, soak):
        self.soak = soak
        self.roots = []
        self.fixtures = {}

    def __enter__(self):
        return self

    def __exit__(self, *_exception):
        for root in self.roots:
            shutil.rmtree(root)

    def get(self, workload):
        if workload not in self.fixtures:
            root = harness.temporary_state_directory(prefix="adks.")
            self.roots.append(root)
            started = clocks.awake_seconds()
            manifest = seed(self.soak, root, workload)
            proof = validate_input(root, manifest)
            proof["templatePreparationMilliseconds"] = (clocks.awake_seconds() - started) * 1000
            self.fixtures[workload] = (root, manifest, proof)
        return self.fixtures[workload]


def measure(daemon, soak, workload: str, budget_seconds: float = 60.0, *, require_quiet: bool = False, fixture=None) -> tuple[float, dict]:
    if workload not in METRICS or not math.isfinite(budget_seconds) or budget_seconds <= 0:
        raise ValueError("invalid recovery workload or timeout")
    root = harness.temporary_state_directory(prefix="adkr.")
    try:
        seed_started = clocks.awake_seconds()
        if fixture is None:
            manifest = seed(soak, root, workload)
            evidence = validate_input(root, manifest)
        else:
            template, manifest, expected = fixture
            if manifest["workload"] != workload:
                raise RecoveryFailed("template workload differs")
            shutil.copytree(template, root, dirs_exist_ok=True)
            copied_files = 0
            for source in template.rglob("*"):
                if source.is_symlink():
                    raise RecoveryFailed("pristine template contains a symlink")
                if source.is_file():
                    if source.samefile(root / source.relative_to(template)):
                        raise RecoveryFailed("fixture copy shares a writable inode with template")
                    copied_files += 1
            evidence = validate_input(root, manifest)
            evidence["copyIsolationVerified"] = True
            evidence["copiedRegularFiles"] = copied_files
            if evidence["inputSha256"] != expected["inputSha256"]:
                raise RecoveryFailed("copied recovery input differs from pristine seed")
            evidence["templatePreparationMilliseconds"] = expected["templatePreparationMilliseconds"]
        evidence["seedPreparationMilliseconds"] = (clocks.awake_seconds() - seed_started) * 1000
        quiet = assert_quiet_host() if require_quiet else {"waived": True}
        with harness.IsolatedRuntime(daemon, root, runtime_kind="rust") as runtime:
            deadline = clocks.Deadline(budget_seconds)
            started = clocks.awake_seconds()
            health_seconds = runtime.start(budget_seconds=budget_seconds)
            completion = verify_completed(runtime, root, manifest, deadline, evidence.get("inputSha256"))
            milliseconds = (clocks.awake_seconds() - started) * 1000.0
        # Journals must remain byte-identical: this is clean replay, no dispatch.
        after = hashlib.sha256()
        for path in sorted((root / "jobs-state/jobs").glob("*/journal.jsonl")):
            after.update(path.read_bytes())
        if after.hexdigest() != evidence["journalSha256"]:
            raise RecoveryFailed("unexpected journal write during clean recovery")
        sample = {**manifest, **evidence, **completion, "milliseconds": milliseconds,
                "quietHostAtStart": quiet,
                "spawnThroughHealthMilliseconds": health_seconds * 1000,
                "completionVerificationMilliseconds": milliseconds - health_seconds * 1000}
        if fixture is not None:
            if validate_input(template, manifest)["inputSha256"] != expected["inputSha256"]:
                raise RecoveryFailed("Runtime modified the pristine template")
            sample["templateUnchanged"] = True
        if require_quiet:
            try:
                sample["quietHostAtEnd"] = assert_quiet_host()
            except harness.HostTooBusy as error:
                failure = RecoveryFailed(str(error))
                failure.sample = sample
                raise failure from error
        return milliseconds, sample
    finally:
        shutil.rmtree(root)


def assert_quiet_host() -> dict:
    """Repository measurement gate; evaluated before every recovery sample."""
    import re
    load = harness.assert_host_is_quiet()
    if load >= 4:
        raise harness.HostTooBusy("recovery measurement requires one-minute load < 4")
    processes = subprocess.run(["ps", "-axo", "comm=,args="], capture_output=True,
                               text=True, check=True, timeout=10)
    for line in processes.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        if not fields:
            continue
        command = pathlib.Path(fields[0]).name
        arguments = fields[1] if len(fields) > 1 else ""
        if (command in {"cargo", "rustc", "xcodebuild"}
                or (command.lower().startswith("python") and re.search(r"(?:^|[ /])plan\.py(?:\s|$)", arguments))):
            raise harness.HostTooBusy(f"recovery measurement refused while {command} is running")
    return {"oneMinuteLoad": load, "conflictingBuildProcesses": 0}
