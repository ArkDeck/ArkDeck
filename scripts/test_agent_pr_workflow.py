#!/usr/bin/env python3
"""Closed contract for automatic Agent PR and compiled CI workflows.

The test parser intentionally accepts only the reviewed ``on.push.branches``
shape. It uses the Python standard library and performs no network, subprocess,
shell, or repository mutation.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
WORKFLOW_PATH = REPOSITORY_ROOT / ".github" / "workflows" / "agent-pr.yml"
SDD_WORKFLOW_PATH = REPOSITORY_ROOT / ".github" / "workflows" / "sdd-guard.yml"
SWIFT_WORKFLOW_PATH = REPOSITORY_ROOT / ".github" / "workflows" / "swift-ci.yml"
RUST_WORKFLOW_PATH = REPOSITORY_ROOT / ".github" / "workflows" / "rust-ci.yml"
RELEASE_RC_WORKFLOW_PATH = REPOSITORY_ROOT / ".github" / "workflows" / "release-rc.yml"
SWIFTPM_CACHE_KEY = (
    "          key: arkdeck-swiftpm-v2-${{ runner.os }}-${{ runner.arch }}-xcode-27.0"
    "-image-${{ steps.runner-image.outputs.version }}"
    "-${{ hashFiles('Packages/ArkDeckKit/Package.swift') }}-${{ github.sha }}\n"
)
RUST_POLICY_TOOLS_CACHE_KEY = (
    "arkdeck-cargo-policy-tools-v1-${{ runner.os }}-${{ runner.arch }}"
    "-cargo-deny-0.20.2-cargo-vet-0.10.2-${{ hashFiles('rust/rust-toolchain.toml') }}"
)
ARKFORGE_AUTH_PATH = REPOSITORY_ROOT / "scripts" / "ci" / "arkforge-package-auth.sh"
ARKFORGE_CARGO_FETCH_PATH = REPOSITORY_ROOT / "scripts" / "ci" / "arkforge-cargo-fetch.sh"
EXPECTED_PATTERNS = ("agent/**", "!agent/host-loop/**")
EXPECTED_PUSH_FLOW = '    branches: [main, "agent/**"]'

TASK_ID_TEXT = r"TASK-[A-Z0-9]+-[A-Z0-9]+(?:-[A-Z0-9]+)*"
UUID4_TEXT = (
    r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12}"
)
RESERVED_BRANCH_RE = re.compile(
    rf"\Aagent/host-loop/(?:"
    rf"tasks/(?P<task>{TASK_ID_TEXT})|"
    rf"leases/(?P<lease>{TASK_ID_TEXT})|"
    rf"probes/(?P<probe>{UUID4_TEXT})"
    rf")\Z"
)


class WorkflowContractError(ValueError):
    """The workflow event filter is outside the reviewed contract."""


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _meaningful_lines(text: str) -> list[tuple[int, str]]:
    if "\r" in text:
        raise WorkflowContractError("workflow must use LF line endings")
    if "\t" in text:
        raise WorkflowContractError("workflow indentation must not contain tabs")
    if "\x00" in text:
        raise WorkflowContractError("workflow must not contain NUL")

    result: list[tuple[int, str]] = []
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if _indent(line) % 2:
            raise WorkflowContractError(
                f"line {number}: indentation must use two-space levels"
            )
        result.append((number, line))
    return result


def _closed_child_block(
    lines: list[tuple[int, str]],
    parent_index: int,
    parent_indent: int,
) -> tuple[int, int]:
    start = parent_index + 1
    end = len(lines)
    for index in range(start, len(lines)):
        indent = _indent(lines[index][1])
        if indent <= parent_indent:
            end = index
            break
    if start == end:
        number = lines[parent_index][0]
        raise WorkflowContractError(f"line {number}: mapping is empty")
    for number, line in lines[start:end]:
        if _indent(line) <= parent_indent:
            raise WorkflowContractError(f"line {number}: invalid child indentation")
    return start, end


def extract_push_branches(text: str) -> tuple[str, ...]:
    """Extract the one permitted ``on.push.branches`` block."""

    lines = _meaningful_lines(text)
    on_indexes = [
        index for index, (_, line) in enumerate(lines) if line == "on:"
    ]
    if len(on_indexes) != 1:
        raise WorkflowContractError(
            f"expected exactly one top-level on block, found {len(on_indexes)}"
        )

    on_index = on_indexes[0]
    on_start, on_end = _closed_child_block(lines, on_index, 0)
    event_indexes: list[int] = []
    for index in range(on_start, on_end):
        number, line = lines[index]
        if _indent(line) != 2:
            continue
        if line != "  push:":
            raise WorkflowContractError(
                f"line {number}: unknown or non-canonical event entry"
            )
        event_indexes.append(index)
    if len(event_indexes) != 1:
        raise WorkflowContractError(
            f"expected exactly one push event, found {len(event_indexes)}"
        )

    push_index = event_indexes[0]
    push_start, push_end = _closed_child_block(lines, push_index, 2)
    filter_indexes: list[int] = []
    for index in range(push_start, push_end):
        number, line = lines[index]
        if _indent(line) != 4:
            continue
        if line != "    branches:":
            raise WorkflowContractError(
                f"line {number}: unknown or non-canonical push filter"
            )
        filter_indexes.append(index)
    if len(filter_indexes) != 1:
        raise WorkflowContractError(
            f"expected exactly one branches filter, found {len(filter_indexes)}"
        )

    branches_index = filter_indexes[0]
    branches_start, branches_end = _closed_child_block(lines, branches_index, 4)
    item_re = re.compile(r'^      - ("(?:[^"\\]|\\.)*")$')
    patterns: list[str] = []
    for number, line in lines[branches_start:branches_end]:
        match = item_re.fullmatch(line)
        if match is None:
            raise WorkflowContractError(
                f"line {number}: branch pattern must be a double-quoted scalar"
            )
        try:
            value = json.loads(match.group(1))
        except json.JSONDecodeError as error:
            raise WorkflowContractError(
                f"line {number}: invalid quoted branch pattern"
            ) from error
        if not isinstance(value, str) or not value:
            raise WorkflowContractError(
                f"line {number}: branch pattern must be a non-empty string"
            )
        patterns.append(value)
    return tuple(patterns)


def validate_agent_pr_filter(text: str) -> tuple[str, ...]:
    patterns = extract_push_branches(text)
    if patterns != EXPECTED_PATTERNS:
        raise WorkflowContractError(
            "on.push.branches must equal the reviewed include/exclude sequence"
        )
    return patterns


def extract_event_names(text: str) -> tuple[str, ...]:
    lines = _meaningful_lines(text)
    on_indexes = [index for index, (_, line) in enumerate(lines) if line == "on:"]
    if len(on_indexes) != 1:
        raise WorkflowContractError(
            f"expected exactly one top-level on block, found {len(on_indexes)}"
        )
    start, end = _closed_child_block(lines, on_indexes[0], 0)
    event_re = re.compile(r"^  ([a-z_]+):$")
    events: list[str] = []
    for number, line in lines[start:end]:
        if _indent(line) != 2:
            continue
        match = event_re.fullmatch(line)
        if match is None:
            raise WorkflowContractError(f"line {number}: invalid event entry")
        events.append(match.group(1))
    return tuple(events)


def extract_pull_request_types(text: str) -> tuple[str, ...]:
    lines = _meaningful_lines(text)
    event_indexes = [
        index for index, (_, line) in enumerate(lines) if line == "  pull_request:"
    ]
    if len(event_indexes) != 1:
        raise WorkflowContractError(
            f"expected exactly one pull_request event, found {len(event_indexes)}"
        )
    start, end = _closed_child_block(lines, event_indexes[0], 2)
    entries = [
        (number, line)
        for number, line in lines[start:end]
        if _indent(line) == 4
    ]
    if len(entries) != 1:
        raise WorkflowContractError("pull_request event must contain exactly one types entry")
    number, line = entries[0]
    match = re.fullmatch(r"    types: \[([a-z_]+(?:, [a-z_]+)*)\]", line)
    if match is None:
        raise WorkflowContractError(f"line {number}: invalid pull_request types")
    return tuple(match.group(1).split(", "))


def extract_job_names(text: str) -> tuple[str, ...]:
    """Top-level job names in order; the jobs mapping must be canonical."""
    lines = _meaningful_lines(text)
    jobs_indexes = [index for index, (_, line) in enumerate(lines) if line == "jobs:"]
    if len(jobs_indexes) != 1:
        raise WorkflowContractError(
            f"expected exactly one top-level jobs block, found {len(jobs_indexes)}"
        )
    start, end = _closed_child_block(lines, jobs_indexes[0], 0)
    name_re = re.compile(r"^  ([a-z][a-z0-9-]*):$")
    names: list[str] = []
    for number, line in lines[start:end]:
        if _indent(line) != 2:
            continue
        match = name_re.fullmatch(line)
        if match is None:
            raise WorkflowContractError(f"line {number}: invalid job entry")
        names.append(match.group(1))
    return tuple(names)


def _job_block(text: str, job_name: str) -> str:
    raw_lines = text.splitlines()
    indexes = [
        index for index, line in enumerate(raw_lines) if line == f"  {job_name}:"
    ]
    if len(indexes) != 1:
        raise WorkflowContractError(
            f"expected exactly one {job_name} job, found {len(indexes)}"
        )
    start = indexes[0]
    end = len(raw_lines)
    for index in range(start + 1, len(raw_lines)):
        line = raw_lines[index]
        if line and not line.startswith(" ") and not line.startswith("#"):
            end = index
            break
        if line.startswith("  ") and not line.startswith("    ") and line.endswith(":"):
            end = index
            break
    return "\n".join(raw_lines[start:end]) + "\n"


def validate_automatic_check_contract(
    agent_text: str, sdd_text: str, swift_text: str
) -> None:
    validate_agent_pr_filter(agent_text)
    if agent_text.count("permissions: {}") != 1:
        raise WorkflowContractError("Agent PR must deny permissions at workflow scope")
    open_job = _job_block(agent_text, "open-pr")
    if extract_job_names(agent_text) != ("open-pr",):
        raise WorkflowContractError(
            "Agent PR must declare exactly one job, open-pr; the allowed-paths "
            "job was retired by CHG-2026-077"
        )
    required_open = (
        "    permissions:\n      contents: read\n      pull-requests: write\n",
        "    outputs:\n      pr-number: ${{ steps.validate.outputs.pr-number }}\n",
        "          fetch-depth: 0\n",
        "python scripts/agent_pr_identity.py",
        '--commit-task "$HEAD_SHA"',
        'none|TASK-*)',
        'if [ "$TASK_ID" != "none" ]; then',
        "printf 'Task: %s\\n\\n' \"$TASK_ID\" >> \"$BODY\"",
        "gh api --method GET --paginate --slurp",
        "--pull-list \"$CANDIDATES\"",
        "--allow-zero",
        "--pull-request \"$PULL_REQUEST\"",
        "--expected-head-oid \"$HEAD_SHA\"",
        "--expected-author 'github-actions[bot]'",
        'if [ "$VALIDATED_NUMBER" != "$PR_NUMBER" ]; then',
        'echo "pr-number=$VALIDATED_NUMBER" >> "$GITHUB_OUTPUT"',
    )
    for token in required_open:
        if token not in open_job:
            raise WorkflowContractError(f"open-pr job missing contract token: {token}")
    task_read_index = open_job.index("--commit-task")
    task_body_index = open_job.index("printf 'Task: %s\\n\\n'")
    create_index = open_job.index("--body-file")
    if not task_read_index < task_body_index < create_index:
        raise WorkflowContractError(
            "Agent PR must read the commit Task and write it before creating the PR"
        )
    if open_job.rindex("--allow-zero") > create_index:
        raise WorkflowContractError(
            "Agent PR may tolerate zero candidates only before creating the PR"
        )
    # The PR allowed-paths guard was retired by CHG-2026-077. Its names must
    # not come back into either workflow without this contract being rewritten
    # on purpose.
    for retired in (
        "check_pr_paths",
        "automation_config",
        "--preflight",
        "--infer-task",
        "--allow-bootstrap",
        "Scope-Extension",
    ):
        if retired in agent_text or retired in sdd_text:
            raise WorkflowContractError(f"retired path-guard token present: {retired}")
    if "  allowed-paths:\n" in sdd_text:
        raise WorkflowContractError("SDD Guard must not declare an allowed-paths job")
    if "python3 scripts/test_agent_pr_identity.py" not in _job_block(sdd_text, "guard"):
        raise WorkflowContractError(
            "SDD Guard must run the Agent PR identity helper contract tests"
        )

    allowed_swift_secret = "${{ secrets.ARKFORGE_DEPLOY_KEY }}"
    if swift_text.count(allowed_swift_secret) != 1:
        raise WorkflowContractError(
            "Swift CI must expose the ArkForge deploy key only to the Rust lane's locked fetch"
        )
    if _job_block(swift_text, "rust-checks").count(RUST_CHECKS_SECRET) != 1:
        raise WorkflowContractError(
            "the Rust lane must receive the ArkForge deploy key by name, and nothing else"
        )
    capability_text = agent_text + sdd_text + swift_text.replace(allowed_swift_secret, "")
    forbidden = (
        "pull_request_target:",
        "secrets.",
        "secrets[",
        "id-token: write",
        "contents: write",
        "actions: write",
        "checks: write",
        "statuses: write",
        "workflows: write",
        "administration: write",
    )
    for token in forbidden:
        if token in capability_text:
            raise WorkflowContractError(f"forbidden workflow capability: {token}")

    if extract_event_names(sdd_text) != ("push", "pull_request"):
        raise WorkflowContractError("SDD Guard event set must be push + pull_request")
    if EXPECTED_PUSH_FLOW not in sdd_text:
        raise WorkflowContractError("SDD Guard push branches drifted")
    if extract_pull_request_types(sdd_text) != ("reopened", "edited"):
        raise WorkflowContractError(
            "SDD Guard pull_request types must be reopened + edited"
        )
    if extract_event_names(swift_text) != ("push",):
        raise WorkflowContractError("Swift CI must be push-only")
    if EXPECTED_PUSH_FLOW not in swift_text:
        raise WorkflowContractError("Swift CI push branches drifted")
    if "\n    paths:" in swift_text or "\n    paths-ignore:" in swift_text:
        raise WorkflowContractError(
            "Swift CI must report its stable check instead of skipping the workflow"
        )
    if (
        "concurrency:\n  group: swift-ci-${{ github.ref }}\n"
        "  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}\n"
    ) not in swift_text:
        raise WorkflowContractError(
            "Swift CI must cancel superseded branch runs and finish every main run"
        )

    plan_job = _job_block(swift_text, "plan")
    swift_tests_job = _job_block(swift_text, "swift-tests")
    app_build_job = _job_block(swift_text, "app-build")
    ds_job = _job_block(swift_text, "ds-interactions")
    rust_job = _job_block(swift_text, "rust-checks")
    windows_job = _job_block(swift_text, "windows-clientkit")
    swift_aggregate_job = _job_block(swift_text, "swift")
    for job_name, job_block in (
        ("Swift test", swift_tests_job),
        ("App build", app_build_job),
    ):
        job_header, separator, _ = job_block.partition("    steps:\n")
        if not separator:
            raise WorkflowContractError(f"{job_name} job has no steps block")
        if "${{ runner." in job_header:
            raise WorkflowContractError(
                f"{job_name} job-level fields cannot use the step-only runner context"
            )
    if not swift_aggregate_job.startswith("  swift:\n    if: always()\n"):
        raise WorkflowContractError("Swift aggregate job must run after every lane result")
    for job_name, job_block in (
        ("plan", plan_job), ("swift-tests", swift_tests_job),
        ("app-build", app_build_job), ("ds-interactions", ds_job),
        ("windows-clientkit", windows_job),
    ):
        for required in (
            "ARKDECK_CI_SHA: ${{ github.sha }}",
            '"+${ARKDECK_CI_SHA}:refs/remotes/origin/ci"',
            'git checkout --detach refs/remotes/origin/ci',
            'test "$(git rev-parse HEAD)" = "$ARKDECK_CI_SHA"',
        ):
            if required not in job_block:
                raise WorkflowContractError(f"{job_name} must fetch and assert the event SHA: {required}")
        if "ARKDECK_CI_REF" in job_block:
            raise WorkflowContractError(f"{job_name} must not fetch a moving event ref")

    required_plan = (
        "    runs-on: ubuntu-latest\n",
        '"+refs/heads/main:refs/remotes/origin/main"',
        '"+${ARKDECK_CI_SHA}:refs/remotes/origin/ci"',
        "python3 scripts/ci/test_plan.py",
        "python3 scripts/ci/test_event_checkout.py",
        "python3 scripts/test_agent_pr_workflow.py",
        "python3 scripts/ci/plan.py",
        '--event "$GITHUB_EVENT_PATH"',
        '--github-output "$GITHUB_OUTPUT"',
        "      rust: ${{ steps.paths.outputs.rust }}\n",
        "      windows: ${{ steps.paths.outputs.windows }}\n",
        # A main run plans from the newest main commit this workflow passed on.
        # Only a successful run counts: a red or replaced one leaves its
        # changes to the next run. The job may read runs and nothing more.
        "    permissions:\n      contents: read\n      actions: read\n",
        "      - name: Find the last main commit Swift CI passed on\n"
        "        id: last-success\n"
        "        if: github.ref == 'refs/heads/main'\n",
        "actions/workflows/swift-ci.yml/runs?branch=main&event=push&status=success&per_page=1",
        "ARKDECK_MAIN_LAST_SUCCESS: ${{ steps.last-success.outputs.oid }}",
        '--main-last-success "$ARKDECK_MAIN_LAST_SUCCESS"',
    )
    required_swift_tests = (
        "    needs: plan\n",
        "    if: needs.plan.outputs.swift == 'true'\n",
        "    runs-on: xcode-27\n",
        "DEVELOPER_DIR: /Applications/Xcode_27.0.app/Contents/Developer",
        "ARKDECK_SWIFTPM_CACHE_ROOT: ${{ runner.temp }}/arkdeck-swiftpm",
        "python3 Packages/ArkDeckKit/Scripts/test_run_swiftpm.py",
        # The SwiftPM cache is keyed by runner image build: a C compile is
        # invalidated by SDK inputs that differ between image builds, so a
        # cross-image restore recompiles every C unit. Restore order is exact
        # inputs, newest same-image entry, then any same-toolchain entry, and
        # the version comes from a step because the runner exports it to the
        # process environment, not to the workflow env context.
        "      - name: Record the runner image build\n"
        "        id: runner-image\n",
        "printf 'version=%s\\n' \"${ImageVersion:-unknown}\" >> \"$GITHUB_OUTPUT\"",
        "actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
        SWIFTPM_CACHE_KEY,
        "          restore-keys: |\n"
        "            arkdeck-swiftpm-v2-${{ runner.os }}-${{ runner.arch }}-xcode-27.0-"
        "image-${{ steps.runner-image.outputs.version }}-"
        "${{ hashFiles('Packages/ArkDeckKit/Package.swift') }}-\n"
        "            arkdeck-swiftpm-v2-${{ runner.os }}-${{ runner.arch }}-xcode-27.0-"
        "image-${{ steps.runner-image.outputs.version }}-\n"
        "            arkdeck-swiftpm-v2-${{ runner.os }}-${{ runner.arch }}-xcode-27.0-\n",
        "sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh",
        "--num-workers 8",
        "        if: >-\n"
        "          success() &&\n"
        "          github.ref == 'refs/heads/main' &&\n"
        "          steps.swift-build-cache.outputs.cache-hit != 'true'\n",
        "actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
    )
    required_app_build = (
        "    needs: plan\n",
        "    if: needs.plan.outputs.app == 'true'\n",
        "    runs-on: xcode-27\n",
        "ARKDECK_XCODE_CACHE_ROOT: ${{ runner.temp }}/arkdeck-xcode",
        "python3 scripts/ci/test_run_xcodebuild.py",
        "actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
        "          restore-keys: |\n"
        "            arkdeck-xcode-v2-${{ runner.os }}-${{ runner.arch }}-xcode-27.0-"
        "${{ hashFiles('ArkDeck.xcodeproj/project.pbxproj', 'Packages/ArkDeckKit/Package.swift', 'Packages/ArkDeckKit/Package.resolved') }}-\n"
        "            arkdeck-xcode-v2-${{ runner.os }}-${{ runner.arch }}-xcode-27.0-\n",
        "sh scripts/ci/run-xcodebuild.sh",
        "        if: >-\n"
        "          success() &&\n"
        "          github.ref == 'refs/heads/main' &&\n"
        "          steps.app-build-cache.outputs.cache-hit != 'true'\n",
        "actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
    )
    # npm ci is load-bearing: node_modules is not committed, and without the
    # install the interaction files that import esbuild/react die on
    # ERR_MODULE_NOT_FOUND while the node:-only files still pass — a
    # misleading partial pass, so the exact install is pinned before the run.
    required_ds = (
        "    needs: plan\n",
        "    if: needs.plan.outputs.ds == 'true'\n",
        "    runs-on: ubuntu-latest\n",
        "        working-directory: docs/design/arkdeck-ds\n"
        "        run: npm ci\n",
        "        working-directory: docs/design/arkdeck-ds\n"
        "        run: npm test\n",
    )
    required_aggregate = (
        "    needs: [plan, swift-tests, app-build, ds-interactions, rust-checks, windows-clientkit]\n",
        "PLAN_RESULT: ${{ needs.plan.result }}",
        "SWIFT_RESULT: ${{ needs.swift-tests.result }}",
        "APP_RESULT: ${{ needs.app-build.result }}",
        "DS_RESULT: ${{ needs.ds-interactions.result }}",
        "RUST_SELECTED: ${{ needs.plan.outputs.rust }}",
        "RUST_RESULT: ${{ needs.rust-checks.result }}",
        'test "$PLAN_RESULT" = success',
        'test "$SWIFT_RESULT" = success',
        'test "$APP_RESULT" = success',
        'test "$DS_RESULT" = success',
        '          if [ "$RUST_SELECTED" = true ]; then\n'
        '            test "$RUST_RESULT" = success\n'
        '          else\n'
        '            test "$RUST_RESULT" = skipped\n'
        '          fi\n',
        "WINDOWS_SELECTED: ${{ needs.plan.outputs.windows }}",
        "WINDOWS_RESULT: ${{ needs.windows-clientkit.result }}",
        '          if [ "$WINDOWS_SELECTED" = true ]; then\n'
        '            test "$WINDOWS_RESULT" = success\n'
        '          else\n'
        '            test "$WINDOWS_RESULT" = skipped\n'
        '          fi\n',
    )
    # TASK-XPA-007: the Windows client lane. Exact repository bytes (the
    # generator checks, embedded schema digests and corpus wire tests compare
    # them), the SDK global.json pins, then the three generator checks (ClientKit
    # bindings, App strings, App tokens), build and tests.
    required_windows = (
        "    needs: plan\n",
        "    if: needs.plan.outputs.windows == 'true'\n",
        "    runs-on: windows-latest\n",
        "          git config core.autocrlf false\n",
        "        uses: actions/setup-dotnet@a98b56852c35b8e3190ac28c8c2271da59106c68 # v6.0.0 (Node 24)\n"
        "        with:\n"
        "          global-json-file: windows/global.json\n",
        "        run: python windows/scripts/generate-clientkit.py --check\n",
        "        run: python windows/scripts/generate-ui-strings.py --check\n",
        "        run: python windows/scripts/generate-xaml-tokens.py --check\n",
        "        run: dotnet build windows/ArkDeck.Windows.slnx -c Release\n",
        "        run: dotnet test windows/ArkDeck.Windows.slnx -c Release --no-build\n",
    )
    required_rust = (
        "    needs: plan\n",
        "    if: needs.plan.outputs.rust == 'true'\n",
        "    uses: ./.github/workflows/rust-ci.yml\n",
        RUST_CHECKS_SECRET,
    )
    for token in required_plan:
        if token not in plan_job:
            raise WorkflowContractError(f"Swift plan job missing contract token: {token}")
    if plan_job.index("        id: last-success\n") > plan_job.index("        id: paths\n"):
        raise WorkflowContractError(
            "Swift plan job must look up the last main success before it plans"
        )
    for token in required_swift_tests:
        if token not in swift_tests_job:
            raise WorkflowContractError(
                f"Swift test job missing contract token: {token}"
            )
    if swift_tests_job.count(SWIFTPM_CACHE_KEY) != 2:
        raise WorkflowContractError(
            "Swift test job must restore and save the SwiftPM cache under one exact key"
        )
    if swift_tests_job.index("        id: runner-image\n") > swift_tests_job.index(
        "        id: swift-build-cache\n"
    ):
        raise WorkflowContractError(
            "Swift test job must record the runner image build before restoring the cache"
        )
    for token in required_app_build:
        if token not in app_build_job:
            raise WorkflowContractError(
                f"App build job missing contract token: {token}"
            )
    for token in required_ds:
        if token not in ds_job:
            raise WorkflowContractError(
                f"ds interaction job missing contract token: {token}"
            )
    if ds_job.index("run: npm ci") > ds_job.index("run: npm test"):
        raise WorkflowContractError(
            "ds interaction job must install exact dependencies before testing"
        )
    for token in required_rust:
        if token not in rust_job:
            raise WorkflowContractError(f"Rust job missing contract token: {token}")
    for token in required_windows:
        if token not in windows_job:
            raise WorkflowContractError(f"Windows ClientKit job missing contract token: {token}")
    windows_order = [
        windows_job.index(token)
        for token in (
            "git config core.autocrlf false",
            "uses: actions/setup-dotnet@",
            "generate-clientkit.py --check",
            "generate-ui-strings.py --check",
            "generate-xaml-tokens.py --check",
            "dotnet build windows/ArkDeck.Windows.slnx",
            "dotnet test windows/ArkDeck.Windows.slnx",
        )
    ]
    if windows_order != sorted(windows_order):
        raise WorkflowContractError(
            "Windows ClientKit job must keep bytes, pin the SDK, check the generators, build, then test"
        )
    for token in required_aggregate:
        if token not in swift_aggregate_job:
            raise WorkflowContractError(
                f"Swift aggregate job missing contract token: {token}"
            )


RUST_CI_JOBS = ("policy", "workspace", "contracts")
# The Rust lane receives exactly one secret, the read-only ArkForge deploy key,
# by name. Each job hands it to its locked fetch alone: the wrapper keeps the
# key and the SSH rewrite of github.com out of GITHUB_ENV and removes the key
# before any later step builds or runs checked-out code.
RUST_CHECKS_SECRET = (
    "    secrets:\n"
    "      ARKFORGE_DEPLOY_KEY: ${{ secrets.ARKFORGE_DEPLOY_KEY }}\n"
)
RUST_FETCH_SECRET = "${{ secrets.ARKFORGE_DEPLOY_KEY }}"
RUST_FETCH_RUN = "run: sh ../scripts/ci/arkforge-cargo-fetch.sh"
RUST_FETCH_STEP = (
    "      - name: Fetch the locked dependency graph for all host platforms\n"
    "        env:\n"
    "          ARKFORGE_DEPLOY_KEY: ${{ secrets.ARKFORGE_DEPLOY_KEY }}\n"
    "        run: sh ../scripts/ci/arkforge-cargo-fetch.sh\n"
)
RUST_SECRET_DECLARATION = (
    "on:\n"
    "  workflow_call:\n"
    "    secrets:\n"
    "      ARKFORGE_DEPLOY_KEY:\n"
    "        required: true\n"
)
# Every job checks out, sets up and fetches the same way: every contract digest
# is over repository bytes on every host.
RUST_SHARED_JOB_TOKENS = (
    "        shell: bash\n        working-directory: rust\n",
    "git config core.autocrlf false",
    '"+refs/heads/main:refs/remotes/origin/main"',
    '"+${ARKDECK_CI_SHA}:refs/remotes/origin/ci"',
    'test "$(git rev-parse HEAD)" = "$ARKDECK_CI_SHA"',
    "actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97",
    '          python-version: "3.14"\n',
    "run: python -m pip install PyYAML==6.0.3 jsonschema==4.26.0",
    "rustup toolchain install --profile minimal --component rustfmt,clippy --no-self-update",
    "rustup show active-toolchain",
    RUST_FETCH_STEP,
)
# Answers that cannot depend on the host: each runs exactly once, in `policy`.
RUST_POLICY_TOKENS = (
    "run: python rust/scripts/test_ci_execution.py\n",
    "run: python rust/scripts/generate-contract.py --check",
    "run: cargo fmt --all --check",
    "        working-directory: .\n"
    "        run: python rust/scripts/test_contract_checks.py\n",
    # One ArkForge revision, and ArkForge's own wire and StepPermit vectors
    # rerun at it.
    "        working-directory: .\n"
    "        run: python rust/scripts/check-arkforge-pin.py --run-vectors\n",
    # cargo-deny and cargo-vet are memoized between hosted runs. The memo
    # must stay exact (one key naming both pinned versions and the pinned
    # toolchain, no prefix fallback), be written only by protected main,
    # and be read back against the pinned versions before either policy
    # check runs, so a restored binary never stands in for the `--locked`
    # install it replaces.
    "      - name: Restore pinned dependency policy tools\n"
    "        id: policy-tools\n"
    "        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
    "      - name: Install pinned dependency policy tools\n"
    "        id: policy-install\n",
    "run: python rust/scripts/ci-policy-tools.py\n",
    "        if: success() && github.ref == 'refs/heads/main' && steps.policy-install.outputs.publish-vet == 'true'\n",
    "          name: cargo-vet-linux-x64-0.10.2-v1\n",
    "      - name: Require the pinned dependency policy tool versions\n"
    "        run: |\n",
    "test \"$(cargo deny --version | tr -d '\\r')\" = \"cargo-deny 0.20.2\"",
    "test \"$(cargo vet --version | tr -d '\\r')\" = \"cargo-vet 0.10.2\"",
    "      - name: Save pinned dependency policy tools\n"
    "        if: >-\n"
    "          success() &&\n"
    "          github.ref == 'refs/heads/main' &&\n"
    "          steps.policy-tools.outputs.cache-hit != 'true'\n"
    "        uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
    "run: cargo deny --locked check",
    "run: cargo vet --locked --no-registry-suggestions",
    "run: git diff --exit-code -- Cargo.lock supply-chain",
)
# The two host matrices, `workspace` and `contracts`, each carry these once:
# the same policy gate (and only it, so neither waits for the other), hosts,
# worker count and cache discipline.
RUST_NATIVE_JOB_TOKENS = (
    "    needs: policy\n",
    "      fail-fast: false\n",
    "        os: [ubuntu-latest, xcode-27, windows-latest]\n",
    "    runs-on: ${{ matrix.os }}\n",
    "    timeout-minutes: ${{ startsWith(matrix.os, 'xcode') && 50 || 30 }}\n",
    "      ARKDECK_RUST_TEST_WORKERS: ${{ startsWith(matrix.os, 'xcode') && '2' || '1' }}\n",
    # Incremental state is never reused across jobs (compact deletes it before
    # a save), so writing it is pure cost; the value is in the cache key.
    '      CARGO_INCREMENTAL: "0"\n',
    "run: python rust/scripts/ci-workspace.py key\n",
    "run: python rust/scripts/ci-workspace.py prepare\n",
    "run: python rust/scripts/ci-workspace.py compact\n",
)
# Answers that can differ between hosts: each runs exactly once per host, in
# the `workspace` matrix.
RUST_WORKSPACE_TOKENS = (
    # Each native job owns its cache root; the root is part of the cache key,
    # so the two jobs never restore, carry or save each other's products.
    'echo "ARKDECK_RUST_CACHE_ROOT=$RUNNER_TEMP/arkdeck-rust-workspace" >> "$GITHUB_ENV"',
    'echo "ARKDECK_RUST_TEST_REPORT_DIR=$RUNNER_TEMP/rust-test-timings" >> "$GITHUB_ENV"',
    # Only these two steps compile and run the checkout. Every contract
    # step either reads Git objects at the pinned Swift commit or builds a
    # separate candidate view, so dropping either one lets a workspace
    # that does not build, or whose tests fail, pass a green rust lane.
    # The workspace tests run through a wrapper that keeps the pin's
    # currency and the Rust code's correctness as separate questions;
    # calling `cargo test --workspace` directly here fails every branch
    # that legitimately changes a recorded frame.
    "run: python rust/scripts/ci-workspace.py --cwd rust exec -- cargo clippy --workspace --all-targets -- -D warnings\n",
    "        working-directory: .\n"
    "        run: python rust/scripts/ci-workspace.py exec -- python rust/scripts/workspace-tests.py\n",
)
# The published and candidate contract views: once per host, in the
# `contracts` matrix beside `workspace`, since they read none of its products.
RUST_CONTRACTS_TOKENS = (
    'echo "ARKDECK_RUST_CACHE_ROOT=$RUNNER_TEMP/arkdeck-rust-contracts" >> "$GITHUB_ENV"',
    'echo "ARKDECK_RUST_TEST_REPORT_DIR=$RUNNER_TEMP/rust-contract-test-timings" >> "$GITHUB_ENV"',
    "        working-directory: .\n"
    '        run: python rust/scripts/ci-workspace.py exec -- python rust/scripts/check-contracts.py --output-dir "$GITHUB_WORKSPACE/rust/target/readonly-check"\n',
    "      - name: Preserve actual read-only recordings\n"
    "        if: always()\n"
    "        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1 (Node 24)\n"
    "        with:\n"
    "          name: rust-readonly-recordings-${{ matrix.os }}\n"
    "          path: rust/target/readonly-check/\n"
    "          if-no-files-found: warn\n"
    "          retention-days: 7\n",
)


def validate_rust_ci_contract(text: str) -> None:
    """Require native host checks and fail-closed locked dependency audits.

    The checks whose answer cannot depend on the host run once, in `policy`.
    Lint and the workspace tests run on every host, in the `workspace` matrix;
    the contract views run on every host beside them, in the `contracts`
    matrix. The swift aggregate requires all three through the calling job's
    result.
    """

    if extract_event_names(text) != ("workflow_call",):
        raise WorkflowContractError("Rust CI must be called through the shared planner")
    if "permissions:\n  contents: read\n" not in text:
        raise WorkflowContractError("Rust CI must be limited to reading contents")
    if extract_job_names(text) != RUST_CI_JOBS:
        raise WorkflowContractError(
            "Rust CI must run its host-independent checks in `policy`, its "
            "workspace checks in the `workspace` matrix and its contract views "
            "in the `contracts` matrix"
        )
    policy = _job_block(text, "policy")
    workspace = _job_block(text, "workspace")
    contracts = _job_block(text, "contracts")
    if "    runs-on: ubuntu-latest\n" not in policy or "matrix" in policy:
        raise WorkflowContractError("Rust policy checks must run once, on one fixed host")
    for name, block in (("workspace", workspace), ("contracts", contracts)):
        for token in RUST_NATIVE_JOB_TOKENS:
            if block.count(token) != 1 or text.count(token) != 2:
                raise WorkflowContractError(
                    f"Rust {name} matrix must carry this exactly once: {token}"
                )
    for name, block in (("policy", policy), ("workspace", workspace), ("contracts", contracts)):
        for token in RUST_SHARED_JOB_TOKENS:
            if token not in block:
                raise WorkflowContractError(f"Rust {name} job missing contract token: {token}")
    for name, block, tokens in (
        ("policy", policy, RUST_POLICY_TOKENS),
        ("workspace", workspace, RUST_WORKSPACE_TOKENS),
        ("contracts", contracts, RUST_CONTRACTS_TOKENS),
    ):
        for token in tokens:
            if token not in block:
                raise WorkflowContractError(f"Rust {name} job missing contract token: {token}")
            if text.count(token) != 1:
                raise WorkflowContractError(
                    f"Rust CI must run this check exactly once, in the {name} job: {token}"
                )
    if RUST_SECRET_DECLARATION not in text:
        raise WorkflowContractError(
            "Rust CI must declare the ArkForge deploy key as its one required secret"
        )
    if (
        text.count(RUST_FETCH_SECRET) != 3
        or text.count(RUST_FETCH_STEP) != 3
        or policy.count(RUST_FETCH_STEP) != 1
        or workspace.count(RUST_FETCH_STEP) != 1
        or contracts.count(RUST_FETCH_STEP) != 1
    ):
        raise WorkflowContractError(
            "Rust CI must hand the ArkForge deploy key to each job's locked fetch and "
            "to no other step"
        )
    for token in (
        "continue-on-error:", "secrets.", "secrets[", "secrets: inherit",
        "contents: write", "id-token: write", "cargo vet init",
        "cargo vet regenerate", "cargo vet add-exemption", "|| true",
        "--depth=", "--depth ", "arkforge-package-auth.sh",
        "run: cargo fetch",
    ):
        if token in text.replace(RUST_FETCH_SECRET, ""):
            raise WorkflowContractError(f"Rust CI contains forbidden token: {token}")
    if "restore-keys:" in policy:
        raise WorkflowContractError("Policy tool cache must not use prefix fallback")
    cache_key = "          key: ${{ steps.rust-cache-key.outputs.key }}\n"
    prefix = "          restore-keys: ${{ steps.rust-cache-key.outputs.prefix }}\n"
    for block in (workspace, contracts):
        if block.count(cache_key) != 2:
            raise WorkflowContractError("Rust build restore and save must use the same daily compatibility key")
        if block.count("restore-keys:") != 1 or prefix not in block:
            raise WorkflowContractError("Rust build cache fallback must retain every compatibility dimension")
    save_block = (
        "      - name: Save trusted Rust build products\n"
        "        if: >-\n"
        "          success() &&\n"
        "          github.ref == 'refs/heads/main' &&\n"
        "          steps.rust-build-cache.outputs.cache-hit != 'true'\n"
        "        uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
    )
    if workspace.count(save_block) != 1 or contracts.count(save_block) != 1:
        raise WorkflowContractError("Only successful protected main may publish Rust build products")
    if text.count(RUST_POLICY_TOOLS_CACHE_KEY) != 2 or policy.count(RUST_POLICY_TOOLS_CACHE_KEY) != 2:
        raise WorkflowContractError(
            "Rust CI must restore and save the policy tools under one exact key "
            "naming both pinned versions and the pinned toolchain"
        )
    restore = policy.index("      - name: Restore pinned dependency policy tools")
    install = policy.index("      - name: Install pinned dependency policy tools")
    read_back = policy.index("      - name: Require the pinned dependency policy tool versions")
    save = policy.index("      - name: Save pinned dependency policy tools")
    if not (restore < install < read_back < save < policy.index("run: cargo deny --locked check")):
        raise WorkflowContractError(
            "Rust CI must restore, install on a miss, read back the pinned versions "
            "and save before the dependency policy checks"
        )
    if not (
        policy.index(RUST_FETCH_RUN)
        < policy.index("run: python rust/scripts/test_contract_checks.py")
        < policy.index("run: python rust/scripts/check-arkforge-pin.py --run-vectors")
        < policy.index("run: cargo vet --locked")
    ):
        raise WorkflowContractError(
            "Rust CI must fetch locked metadata before it runs checked-out code, "
            "the ArkForge pin check and locked vet"
        )
    if policy.index("rustup toolchain install") > policy.index(
        "run: python rust/scripts/generate-contract.py --check"
    ):
        raise WorkflowContractError("Rust CI must install rustfmt before checking generated inputs")
    order = [
        workspace.index("rustup toolchain install"),
        workspace.index(RUST_FETCH_RUN),
        workspace.index("run: python rust/scripts/ci-workspace.py key"),
        workspace.index("      - name: Restore trusted Rust build products"),
        workspace.index("run: python rust/scripts/ci-workspace.py prepare"),
        workspace.index("run: python rust/scripts/ci-workspace.py --cwd rust exec -- cargo clippy --workspace"),
        workspace.index("run: python rust/scripts/ci-workspace.py exec -- python rust/scripts/workspace-tests.py"),
        workspace.index("run: python rust/scripts/ci-workspace.py compact"),
        workspace.index("      - name: Save trusted Rust build products"),
    ]
    if order != sorted(order):
        raise WorkflowContractError(
            "Rust workspace job must fetch locked metadata before it lints and tests"
        )
    order = [
        contracts.index("rustup toolchain install"),
        contracts.index(RUST_FETCH_RUN),
        contracts.index("run: python rust/scripts/ci-workspace.py key"),
        contracts.index("      - name: Restore trusted Rust build products"),
        contracts.index("run: python rust/scripts/ci-workspace.py prepare"),
        contracts.index("run: python rust/scripts/ci-workspace.py exec -- python rust/scripts/check-contracts.py"),
        contracts.index("run: python rust/scripts/ci-workspace.py compact"),
        contracts.index("      - name: Save trusted Rust build products"),
        contracts.index("      - name: Preserve actual read-only recordings"),
    ]
    if order != sorted(order):
        raise WorkflowContractError(
            "Rust contracts job must fetch locked metadata before it runs the contract "
            "views, and preserve recordings after their producer runs"
        )


def validate_cache_retention_contract(text: str) -> None:
    if extract_event_names(text) != ("workflow_run",):
        raise WorkflowContractError("Cache deletion must be triggered only after a completed workflow")
    if extract_job_names(text) != ("retain-rust",):
        raise WorkflowContractError("Cache retention must have one trusted maintenance job")
    for token in (
        "    workflows: [Swift CI]\n", "    types: [completed]\n",
        "permissions:\n  contents: read\n",
        "      github.event.workflow_run.conclusion == 'success' &&\n",
        "      github.event.workflow_run.event == 'push' &&\n",
        "      github.event.workflow_run.head_branch == 'main' &&\n",
        "      github.event.workflow_run.head_repository.full_name == github.repository\n",
        "    permissions:\n      contents: read\n      actions: write\n",
        "          ARKDECK_CI_SHA: ${{ github.sha }}\n",
        '          git fetch --no-tags origin "$ARKDECK_CI_SHA"\n',
        '          test "$(git rev-parse HEAD)" = "$ARKDECK_CI_SHA"\n',
        "        run: python3 scripts/ci/retain-rust-caches.py --apply\n",
    ):
        if token not in text:
            raise WorkflowContractError(f"Cache retention missing trust boundary: {token}")
    if text.count("actions: write") != 1 or "contents: write" in text:
        raise WorkflowContractError("Only the trusted maintenance job may delete caches")


RELEASE_RC_SECRETS = (
    "ARKDECK_DEVELOPER_ID_P12_BASE64",
    "ARKDECK_DEVELOPER_ID_P12_PASSWORD",
    "ARKDECK_CLI_PROVISIONING_PROFILE_BASE64",
    "ARKDECK_DAEMON_PROVISIONING_PROFILE_BASE64",
    "ARKDECK_NOTARY_API_KEY_P8_BASE64",
    "ARKDECK_NOTARY_API_KEY_ID",
    "ARKDECK_NOTARY_API_ISSUER_ID",
)
RELEASE_RC_INSTALL_STEP = "Install release credentials"
RELEASE_RC_BUILD_STEP = "Build the signed and notarized release candidate"
RELEASE_RC_CLEANUP_STEP = "Remove release credentials"
RELEASE_RC_UPLOAD_STEP = "Keep the release candidate"
RELEASE_RC_BUILDS_ONLY_NEW = "steps.existing.outputs.exists == 'false'"


def _steps(job_text: str) -> list[tuple[str, str]]:
    """(name, text) of each step of a job block, in order; every step is named."""
    lines = job_text.splitlines(keepends=True)
    steps_index = [index for index, line in enumerate(lines) if line == "    steps:\n"]
    if len(steps_index) != 1:
        raise WorkflowContractError("job must have exactly one steps list")
    steps: list[tuple[str, list[str]]] = []
    for line in lines[steps_index[0] + 1:]:
        if line.startswith("      - "):
            match = re.fullmatch(r"      - name: (.+)\n", line)
            if match is None:
                raise WorkflowContractError(f"every step must start with its name: {line!r}")
            steps.append((match.group(1), [line]))
        elif steps:
            steps[-1][1].append(line)
    return [(name, "".join(body)) for name, body in steps]


def validate_release_rc_contract(text: str) -> None:
    """The signed release candidate: main only, credentials in one job.

    The workflow never runs code that has not merged: its only triggers are a
    push to main that changes the release version and a dispatch refused off
    main. Its secrets live in the `release` environment and reach two steps of
    its one job (the credential install and the build); the step after the
    build removes the temporary keychain and credential files whatever
    happened, before anything is uploaded.
    """

    meaningful = "".join(line + "\n" for _, line in _meaningful_lines(text))
    if extract_event_names(text) != ("push", "workflow_dispatch"):
        raise WorkflowContractError(
            "the release candidate runs on a push to main or a dispatch, never on PR code"
        )
    for event in ("pull_request", "pull_request_target", "workflow_run", "workflow_call"):
        if event in meaningful:
            raise WorkflowContractError(f"the release candidate must not run on {event}")
    if (
        "  push:\n"
        "    branches: [main]\n"
        "    paths:\n"
        "      - scripts/release/release-version.json\n"
        "  workflow_dispatch:\n"
    ) not in meaningful:
        raise WorkflowContractError(
            "the release candidate is built when release-version.json changes on main"
        )
    if "permissions:\n  contents: read\n" not in text or re.search(r": write\b", meaningful):
        raise WorkflowContractError("the release candidate workflow must not write to the repository")
    if "concurrency:\n  group: release-rc\n  cancel-in-progress: false\n" not in text:
        raise WorkflowContractError("release candidates must run one at a time and never be cancelled")
    if extract_job_names(text) != ("release-rc",):
        raise WorkflowContractError("the release candidate is one job")
    job = _job_block(text, "release-rc")
    for token in ("    runs-on: xcode-27\n", "    environment: release\n"):
        if token not in job:
            raise WorkflowContractError(f"the release job must carry: {token.strip()}")
    if re.search(r"\bset -[a-z]*x", meaningful) or "set -o xtrace" in meaningful:
        raise WorkflowContractError("the release workflow must never trace its commands")

    steps = _steps(job)
    names = [name for name, _ in steps]
    for name in (RELEASE_RC_INSTALL_STEP, RELEASE_RC_BUILD_STEP, RELEASE_RC_CLEANUP_STEP,
                 RELEASE_RC_UPLOAD_STEP):
        if names.count(name) != 1:
            raise WorkflowContractError(f"the release job must have exactly one step: {name}")
    body = dict(steps)
    first_name, first = steps[0]
    if (
        first_name != "Require protected main"
        or '          if [ "$GITHUB_REF" != refs/heads/main ]; then\n' not in first
        or "            exit 1\n" not in first
        or "        if:" in first
    ):
        raise WorkflowContractError("the release job must first refuse any ref but main")

    referenced = re.findall(r"\$\{\{\s*secrets\.([A-Za-z0-9_]+)\s*\}\}", text)
    if sorted(referenced) != sorted(RELEASE_RC_SECRETS) or "secrets:" in meaningful:
        raise WorkflowContractError(
            "the release job must reference exactly its seven secrets, each once"
        )
    allowed = {RELEASE_RC_INSTALL_STEP, RELEASE_RC_BUILD_STEP}
    for name, step in steps:
        if "secrets." in step and name not in allowed:
            raise WorkflowContractError(f"release secrets must not reach the step: {name}")
    outside = text.replace(body[RELEASE_RC_INSTALL_STEP], "").replace(body[RELEASE_RC_BUILD_STEP], "")
    if "secrets." in outside:
        raise WorkflowContractError("release secrets must be scoped to their two steps")

    install = body[RELEASE_RC_INSTALL_STEP]
    for token in (
        "          umask 077\n",
        "          keychain_password=$(openssl rand -hex 32)\n",
        '          echo "::add-mask::$keychain_password"\n',
        "-T /usr/bin/codesign",
        "security set-key-partition-list",
        '          rm -f "$credentials/developer-id.p12"\n',
        '          security list-keychains -d user -s "${search_list[@]}"\n',
    ):
        if token not in install:
            raise WorkflowContractError(f"credential install must carry: {token.strip()}")
    if install.index("::add-mask::$keychain_password") > install.index("security create-keychain"):
        raise WorkflowContractError("the keychain password must be masked before it is used")
    # A secret is only ever piped into base64 and on into a file.
    for line in install.splitlines():
        if re.search(r"\b(echo|printf)\b", line) and re.search(r"\$\{?ARKDECK_[A-Z0-9_]+", line):
            if not re.fullmatch(
                r"          printf '%s' \"\$ARKDECK_[A-Z0-9_]+_BASE64\" \| base64 --decode > \"\$credentials/[a-z.0-9-]+\"",
                line,
            ):
                raise WorkflowContractError(f"credential install must not print a secret: {line.strip()}")
    build = body[RELEASE_RC_BUILD_STEP]
    if "python3 scripts/release/build_macos_release.py release" not in build or "--arkforge-checkout" not in build:
        raise WorkflowContractError("the release job must build through build_macos_release.py release")

    cleanup = body[RELEASE_RC_CLEANUP_STEP]
    for token in (
        "        if: always()\n",
        '            security delete-keychain "$keychain" || status=1\n',
        '          rm -rf "$credentials" || status=1\n',
    ):
        if token not in cleanup:
            raise WorkflowContractError(f"credential cleanup must carry: {token.strip()}")
    install_at, build_at = names.index(RELEASE_RC_INSTALL_STEP), names.index(RELEASE_RC_BUILD_STEP)
    cleanup_at, upload_at = names.index(RELEASE_RC_CLEANUP_STEP), names.index(RELEASE_RC_UPLOAD_STEP)
    if not install_at < build_at < cleanup_at < upload_at or cleanup_at != build_at + 1:
        raise WorkflowContractError(
            "credential cleanup must follow the build directly and precede the upload"
        )
    for name, step in steps[names.index("Skip a release candidate that already exists") + 1:]:
        if name != RELEASE_RC_CLEANUP_STEP and RELEASE_RC_BUILDS_ONLY_NEW not in step:
            raise WorkflowContractError(f"an existing release candidate must not be rebuilt: {name}")
    upload = body[RELEASE_RC_UPLOAD_STEP]
    for token in (
        "        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
        "          name: ${{ steps.version.outputs.artifact }}\n",
        "          if-no-files-found: error\n",
    ):
        if token not in upload:
            raise WorkflowContractError(f"the release candidate upload must carry: {token.strip()}")
    _validate_release_rc_caches(steps, install_at, cleanup_at)


RELEASE_RC_CACHE_ACTIONS = {
    "actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9": "restore",
    "actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9": "save",
}
# Nothing the credential install writes, nothing signed and nothing built by
# xcodebuild may be cached: only build inputs and the unsigned cargo targets.
RELEASE_RC_UNCACHEABLE = (
    "arkdeck-release-credentials", "keychain", ".p12", ".p8", "provisionprofile",
    "${{ runner.temp }}/rc", "DerivedData", "xcarchive", "export", "CompilationCache",
)
RELEASE_RC_CACHE_SAVE_CONDITION = (
    "        if: >-\n"
    "          success() &&\n"
    "          github.ref == 'refs/heads/main' &&\n"
    "          steps.existing.outputs.exists == 'false' &&\n"
)


def _cache_paths(step: str) -> tuple[str, ...]:
    lines = step.splitlines()
    for index, line in enumerate(lines):
        if line == "          path: |":
            block = []
            for item in lines[index + 1:]:
                if not item.startswith("            "):
                    break
                block.append(item.strip())
            return tuple(block) or ("",)
        if line.startswith("          path: "):
            return (line.removeprefix("          path: ").strip(),)
    raise WorkflowContractError("a release cache step must name its path")


def _validate_release_rc_caches(steps: list[tuple[str, str]], install_at: int, cleanup_at: int) -> None:
    """Build caches restore before any credential exists and are saved only
    after the credentials are removed, from a successful main run that built
    an RC; neither kind touches a secret, the credential files, the keychain
    or a signed or xcodebuild-built product."""

    restored: set[tuple[str, ...]] = set()
    saved: list[tuple[str, tuple[str, ...]]] = []
    for index, (name, step) in enumerate(steps):
        if "actions/cache" not in step:
            continue
        uses = re.search(r"^        uses: (\S+)", step, re.MULTILINE)
        kind = RELEASE_RC_CACHE_ACTIONS.get(uses.group(1) if uses else "")
        if kind is None:
            raise WorkflowContractError(
                f"release caches use the pinned actions/cache/restore or actions/cache/save only: {name}"
            )
        if "secrets." in step or "\n        env:" in step:
            raise WorkflowContractError(f"a release cache step takes no secret and no environment: {name}")
        paths = _cache_paths(step)
        for path in paths:
            if not path or any(token.lower() in path.lower() for token in RELEASE_RC_UNCACHEABLE):
                raise WorkflowContractError(f"a release cache must not hold {path!r}: {name}")
        if kind == "restore":
            if index > install_at:
                raise WorkflowContractError(f"release caches are restored before the credentials: {name}")
            if RELEASE_RC_BUILDS_ONLY_NEW not in step:
                raise WorkflowContractError(f"an existing release candidate restores no cache: {name}")
            restored.add(paths)
        else:
            if index < cleanup_at:
                raise WorkflowContractError(
                    f"release caches are saved only after the credentials are removed: {name}"
                )
            if RELEASE_RC_CACHE_SAVE_CONDITION not in step:
                raise WorkflowContractError(
                    f"release caches are saved only from a successful main run that built an RC: {name}"
                )
            saved.append((name, paths))
    for name, paths in saved:
        if paths not in restored:
            raise WorkflowContractError(f"a release cache saves only what it restored: {name}")


def validate_arkforge_cargo_fetch(fetch_text: str) -> None:
    """Pin the Rust lanes' locked fetch: the deploy key for that fetch alone."""

    required = (
        "set -eu",
        "umask 077",
        'transport="${RUNNER_TEMP}/arkforge-cargo-transport.env"',
        'sh "$here/arkforge-package-auth.sh" cleanup',
        'rm -f "$transport"',
        "trap remove EXIT",
        'GITHUB_ENV="$transport" sh "$here/arkforge-package-auth.sh" setup',
        # Git Bash on Windows cannot set an NTFS mode: the key goes into a
        # directory mktemp creates for that user, pinned and checked as the
        # auth script does, and removed on exit.
        "MINGW* | MSYS* | CYGWIN*) windows=true ;;",
        "credentials=$(mktemp -d)",
        'ssh-keygen -y -f "$credentials/id_ed25519" </dev/null >/dev/null 2>&1',
        "-o StrictHostKeyChecking=yes",
        'rm -f "$credentials/id_ed25519" "$credentials/known_hosts"',
        "CARGO_NET_GIT_FETCH_WITH_CLI=true cargo fetch --locked",
    )
    for token in required:
        if token not in fetch_text:
            raise WorkflowContractError(f"ArkForge cargo fetch missing contract token: {token}")
    if fetch_text.index("trap remove EXIT") > min(
        fetch_text.index('GITHUB_ENV="$transport" sh "$here/arkforge-package-auth.sh" setup'),
        fetch_text.index("credentials=$(mktemp -d)"),
    ):
        raise WorkflowContractError("ArkForge cargo fetch must arm its cleanup before setup")
    pinned = re.search(r"readonly github_ed25519_host_key='([^']+)'", fetch_text)
    if pinned is None or pinned.group(1) != (
        "github.com ssh-ed25519 "
        "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
    ):
        raise WorkflowContractError(
            "ArkForge cargo fetch must pin the host key the auth script pins"
        )
    # Nothing is built or run while the key exists, and nothing it configures
    # reaches a later step.
    for token in (
        "cargo build", "cargo test", "cargo run", "cargo clippy", "cargo install",
        '>> "$GITHUB_ENV"', "GITHUB_OUTPUT", "cargo fetch\n", "|| true",
        "StrictHostKeyChecking=no",
    ):
        if token in fetch_text:
            raise WorkflowContractError(f"ArkForge cargo fetch contains forbidden token: {token}")
    if fetch_text.count("GITHUB_ENV=") != 1:
        raise WorkflowContractError(
            "ArkForge cargo fetch must hand the auth script a private GITHUB_ENV only"
        )


