"""The measurements themselves, and the design rows they do and do not cover.

Design section I.2 lists twelve metric rows.  This module measures the ones a
macOS host can measure honestly with no device attached, no Rust workspace and
no UI lane, and declares every remaining row as a gap with the reason it is
blocked.  A row is never silently dropped: an omission would read as coverage.

Noise control follows the design's own prescription for the PR lane — each run
also times a fixed calibration workload, so a latency can be reported as a
ratio against work whose cost is known.  A ratio survives a runner that is
merely slower; an absolute number does not.
"""

from __future__ import annotations

import pathlib
import time

from . import baseline, clocks, control, harness

# A pure-CPU workload with no allocation growth and no syscall, sized to land in
# the same millisecond range as the IPC round trips it normalises.
CALIBRATION_ITERATIONS = 60_000

# The soak fixture completes one cycle per restart interval, so this is what
# decides how many Jobs the seed leaves behind — not `--seed-jobs-per-cycle`
# alone.  The fixture's own default is 300 s, which would yield a single cycle.
SEED_RESTART_INTERVAL_SECONDS = 1

# An idle daemon holds its start-up working set for tens of seconds and then
# returns most of it in one step.  Measured on the reference host, the release
# has landed anywhere between 4 s and 29 s after start, and the plateau either
# side of it is flat to within a few kilobytes.  Percentiles taken across the
# step describe neither level, so the series is split at the release and each
# level is reported on its own.  A drop of at least this fraction of the
# running median is what counts as the release.
RESIDENT_SET_RELEASE_FRACTION = 0.25


def calibration_sample() -> float:
    started = clocks.awake_seconds()
    total = 0
    for index in range(CALIBRATION_ITERATIONS):
        total += index ^ (index >> 3)
    elapsed = clocks.awake_seconds() - started
    # Keep the optimiser honest about the loop's result.
    if total < 0:
        raise RuntimeError("calibration workload miscomputed")
    return elapsed * 1000.0


METRIC_DEFINITIONS: dict[str, tuple[str, str, str]] = {
    # metric id -> (unit, design row, description)
    "daemon.coldStart": (
        "milliseconds",
        "I.2 row 1 (daemon cold start)",
        "process spawn through the first successful health response",
    ),
    "ipc.health": (
        "milliseconds",
        "I.2 row 4 (IPC request p50/p95/p99, UDS leg)",
        "health round trip on an established Unix domain socket connection",
    ),
    "ipc.jobList": (
        "milliseconds",
        "I.2 row 4 (IPC request p50/p95/p99, UDS leg)",
        "job.list round trip over a seeded Job store",
    ),
    "ipc.jobStatus": (
        "milliseconds",
        "I.2 row 4 (IPC request p50/p95/p99, UDS leg)",
        "job.status round trip for one terminal Job",
    ),
    "daemon.residentSetPlateau": (
        "bytes",
        "I.2 row 8 (idle resource footprint)",
        "resident set an idle daemon holds from start until it releases its "
        "start-up working set",
    ),
    "daemon.residentSetSteady": (
        "bytes",
        "I.2 row 8 (idle resource footprint)",
        "resident set an idle daemon holds after that release",
    ),
    "daemon.idleCpuPercent": (
        "percent",
        "I.2 row 8 (idle resource footprint)",
        "CPU share of a freshly started daemon as ps reports it, which is an "
        "average over the process lifetime rather than an instantaneous reading",
    ),
    "daemon.idleThreadCount": (
        "count",
        "I.2 row 8 (idle resource footprint)",
        "thread count of a freshly started daemon",
    ),
    "daemon.idleOpenFileDescriptorCount": (
        "count",
        "I.2 row 8 (idle resource footprint)",
        "open descriptors of a freshly started daemon",
    ),
    "calibration.busyLoop": (
        "milliseconds",
        "noise control (design section I.2, ratio-based PR gate)",
        "fixed CPU workload used as the ratio denominator",
    ),
}


