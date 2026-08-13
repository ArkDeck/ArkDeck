#!/usr/bin/env python3
"""Compute and optionally execute ArkDeck's path-aware local/hosted CI plan.

The planner deliberately lives outside GitHub Actions YAML so local validation
and hosted validation classify the same diff.  An unavailable comparison base
never means "nothing changed": it selects every compiled lane instead.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
from collections.abc import Mapping, Sequence


ZERO_OID = "0" * 40
DEFAULT_BRANCH = "main"
SWIFT_WORKFLOW = ".github/workflows/swift-ci.yml"
PLANNER_PREFIX = "scripts/ci/"


class PlanError(RuntimeError):
    """The requested exact-head plan could not be computed safely."""


@dataclasses.dataclass(frozen=True)
class LaneSelection:
    swift: bool
    app: bool


@dataclasses.dataclass(frozen=True)
class CIPlan:
    lanes: LaneSelection
    base_revision: str | None
    head_revision: str
    base_kind: str
    reason: str
    changed_files: tuple[str, ...]

    def as_dict(self) -> dict[str, object]:
        return {
            "swift": self.lanes.swift,
            "app": self.lanes.app,
            "baseRevision": self.base_revision,
            "headRevision": self.head_revision,
            "baseKind": self.base_kind,
            "reason": self.reason,
            "changedFileCount": len(self.changed_files),
            "changedFiles": list(self.changed_files),
        }


def classify_paths(paths: Sequence[str]) -> LaneSelection:
    swift = False
    app = False
    for raw_path in paths:
        if not raw_path or "\x00" in raw_path:
            raise PlanError("changed paths must be non-empty and NUL-free")
        path = raw_path.replace("\\", "/")

        # A planner/workflow change validates both branches of the decision it
        # is changing.  This prevents a broken classifier from self-skipping.
        if path == SWIFT_WORKFLOW or path.startswith(PLANNER_PREFIX):
            swift = True
            app = True
            continue

        if path.startswith("Packages/ArkDeckKit/") or path.startswith("Package."):
            swift = True

        # The desktop app links ArkDeckKit production targets.  Package tests
        # and test fixtures do not affect that composition root, while sources,
        # resources, launch-agent inputs and the manifest do.
        if (
            path.startswith("ArkDeckApp/")
            or path.startswith("ArkDeckAppUITests/")
            or path.startswith("ArkDeck.xcodeproj/")
            or path.startswith("Packages/ArkDeckKit/Sources/")
            or path.startswith("Packages/ArkDeckKit/LaunchAgents/")
            or path == "Packages/ArkDeckKit/Package.swift"
            or path.startswith("Package.")
        ):
            app = True

    return LaneSelection(swift=swift, app=app)


def _git(
    repo_root: pathlib.Path,
    arguments: Sequence[str],
    *,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", os.fspath(repo_root), *arguments],
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def _git_bytes(
    repo_root: pathlib.Path,
    arguments: Sequence[str],
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["git", "-C", os.fspath(repo_root), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def _commit_oid(repo_root: pathlib.Path, revision: str) -> str | None:
    result = _git(
        repo_root,
        ["rev-parse", "--verify", "--end-of-options", f"{revision}^{{commit}}"],
        check=False,
    )
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value if len(value) == 40 else None


def _merge_base(repo_root: pathlib.Path, left: str, right: str) -> str | None:
    result = _git(repo_root, ["merge-base", "--", left, right], check=False)
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value if len(value) == 40 else None


def _changed_files(
    repo_root: pathlib.Path, base_revision: str, head_revision: str
) -> tuple[str, ...]:
    # --no-renames reports both sides of a cross-surface rename.  Otherwise a
    # Swift source moved into docs could be represented only by its new path
    # and incorrectly skip the compiled lane that lost the source.
    result = _git_bytes(
        repo_root,
        [
            "diff",
            "--name-only",
            "-z",
            "--no-renames",
            "--diff-filter=ACDMRTUXB",
            base_revision,
            head_revision,
            "--",
        ],
    )
    return tuple(os.fsdecode(value) for value in result.stdout.split(b"\x00") if value)


def _working_tree_files(repo_root: pathlib.Path) -> tuple[str, ...]:
    tracked = _git_bytes(
        repo_root,
        [
            "diff",
            "--name-only",
            "-z",
            "--no-renames",
            "--diff-filter=ACDMRTUXB",
            "HEAD",
            "--",
        ],
    )
    untracked = _git_bytes(
        repo_root,
        ["ls-files", "-z", "--others", "--exclude-standard"],
    )
    return tuple(
        sorted(
            {
                os.fsdecode(value)
                for value in (
                    *tracked.stdout.split(b"\x00"),
                    *untracked.stdout.split(b"\x00"),
                )
                if value
            }
        )
    )


def _all_lanes_plan(
    *, head_revision: str, base_kind: str, reason: str
) -> CIPlan:
    return CIPlan(
        lanes=LaneSelection(swift=True, app=True),
        base_revision=None,
        head_revision=head_revision,
        base_kind=base_kind,
        reason=reason,
        changed_files=(),
    )


def plan_between(
    repo_root: pathlib.Path,
    *,
    base_revision: str,
    head_revision: str,
    use_merge_base: bool,
    include_worktree: bool = False,
    base_kind: str = "explicit",
) -> CIPlan:
    head_oid = _commit_oid(repo_root, head_revision)
    if head_oid is None:
        raise PlanError(f"head revision is not a commit: {head_revision}")
    base_oid = _commit_oid(repo_root, base_revision)
    if base_oid is None:
        return _all_lanes_plan(
            head_revision=head_oid,
            base_kind=base_kind,
            reason="base-unavailable-fail-closed",
        )
    if use_merge_base:
        merge_base = _merge_base(repo_root, base_oid, head_oid)
        if merge_base is None:
            return _all_lanes_plan(
                head_revision=head_oid,
                base_kind=base_kind,
                reason="merge-base-unavailable-fail-closed",
            )
        base_oid = merge_base
        base_kind = f"{base_kind}-merge-base"
    try:
        changed_files = _changed_files(repo_root, base_oid, head_oid)
        if include_worktree:
            changed_files = tuple(
                sorted({*changed_files, *_working_tree_files(repo_root)})
            )
    except subprocess.CalledProcessError:
        return _all_lanes_plan(
            head_revision=head_oid,
            base_kind=base_kind,
            reason="diff-unavailable-fail-closed",
        )
    return CIPlan(
        lanes=classify_paths(changed_files),
        base_revision=base_oid,
        head_revision=head_oid,
        base_kind=base_kind,
        reason=(
            "classified-changed-files-and-worktree"
            if include_worktree
            else "classified-changed-files"
        ),
        changed_files=changed_files,
    )


def plan_from_push_event(
    repo_root: pathlib.Path,
    event: Mapping[str, object],
) -> CIPlan:
    ref = event.get("ref")
    after = event.get("after")
    before = event.get("before")
    if not isinstance(ref, str) or not ref.startswith("refs/heads/"):
        raise PlanError("push event ref must name a branch")
    if not isinstance(after, str) or len(after) != 40:
        raise PlanError("push event after must be a full commit OID")

    checked_out = _commit_oid(repo_root, "HEAD")
    if checked_out != after:
        raise PlanError(
            "push event after does not match the exact checked-out HEAD "
            f"({after} != {checked_out})"
        )

    branch = ref.removeprefix("refs/heads/")
    if branch == DEFAULT_BRANCH:
        if not isinstance(before, str) or before == ZERO_OID or len(before) != 40:
            return _all_lanes_plan(
                head_revision=after,
                base_kind="push-before",
                reason="main-before-unavailable-fail-closed",
            )
        return plan_between(
            repo_root,
            base_revision=before,
            head_revision=after,
            use_merge_base=False,
            base_kind="push-before",
        )

    if branch.startswith("agent/"):
        # Every agent head is compared with its current main merge base.  This
        # handles the all-zero first-push before OID and prevents a later docs
        # commit from hiding an earlier still-present Swift change.
        return plan_between(
            repo_root,
            base_revision="refs/remotes/origin/main",
            head_revision=after,
            use_merge_base=True,
            base_kind="origin-main",
        )

    return _all_lanes_plan(
        head_revision=after,
        base_kind="unsupported-branch",
        reason="unsupported-branch-fail-closed",
    )


def _append_github_output(path: pathlib.Path, plan: CIPlan) -> None:
    values = {
        "swift": str(plan.lanes.swift).lower(),
        "app": str(plan.lanes.app).lower(),
        "base": plan.base_revision or "unavailable",
        "head": plan.head_revision,
        "base-kind": plan.base_kind,
        "reason": plan.reason,
        "changed-count": str(len(plan.changed_files)),
    }
    with path.open("a", encoding="utf-8", newline="\n") as output:
        for key, value in values.items():
            if "\n" in value or "\r" in value:
                raise PlanError(f"GitHub output value contains a newline: {key}")
            output.write(f"{key}={value}\n")


def _sdd_python(repo_root: pathlib.Path) -> str:
    explicit = os.environ.get("ARKDECK_PYTHON")
    if explicit:
        return explicit
    worktree = repo_root / ".venv-sdd" / "bin" / "python"
    if worktree.is_file() and os.access(worktree, os.X_OK):
        return os.fspath(worktree)
    common = _git(repo_root, ["rev-parse", "--git-common-dir"], check=False)
    if common.returncode == 0 and common.stdout.strip():
        common_path = pathlib.Path(common.stdout.strip())
        if not common_path.is_absolute():
            common_path = repo_root / common_path
        try:
            shared = common_path.resolve(strict=True).parent / ".venv-sdd" / "bin" / "python"
        except OSError:
            shared = pathlib.Path("/__arkdeck_missing_shared_python__")
        if shared.is_file() and os.access(shared, os.X_OK):
            return os.fspath(shared)
    fallback = shutil.which("python3")
    if fallback is None:
        raise PlanError("no Python interpreter available for SDD checks")
    return fallback


def local_commands(repo_root: pathlib.Path, plan: CIPlan) -> tuple[tuple[str, ...], ...]:
    python = _sdd_python(repo_root)
    commands: list[tuple[str, ...]] = [
        (python, "scripts/ci/test_plan.py"),
        (python, "scripts/test_agent_pr_workflow.py"),
        ("sh", "scripts/check-sdd.sh"),
        (
            python,
            "-m",
            "unittest",
            "discover",
            "-s",
            "scripts/catalog_gen",
            "-p",
            "test_*.py",
        ),
        (python, "scripts/catalog_gen/generate.py", "--check"),
    ]
    if plan.lanes.swift:
        commands.extend(
            [
                (python, "Packages/ArkDeckKit/Scripts/test_run_swiftpm.py"),
                ("sh", "Packages/ArkDeckKit/Scripts/run-test-lane.sh", "full"),
            ]
        )
    if plan.lanes.app:
        path_digest = hashlib.sha256(os.fsencode(repo_root.resolve())).hexdigest()[:16]
        cache_root = pathlib.Path(
            os.environ.get(
                "ARKDECK_XCODE_CACHE_ROOT",
                os.fspath(
                    pathlib.Path.home()
                    / "Library"
                    / "Caches"
                    / "com.arkdeck.ArkDeck"
                    / "Xcode"
                    / path_digest
                ),
            )
        )
        if not cache_root.is_absolute():
            raise PlanError("ARKDECK_XCODE_CACHE_ROOT must be absolute")
        commands.append(
            (
                "xcodebuild",
                "-project",
                "ArkDeck.xcodeproj",
                "-scheme",
                "ArkDeck",
                "-configuration",
                "Debug",
                "-destination",
                "platform=macOS,arch=arm64",
                "-derivedDataPath",
                os.fspath(cache_root / "DerivedData"),
                "-clonedSourcePackagesDirPath",
                os.fspath(cache_root / "SourcePackages"),
                "-packageCachePath",
                os.fspath(cache_root / "PackageCache"),
                "CODE_SIGNING_ALLOWED=NO",
                "ROCKCHIP_COMPONENT_INPUT=/usr/bin/false",
                "build-for-testing",
            )
        )
    return tuple(commands)


def run_local(repo_root: pathlib.Path, plan: CIPlan) -> None:
    for command in local_commands(repo_root, plan):
        print("+ " + " ".join(command), flush=True)
        environment = os.environ.copy()
        if command[0] == "xcodebuild":
            derived_index = command.index("-derivedDataPath") + 1
            module_cache = pathlib.Path(command[derived_index]).parent / "ModuleCache"
            environment["CLANG_MODULE_CACHE_PATH"] = os.fspath(module_cache)
            environment["SWIFTPM_MODULECACHE_OVERRIDE"] = os.fspath(module_cache)
        subprocess.run(command, cwd=repo_root, env=environment, check=True)


def _parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=pathlib.Path, default=pathlib.Path.cwd())
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--event", type=pathlib.Path)
    source.add_argument("--base-revision")
    parser.add_argument("--head-revision", default="HEAD")
    parser.add_argument("--merge-base", action="store_true")
    parser.add_argument("--include-worktree", action="store_true")
    parser.add_argument("--github-output", type=pathlib.Path)
    parser.add_argument("--run-local", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parse_arguments(sys.argv[1:] if argv is None else argv)
    repo_root = arguments.repo_root.resolve()
    try:
        if arguments.event is not None:
            if arguments.include_worktree:
                raise PlanError("--include-worktree is not valid with --event")
            with arguments.event.open("r", encoding="utf-8") as stream:
                event = json.load(stream)
            if not isinstance(event, dict):
                raise PlanError("event root must be an object")
            plan = plan_from_push_event(repo_root, event)
        else:
            plan = plan_between(
                repo_root,
                base_revision=arguments.base_revision,
                head_revision=arguments.head_revision,
                use_merge_base=arguments.merge_base,
                include_worktree=arguments.include_worktree,
            )
        if arguments.github_output is not None:
            _append_github_output(arguments.github_output, plan)
        print(json.dumps(plan.as_dict(), indent=2, sort_keys=True))
        if arguments.run_local:
            run_local(repo_root, plan)
    except (OSError, json.JSONDecodeError, PlanError, subprocess.CalledProcessError) as error:
        print(f"ci-plan: ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
