"""Command line for the performance baseline harness.

    python3 -m bench capture --daemon <path> --soak <path> --out-dir <dir>
    python3 -m bench compare --committed <file> --candidate <file> --mode ratio

Run from the `scripts` directory, the same way the repository's other Python
harnesses are run.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

from . import baseline, clocks, harness, metrics


def _existing_file(value: str) -> pathlib.Path:
    path = pathlib.Path(value)
    if not path.is_file():
        raise argparse.ArgumentTypeError(f"{value} is not a file")
    return path


def _executable(value: str) -> pathlib.Path:
    path = pathlib.Path(value)
    if not path.is_file():
        raise argparse.ArgumentTypeError(f"{value} is not a file")
    return path.resolve()


def _positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"{value} is not an integer") from error
    if parsed <= 0:
        raise argparse.ArgumentTypeError(f"{value} must be positive")
    return parsed


def _minimum_runs(value: str) -> int:
    parsed = _positive_int(value)
    if parsed < baseline.MINIMUM_RUNS:
        raise argparse.ArgumentTypeError(
            f"SPK-1 needs at least {baseline.MINIMUM_RUNS} independent runs"
        )
    return parsed


def _ratio(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"{value} is not a number") from error
    if parsed < 0:
        raise argparse.ArgumentTypeError(f"{value} must not be negative")
    return parsed


def _toolchain_facts(daemon: pathlib.Path, soak: pathlib.Path) -> dict[str, object]:
    def digest(path: pathlib.Path) -> str | None:
        binary = shutil.which("shasum")
        if binary is None:
            return None
        completed = subprocess.run(
            [binary, "-a", "256", str(path)],
            stdout=subprocess.PIPE,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            return None
        return completed.stdout.split()[0]

    return {
        "daemonSha256": digest(daemon),
        "soakFixtureSha256": digest(soak),
        "calibrationIterations": metrics.CALIBRATION_ITERATIONS,
    }


# Design section I.2 pins the reference hosts to release builds.  A debug build
# carries different allocator, inlining and assertion behaviour, so its numbers
# describe a different program; they are useful for development feedback and
# must never be committed as the baseline.
RELEASE_CONFIGURATION = "release"


def capture_exit_code(unstable: list[str], disqualifiers: list[str]) -> int:
    """Exit status for a completed capture.

    Instability fails SPK-1's stability criterion only for a run that could
    have established a baseline.  A capture already disqualified — a shared CI
    runner, or a debug build — is expected to be noisy, and its lane is gated by
    the ratio comparison that follows, not by this exit code.  Returning
    non-zero there kills the step before it ever compares.
    """

    if unstable and not disqualifiers:
        return 2
    return 0


def command_capture(arguments: argparse.Namespace) -> int:
    context = metrics.RunContext(
        daemon_executable=arguments.daemon,
        soak_executable=arguments.soak,
        cold_start_samples=arguments.cold_start_samples,
        ipc_samples=arguments.ipc_samples,
        idle_seconds=arguments.idle_seconds,
        calibration_samples=arguments.calibration_samples,
        seed_seconds=arguments.seed_seconds,
        seed_jobs_per_cycle=arguments.seed_jobs_per_cycle,
    )

    results: dict[str, baseline.MetricResult] = {}
    run_records: list[dict[str, object]] = []
    disqualifiers: list[str] = []
    if arguments.build_configuration != RELEASE_CONFIGURATION:
        disqualifiers.append(
            f"built {arguments.build_configuration}; design section I.2 pins the "
            "reference hosts to release builds"
        )
    if arguments.allow_loaded_host:
        # Opting out of the quiet-host requirement is a declaration that this
        # capture is not trying to establish a baseline.  It has to disqualify
        # the run whether or not the guard actually trips: a shared runner is
        # frequently quiet at the start of a run and busy during it, which is
        # exactly the case the guard cannot see.
        disqualifiers.append(
            "recorded with --allow-loaded-host, so the quiet-host requirement "
            "was waived"
        )

    for index in range(arguments.runs):
        try:
            load_start = harness.assert_host_is_quiet()
        except harness.HostTooBusy as error:
            if not arguments.allow_loaded_host:
                print(f"bench: {error}", file=sys.stderr)
                return 1
            load_start = harness.load_average()[0]
            disqualifiers.append(
                f"run {index} started at load {load_start:.2f}, above the "
                "quiet-host ceiling"
            )

        state_directory = harness.temporary_state_directory()
        started_at = clocks.utc_now()
        try:
            samples, scale = metrics.execute_run(context, state_directory)
        except (metrics.RunFailed, harness.DaemonStartFailed) as error:
            print(f"bench: run {index} failed: {error}", file=sys.stderr)
            return 1
        finally:
            shutil.rmtree(state_directory, ignore_errors=True)

        for name, values in samples.items():
            unit, design_row, description = metrics.METRIC_DEFINITIONS[name]
            result = results.setdefault(
                name, baseline.MetricResult(name, unit, design_row, description)
            )
            result.add_run(values, scale)

        run_records.append(
            {
                "index": index,
                "startedAtUtc": started_at,
                "finishedAtUtc": clocks.utc_now(),
                "loadAverageOneMinuteStart": round(load_start, 3),
                "loadAverageOneMinuteEnd": round(harness.load_average()[0], 3),
                "measuredMetrics": sorted(samples),
                "scale": scale,
            }
        )
        print(
            f"bench: run {index + 1}/{arguments.runs} complete "
            f"({len(samples)} metrics)",
            file=sys.stderr,
        )

    toolchain = _toolchain_facts(arguments.daemon, arguments.soak)
    toolchain["buildConfiguration"] = arguments.build_configuration
    document = baseline.build_document(
        host=harness.host_facts(),
        toolchain=toolchain,
        runs=run_records,
        metrics=results,
        gaps=metrics.gap_definitions(),
        baseline_eligible=not disqualifiers,
        eligibility_reason=(
            "; ".join(disqualifiers)
            if disqualifiers
            else "release build measured on a quiet host with the required run count"
        ),
    )
    serialized = baseline.serialize(document)

    arguments.out_dir.mkdir(parents=True, exist_ok=True)
    destination = arguments.out_dir / f"perf-baseline-{document['generatedAtUtc'][:10]}.json"
    destination.write_text(serialized, encoding="utf-8")
    print(f"bench: wrote {destination}", file=sys.stderr)
    print(
        f"bench: verdict={document['spikeVerdict']} "
        f"measured={document['measuredMetricCount']} "
        f"gaps={document['gapCount']} "
        f"baselineEligible={document['baselineEligible']}",
        file=sys.stderr,
    )
    if document["unstableMetrics"]:
        print(
            "bench: unstable p95 across runs: "
            + ", ".join(document["unstableMetrics"]),
            file=sys.stderr,
        )
        if disqualifiers:
            print(
                "bench: advisory capture; instability is not an error here",
                file=sys.stderr,
            )
    return capture_exit_code(list(document["unstableMetrics"]), disqualifiers)


def command_compare(arguments: argparse.Namespace) -> int:
    from . import compare as comparison

    committed = json.loads(arguments.committed.read_text(encoding="utf-8"))
    candidate = json.loads(arguments.candidate.read_text(encoding="utf-8"))
    result = comparison.compare(
        committed,
        candidate,
        mode=arguments.mode,
        threshold=arguments.threshold,
        on_host_mismatch=arguments.on_host_mismatch,
    )
    print(comparison.render(result))
    if arguments.out is not None:
        arguments.out.write_text(
            json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    return 0 if result["passed"] else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="bench",
        description=(
            "Measure and compare ArkDeck Runtime performance baselines "
            "(SPK-1, TASK-XPA-023).  Host-only; no device is contacted."
        ),
        allow_abbrev=False,
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    capture = subparsers.add_parser(
        "capture",
        help="take a baseline over several independent runs",
        allow_abbrev=False,
    )
    capture.add_argument("--daemon", type=_executable, required=True)
    capture.add_argument("--soak", type=_executable, required=True)
    capture.add_argument(
        "--out-dir",
        type=pathlib.Path,
        required=True,
        help="controlled output directory for the baseline document",
    )
    capture.add_argument(
        "--build-configuration",
        choices=("release", "debug"),
        default=RELEASE_CONFIGURATION,
        help=(
            "how the measured executables were built; a debug capture is "
            "recorded as advisory and never as the committed baseline"
        ),
    )
    capture.add_argument("--runs", type=_minimum_runs, default=baseline.MINIMUM_RUNS)
    capture.add_argument("--cold-start-samples", type=_positive_int, default=50)
    capture.add_argument("--ipc-samples", type=_positive_int, default=1000)
    capture.add_argument(
        "--idle-seconds",
        type=_positive_int,
        # Long enough to contain the daemon's start-up working-set
        # release, which has landed as late as 29 s after start.
        default=120,
    )
    capture.add_argument("--calibration-samples", type=_positive_int, default=200)
    capture.add_argument("--seed-seconds", type=_positive_int, default=6)
    capture.add_argument("--seed-jobs-per-cycle", type=_positive_int, default=10)
    capture.add_argument(
        "--allow-loaded-host",
        action="store_true",
        help=(
            "record a run on a busy host as advisory output; the document is "
            "marked not baseline-eligible"
        ),
    )
    capture.set_defaults(handler=command_capture)

    compare = subparsers.add_parser(
        "compare",
        help="compare a candidate baseline against the committed one",
        allow_abbrev=False,
    )
    compare.add_argument("--committed", type=_existing_file, required=True)
    compare.add_argument("--candidate", type=_existing_file, required=True)
    compare.add_argument("--mode", choices=("absolute", "ratio"), default="absolute")
    compare.add_argument("--threshold", type=_ratio, default=0.10)
    compare.add_argument(
        "--on-host-mismatch",
        choices=("fail", "skip"),
        default="fail",
        help=(
            "what to do when the two documents were measured on different "
            "hosts; neither comparison mode survives a change of machine"
        ),
    )
    compare.add_argument("--out", type=pathlib.Path, default=None)
    compare.set_defaults(handler=command_compare)

    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        return arguments.handler(arguments)
    except (baseline.BaselineError, ValueError) as error:
        print(f"bench: ERROR: {error}", file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001 - the CLI reports, never traces
        # A comparison or capture refusal is a result, not a crash; a traceback
        # in a CI log buries the sentence that says what to do about it.
        if type(error).__name__ in {"ComparisonError", "ControlError", "HostTooBusy"}:
            print(f"bench: ERROR: {error}", file=sys.stderr)
            return 1
        raise


if __name__ == "__main__":
    raise SystemExit(main())
