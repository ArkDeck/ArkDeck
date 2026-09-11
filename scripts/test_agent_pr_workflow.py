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
RUST_POLICY_TOOLS_CACHE_KEY = (
    "arkdeck-cargo-policy-tools-v1-${{ runner.os }}-${{ runner.arch }}"
    "-cargo-deny-0.20.2-cargo-vet-0.10.2-${{ hashFiles('rust/rust-toolchain.toml') }}"
)
ARKFORGE_AUTH_PATH = REPOSITORY_ROOT / "scripts" / "ci" / "arkforge-package-auth.sh"
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
    allowed_job = _job_block(agent_text, "allowed-paths")
    required_open = (
        "    permissions:\n      contents: read\n      pull-requests: write\n",
        "    outputs:\n      pr-number: ${{ steps.validate.outputs.pr-number }}\n",
        "          fetch-depth: 0\n",
        "--preflight",
        "--base-revision origin/main",
        '--head-revision "$HEAD_SHA"',
        '--expected-head-ref "$BRANCH"',
        "--allow-bootstrap",
        "--infer-task",
        'none|bootstrap|TASK-*)',
        'if [ "$TASK_ID" = "bootstrap" ]; then',
        "maintainer-authorized one-time base/head/path tuple",
        'if [ "$TASK_ID" != "none" ]; then',
        "printf 'Task: %s\\n\\n' \"$TASK_ID\" >> \"$BODY\"",
        "grep -E '^[[:space:]]*Scope-Extension:' >> \"$BODY\" || true",
        "gh api --method GET --paginate --slurp",
        "--pull-list \"$CANDIDATES\"",
        "--identity-only",
        "--expected-author 'github-actions[bot]'",
        'echo "pr-number=$VALIDATED_NUMBER" >> "$GITHUB_OUTPUT"',
    )
    required_allowed = (
        "    needs: open-pr\n",
        "    permissions:\n      contents: read\n      pull-requests: read\n",
        "PR_NUMBER: ${{ needs.open-pr.outputs.pr-number }}",
        "gh api --method GET --paginate --slurp",
        "--pull-list \"$CANDIDATES\"",
        'if [ "$CURRENT_NUMBER" != "$PR_NUMBER" ]; then',
        '"/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER"',
        "--pull-request \"$PULL_REQUEST\"",
        "--expected-head-oid \"$HEAD_SHA\"",
        "--allow-bootstrap",
        '--scope-extension-summary "$RUNNER_TEMP/scope-extension.md"',
        'cat "$RUNNER_TEMP/scope-extension.md" >> "$GITHUB_STEP_SUMMARY"',
    )
    for token in required_open:
        if token not in open_job:
            raise WorkflowContractError(f"open-pr job missing contract token: {token}")
    for token in required_allowed:
        if token not in allowed_job:
            raise WorkflowContractError(
                f"allowed-paths job missing contract token: {token}"
            )
    preflight_index = open_job.index("--preflight")
    task_body_index = open_job.index("printf 'Task: %s\\n\\n'")
    create_index = open_job.index("gh pr create")
    if not preflight_index < task_body_index < create_index:
        raise WorkflowContractError(
            "Agent PR must preflight and write Task before creating the PR"
        )
    extension_body_index = open_job.index("Scope-Extension:")
    if not task_body_index < extension_body_index < create_index:
        raise WorkflowContractError(
            "Agent PR must copy Scope-Extension trailers after Task and before creating the PR"
        )
    if agent_text.count("--allow-bootstrap") != 2:
        raise WorkflowContractError(
            "one-time bootstrap must be wired exactly once per Agent PR job"
        )

    allowed_swift_secret = "${{ secrets.ARKFORGE_DEPLOY_KEY }}"
    if swift_text.count(allowed_swift_secret) != 2:
        raise WorkflowContractError(
            "Swift CI must expose the ArkForge deploy key only to both setup steps"
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

    plan_job = _job_block(swift_text, "plan")
    swift_tests_job = _job_block(swift_text, "swift-tests")
    app_build_job = _job_block(swift_text, "app-build")
    ds_job = _job_block(swift_text, "ds-interactions")
    rust_job = _job_block(swift_text, "rust-checks")
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
    required_plan = (
        "    runs-on: ubuntu-latest\n",
        '"+refs/heads/main:refs/remotes/origin/main"',
        '"+${ARKDECK_CI_REF}:refs/remotes/origin/ci"',
        "python3 scripts/ci/test_plan.py",
        "python3 scripts/test_agent_pr_workflow.py",
        "python3 scripts/ci/plan.py",
        '--event "$GITHUB_EVENT_PATH"',
        '--github-output "$GITHUB_OUTPUT"',
        "      rust: ${{ steps.paths.outputs.rust }}\n",
    )
    required_swift_tests = (
        "    needs: plan\n",
        "    if: needs.plan.outputs.swift == 'true'\n",
        "    runs-on: macos-26\n",
        "DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer",
        "ARKDECK_SWIFTPM_CACHE_ROOT: ${{ runner.temp }}/arkdeck-swiftpm",
        "python3 Packages/ArkDeckKit/Scripts/test_run_swiftpm.py",
        "actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
        "          restore-keys: |\n"
        "            arkdeck-swiftpm-v2-${{ runner.os }}-${{ runner.arch }}-xcode-26.6-"
        "${{ hashFiles('Packages/ArkDeckKit/Package.swift') }}-\n"
        "            arkdeck-swiftpm-v2-${{ runner.os }}-${{ runner.arch }}-xcode-26.6-\n",
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
        "    runs-on: macos-26\n",
        "ARKDECK_XCODE_CACHE_ROOT: ${{ runner.temp }}/arkdeck-xcode",
        "python3 scripts/ci/test_run_xcodebuild.py",
        "actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
        "          restore-keys: |\n"
        "            arkdeck-xcode-v2-${{ runner.os }}-${{ runner.arch }}-xcode-26.6-"
        "${{ hashFiles('ArkDeck.xcodeproj/project.pbxproj', 'Packages/ArkDeckKit/Package.swift', 'Packages/ArkDeckKit/Package.resolved') }}-\n"
        "            arkdeck-xcode-v2-${{ runner.os }}-${{ runner.arch }}-xcode-26.6-\n",
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
        "    needs: [plan, swift-tests, app-build, ds-interactions, rust-checks]\n",
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
    )
    required_rust = (
        "    needs: plan\n",
        "    if: needs.plan.outputs.rust == 'true'\n",
        "    uses: ./.github/workflows/rust-ci.yml\n",
    )
    for token in required_plan:
        if token not in plan_job:
            raise WorkflowContractError(f"Swift plan job missing contract token: {token}")
    for token in required_swift_tests:
        if token not in swift_tests_job:
            raise WorkflowContractError(
                f"Swift test job missing contract token: {token}"
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
    for token in required_aggregate:
        if token not in swift_aggregate_job:
            raise WorkflowContractError(
                f"Swift aggregate job missing contract token: {token}"
            )


def validate_rust_ci_contract(text: str) -> None:
    """Require native host checks and fail-closed locked dependency audits."""

    if extract_event_names(text) != ("workflow_call",):
        raise WorkflowContractError("Rust CI must be called through the shared planner")
    required = (
        "permissions:\n  contents: read\n",
        "      fail-fast: false\n",
        "        os: [ubuntu-latest, macos-26, windows-latest]\n",
        "    runs-on: ${{ matrix.os }}\n",
        "        shell: bash\n        working-directory: rust\n",
        "git config core.autocrlf false",
        '"+refs/heads/main:refs/remotes/origin/main"',
        'test "$(git rev-parse HEAD)" = "$ARKDECK_CI_SHA"',
        "actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97",
        '          python-version: "3.14"\n',
        "run: python -m pip install PyYAML==6.0.3 jsonschema==4.26.0",
        "run: python rust/scripts/generate-contract.py --check",
        "rustup toolchain install --profile minimal --component rustfmt,clippy --no-self-update",
        "rustup show active-toolchain",
        "run: cargo fmt --all --check",
        "run: cargo fetch --locked",
        # Only these two steps compile and run the checkout. Every contract
        # step either reads Git objects at the pinned Swift commit or builds a
        # separate candidate view, so dropping either one lets a workspace
        # that does not build, or whose tests fail, pass a green rust lane.
        # The workspace tests run through a wrapper that keeps the pin's
        # currency and the Rust code's correctness as separate questions;
        # calling `cargo test --workspace` directly here fails every branch
        # that legitimately changes a recorded frame.
        "run: cargo clippy --workspace --all-targets -- -D warnings\n",
        "        working-directory: .\n"
        "        run: python rust/scripts/workspace-tests.py\n",
        "        working-directory: .\n"
        "        run: python rust/scripts/test_contract_checks.py\n",
        "        working-directory: .\n"
        "        run: python rust/scripts/check-contracts.py\n",
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
        "        if: steps.policy-tools.outputs.cache-hit != 'true'\n",
        "cargo install --locked --version 0.20.2 cargo-deny",
        "cargo install --locked --version 0.10.2 cargo-vet",
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
        "      - name: Preserve actual read-only recordings\n"
        "        if: always()\n"
        "        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1 (Node 24)\n"
        "        with:\n"
        "          name: rust-readonly-recordings-${{ matrix.os }}\n"
        "          path: rust/target/readonly-check/\n"
        "          if-no-files-found: warn\n"
        "          retention-days: 7\n",
    )
    for token in required:
        if token not in text:
            raise WorkflowContractError(f"Rust CI missing contract token: {token}")
    for token in (
        "continue-on-error:", "secrets.", "secrets[", "secrets: inherit",
        "contents: write", "id-token: write", "cargo vet init",
        "cargo vet regenerate", "cargo vet add-exemption", "|| true",
        "--depth=", "--depth ", "restore-keys:",
    ):
        if token in text:
            raise WorkflowContractError(f"Rust CI contains forbidden token: {token}")
    if text.count(RUST_POLICY_TOOLS_CACHE_KEY) != 2:
        raise WorkflowContractError(
            "Rust CI must restore and save the policy tools under one exact key "
            "naming both pinned versions and the pinned toolchain"
        )
    restore = text.index("      - name: Restore pinned dependency policy tools")
    install = text.index("      - name: Install pinned dependency policy tools")
    read_back = text.index("      - name: Require the pinned dependency policy tool versions")
    save = text.index("      - name: Save pinned dependency policy tools")
    if not (restore < install < read_back < save < text.index("run: cargo deny --locked check")):
        raise WorkflowContractError(
            "Rust CI must restore, install on a miss, read back the pinned versions "
            "and save before the dependency policy checks"
        )
    if text.index("run: cargo fetch --locked") > text.index("run: cargo vet --locked"):
        raise WorkflowContractError("Rust CI must fetch locked metadata before locked vet")
    if text.index("rustup toolchain install") > text.index(
        "run: python rust/scripts/generate-contract.py --check"
    ):
        raise WorkflowContractError("Rust CI must install rustfmt before checking generated inputs")
    if text.index("run: python rust/scripts/generate-contract.py --check") > text.index(
        "run: python rust/scripts/check-contracts.py"
    ):
        raise WorkflowContractError("Rust CI must check generated inputs before compilation")
    if text.index("run: cargo fetch --locked") > text.index(
        "run: python rust/scripts/check-contracts.py"
    ):
        raise WorkflowContractError("Rust CI must fetch locked metadata before contract checks")
    if text.index("run: python rust/scripts/test_contract_checks.py") > text.index(
        "run: python rust/scripts/check-contracts.py"
    ):
        raise WorkflowContractError("Rust CI must verify isolation and provenance before contract checks")
    if text.index("run: python rust/scripts/check-contracts.py") > text.index(
        "run: cargo deny --locked check"
    ):
        raise WorkflowContractError("Rust CI must record contract checks before dependency policy")
    if text.index("run: python rust/scripts/check-contracts.py") > text.index(
        "      - name: Preserve actual read-only recordings"
    ):
        raise WorkflowContractError("Rust CI must preserve recordings after their producer runs")


def validate_arkforge_private_package_auth(swift_text: str, auth_text: str) -> None:
    """Pin least-privilege private Swift-package access in both compiled lanes."""

    setup = """      - name: Configure read-only ArkForge package access
        env:
          ARKFORGE_DEPLOY_KEY: ${{ secrets.ARKFORGE_DEPLOY_KEY }}
        run: sh scripts/ci/arkforge-package-auth.sh setup
"""
    cleanup = """      - name: Remove ArkForge package credential
        if: always()
        run: sh scripts/ci/arkforge-package-auth.sh cleanup
"""
    if swift_text.count(setup) != 2:
        raise WorkflowContractError(
            "both compiled lanes must configure the ArkForge deploy key exactly once"
        )
    if swift_text.count(cleanup) != 2:
        raise WorkflowContractError(
            "both compiled lanes must always remove the ArkForge deploy key"
        )

    swift_tests_job = _job_block(swift_text, "swift-tests")
    app_build_job = _job_block(swift_text, "app-build")
    for job_name, job_block, build_token in (
        ("Swift test", swift_tests_job, "ArkDeckKit full test suite (8 workers)"),
        ("App build", app_build_job, "Build ArkDeck app and UI-test bundle"),
    ):
        setup_index = job_block.find(setup)
        build_index = job_block.find(build_token)
        cleanup_index = job_block.find(cleanup)
        if not (0 <= setup_index < build_index < cleanup_index):
            raise WorkflowContractError(
                f"{job_name} ArkForge credential lifetime does not bracket the build"
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

    def test_rust_checks_reject_skipped_hosts_and_unlocked_or_bypassed_policy(self) -> None:
        rust = RUST_WORKFLOW_PATH.read_text(encoding="utf-8")
        bootstrap = rust[
            rust.index("      - name: Activate workspace toolchain"):
            rust.index("      - name: Verify generated contract inputs")
        ]
        mutations = (
            rust.replace(bootstrap, "").replace(
                "      - name: Format check", bootstrap + "      - name: Format check"
            ),
            rust.replace("  workflow_call:\n", "  push:\n"),
            rust.replace(
                "os: [ubuntu-latest, macos-26, windows-latest]",
                "os: [ubuntu-latest, macos-26]",
            ),
            rust.replace("run: python rust/scripts/test_contract_checks.py", "run: true"),
            rust.replace(
                "run: cargo clippy --workspace --all-targets -- -D warnings\n",
                "run: cargo clippy --workspace\n",
            ),
            rust.replace(
                "run: cargo clippy --workspace --all-targets -- -D warnings\n", "run: true\n"
            ),
            rust.replace(
                "run: python rust/scripts/workspace-tests.py\n",
                "run: cargo test -p arkdeck-contract\n",
            ),
            rust.replace("run: python rust/scripts/workspace-tests.py\n", "run: true\n"),
            rust.replace("run: python rust/scripts/check-contracts.py", "run: cargo test --workspace --locked"),
            rust.replace("run: python rust/scripts/check-contracts.py", "run: python rust/scripts/check-contracts.py --published-only"),
            rust.replace(
                "run: cargo deny --locked check", "run: cargo deny --locked check || true"
            ),
            rust.replace("run: cargo vet --locked --no-registry-suggestions", "run: cargo vet"),
            rust.replace(
                "cargo install --locked --version 0.10.2 cargo-vet", "cargo install cargo-vet"
            ),
            rust + "\n        continue-on-error: true\n",
            rust + "\n        run: cargo vet init\n",
            rust.replace("working-directory: rust", "working-directory: ."),
            rust.replace("git config core.autocrlf false", "git config core.autocrlf true"),
            rust.replace("git fetch --no-tags --prune origin", "git fetch --depth=1 origin"),
            rust.replace(
                "run: python rust/scripts/generate-contract.py --check", "run: true"
            ),
            rust.replace("run: python rust/scripts/check-contracts.py", "run: true"),
        )
        for mutated in mutations:
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
            # The install must stay the miss path of that memo, not disappear.
            rust.replace("        if: steps.policy-tools.outputs.cache-hit != 'true'\n        run: |\n", "        run: |\n"),
            rust.replace("actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9", "actions/cache/restore@v6"),
            rust.replace("actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9", "actions/cache/save@v6"),
        )
        for mutated in mutations:
            with self.assertRaises(WorkflowContractError):
                validate_rust_ci_contract(mutated)

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
        mutations = (
            (swift.replace("        if: always()\n", "        if: success()\n", 1), auth),
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
            ("missing dependency", agent.replace("    needs: open-pr\n", ""), sdd, swift),
            (
                "write validation",
                agent.replace(
                    "      pull-requests: read\n", "      pull-requests: write\n"
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
                    "      DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer\n",
                    "      DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer\n"
                    "      INVALID_JOB_CACHE: ${{ runner.temp }}/invalid\n",
                    1,
                ),
            ),
            (
                "missing SwiftPM toolchain fallback",
                agent,
                sdd,
                swift.replace(
                    "            arkdeck-swiftpm-v2-${{ runner.os }}-${{ runner.arch }}-xcode-26.6-\n",
                    "",
                ),
            ),
            (
                "missing Xcode toolchain fallback",
                agent,
                sdd,
                swift.replace(
                    "            arkdeck-xcode-v2-${{ runner.os }}-${{ runner.arch }}-xcode-26.6-\n",
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