def validate_arkforge_private_package_auth(swift_text: str, auth_text: str) -> None:
    """Pin the ArkForge transport the Rust lane's locked fetch uses.

    No Swift package depends on ArkForge any more (TASK-XPA-017), so neither
    compiled Swift lane holds the deploy key: only `arkforge-cargo-fetch.sh`
    runs the auth script, around `cargo fetch --locked`.
    """

    for job_name in ("swift-tests", "app-build"):
        job_block = _job_block(swift_text, job_name)
        for token in ("arkforge-package-auth.sh", "ARKFORGE_DEPLOY_KEY"):
            if token in job_block:
                raise WorkflowContractError(
                    f"{job_name} must not handle the ArkForge deploy key: {token}"
                )

    required_auth = (
        "set -eu",
        "umask 077",
        "${ARKFORGE_DEPLOY_KEY:-}",
        "ssh-keygen -y -f \"$key_path\" </dev/null >/dev/null 2>&1",
        "github.com ssh-ed25519 "
        "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl",
        "StrictHostKeyChecking=yes",
        "GIT_CONFIG_KEY_0=url.git@github.com:.insteadOf",
        "GIT_CONFIG_VALUE_0=https://github.com/",
        'rm -f "$key_path" "$known_hosts_path"',
    )
    for token in required_auth:
        if token not in auth_text:
            raise WorkflowContractError(
                f"ArkForge package authentication missing contract token: {token}"
            )
    forbidden_auth = (
        "StrictHostKeyChecking=no",
        "ssh-keyscan",
        "secrets.GITHUB_TOKEN",
        "github.token",
        "PERSONAL_ACCESS_TOKEN",
    )
    for token in forbidden_auth:
        if token in auth_text:
            raise WorkflowContractError(
                f"ArkForge package authentication contains forbidden token: {token}"
            )


