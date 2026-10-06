"""Command line for the Golden Journey record generator.

    python -m gj_record capture --out <dir> --step <label> [--quiet] -- <arkdeck> <args...>
    python -m gj_record assemble --out <dir> --date <YYYY-MM-DD> \
        --runtime-source-revision <sha> --record <file> [--journey GJ-1 ...]

Run from the `scripts` directory, the same way the repository's other Python
harnesses are run.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import capture, record

REPOSITORY = Path(__file__).resolve().parent.parent.parent


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="gj_record")
    commands = parser.add_subparsers(dest="action", required=True)

    run = commands.add_parser("capture", help="run one arkdeck command and journal its output")
    run.add_argument("--out", required=True, type=Path)
    run.add_argument("--step", required=True)
    run.add_argument(
        "--quiet",
        action="store_true",
        help="keep stdout in the journal only (the HAR crash-resume step discards it)",
    )
    run.add_argument("--timeout-seconds", type=float, default=None)
    run.add_argument("command", nargs=argparse.REMAINDER)

    build = commands.add_parser("assemble", help="judge the journal and write the record")
    build.add_argument("--out", required=True, type=Path)
    build.add_argument("--date", required=True)
    build.add_argument("--attempt", type=int, default=None,
                       help="select an independent same-day attempt (1..999), never replay an old ID")
    build.add_argument("--runtime-source-revision", required=True)
    build.add_argument("--protected-main", default="origin/main")
    build.add_argument("--record", required=True, type=Path)
    build.add_argument("--journey", action="append", choices=record.JOURNEYS, default=None)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.action == "capture":
            command = arguments.command
            if command and command[0] == "--":
                command = command[1:]
            entry = capture.capture(
                arguments.out,
                arguments.step,
                command,
                repository=REPOSITORY,
                quiet=arguments.quiet,
                timeout=arguments.timeout_seconds,
            )
            # The CLI's own exit code, so a caller still sees 75 for a human
            # action; the generator's own refusals exit 2 before anything ran.
            return entry["exitCode"]
        document = record.assemble(
            arguments.out,
            date=arguments.date,
            runtime_source_revision=arguments.runtime_source_revision,
            protected_main=arguments.protected_main,
            repository=REPOSITORY,
            names=arguments.journey or list(record.JOURNEYS),
            attempt=arguments.attempt,
        )
        record.write(arguments.record, document)
        for journey in document["journeys"]:
            failing = journey.get("firstFailingCriterion")
            print(
                f"{journey['goldenJourney']}: {journey['state']}"
                + (f" ({failing['criterion']}: {failing['raw']})" if failing else ""),
                file=sys.stderr,
            )
        return 0
    except (capture.CaptureError, record.AssemblyError) as error:
        print(f"gj_record: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