def gap_definitions() -> dict[str, baseline.Gap]:
    """Design rows this host cannot measure, with the reason for each."""

    return {
        "daemon.warmStartRecovery": baseline.Gap(
            "daemon.warmStartRecovery",
            "I.2 rows 2 and 7 (warm start and 10k journal/history recovery)",
            "measured today by JournalRecoveryContractTests under "
            "ARKDECK_RUN_LONG_JOURNAL_TESTS=1 in the nightly slow lane; the "
            "measurement exists but is neither archived nor comparable across "
            "runs, so no baseline value can be carried here yet",
            "no cross-run archiving for the existing slow lane",
        ),
        "app.timeToInteractive": baseline.Gap(
            "app.timeToInteractive",
            "I.2 row 3 (App time to interactive)",
            "AppShellUITests asserts a connected device row before its 2s "
            "budget, so the measurement needs a real device and the UI lane",
            "device window and UI lane",
        ),
        "ipc.namedPipe": baseline.Gap(
            "ipc.namedPipe",
            "I.2 row 4 (IPC, named-pipe leg)",
            "no named-pipe transport exists on any platform yet",
            "TASK-XPA-002 (Windows transport)",
        ),
        "job.eventsWait": baseline.Gap(
            "job.eventsWait",
            "I.2 row 5 (job.events.wait idle CPU)",
            "job.events.wait is a protocol 2.x proposal in design section F.2 "
            "and does not exist in any published method table",
            "the protocol 2.1.0 method table (TASK-XPA-001)",
        ),
        "artifact.pagedRead": baseline.Gap(
            "artifact.pagedRead",
            "I.2 row 6 (large artifact transfer, paged base64 leg)",
            "measurable in principle through artifact.read, but the 128 MiB and "
            "1 GiB fixtures are built by the opt-in slow artifact tests rather "
            "than by this harness",
            "artifact fixture generation in the perf lane",
        ),
        "artifact.open": baseline.Gap(
            "artifact.open",
            "I.2 row 6 (large artifact transfer, zero-copy leg)",
            "artifact.open does not exist; whether to build it is itself one of "
            "the decisions section I.3 expects SPK-1 to unblock, so it cannot "
            "be baselined before it is decided",
            "a maintainer ruling on the zero-copy artifact path",
        ),
        "job.cancelReconcile": baseline.Gap(
            "job.cancelReconcile",
            "I.2 row 9 (cancel and reconcile latency)",
            "job.cancel and job.reconcile are published only on protocol 1.x, "
            "so a 2.x measurement client cannot reach them, and the terminal "
            "leg needs an HDC child process on a real device",
            "TASK-XPA-001 (2.1.0 publication) and a device window",
        ),
        "viewer.scale": baseline.Gap(
            "viewer.scale",
            "I.2 row 10 (Viewer build, search, hit-test, scroll)",
            "build, search and hit-test are covered by the existing ratio gate "
            "in ViewerScalePerformanceTests, whose header refuses wall-clock "
            "budgets; the scroll leg needs the UI lane",
            "a maintainer ruling on wall-clock Viewer budgets, and the UI lane",
        ),
        "ui.frameResponse": baseline.Gap(
            "ui.frameResponse",
            "I.2 row 11 (UI frame response)",
            "needs the UI lane on both platforms",
            "UI lane",
        ),
        "package.size": baseline.Gap(
            "package.size",
            "I.2 row 12 (installer size and update delta)",
            "no DMG or MSIX producer exists in the repository, so there is no "
            "artefact to size",
            "TASK-XPA-022 (Windows packaging) and a macOS installer producer",
        ),
    }


class RunContext:
    """Executables and sample counts for one capture."""

    def __init__(
        self,
        *,
        daemon_executable: pathlib.Path,
        soak_executable: pathlib.Path,
        cold_start_samples: int,
        ipc_samples: int,
        idle_seconds: int,
        calibration_samples: int,
        seed_seconds: int,
        seed_jobs_per_cycle: int,
    ) -> None:
        self.daemon_executable = daemon_executable
        self.soak_executable = soak_executable
        self.cold_start_samples = cold_start_samples
        self.ipc_samples = ipc_samples
        self.idle_seconds = idle_seconds
        self.calibration_samples = calibration_samples
        self.seed_seconds = seed_seconds
        self.seed_jobs_per_cycle = seed_jobs_per_cycle


class RunFailed(RuntimeError):
    """One measurement run could not complete."""


JOB_LIST_PAGE_SIZE = 50


def split_at_release(
    samples: list[float], fraction: float = RESIDENT_SET_RELEASE_FRACTION
) -> tuple[list[float], list[float], int | None]:
    """Split a resident-set series at its largest qualifying downward step.

    Returns `(plateau, steady, index)`.  With no qualifying step the whole
    series is both the plateau and the steady state, and the index is `None`;
    the caller records that so a reader can tell a flat daemon from one whose
    release was simply not observed inside the window.
    """

    best_index: int | None = None
    best_drop = 0.0
    for index in range(1, len(samples)):
        previous = samples[index - 1]
        drop = previous - samples[index]
        if previous > 0 and drop / previous >= fraction and drop > best_drop:
            best_drop = drop
            best_index = index
    if best_index is None:
        return list(samples), list(samples), None
    return samples[:best_index], samples[best_index:], best_index


