#!/usr/bin/env python3
"""Compute and optionally execute ArkDeck's path-aware local/hosted CI plan.

The planner deliberately lives outside GitHub Actions YAML so local validation
and hosted validation classify the same diff.  An unavailable comparison base
never means "nothing changed": it selects every lane instead.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
from collections.abc import Mapping, Sequence


ZERO_OID = "0" * 40
DEFAULT_BRANCH = "main"
SWIFT_WORKFLOW = ".github/workflows/swift-ci.yml"
RUST_WORKFLOW = ".github/workflows/rust-ci.yml"
PLANNER_PREFIX = "scripts/ci/"
RUST_WORKSPACE_DIR = "rust"
# Both published and candidate contract checks consume these shared inputs.
# Keep source-only edits visible even when a schema or recorded corpus has not
# changed yet; test_plan verifies coverage against the generator's actual INPUTS.
RUST_CONTRACT_INPUT_PREFIXES = (
    "rust/",
    "spec/",
    "Catalog/",
    "scripts/catalog_gen/",
    "Packages/ArkDeckKit/Contracts/",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI/",
)
# The machine-contract bundle the Rust export renders. Its test holds every
# product to `rust/tests/fixtures/contracts-bundle/owned.json` or to the
# committed file, and check-contracts.py holds that table to the committed
# bundle. A PR can edit products without touching rust/ (the Rust export is the
# only producer since the Swift CLI's deletion, TASK-XPA-018). Such a PR still
# runs the Rust lane, so the table and the Rust copies cannot drift into main
# and fail the next unrelated Rust PR. Swift tests still read some of the
# bundle's schemas, so such a change runs the Swift lane as well.
RUST_BUNDLE_PREFIXES = ("openspec/contracts/",)
# The Rust helper pair's release layout and the structure check that holds it
# (G5 slice 20a, #2218) run in the Rust lane's macOS workspace job, over the
# binaries that job builds. A change to them must run that lane, or it merges
# unchecked (#2236 did: its fix to the check skipped the lane that runs it).
RUST_PACKAGING_PREFIXES = (
    "Packages/ArkDeckKit/Distribution/macOS/",
    "Packages/ArkDeckKit/Resources/OpenHarmonyNativeCodeSign/",
    # The release DMG entry and its fixture tests (TASK-XPA-017 S5) run in the
    # same job, driving build-helpers.sh from this directory.
    "scripts/release/",
)
RUST_CONTRACT_SOURCE_PREFIXES = (
    "Packages/ArkDeckKit/Sources/ArkDeckCore/Canonical",
    "Packages/ArkDeckKit/Sources/ArkDeckCore/Control",
)
RUST_CONTRACT_INPUT_FILES = frozenset({
    "Packages/ArkDeckKit/Sources/ArkDeckCore/PortableCanonicalJSON.swift",
    "Packages/ArkDeckKit/Scripts/generate-control-contract.py",
    "openspec/contracts/runtime-control-plane.schema.json",
    "openspec/contracts/cli-canonical-json-vectors.json",
    "openspec/contracts/cli-result.schema.json",
    "openspec/contracts/cli-error-registry.yaml",
    "openspec/contracts/journal-event.schema.json",
    "openspec/contracts/workflow-step.schema.json",
    "openspec/changes/chg-2026-059-arkdeck-arkforge-authority/permit-vectors.md",
})
APP_PACKAGE_TARGET_PREFIXES = (
    "Packages/ArkDeckKit/Sources/ArkDeckClientKit/",
    "Packages/ArkDeckKit/Sources/ArkDeckCore/",
    "Packages/ArkDeckKit/Sources/ArkDeckTraceAdapter/",
)
# The @arkdeck/ds interaction tests execute the docs/design prototype draft and
# cross-check it against the audit inventory and the App/Package Swift sources
# it names, so a change under any of these directories can flip an assertion.
# PR #1606 merged all-green from ArkDeckApp/ alone while breaking two of them.
DS_INTERACTION_INPUT_PREFIXES = (
    "ArkDeckApp/",
    "ArkDeckAppUITests/",
    "Packages/",
    "docs/design/",
)
DS_PACKAGE_DIR = "docs/design/arkdeck-ds"
# The Windows client (TASK-XPA-007): windows/** plus every input its generators
# (INPUTS of windows/scripts/generate-clientkit.py, generate-ui-strings.py,
# generate-xaml-tokens.py and generate-app-icons.py) and its tests read, so a schema, registry, corpus,
# pattern, shared string, design token or coverage edit cannot skip the Windows
# checks. test_plan verifies coverage against the generators' actual INPUTS.
WINDOWS_DIR = "windows"
WINDOWS_SOLUTION = "windows/ArkDeck.Windows.slnx"
WINDOWS_INPUT_PREFIXES = (
    "windows/",
    "spec/control/methods/",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/",
    # The shared UI semantics: bilingual strings and the UIA semantic snapshots.
    "spec/ui-semantics/",
    # The App's tests read the recorded Trace inspections and the adoption oracle's
    # Target store (TASK-XPA-020).
    "rust/tests/fixtures/trace-inspect/",
    "rust/tests/fixtures/target-adoption/",
    # The Flash host review is checked against the Swift archive oracle (TASK-XPA-020).
    "rust/tests/fixtures/flash-archive/",
    # The Trace probe checks and the UI dump parser are checked against the Swift oracles
    # (TASK-XPA-020/021).
    "rust/tests/fixtures/trace-probe/",
    "rust/tests/fixtures/ui-dump-inspect/",
    # The App's tests also read the recorded human-action corpus, the Debug probe oracle, the
    # observe-device Sessions and the Import upload fixture.
    "rust/tests/fixtures/agent-human-action/",
    "rust/tests/fixtures/debug-probe/",
    "rust/tests/fixtures/observe-device/",
    "rust/tests/fixtures/import-upload-current/",
    # The Diagnostics readers are checked against the Swift session inspector and HiLog
    # summary oracles (TASK-XPA-020).
    "rust/tests/fixtures/diagnostics-inspect/",
    "rust/tests/fixtures/job-run-hilog/",
    "rust/tests/fixtures/hilog-summary-analyzer/",
    # The App's icon and MSIX assets are the macOS AppIcon (generate-app-icons.py).
    "ArkDeckApp/Resources/Assets.xcassets/AppIcon.appiconset/",
    "ArkDeckApp/Resources/Assets.xcassets/ArkDeckKeycapIcon.imageset/",
    "ArkDeckApp/Resources/Assets.xcassets/ArkDeckWaveformIcon.imageset/",
)
WINDOWS_INPUT_FILES = frozenset({
    "Packages/ArkDeckKit/Contracts/control-protocol.json",
    "spec/baselines/swift-single-v1.json",
    "rust/crates/arkdeck-contract/src/schema_patterns.json",
    # The end-to-end ClientKit test signs its daemon copy with it.
    "rust/scripts/windows-dev-identity.ps1",
    # The App's shared strings are these macOS tables' values (generate-ui-strings.py).
    "ArkDeckApp/Resources/Localizable.xcstrings",
    "ArkDeckApp/Resources/HistoryLocalizable.xcstrings",
    "ArkDeckApp/Resources/JobsLocalizable.xcstrings",
    "ArkDeckApp/Resources/SettingsLocalizable.xcstrings",
    "ArkDeckApp/Resources/DebugLocalizable.xcstrings",
    "ArkDeckApp/Resources/FlashLocalizable.xcstrings",
    "ArkDeckApp/Resources/TraceLocalizable.xcstrings",
    "ArkDeckApp/Resources/TraceViewerLocalizable.xcstrings",
    "ArkDeckApp/Resources/UIDumpLocalizable.xcstrings",
    "ArkDeckApp/Resources/DiagnosticsLocalizable.xcstrings",
    # The App's theme is generated from the design tokens (generate-xaml-tokens.py).
    "docs/design/arkdeck-ds/src/tokens.css",
    # The App's tests read the Job state classes and the CLI coverage commands.
    "spec/recovery/job-state-preflight.json",
    "openspec/contracts/cli-feature-coverage.json",
    # The embedded Flash catalog review is checked against the one macOS compiles in.
    "Packages/ArkDeckKit/Sources/ArkDeckCore/FlashReviewCatalogGenerated.swift",
    # The Diagnostics Artifact roles are checked against these operations' Catalog entries.
    "Catalog/operations/capture.diagnostics.v1.json",
    "Catalog/operations/analyzer.summarize-hilog.v1.json",
})


class PlanError(RuntimeError):
    """The requested exact-head plan could not be computed safely."""


@dataclasses.dataclass(frozen=True)
class LaneSelection:
    swift: bool
    app: bool
    ds: bool
    rust: bool
    windows: bool = False


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
            "ds": self.lanes.ds,
            "rust": self.lanes.rust,
            "windows": self.lanes.windows,
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
    ds = False
    rust = False
    windows = False
    for raw_path in paths:
        if not raw_path or "\x00" in raw_path:
            raise PlanError("changed paths must be non-empty and NUL-free")
        path = raw_path.replace("\\", "/")

        # A planner/workflow change validates every branch of the decision it
        # is changing.  This prevents a broken classifier from self-skipping.
        if path in (
            SWIFT_WORKFLOW, RUST_WORKFLOW, "scripts/test_agent_pr_workflow.py"
        ) or path.startswith(PLANNER_PREFIX):
            swift = True
            app = True
            ds = True
            rust = True
            windows = True
            continue

        # Each view must consume the contract it actually validates. Selecting
        # only rust/spec misses source, schema, fixture and Catalog-only edits.
        if (
            path.startswith(RUST_CONTRACT_INPUT_PREFIXES)
            or path.startswith(RUST_BUNDLE_PREFIXES)
            or path.startswith(RUST_PACKAGING_PREFIXES)
            or path in RUST_CONTRACT_INPUT_FILES
            or (
                path.endswith(".swift")
                and path.startswith(RUST_CONTRACT_SOURCE_PREFIXES)
            )
        ):
            rust = True

        if path.startswith(WINDOWS_INPUT_PREFIXES) or path in WINDOWS_INPUT_FILES:
            windows = True

        if (
            path.startswith("Packages/ArkDeckKit/")
            or path.startswith("Package.")
            or path.startswith(RUST_BUNDLE_PREFIXES)
        ):
            swift = True

        if any(path.startswith(prefix) for prefix in DS_INTERACTION_INPUT_PREFIXES):
            ds = True

        # The desktop app links a precise subset of ArkDeckKit production
        # targets. Package tests, the agent client, bootstrap registries and
        # fixtures do not affect that graph. Keeping those changes on the
        # Swift lane avoids a redundant app rebuild.
        package_source_affects_app = any(
            path.startswith(prefix) for prefix in APP_PACKAGE_TARGET_PREFIXES
        )
        if (
            path.startswith("ArkDeckApp/")
            or path.startswith("ArkDeckAppUITests/")
            or path.startswith("ArkDeck.xcodeproj/")
            or package_source_affects_app
            or path == "Packages/ArkDeckKit/Package.swift"
            or path == "Packages/ArkDeckKit/Package.resolved"
            or path.startswith("Package.")
        ):
            app = True

    return LaneSelection(swift=swift, app=app, ds=ds, rust=rust, windows=windows)


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
        lanes=LaneSelection(swift=True, app=True, ds=True, rust=True, windows=True),
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


def _full_oid(value: str | None) -> str | None:
    """A full lowercase commit OID, the form the Actions API reports, or None."""
    if (
        value is None
        or len(value) != 40
        or not all(character in "0123456789abcdef" for character in value)
    ):
        return None
    return value


def _is_ancestor(repo_root: pathlib.Path, ancestor: str, descendant: str) -> bool:
    result = _git(
        repo_root,
        ["merge-base", "--is-ancestor", "--end-of-options", ancestor, descendant],
        check=False,
    )
    return result.returncode == 0


def plan_from_merge_group_event(
    repo_root: pathlib.Path, event: Mapping[str, object]
) -> CIPlan:
    """Validate the entire queued combination against its immutable event base.

    origin/main may already have advanced (or the temporary branch disappeared)
    by the time a runner starts. Neither changes the comparison for this run.
    """
    group = event.get("merge_group")
    if event.get("action") != "checks_requested" or not isinstance(group, dict):
        raise PlanError("expected a merge_group checks_requested event")
    head, base = group.get("head_sha"), group.get("base_sha")
    if not isinstance(head, str) or _full_oid(head) is None or head == ZERO_OID:
        raise PlanError("merge_group head_sha must be a full commit OID")
    if _commit_oid(repo_root, "HEAD") != head:
        raise PlanError("merge_group head_sha does not match the exact checked-out HEAD")
    if group.get("base_ref") != "refs/heads/main":
        raise PlanError("merge_group base_ref must be refs/heads/main")
    head_ref = group.get("head_ref")
    if not isinstance(head_ref, str) or not head_ref.startswith("refs/heads/gh-readonly-queue/main/"):
        raise PlanError("merge_group head_ref must belong to the main merge queue")
    if not isinstance(base, str) or _full_oid(base) is None or _commit_oid(repo_root, base) is None:
        return _all_lanes_plan(head_revision=head, base_kind="merge-group-base",
                               reason="merge-group-base-unavailable-fail-closed")
    if not _is_ancestor(repo_root, base, head):
        raise PlanError("merge_group base_sha is not an ancestor of head_sha")
    return plan_between(repo_root, base_revision=base, head_revision=head,
                        use_merge_base=False, base_kind="merge-group-base")


def plan_from_event(repo_root: pathlib.Path, event: Mapping[str, object], *,
                    last_success: str | None = None) -> CIPlan:
    if "merge_group" in event:
        return plan_from_merge_group_event(repo_root, event)
    return plan_from_push_event(repo_root, event, last_success=last_success)


def plan_from_push_event(
    repo_root: pathlib.Path,
    event: Mapping[str, object],
    *,
    last_success: str | None = None,
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
        # A main run validates every change since the newest main commit this
        # workflow passed on, not only its own push. GitHub keeps one pending
        # run per concurrency group, so a third merge replaces the run still
        # waiting behind the first, and `before` then names a commit no run
        # validated: #1903's 99dda729 on 2026-09-14, whose files the next run
        # never looked at. A red run leaves the same hole, and a docs-only merge
        # after it would otherwise turn main green over a lane still broken.
        candidate = _full_oid(last_success)
        validated = _commit_oid(repo_root, candidate) if candidate else None
        if validated is None:
            return _all_lanes_plan(
                head_revision=after,
                base_kind="main-last-success",
                reason="main-last-success-unavailable-fail-closed",
            )
        if validated == after:
            # A re-run of a commit main already passed re-checks its own push.
            return plan_between(
                repo_root,
                base_revision=before,
                head_revision=after,
                use_merge_base=False,
                base_kind="push-before",
            )
        if not _is_ancestor(repo_root, validated, before):
            return _all_lanes_plan(
                head_revision=after,
                base_kind="main-last-success",
                reason="main-last-success-not-behind-push-fail-closed",
            )
        return plan_between(
            repo_root,
            base_revision=validated,
            head_revision=after,
            use_merge_base=False,
            base_kind="main-last-success",
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
        "ds": str(plan.lanes.ds).lower(),
        "rust": str(plan.lanes.rust).lower(),
        "windows": str(plan.lanes.windows).lower(),
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
    if plan.lanes.ds:
        # node_modules is not committed and the suite imports esbuild/react
        # from it.  Without the install, the files with only node: imports
        # still pass and the rest die on ERR_MODULE_NOT_FOUND — a misleading
        # partial pass — so the install is part of the lane, not a setup hint.
        commands.extend(
            [
                ("npm", "--prefix", DS_PACKAGE_DIR, "ci"),
                ("npm", "--prefix", DS_PACKAGE_DIR, "test"),
            ]
        )
    if plan.lanes.swift:
        commands.extend(
            [
                (python, "Packages/ArkDeckKit/Scripts/generate-clientkit-models.py", "--check"),
                (python, "Packages/ArkDeckKit/Scripts/test_generate_clientkit_models.py"),
                (python, "Packages/ArkDeckKit/Scripts/test_run_swiftpm.py"),
                ("sh", "Packages/ArkDeckKit/Scripts/run-test-lane.sh", "full"),
            ]
        )
    if plan.lanes.app:
        commands.extend(
            [
                (python, "scripts/ci/test_run_xcodebuild.py"),
                ("sh", "scripts/ci/run-xcodebuild.sh"),
            ]
        )
    if plan.lanes.rust:
        commands.extend(
            [
                (sys.executable, "rust/scripts/generate-contract.py", "--check"),
                ("cargo", "fmt", "--all", "--check"),
                # vet --locked freezes cargo metadata too. Fetch the complete
                # graph first, including dependencies for other host targets.
                ("cargo", "fetch", "--locked"),
                # Every other rust check regenerates from the checkout or
                # builds its own source views under rust/target, so none of
                # them compiles the checkout. Clippy and the workspace tests
                # are the only lane members that do.
                #
                # The workspace tests go through a wrapper because two
                # `corpus_parity` cases assert the checkout equals its
                # committed manifest. The wrapper names an input that was
                # edited without regenerating before the tests run; it never
                # compares the checkout with origin/main. Published-versus-
                # candidate parity is check-contracts.py, whose published
                # inputs come from the merge-base with main.
                ("cargo", "clippy", "--workspace", "--all-targets", "--", "-D", "warnings"),
                (sys.executable, "rust/scripts/workspace-tests.py"),
                (sys.executable, "rust/scripts/test_contract_checks.py"),
                (sys.executable, "rust/scripts/test_ci_execution.py"),
                (sys.executable, "rust/scripts/check-contracts.py"),
                ("cargo", "deny", "--locked", "check"),
                ("cargo", "vet", "--locked", "--no-registry-suggestions"),
            ]
        )
    if plan.lanes.windows:
        commands.extend(
            [
                (python, "windows/scripts/generate-clientkit.py", "--check"),
                (python, "windows/scripts/generate-ui-strings.py", "--check"),
                (python, "windows/scripts/generate-xaml-tokens.py", "--check"),
                (python, "windows/scripts/generate-app-icons.py", "--check"),
                ("dotnet", "build", WINDOWS_SOLUTION, "-c", "Release"),
                ("dotnet", "test", WINDOWS_SOLUTION, "-c", "Release", "--no-build"),
            ]
        )
    return tuple(commands)


def windows_lane_runnable() -> bool:
    """The windows lane builds and tests a Windows-only solution (net10.0-windows,
    named-pipe P/Invoke); nothing else can stand in for it."""
    return platform.system() == "Windows"


def _is_windows_lane_command(command: Sequence[str]) -> bool:
    return command[0] == "dotnet" or (
        len(command) > 1 and command[1].startswith(f"{WINDOWS_DIR}/")
    )


def run_local(repo_root: pathlib.Path, plan: CIPlan) -> None:
    # A selected windows lane on another host is reported as not runnable and
    # fails the local gate after the other lanes ran; it never passes silently.
    skip_windows = plan.lanes.windows and not windows_lane_runnable()
    if skip_windows:
        print(
            "ci-plan: the windows lane is selected but cannot run on this host "
            f"({platform.system() or 'unknown'}); the other lanes run first",
            file=sys.stderr,
            flush=True,
        )
    for command in local_commands(repo_root, plan):
        if skip_windows and _is_windows_lane_command(command):
            continue
        # rustup discovers rust-toolchain.toml from the working directory,
        # not --manifest-path. Run each Cargo invocation in the workspace so
        # local validation uses the same pinned toolchain as hosted CI.
        cwd = repo_root / RUST_WORKSPACE_DIR if command[0] == "cargo" else repo_root
        location = f"[{RUST_WORKSPACE_DIR}] " if cwd != repo_root else ""
        print("+ " + location + " ".join(command), flush=True)
        subprocess.run(command, cwd=cwd, env=os.environ.copy(), check=True)
    if skip_windows:
        raise PlanError(
            "the windows lane is not runnable on this host "
            f"({platform.system() or 'unknown'}): it builds and tests "
            f"{WINDOWS_SOLUTION} with the .NET SDK on Windows 11 x64; run "
            "`--run-local` on a Windows host (the hosted windows-clientkit job "
            "runs it in CI)"
        )


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
    # Hosted runs only: the newest main commit Swift CI passed on. A push to
    # main plans from it; empty means the workflow could not tell, which
    # selects every lane on main. Agent branches ignore it.
    parser.add_argument("--main-last-success")
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
            plan = plan_from_event(
                repo_root, event, last_success=arguments.main_last_success or None
            )
        else:
            if arguments.main_last_success is not None:
                raise PlanError("--main-last-success is only valid with --event")
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
