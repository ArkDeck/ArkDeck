#!/usr/bin/env python3
"""Closed contract for the legacy Agent PR namespace partition.

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
    )
    for token in required_open:
        if token not in open_job:
            raise WorkflowContractError(f"open-pr job missing contract token: {token}")
    for token in required_allowed:
        if token not in allowed_job:
            raise WorkflowContractError(
                f"allowed-paths job missing contract token: {token}"
            )

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
        if token in agent_text + sdd_text + swift_text:
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