def _glob_regex(pattern: str) -> re.Pattern[str]:
    pieces = [r"\A"]
    index = 0
    while index < len(pattern):
        character = pattern[index]
        if (
            character == "*"
            and index + 1 < len(pattern)
            and pattern[index + 1] == "*"
        ):
            pieces.append(".*")
            index += 2
            continue
        if character == "*":
            pieces.append("[^/]*")
        elif character == "?":
            pieces.append("[^/]")
        else:
            pieces.append(re.escape(character))
        index += 1
    pieces.append(r"\Z")
    return re.compile("".join(pieces))


def branch_dispatches(patterns: tuple[str, ...], branch: str) -> bool:
    """Evaluate ordered positive/negative branch patterns."""

    if not patterns or not any(not item.startswith("!") for item in patterns):
        raise WorkflowContractError("ordered branch patterns need a positive pattern")
    included = False
    for pattern in patterns:
        negative = pattern.startswith("!")
        candidate = pattern[1:] if negative else pattern
        if not candidate:
            raise WorkflowContractError("empty branch pattern")
        if _glob_regex(candidate).fullmatch(branch):
            included = not negative
    return included


def reserved_family(branch: str) -> str | None:
    match = RESERVED_BRANCH_RE.fullmatch(branch)
    if match is None:
        return None
    for family in ("task", "lease", "probe"):
        if match.group(family) is not None:
            return family
    raise AssertionError("reserved branch matched without a family")


