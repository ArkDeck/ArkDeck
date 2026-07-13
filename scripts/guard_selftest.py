#!/usr/bin/env python3.14
"""Adversarial self-test for the ArkDeck SDD guard."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from sdd_protected_set import require_sdd_runtime


require_sdd_runtime()


# The guard (check_sdd.py) is the single enforcement point for the whole
# governance model, so "the guard passes" is only meaningful if the guard is
# also proven to FAIL on tampering. Each case below copies the repository to a
# scratch directory, injects exactly one class of violation and asserts that
# the guard reports the expected error. A mutation the guard fails to detect
# fails this suite.
#
# Run alongside scripts/check-sdd.sh; CI must require both to pass.
# Override the scratch location with ARKDECK_SELFTEST_TMPDIR if needed.
SOURCE_ROOT = Path(__file__).resolve().parent.parent
COPY_EXCLUDES = frozenset((".git", ".claude", "__pycache__"))


def _is_virtualenv(entry: Path) -> bool:
    return entry.is_dir() and (entry / "pyvenv.cfg").is_file()


def copy_repo(destination: Path) -> None:
    for entry in SOURCE_ROOT.iterdir():
        if entry.name in COPY_EXCLUDES or _is_virtualenv(entry):
            continue
        target = destination / entry.name
        if entry.is_dir():
            shutil.copytree(entry, target, copy_function=shutil.copy2)
        else:
            shutil.copy2(entry, target)
    for cache in destination.rglob("__pycache__"):
        if cache.is_dir():
            shutil.rmtree(cache)


def run_python(root: Path, script_name: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(root / "scripts" / script_name)],
        check=False,
        capture_output=True,
        text=True,
    )


def run_guard(root: Path) -> subprocess.CompletedProcess[str]:
    return run_python(root, "check_sdd.py")


def run_relock(root: Path) -> subprocess.CompletedProcess[str]:
    return run_python(root, "relock_baseline.py")


@dataclass(frozen=True, slots=True)
class Case:
    name: str
    expected_error: re.Pattern[str]
    mutation: Callable[[Path], None]


def append_text(path: Path, content: str) -> None:
    with path.open("a", encoding="utf-8") as stream:
        stream.write(content)


def replace_text(path: Path, old: str, new: str) -> None:
    path.write_text(path.read_text(encoding="utf-8").replace(old, new, 1), encoding="utf-8")


def manifest_path(root: Path) -> Path:
    return next((root / "openspec/baselines").glob("*.files.yaml"))


def regex_inspect(pattern: re.Pattern[str]) -> str:
    """Render a pattern as /.../ for stable failure output."""

    return f"/{pattern.pattern}/"


def bool_text(value: bool) -> str:
    return "true" if value else "false"


def tamper_file_manifest(root: Path) -> None:
    path = manifest_path(root)
    text = path.read_text(encoding="utf-8")

    def flip(match: re.Match[str]) -> str:
        return f"sha256: {'1' if match.group(1) == '0' else '0'}"

    path.write_text(re.sub(r"sha256: ([0-9a-f])", flip, text, count=1), encoding="utf-8")


def unsort_file_manifest(root: Path) -> None:
    path = manifest_path(root)
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    first = next(index for index, line in enumerate(lines) if line.startswith("- path: "))
    lines[first : first + 4] = lines[first + 2 : first + 4] + lines[first : first + 2]
    path.write_text("".join(lines), encoding="utf-8")


def drop_acceptance_index_entry(root: Path) -> None:
    path = root / "openspec/verification/acceptance-index.txt"
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    victim = next(index for index, line in enumerate(lines) if line.startswith("AC-"))
    del lines[victim]
    path.write_text("".join(lines), encoding="utf-8")


CASES = (
    Case(
        name="tamper-protected-content",
        expected_error=re.compile(r"baseline protected hash mismatch: openspec/constitution\.md"),
        mutation=lambda root: append_text(root / "openspec/constitution.md", "\n<!-- tampered -->\n"),
    ),
    Case(
        name="inject-unregistered-protected-file",
        expected_error=re.compile(r"baseline omits protected files: .*zzz-injected"),
        mutation=lambda root: (root / "openspec/contracts/zzz-injected.schema.json").write_text(
            "{}\n", encoding="utf-8"
        ),
    ),
    Case(
        name="delete-protected-file",
        expected_error=re.compile(r"baseline protected path missing: openspec/specs/flashing/spec\.md"),
        mutation=lambda root: (root / "openspec/specs/flashing/spec.md").unlink(),
    ),
    Case(
        name="tamper-file-manifest",
        expected_error=re.compile(r"baseline hash mismatch: openspec/baselines/"),
        mutation=tamper_file_manifest,
    ),
    Case(
        name="unsorted-file-manifest",
        expected_error=re.compile(r"baseline file manifest is not path-sorted"),
        mutation=unsort_file_manifest,
    ),
    Case(
        name="drop-acceptance-index-entry",
        expected_error=re.compile(r"acceptance index missing: AC-"),
        mutation=drop_acceptance_index_entry,
    ),
    Case(
        name="add-unknown-acceptance-id",
        expected_error=re.compile(r"acceptance index has unknown IDs: AC-ZZZ-999-01"),
        mutation=lambda root: append_text(
            root / "openspec/verification/acceptance-index.txt", "AC-ZZZ-999-01\n"
        ),
    ),
    Case(
        name="duplicate-acceptance-scenario",
        expected_error=re.compile(r"duplicate Acceptance AC-DUMP-001-01"),
        mutation=lambda root: append_text(
            root / "openspec/specs/ui-dump/spec.md",
            "\n#### Scenario: AC-DUMP-001-01 duplicate injection\n\n"
            "- GIVEN x\n- WHEN y\n- THEN z\n",
        ),
    ),
    Case(
        name="requirement-without-scenario",
        expected_error=re.compile(r"REQ-ZZZ-001 has no Scenario"),
        mutation=lambda root: append_text(
            root / "openspec/specs/ui-dump/spec.md",
            "\n### Requirement: REQ-ZZZ-001 Injected requirement\n\n"
            "THE SYSTEM SHALL be detected.\n",
        ),
    ),
    Case(
        name="escalate-task-packet-status",
        expected_error=re.compile(r"ready Task TASK-M0A-001"),
        mutation=lambda root: replace_text(
            root
            / "openspec/changes/chg-2026-001-macos-m0a/task-packets/TASK-M0A-001.json",
            '"status": "draft"',
            '"status": "ready"',
        ),
    ),
    Case(
        name="tamper-platform-profile",
        expected_error=re.compile(r"platform lock hash mismatch: openspec/platforms/linux/profile\.md"),
        mutation=lambda root: append_text(
            root / "openspec/platforms/linux/profile.md", "\n<!-- tampered -->\n"
        ),
    ),
)


def main() -> int:
    failures: list[str] = []
    base_tmp_text = os.environ.get("ARKDECK_SELFTEST_TMPDIR")
    base_tmp = Path(base_tmp_text) if base_tmp_text else None
    if base_tmp is not None:
        base_tmp.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="arkdeck-guard-selftest-", dir=base_tmp) as tmp:
        temp_root = Path(tmp)

        # Case 0: the pristine copy must be green, otherwise mutations prove nothing.
        pristine = temp_root / "pristine"
        pristine.mkdir()
        copy_repo(pristine)
        result = run_guard(pristine)
        if result.returncode == 0:
            print("PASS pristine-copy-is-green")
        else:
            failures.append("pristine-copy-is-green")
            print(
                "FAIL pristine-copy-is-green — guard must pass on an unmodified tree "
                f"before mutations mean anything:\n{result.stderr}"
            )

        for test_case in CASES:
            root = temp_root / test_case.name
            root.mkdir()
            copy_repo(root)
            test_case.mutation(root)
            result = run_guard(root)
            if result.returncode == 0:
                failures.append(test_case.name)
                print(f"FAIL {test_case.name} — guard did not detect the mutation")
            elif test_case.expected_error.search(result.stderr):
                print(f"PASS {test_case.name}")
            else:
                failures.append(test_case.name)
                print(
                    f"FAIL {test_case.name} — guard failed, but without the expected error "
                    f"{regex_inspect(test_case.expected_error)}:\n{result.stderr}"
                )

        # Round-trip: relock must repair candidate drift and return the guard to
        # green, and must refuse to run against an accepted baseline.
        round_trip = temp_root / "relock-repairs-drift"
        round_trip.mkdir()
        copy_repo(round_trip)
        append_text(round_trip / "openspec/constitution.md", "\n<!-- candidate drift -->\n")
        drift_result = run_guard(round_trip)
        relock_result = run_relock(round_trip)
        post_result = run_guard(round_trip)
        if (
            drift_result.returncode != 0
            and relock_result.returncode == 0
            and post_result.returncode == 0
        ):
            print("PASS relock-repairs-drift")
        else:
            failures.append("relock-repairs-drift")
            print(
                "FAIL relock-repairs-drift — drift detected: "
                f"{bool_text(drift_result.returncode != 0)}, relock: "
                f"{bool_text(relock_result.returncode == 0)} "
                f"({relock_result.stderr}{relock_result.stdout}), post-relock guard: "
                f"{bool_text(post_result.returncode == 0)}\n{post_result.stderr}"
            )

        refusal = temp_root / "relock-refuses-accepted-baseline"
        refusal.mkdir()
        copy_repo(refusal)
        lock = next((refusal / "openspec/baselines").glob("*.lock.yaml"))
        lock.write_text(
            re.sub(
                r"^status: review$",
                "status: accepted",
                lock.read_text(encoding="utf-8"),
                count=1,
                flags=re.MULTILINE,
            ),
            encoding="utf-8",
        )
        refusal_result = run_relock(refusal)
        if refusal_result.returncode != 0 and "refusing to relock" in refusal_result.stderr:
            print("PASS relock-refuses-accepted-baseline")
        else:
            failures.append("relock-refuses-accepted-baseline")
            print("FAIL relock-refuses-accepted-baseline — relock must never rewrite an accepted baseline")

    if not failures:
        print(f"Guard self-test passed: {len(CASES) + 3} cases.")
        return 0

    print(f"Guard self-test FAILED: {', '.join(failures)}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