def _job_store_probe(client: control.ControlClient) -> tuple[str | None, int | None]:
    """Return one Job id and the number of rows the projection returned.

    The row count is what every per-row figure for `job.list` divides by, so it
    is read back and recorded rather than inferred from the seed parameters: the
    seed produces a different number of Jobs depending on the fixture's restart
    interval, and a reader of the baseline document cannot reconstruct it.
    """

    result = client.call("job.list", {"pageSize": JOB_LIST_PAGE_SIZE})
    if not isinstance(result, dict):
        return None, None
    items = result.get("items")
    if not isinstance(items, list):
        return None, None
    job_id: str | None = None
    for item in items:
        if isinstance(item, dict) and isinstance(item.get("jobId"), str):
            job_id = item["jobId"]
            break
    return job_id, len(items)


def execute_run(
    context: RunContext, state_directory: pathlib.Path
) -> tuple[dict[str, list[float]], dict[str, object]]:
    """Take every measurable sample once, against one isolated Runtime.

    Returns the samples and the data scale they were taken at.  A budget only
    holds at the scale it was measured at, so the scale travels with the
    numbers instead of being reconstructed from the seed parameters.
    """

    samples: dict[str, list[float]] = {name: [] for name in METRIC_DEFINITIONS}
    scale: dict[str, object] = {
        "seedSeconds": context.seed_seconds,
        "seedJobsPerCycle": context.seed_jobs_per_cycle,
        "seedRestartIntervalSeconds": SEED_RESTART_INTERVAL_SECONDS,
        "jobListPageSize": JOB_LIST_PAGE_SIZE,
        "jobStoreRowCount": None,
    }

    for _ in range(context.calibration_samples):
        samples["calibration.busyLoop"].append(calibration_sample())

    seeded = harness.seed_state_directory(
        context.soak_executable,
        state_directory,
        context.seed_seconds,
        context.seed_jobs_per_cycle,
        SEED_RESTART_INTERVAL_SECONDS,
    )
    if seeded.returncode != 0:
        raise RunFailed(
            "the soak fixture could not seed a Runtime state directory: "
            f"{seeded.stdout.strip()} {seeded.stderr.strip()}"
        )

    runtime = harness.IsolatedRuntime(context.daemon_executable, state_directory)
    try:
        # Cold start is measured by repeatedly restarting the daemon on the
        # same populated state directory, which is what design section I.2
        # describes.  Every start is paired with a stop so that each sample is a
        # genuine cold start rather than the first one plus a long-lived server.
        for _ in range(context.cold_start_samples):
            elapsed = runtime.start()
            samples["daemon.coldStart"].append(elapsed * 1000.0)
            runtime.stop()

        runtime.start()
        with runtime.client() as client:
            job_id, row_count = _job_store_probe(client)
            scale["jobStoreRowCount"] = row_count
            for _ in range(context.ipc_samples):
                _, elapsed = client.timed_call("health")
                samples["ipc.health"].append(elapsed * 1000.0)
                _, elapsed = client.timed_call(
                    "job.list", {"pageSize": JOB_LIST_PAGE_SIZE}
                )
                samples["ipc.jobList"].append(elapsed * 1000.0)
                if job_id is not None:
                    _, elapsed = client.timed_call("job.status", {"jobId": job_id})
                    samples["ipc.jobStatus"].append(elapsed * 1000.0)
        runtime.stop()

        # The resource window needs a daemon that has served nothing but its own
        # health check.  Sampling the process that just answered thousands of
        # requests measures a served-then-quiet resident set, and calling that
        # "idle" flatters nothing — it inflates the number, which is the wrong
        # direction for arguing about headroom under a ceiling.
        runtime.start()
        if runtime.process is None:
            raise RunFailed("the daemon stopped before the idle window")
        pid = runtime.process.pid
        resident_series: list[float] = []
        idle_deadline = clocks.Deadline(max(1, context.idle_seconds))
        while not idle_deadline.expired():
            # One sample per second: the resource readers shell out, and
            # sampling as fast as they return would make the harness itself the
            # busiest thing on an otherwise idle host.
            time.sleep(1.0)
            sample = harness.sample_process_resources(pid)
            if sample.resident_set_bytes is not None:
                resident_series.append(float(sample.resident_set_bytes))
            if sample.cpu_percent is not None:
                samples["daemon.idleCpuPercent"].append(sample.cpu_percent)
            if sample.thread_count is not None:
                samples["daemon.idleThreadCount"].append(float(sample.thread_count))
            if sample.open_file_descriptor_count is not None:
                samples["daemon.idleOpenFileDescriptorCount"].append(
                    float(sample.open_file_descriptor_count)
                )
        plateau, steady, release_index = split_at_release(resident_series)
        samples["daemon.residentSetPlateau"] = plateau
        samples["daemon.residentSetSteady"] = steady
        scale["residentSetReleaseObserved"] = release_index is not None
        scale["residentSetReleaseAtSeconds"] = release_index
        scale["residentSetSampleCount"] = len(resident_series)
    finally:
        runtime.stop()

    return {name: values for name, values in samples.items() if values}, scale