def _workflow(on_block: str) -> str:
    return (
        "name: fixture\n"
        f"{on_block.rstrip()}\n"
        "permissions:\n"
        "  contents: read\n"
        "jobs:\n"
        "  open-pr:\n"
        "    runs-on: ubuntu-latest\n"
    )


VALID_ON_BLOCK = """\
on:
  push:
    branches:
      - "agent/**"
      - "!agent/host-loop/**"
"""


class AgentPrWorkflowContractTests(unittest.TestCase):
    def test_repository_filter_is_exact(self) -> None:
        text = WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertEqual(validate_agent_pr_filter(text), EXPECTED_PATTERNS)

    def test_repository_automatic_check_contract_is_exact(self) -> None:
        validate_automatic_check_contract(
            WORKFLOW_PATH.read_text(encoding="utf-8"),
            SDD_WORKFLOW_PATH.read_text(encoding="utf-8"),
            SWIFT_WORKFLOW_PATH.read_text(encoding="utf-8"),
        )
        validate_arkforge_private_package_auth(
            SWIFT_WORKFLOW_PATH.read_text(encoding="utf-8"),
            ARKFORGE_AUTH_PATH.read_text(encoding="utf-8"),
        )
        validate_rust_ci_contract(RUST_WORKFLOW_PATH.read_text(encoding="utf-8"))
        validate_arkforge_cargo_fetch(ARKFORGE_CARGO_FETCH_PATH.read_text(encoding="utf-8"))

    def test_the_arkforge_deploy_key_reaches_only_the_rust_lanes_locked_fetch(self) -> None:
        rust = RUST_WORKFLOW_PATH.read_text(encoding="utf-8")
        swift = SWIFT_WORKFLOW_PATH.read_text(encoding="utf-8")
        agent = WORKFLOW_PATH.read_text(encoding="utf-8")
        sdd = SDD_WORKFLOW_PATH.read_text(encoding="utf-8")
        fetch = ARKFORGE_CARGO_FETCH_PATH.read_text(encoding="utf-8")
        lint = "        run: python rust/scripts/ci-workspace.py --cwd rust exec -- cargo clippy --workspace --all-targets -- -D warnings\n"
        rust_mutations = (
            # A fetch without the key-bounding wrapper.
            rust.replace(RUST_FETCH_RUN, "run: cargo fetch --locked"),
            # The key handed to a step that runs checked-out code.
            rust.replace(
                lint,
                "        env:\n          ARKFORGE_DEPLOY_KEY: ${{ secrets.ARKFORGE_DEPLOY_KEY }}\n" + lint,
            ),
            # The key configured for the whole job through GITHUB_ENV.
            rust.replace(
                RUST_FETCH_RUN, "run: sh ../scripts/ci/arkforge-package-auth.sh setup", 1
            ),
            # The secret no longer declared, or declared optional.
            rust.replace("        required: true\n", "        required: false\n"),
            # The pin check dropped, or no longer rerunning ArkForge's vectors.
            rust.replace(
                "run: python rust/scripts/check-arkforge-pin.py --run-vectors",
                "run: python rust/scripts/check-arkforge-pin.py",
            ),
            # Fetched after the first step that runs checked-out code.
            rust.replace(
                "      - name: Contract isolation and provenance regression tests\n"
                "        working-directory: .\n"
                "        run: python rust/scripts/test_contract_checks.py\n",
                "",
            ).replace(
                "      - name: Format check\n",
                "      - name: Contract isolation and provenance regression tests\n"
                "        working-directory: .\n"
                "        run: python rust/scripts/test_contract_checks.py\n\n"
                "      - name: Format check\n",
            ),
        )
        for mutated in rust_mutations:
            self.assertNotEqual(mutated, rust)
            with self.assertRaises(WorkflowContractError):
                validate_rust_ci_contract(mutated)
        swift_mutations = (
            swift.replace(RUST_CHECKS_SECRET, "    secrets: inherit\n"),
            swift.replace(RUST_CHECKS_SECRET, ""),
            swift.replace(
                RUST_CHECKS_SECRET,
                RUST_CHECKS_SECRET + "      OTHER_KEY: ${{ secrets.OTHER_KEY }}\n",
            ),
        )
        for mutated in swift_mutations:
            self.assertNotEqual(mutated, swift)
            with self.assertRaises(WorkflowContractError):
                validate_automatic_check_contract(agent, sdd, mutated)
        fetch_mutations = (
            # Setup writing the real GITHUB_ENV: every later step inherits it.
            fetch.replace(
                'GITHUB_ENV="$transport" sh "$here/arkforge-package-auth.sh" setup',
                'sh "$here/arkforge-package-auth.sh" setup',
            ),
            # The Windows key without its host pin, or kept after the fetch.
            fetch.replace("-o StrictHostKeyChecking=yes", "-o StrictHostKeyChecking=no"),
            fetch.replace("AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl", "AAAA"),
            fetch.replace('rm -f "$credentials/id_ed25519" "$credentials/known_hosts"', ":"),
            # No cleanup on exit, or cleanup armed after the key is written.
            fetch.replace("trap remove EXIT\n", ""),
            fetch.replace("trap remove EXIT\n", "").replace(
                "CARGO_NET_GIT_FETCH_WITH_CLI=true cargo fetch --locked",
                "trap remove EXIT\nCARGO_NET_GIT_FETCH_WITH_CLI=true cargo fetch --locked",
            ),
            # Anything built or run while the key exists.
            fetch + "cargo build --locked\n",
            fetch.replace("cargo fetch --locked", "cargo fetch"),
        )
        for mutated in fetch_mutations:
            self.assertNotEqual(mutated, fetch)
            with self.assertRaises(WorkflowContractError):
                validate_arkforge_cargo_fetch(mutated)

    def test_rust_checks_reject_skipped_hosts_and_unlocked_or_bypassed_policy(self) -> None:
        rust = RUST_WORKFLOW_PATH.read_text(encoding="utf-8")
        bootstrap = rust[
            rust.index("      - name: Activate workspace toolchain"):
            rust.index("      - name: Verify generated contract inputs")
        ]
        policy_start = rust.index("  policy:\n")
        workspace_start = rust.index("  workspace:\n")
        deny_step = (
            "      - name: Dependency source, license, ban and advisory policy\n"
            "        run: cargo deny --locked check\n\n"
        )
        lint_step = (
            "      - name: Lint the workspace, its tests and its examples\n"
            "        working-directory: .\n"
            "        run: python rust/scripts/ci-workspace.py --cwd rust exec -- cargo clippy --workspace --all-targets -- -D warnings\n\n"
        )
        recordings = "      - name: Preserve actual read-only recordings\n"
        lock_check = "      - name: Verify checks left locked inputs unchanged\n"
        mutations = (
            # A host-independent check repeated on every host is the cost the
            # policy job removes, and one on no host is no check at all.
            rust.replace(recordings, deny_step + recordings),
            rust[:policy_start] + rust[workspace_start:],
            rust.replace(
                "    name: Rust host-independent checks\n    runs-on: ubuntu-latest\n",
                "    name: Rust host-independent checks\n    runs-on: ${{ matrix.os }}\n",
            ),
            # A host check moved to the single policy host leaves the other two
            # hosts unlinted.
            rust.replace(lint_step, "").replace(lock_check, lint_step + lock_check),
            rust.replace(bootstrap, "").replace(
                "      - name: Format check", bootstrap + "      - name: Format check"
            ),
            rust.replace("  workflow_call:\n", "  push:\n"),
            rust.replace(
                "os: [ubuntu-latest, xcode-27, windows-latest]",
                "os: [ubuntu-latest, xcode-27]",
            ),
            rust.replace("run: python rust/scripts/test_contract_checks.py", "run: true"),
            rust.replace(
                "run: python rust/scripts/ci-workspace.py --cwd rust exec -- cargo clippy --workspace --all-targets -- -D warnings\n",
                "run: cargo clippy --workspace\n",
            ),
            rust.replace(
                "run: python rust/scripts/ci-workspace.py --cwd rust exec -- cargo clippy --workspace --all-targets -- -D warnings\n", "run: true\n"
            ),
            rust.replace(
                "run: python rust/scripts/ci-workspace.py exec -- python rust/scripts/workspace-tests.py\n",
                "run: cargo test -p arkdeck-contract\n",
            ),
            rust.replace("run: python rust/scripts/ci-workspace.py exec -- python rust/scripts/workspace-tests.py\n", "run: true\n"),
            rust.replace("run: python rust/scripts/ci-workspace.py exec -- python rust/scripts/check-contracts.py", "run: cargo test --workspace --locked"),
            rust.replace("run: python rust/scripts/ci-workspace.py exec -- python rust/scripts/check-contracts.py", "run: python rust/scripts/ci-workspace.py exec -- python rust/scripts/check-contracts.py --published-only"),
            rust.replace(
                "run: cargo deny --locked check", "run: cargo deny --locked check || true"
            ),
            rust.replace("run: cargo vet --locked --no-registry-suggestions", "run: cargo vet"),
            rust.replace(
                "run: python rust/scripts/ci-policy-tools.py", "run: cargo install cargo-vet"
            ),
            rust + "\n        continue-on-error: true\n",
            rust + "\n        run: cargo vet init\n",
            rust.replace("working-directory: rust", "working-directory: ."),
            rust.replace("git config core.autocrlf false", "git config core.autocrlf true"),
            rust.replace("git fetch --no-tags --prune origin", "git fetch --depth=1 origin"),
            rust.replace(
                "run: python rust/scripts/generate-contract.py --check", "run: true"
            ),
            rust.replace("run: python rust/scripts/ci-workspace.py exec -- python rust/scripts/check-contracts.py", "run: true"),
            # The contract views wait for no host job, and no job goes missing.
            rust[:rust.index("  contracts:\n")] + rust[rust.index("  contracts:\n"):].replace(
                "    needs: policy\n", "    needs: [policy, workspace]\n"
            ),
            rust[:rust.index("  contracts:\n")],
        )
        for mutated in mutations:
            # A mutation that no longer matches the workflow proves nothing.
            self.assertNotEqual(mutated, rust)
            with self.assertRaises(WorkflowContractError):
                validate_rust_ci_contract(mutated)

    def test_rust_policy_tool_cache_stays_exact_main_written_and_read_back(self) -> None:
        rust = RUST_WORKFLOW_PATH.read_text(encoding="utf-8")
        read_back_start = rust.index("      - name: Require the pinned dependency policy tool versions")
        save_start = rust.index("      - name: Save pinned dependency policy tools")
        read_back = rust[read_back_start:save_start]
        mutations = (
            # A restored binary must be read back against the pinned versions.
            rust.replace(read_back, ""),
            rust.replace('= "cargo-deny 0.20.2"', '= "cargo-deny 0.20.3"'),
            rust.replace(read_back, "").replace(
                "      - name: Dependency source, license, ban and advisory policy",
                read_back + "      - name: Dependency source, license, ban and advisory policy",
            ),
            # Only protected main writes entries.
            rust.replace("          github.ref == 'refs/heads/main' &&\n", ""),
            rust.replace("github.ref == 'refs/heads/main'", "github.ref != ''"),
            # One exact key on both sides, naming both pinned versions and the toolchain.
            rust.replace("cargo-deny-0.20.2-cargo-vet-0.10.2", "cargo-deny-0.20.2-cargo-vet-0.10.3", 1),
            rust.replace("-${{ hashFiles('rust/rust-toolchain.toml') }}", ""),
            rust.replace(
                "          key: arkdeck-cargo-policy-tools-v1",
                "          restore-keys: arkdeck-cargo-policy-tools-v1-\n          key: arkdeck-cargo-policy-tools-v1",
                1,
            ),
            # The version-pinned distribution/fallback must not disappear.
            rust.replace("run: python rust/scripts/ci-policy-tools.py", "run: true"),
            rust.replace("actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9", "actions/cache/restore@v6"),
            rust.replace("actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9", "actions/cache/save@v6"),
        )
        for mutated in mutations:
            with self.assertRaises(WorkflowContractError):
                validate_rust_ci_contract(mutated)

    def test_rust_build_cache_keeps_compatibility_main_only_writes_and_policy_gate(self) -> None:
        rust = RUST_WORKFLOW_PATH.read_text(encoding="utf-8")
        workspace_start = rust.index("  workspace:\n")
        policy, workspace = rust[:workspace_start], rust[workspace_start:]
        for mutated in (
            workspace.replace("    needs: policy\n", ""),
            workspace.replace("github.ref == 'refs/heads/main'", "github.ref != ''"),
            workspace.replace("          success() &&\n", ""),
            workspace.replace("restore-keys: ${{ steps.rust-cache-key.outputs.prefix }}", "restore-keys: arkdeck-rust-build-"),
            workspace.replace("run: python rust/scripts/ci-workspace.py prepare", "run: true"),
            workspace.replace(" && '2' || '1'", " && '4' || '1'"),
            workspace.replace('      CARGO_INCREMENTAL: "0"\n', "", 1),
            workspace.replace('      CARGO_INCREMENTAL: "0"\n', '      CARGO_INCREMENTAL: "1"\n'),
        ):
            self.assertNotEqual(mutated, workspace)
            with self.assertRaises(WorkflowContractError):
                validate_rust_ci_contract(policy + mutated)

    def test_background_macos_lanes_share_one_slot_without_dropping_pending_jobs(self) -> None:
        expected = (
            "    concurrency:\n"
            "      group: arkdeck-macos-background\n"
            "      cancel-in-progress: false\n"
            "      queue: max\n"
        )
        for filename, jobs in (
            ("swift-slow-lanes.yml", ("ui-tests",)),
            ("rust-perf.yml", ("nightly", "soak")),
        ):
            workflow = (REPOSITORY_ROOT / ".github/workflows" / filename).read_text()
            for job in jobs:
                with self.subTest(workflow=filename, job=job):
                    self.assertIn(expected, _job_block(workflow, job))
            self.assertEqual(workflow.count("group: arkdeck-macos-background"), len(jobs))
        for path in (SWIFT_WORKFLOW_PATH, RUST_WORKFLOW_PATH):
            self.assertNotIn("group: arkdeck-macos-background", path.read_text())

    def test_cache_deletion_never_runs_pr_code_or_receives_broader_write_authority(self) -> None:
        text = (REPOSITORY_ROOT / ".github/workflows/ci-cache-retention.yml").read_text()
        validate_cache_retention_contract(text)
        for before, after in (
            ("  workflow_run:", "  pull_request:"),
            ("github.event.workflow_run.head_branch == 'main'", "github.event.workflow_run.head_branch != ''"),
            ("github.event.workflow_run.head_repository.full_name == github.repository", "true"),
            ("github.event.workflow_run.conclusion == 'success'", "true"),
            ("ARKDECK_CI_SHA: ${{ github.sha }}", "ARKDECK_CI_SHA: ${{ github.event.workflow_run.head_sha }}"),
            ("contents: read", "contents: write"),
        ):
            changed = text.replace(before, after)
            self.assertNotEqual(changed, text)
            with self.assertRaises(WorkflowContractError):
                validate_cache_retention_contract(changed)

    def test_release_candidate_keeps_its_credentials_to_main_and_one_job(self) -> None:
        text = RELEASE_RC_WORKFLOW_PATH.read_text(encoding="utf-8")
        validate_release_rc_contract(text)
        install_env = "          ARKDECK_NOTARY_API_KEY_P8_BASE64: ${{ secrets.ARKDECK_NOTARY_API_KEY_P8_BASE64 }}\n"
        cleanup_start = text.index("      - name: Remove release credentials\n")
        upload_start = text.index("      - name: Keep the release candidate\n")
        summary_start = text.index("      - name: Release candidate summary\n")
        cleanup = text[cleanup_start:upload_start]
        upload = text[upload_start:summary_start]
        mutations = {
            "pull_request trigger": text.replace(
                "  workflow_dispatch:\n", "  workflow_dispatch:\n  pull_request:\n    branches: [main]\n"),
            "pull_request_target trigger": text.replace(
                "  workflow_dispatch:\n", "  workflow_dispatch:\n  pull_request_target:\n"),
            "any branch": text.replace("    branches: [main]\n", '    branches: [main, "agent/**"]\n'),
            "no version path": text.replace("      - scripts/release/release-version.json\n", "      - scripts/**\n"),
            "no environment": text.replace("    environment: release\n", ""),
            "another environment": text.replace("    environment: release\n", "    environment: staging\n"),
            "no main check": text.replace(
                '          if [ "$GITHUB_REF" != refs/heads/main ]; then\n', "          if false; then\n"),
            "cancellable": text.replace("  cancel-in-progress: false\n", "  cancel-in-progress: true\n"),
            "write permission": text.replace("permissions:\n  contents: read\n", "permissions:\n  contents: write\n"),
            "cleanup on success only": text.replace(
                "      - name: Remove release credentials\n        if: always()\n",
                "      - name: Remove release credentials\n        if: success()\n"),
            "cleanup keeps the keychain": text.replace(
                '            security delete-keychain "$keychain" || status=1\n', "            :\n"),
            "cleanup after the upload": text[:cleanup_start] + upload + cleanup + text[summary_start:],
            "secret in the job env": text.replace(
                "      CARGO_TERM_COLOR: always\n",
                "      CARGO_TERM_COLOR: always\n"
                "      ARKDECK_NOTARY_API_KEY_ID: ${{ secrets.ARKDECK_NOTARY_API_KEY_ID }}\n"),
            "secret in the ArkForge checkout": text.replace(
                "      - name: Check out ArkForge at the pinned revision\n",
                "      - name: Check out ArkForge at the pinned revision\n        env:\n"
                "          KEY: ${{ secrets.ARKDECK_NOTARY_API_KEY_P8_BASE64 }}\n"),
            "an eighth secret": text.replace(
                install_env, install_env + "          OTHER: ${{ secrets.OTHER_SECRET }}\n"),
            "unmasked keychain password": text.replace(
                '          echo "::add-mask::$keychain_password"\n', ""),
            "traced credential install": text.replace(
                "          set -euo pipefail\n          umask 077\n",
                "          set -euxo pipefail\n          umask 077\n"),
            "printed secret": text.replace(
                "          umask 077\n", '          umask 077\n          echo "$ARKDECK_DEVELOPER_ID_P12_PASSWORD"\n'),
            ".p12 kept": text.replace('          rm -f "$credentials/developer-id.p12"\n', ""),
            "rebuilds an existing RC": text.replace(
                "      - name: Build the signed and notarized release candidate\n"
                "        if: steps.existing.outputs.exists == 'false'\n",
                "      - name: Build the signed and notarized release candidate\n"),
            "upload of nothing passes": text.replace(
                "          if-no-files-found: error\n", "          if-no-files-found: warn\n"),
        }
        # Build caches: restored before the credentials, saved after they are
        # removed and only from a successful main run, never holding a
        # credential, a keychain, a signed or an xcodebuild-built product.
        swiftpm_start = text.index("      - name: Restore the SwiftPM clones\n")
        install_start = text.index("      - name: Install release credentials\n")
        build_start = text.index("      - name: Build the signed and notarized release candidate\n")
        swiftpm_restore = text[swiftpm_start:install_start]
        save_start = text.index("      - name: Save the SwiftPM clones\n")
        swiftpm_save = text[save_start:]
        swiftpm_path = "          path: ${{ runner.temp }}/arkdeck-swiftpm/SourcePackages\n"
        restore_uses = "        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
        mutations.update({
            "cache restored after the credentials": (
                text[:swiftpm_start] + text[install_start:build_start] + swiftpm_restore + text[build_start:]),
            "cache saved before the credentials are removed": (
                text[:cleanup_start] + swiftpm_save.rstrip("\n") + "\n\n" + text[cleanup_start:save_start]),
            "cache saved off main": text.replace("          github.ref == 'refs/heads/main' &&\n", "", 1),
            "cache saved after a failure": text.replace(
                "        if: >-\n          success() &&\n", "        if: >-\n          always() &&\n", 1),
            "cache saved for an existing RC": text.replace(
                "          github.ref == 'refs/heads/main' &&\n          steps.existing.outputs.exists == 'false' &&\n",
                "          github.ref == 'refs/heads/main' &&\n", 1),
            "credentials cached": text.replace(
                swiftpm_path, "          path: ${{ runner.temp }}/arkdeck-release-credentials\n"),
            "keychain cached": text.replace(
                "            ~/.cargo/git/db\n", "            ~/.cargo/git/db\n            ~/Library/Keychains\n"),
            "release candidate cached": text.replace(swiftpm_path, "          path: ${{ runner.temp }}/rc\n"),
            "DerivedData cached": text.replace(
                swiftpm_path, "          path: ${{ runner.temp }}/arkdeck-swiftpm/DerivedData\n"),
            "save of a path never restored": text[:save_start] + swiftpm_save.replace(
                swiftpm_path, "          path: ${{ runner.temp }}/arkdeck-swiftpm\n"),
            "combined cache action": text.replace(
                restore_uses, "        uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9", 1),
            "unpinned cache action": text.replace(restore_uses, "        uses: actions/cache/restore@v6", 1),
            "secret in a cache step": text.replace(
                swiftpm_restore,
                swiftpm_restore.replace(
                    "        continue-on-error: true\n",
                    "        continue-on-error: true\n        env:\n"
                    "          KEY: ${{ secrets.ARKDECK_NOTARY_API_KEY_ID }}\n")),
        })
        for case, mutated in mutations.items():
            with self.subTest(case):
                self.assertNotEqual(mutated, text)
                with self.assertRaises(WorkflowContractError):
                    validate_release_rc_contract(mutated)
        # No other workflow names the release environment or its secrets.
        for path in sorted((REPOSITORY_ROOT / ".github/workflows").glob("*.yml")):
            if path == RELEASE_RC_WORKFLOW_PATH:
                continue
            other = path.read_text(encoding="utf-8")
            with self.subTest(workflow=path.name):
                self.assertNotIn("environment: release", other)
                for secret in RELEASE_RC_SECRETS:
                    self.assertNotIn(secret, other)

    def test_rust_recordings_are_preserved_after_failures(self) -> None:
        rust = RUST_WORKFLOW_PATH.read_text(encoding="utf-8")
        upload_start = rust.index("      - name: Preserve actual read-only recordings")
        upload = rust[upload_start:]
        producer = "      - name: Published consumer and candidate contract parity"
        for mutated in (
            rust.replace("        if: always()\n", "        if: success()\n"),
            rust.replace("path: rust/target/readonly-check/", "path: target/readonly-check/"),
            rust.replace("rust-readonly-recordings-${{ matrix.os }}", "rust-readonly-recordings"),
            rust.replace("if-no-files-found: warn", "if-no-files-found: ignore"),
            rust.replace("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", "actions/upload-artifact@v7"),
            rust[:upload_start].replace(producer, upload + "\n" + producer),
        ):
            with self.assertRaises(WorkflowContractError):
                validate_rust_ci_contract(mutated)

    def test_arkforge_private_package_auth_rejects_credential_regressions(self) -> None:
        swift = SWIFT_WORKFLOW_PATH.read_text(encoding="utf-8")
        auth = ARKFORGE_AUTH_PATH.read_text(encoding="utf-8")
        setup = (
            "      - name: Configure read-only ArkForge package access\n"
            "        env:\n"
            "          ARKFORGE_DEPLOY_KEY: ${{ secrets.ARKFORGE_DEPLOY_KEY }}\n"
            "        run: sh scripts/ci/arkforge-package-auth.sh setup\n\n"
        )
        build = "      - name: Build ArkDeck app and UI-test bundle\n"
        self.assertIn(build, swift)
        mutations = (
            # A compiled Swift lane handed the deploy key again.
            (swift.replace(build, setup + build, 1), auth),
            (swift, auth.replace("StrictHostKeyChecking=yes", "StrictHostKeyChecking=no")),
            (swift, auth.replace("GIT_CONFIG_VALUE_0=https://github.com/", "")),
            (swift, auth + "\nssh-keyscan github.com\n"),
        )
        for mutated_swift, mutated_auth in mutations:
            with self.assertRaises(WorkflowContractError):
                validate_arkforge_private_package_auth(mutated_swift, mutated_auth)

    def test_automatic_check_contract_rejects_permission_event_and_dependency_drift(
        self,
    ) -> None:
        agent = WORKFLOW_PATH.read_text(encoding="utf-8")
        sdd = SDD_WORKFLOW_PATH.read_text(encoding="utf-8")
        swift = SWIFT_WORKFLOW_PATH.read_text(encoding="utf-8")
        cases = (
            (
                "second job",
                agent + "  allowed-paths:\n    needs: open-pr\n    runs-on: ubuntu-latest\n",
                sdd,
                swift,
            ),
            (
                "open-pr without write",
                agent.replace(
                    "      pull-requests: write\n", "      pull-requests: read\n"
                ),
                sdd,
                swift,
            ),
            (
                "retired guard script",
                agent.replace(
                    "python scripts/agent_pr_identity.py",
                    "python scripts/check_pr_paths.py",
                ),
                sdd,
                swift,
            ),
            (
                "retired job in SDD Guard",
                agent,
                sdd + "  allowed-paths:\n    runs-on: ubuntu-latest\n",
                swift,
            ),
            (
                "identity tests dropped from guard",
                agent,
                sdd.replace(
                    "        run: python3 scripts/test_agent_pr_identity.py\n", ""
                ),
                swift,
            ),
            (
                "Task line dropped",
                agent.replace(
                    "printf 'Task: %s\\n\\n' \"$TASK_ID\" >> \"$BODY\"\n",
                    "true\n",
                ),
                sdd,
                swift,
            ),
            (
                "secret",
                agent + "      TOKEN: ${{ secrets.PR_TOKEN }}\n",
                sdd,
                swift,
            ),
            (
                "bot opened",
                agent,
                sdd.replace(
                    "types: [reopened, edited]",
                    "types: [opened, synchronize, reopened, edited]",
                ),
                swift,
            ),
            (
                "swift pull request",
                agent,
                sdd,
                swift.replace(
                    '  push:\n    branches: [main, "agent/**"]\n',
                    '  push:\n    branches: [main, "agent/**"]\n  pull_request:\n',
                ),
            ),
            (
                "workflow paths filter",
                agent,
                sdd,
                swift.replace(
                    '    branches: [main, "agent/**"]\n',
                    '    branches: [main, "agent/**"]\n    paths:\n      - "Packages/**"\n',
                ),
            ),
            (
                "unstable SwiftPM invocation",
                agent,
                sdd,
                swift.replace(
                    "sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh",
                    "swift --package-path Packages/ArkDeckKit",
                ),
            ),
            (
                "missing app build",
                agent,
                sdd,
                swift.replace(
                    "        run: sh scripts/ci/run-xcodebuild.sh\n",
                    "        run: true # app build missing\n",
                ),
            ),
            (
                "ds lane not gated on plan",
                agent,
                sdd,
                swift.replace(
                    "    if: needs.plan.outputs.ds == 'true'\n",
                    "",
                ),
            ),
            (
                "ds install skipped",
                agent,
                sdd,
                swift.replace(
                    "        run: npm ci\n",
                    "        run: true # install skipped\n",
                ),
            ),
            (
                "aggregator ignores ds result",
                agent,
                sdd,
                swift.replace(
                    '            test "$DS_RESULT" = success\n',
                    "            true\n",
                ),
            ),
            (
                "Rust lane not gated on plan",
                agent,
                sdd,
                swift.replace("    if: needs.plan.outputs.rust == 'true'\n", ""),
            ),
            (
                "aggregator ignores Rust failure",
                agent,
                sdd,
                swift.replace('            test "$RUST_RESULT" = success\n', "            true\n"),
            ),
            (
                "aggregator ignores unexpectedly skipped Rust lane",
                agent,
                sdd,
                swift.replace('            test "$RUST_RESULT" = skipped\n', "            true\n"),
            ),
            (
                "Windows lane dropped from the aggregate",
                agent,
                sdd,
                swift.replace(
                    "    needs: [plan, swift-tests, app-build, ds-interactions, rust-checks, windows-clientkit]\n",
                    "    needs: [plan, swift-tests, app-build, ds-interactions, rust-checks]\n",
                ),
            ),
            (
                "Windows lane not gated on plan",
                agent,
                sdd,
                swift.replace("    if: needs.plan.outputs.windows == 'true'\n", ""),
            ),
            (
                "aggregator ignores Windows failure",
                agent,
                sdd,
                swift.replace('            test "$WINDOWS_RESULT" = success\n', "            true\n"),
            ),
            (
                "aggregator ignores unexpectedly skipped Windows lane",
                agent,
                sdd,
                swift.replace('            test "$WINDOWS_RESULT" = skipped\n', "            true\n"),
            ),
            (
                "Windows checkout converts line endings",
                agent,
                sdd,
                swift.replace("          git config core.autocrlf false\n", ""),
            ),
            (
                "Windows lane skips the generator check",
                agent,
                sdd,
                swift.replace(
                    "        run: python windows/scripts/generate-clientkit.py --check\n",
                    "        run: true # generator unchecked\n",
                ),
            ),
            (
                "Windows lane skips the App strings check",
                agent,
                sdd,
                swift.replace(
                    "        run: python windows/scripts/generate-ui-strings.py --check\n",
                    "        run: true # strings unchecked\n",
                ),
            ),
            (
                "Windows lane skips the App tokens check",
                agent,
                sdd,
                swift.replace(
                    "        run: python windows/scripts/generate-xaml-tokens.py --check\n",
                    "        run: true # tokens unchecked\n",
                ),
            ),
            (
                "Windows tests dropped",
                agent,
                sdd,
                swift.replace(
                    "        run: dotnet test windows/ArkDeck.Windows.slnx -c Release --no-build\n",
                    "        run: true # tests dropped\n",
                ),
            ),
            (
                "Windows lane on another runner",
                agent,
                sdd,
                swift.replace("    runs-on: windows-latest\n", "    runs-on: ubuntu-latest\n"),
            ),
            (
                "missing stable aggregator",
                agent,
                sdd,
                swift.replace(
                    "  swift:\n    if: always()\n",
                    "  swift:\n    if: success()\n",
                    1,
                ),
            ),
            (
                "runner context at job scope",
                agent,
                sdd,
                swift.replace(
                    "      DEVELOPER_DIR: /Applications/Xcode_27.0.app/Contents/Developer\n",
                    "      DEVELOPER_DIR: /Applications/Xcode_27.0.app/Contents/Developer\n"
                    "      INVALID_JOB_CACHE: ${{ runner.temp }}/invalid\n",
                    1,
                ),
            ),
            (
                "missing SwiftPM toolchain fallback",
                agent,
                sdd,
                swift.replace(
                    "            arkdeck-swiftpm-v2-${{ runner.os }}-${{ runner.arch }}-xcode-27.0-\n",
                    "",
                ),
            ),
            (
                "superseded main run cancelled",
                agent,
                sdd,
                swift.replace(
                    "  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}\n",
                    "  cancel-in-progress: true\n",
                ),
            ),
            (
                "a red main run counted as validated",
                agent,
                sdd,
                swift.replace("&status=success&", "&status=completed&"),
            ),
            (
                "main planned from its own push alone",
                agent,
                sdd,
                swift.replace('          --main-last-success "$ARKDECK_MAIN_LAST_SUCCESS"\n', ""),
            ),
            (
                "plan job cannot read runs",
                agent,
                sdd,
                swift.replace(
                    "      contents: read\n      actions: read\n", "      contents: read\n"
                ),
            ),
            (
                "SwiftPM cache not keyed by runner image build",
                agent,
                sdd,
                swift.replace("-image-${{ steps.runner-image.outputs.version }}", ""),
            ),
            (
                "SwiftPM cache saved under a different key than restored",
                agent,
                sdd,
                swift.replace(
                    "-image-${{ steps.runner-image.outputs.version }}-${{ hashFiles('Packages/ArkDeckKit/Package.swift') }}-${{ github.sha }}",
                    "-image-${{ steps.runner-image.outputs.version }}-${{ hashFiles('Packages/ArkDeckKit/Package.swift') }}-${{ github.ref }}",
                    1,
                ),
            ),
            (
                "runner image build recorded after the cache restore",
                agent,
                sdd,
                swift.replace(
                    "        id: runner-image\n", "        id: runner-image-late\n"
                ).replace(
                    "        id: swift-build-cache\n",
                    "        id: swift-build-cache\n      - id: runner-image\n        run: true\n",
                ),
            ),
            (
                "missing Xcode toolchain fallback",
                agent,
                sdd,
                swift.replace(
                    "            arkdeck-xcode-v2-${{ runner.os }}-${{ runner.arch }}-xcode-27.0-\n",
                    "",
                ),
            ),
            (
                "Agent branch cache write",
                agent,
                sdd,
                swift.replace(
                    "          github.ref == 'refs/heads/main' &&\n",
                    "          startsWith(github.ref, 'refs/heads/agent/') &&\n",
                    1,
                ),
            ),
        )
        for label, agent_case, sdd_case, swift_case in cases:
            with self.subTest(label=label):
                with self.assertRaises(WorkflowContractError):
                    validate_automatic_check_contract(
                        agent_case, sdd_case, swift_case
                    )

    def test_dispatch_matrix(self) -> None:
        dispatched = (
            "agent/hlr-002a-bootstrap-partition-r2",
            "agent/task-hlr-003",
            "agent/hlr-002a-control/123e4567-e89b-42d3-a456-426614174000",
            "agent/host-loop",
            "agent/host-loopx/tasks/TASK-HLR-003",
            "agent/host-loops/tasks/TASK-HLR-003",
        )
        excluded = (
            "agent/host-loop/tasks/TASK-HLR-003",
            "agent/host-loop/leases/TASK-HLR-003",
            "agent/host-loop/probes/123e4567-e89b-42d3-a456-426614174000",
            "agent/host-loop/tasks/",
            "agent/host-loop/tasks/TASK-HLR-003/extra",
            "agent/host-loop/Tasks/TASK-HLR-003",
            r"agent/host-loop/tasks/TASK-HLR-003\extra",
            "agent/host-loop/tasks/..",
        )
        ignored = ("main", "feature/example", "Agent/host-loop/tasks/TASK-HLR-003")

        for branch in dispatched:
            with self.subTest(branch=branch):
                self.assertTrue(branch_dispatches(EXPECTED_PATTERNS, branch))
        for branch in excluded + ignored:
            with self.subTest(branch=branch):
                self.assertFalse(branch_dispatches(EXPECTED_PATTERNS, branch))

    def test_ordered_evaluator_honors_reinclude(self) -> None:
        patterns = (
            "agent/**",
            "!agent/host-loop/**",
            "agent/host-loop/probes/**",
        )
        self.assertFalse(
            branch_dispatches(patterns, "agent/host-loop/tasks/TASK-HLR-003")
        )
        self.assertTrue(
            branch_dispatches(
                patterns,
                "agent/host-loop/probes/123e4567-e89b-42d3-a456-426614174000",
            )
        )

    def test_reserved_positive_matrix(self) -> None:
        branches = {
            "agent/host-loop/tasks/TASK-HLR-002A": "task",
            "agent/host-loop/tasks/TASK-AF-014-REMEDIATION": "task",
            "agent/host-loop/leases/TASK-HLR-003": "lease",
            "agent/host-loop/probes/123e4567-e89b-42d3-a456-426614174000": "probe",
        }
        for branch, expected in branches.items():
            with self.subTest(branch=branch):
                self.assertEqual(reserved_family(branch), expected)

    def test_reserved_negative_matrix(self) -> None:
        branches = (
            "agent/host-loop/tasks",
            "agent/host-loop/tasks/",
            "agent/host-loop/tasks/TASK-HLR-003/extra",
            "agent/host-loop/tasks/task-hlr-003",
            "agent/host-loop/tasks/TASK-HLR",
            "agent/host-loop/tasks/TASK-HLR-003.",
            "agent/host-loop/tasks/TASK-HLR-003%2Fextra",
            r"agent/host-loop/tasks/TASK-HLR-003\extra",
            "agent/host-loop/tasks/..",
            "agent/host-loop/Tasks/TASK-HLR-003",
            "agent/host-loop/lease/TASK-HLR-003",
            "agent/host-loopx/tasks/TASK-HLR-003",
            "agent/host-loops/tasks/TASK-HLR-003",
            "refs/heads/agent/host-loop/tasks/TASK-HLR-003",
            "agent/host-loop/probes/123e4567-e89b-12d3-a456-426614174000",
            "agent/host-loop/probes/123E4567-E89B-42D3-A456-426614174000",
            "agent/host-loop/probes/123e4567-e89b-42d3-c456-426614174000",
            "agent/host-loop/probes/123e4567-e89b-42d3-a456-426614174000/extra",
            "agent/host-loop/probes/123e4567-e89b-42d3-a456-42661417400",
        )
        for branch in branches:
            with self.subTest(branch=branch):
                self.assertIsNone(reserved_family(branch))

    def test_parser_rejects_noncanonical_shapes(self) -> None:
        invalid = {
            "missing on": """\
push:
  branches:
    - "agent/**"
    - "!agent/host-loop/**"
""",
            "inline on": 'on: {"push": {"branches": ["agent/**"]}}\n',
            "duplicate on": VALID_ON_BLOCK + VALID_ON_BLOCK,
            "unknown event": VALID_ON_BLOCK + "  pull_request:\n",
            "duplicate push": VALID_ON_BLOCK + "  push:\n",
            "flow list": """\
on:
  push:
    branches: ["agent/**", "!agent/host-loop/**"]
""",
            "branches ignore": """\
on:
  push:
    branches-ignore:
      - "agent/host-loop/**"
""",
            "extra filter": VALID_ON_BLOCK + '    paths:\n      - "**"\n',
            "alias": """\
on:
  push:
    branches: *agent-branches
""",
            "unquoted": """\
on:
  push:
    branches:
      - agent/**
      - !agent/host-loop/**
""",
            "reversed": """\
on:
  push:
    branches:
      - "!agent/host-loop/**"
      - "agent/**"
""",
            "missing positive": """\
on:
  push:
    branches:
      - "!agent/host-loop/**"
""",
            "missing negative": """\
on:
  push:
    branches:
      - "agent/**"
""",
            "extra reinclude": VALID_ON_BLOCK
            + '      - "agent/host-loop/probes/**"\n',
            "job if substitute": """\
on:
  push:
    branches:
      - "agent/**"
jobs:
  open-pr:
    if: ${{ !startsWith(github.ref_name, 'agent/host-loop/') }}
""",
        }
        for name, on_block in invalid.items():
            with self.subTest(name=name):
                with self.assertRaises(WorkflowContractError):
                    validate_agent_pr_filter(_workflow(on_block))

        for malformed_text in (
            VALID_ON_BLOCK.replace("  push:", "\tpush:"),
            VALID_ON_BLOCK.replace("\n", "\r\n"),
        ):
            with self.assertRaises(WorkflowContractError):
                validate_agent_pr_filter(_workflow(malformed_text))


if __name__ == "__main__":
    unittest.main(verbosity=2)
