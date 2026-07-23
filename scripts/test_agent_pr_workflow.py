#!/usr/bin/env python3
"""Contract tests for the legacy Agent PR workflow namespace partition.

The parser is intentionally narrow: it accepts only the reviewed YAML shape for
``on.push.branches`` and fails closed on alternate event/filter spellings.  It
uses only the Python standard library so the contract can run before installing
the SDD requirements.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
WORKFLOW_PATH = REPOSITORY_ROOT / ".github" / "workflows" / "agent-pr.yml"
EXPECTED_BRANCH_PATTERNS = ("agent/**", "!agent/host-loop/**")

TASK_ID_PATTERN = r"TASK-[A-Z0-9]+-[A-Z0-9]+(?:-[A-Z0-9]+)*"
UUID4_PATTERN = (
    r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12}"
)
RESERVED_BRANCH_RE = re.compile(
    rf"\Aagent/host-loop/(?:"
    rf"tasks/(?P<task>{TASK_ID_PATTERN})|"
    rf"leases/(?P<lease>{TASK_ID_PATTERN})|"
    rf"probes/(?P<probe>{UUID4_PATTERN})"
    rf")\Z"
)


class WorkflowContractError(ValueError):
    """The workflow event filter is outside the reviewed contract."""


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
        result.append((number, line))
    return result


def extract_push_branches(text: str) -> tuple[str, ...]:
    """Extract the closed ``on.push.branches`` block without a YAML dependency."""

    lines = _meaningful_lines(text)
    top_level_on = [
        index for index, (_, line) in enumerate(lines) if line == "on:"
    ]
    if len(top_level_on) != 1:
        raise WorkflowContractError(
            f"expected exactly one top-level on block, found {len(top_level_on)}"
        )

    start = top_level_on[0]
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if not lines[index][1].startswith(" "):
            end = index
            break
    on_lines = lines[start + 1 : end]
    if not on_lines:
        raise WorkflowContractError("on block is empty")

    event_lines = [(number, line) for number, line in on_lines if line.startswith("  ")]
    for number, line in event_lines:
        if line.startswith("    "):
            continue
        if line != "  push:":
            raise WorkflowContractError(
                f"line {number}: unknown or non-canonical event entry"
            )
    push_entries = [(number, line) for number, line in on_lines if line == "  push:"]
    if len(push_entries) != 1:
        raise WorkflowContractError(
            f"expected exactly one push event, found {len(push_entries)}"
        )

    push_index = on_lines.index(push_entries[0])
    push_end = len(on_lines)
    for index in range(push_index + 1, len(on_lines)):
        line = on_lines[index][1]
        if line.startswith("  ") and not line.startswith("    "):
            push_end = index
            break
    push_lines = on_lines[push_index + 1 : push_end]
    if not push_lines:
        raise WorkflowContractError("push event is empty")

    filter_entries: list[tuple[int, str]] = []
    for number, line in push_lines:
        if line.startswith("      "):
            continue
        if not line.startswith("    "):
            raise WorkflowContractError(
                f"line {number}: invalid push filter indentation"
            )
        filter_entries.append((number, line))
        if line != "    branches:":
            raise WorkflowContractError(
                f"line {number}: unknown or non-canonical push filter"
            )
    if len(filter_entries) != 1:
        raise WorkflowContractError(
            f"expected exactly one branches filter, found {len(filter_entries)}"
        )

    branches_index = push_lines.index(filter_entries[0])
    item_lines = push_lines[branches_index + 1 :]
    if not item_lines:
        raise WorkflowContractError("branches filter is empty")

    patterns: list[str] = []
    item_re = re.compile(r'^      - ("(?:[^"\\]|\\.)*")$')
    for number, line in item_lines:
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
    if patterns != EXPECTED_BRANCH_PATTERNS:
        raise WorkflowContractError(
            "on.push.branches must equal the reviewed include/exclude sequence"
        )
    return patterns


def _glob_regex(pattern: str) -> re.Pattern[str]:
    pieces: list[str] = [r"\A"]
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "*" and index + 1 < len(pattern) and pattern[index + 1] == "*":
            pieces.append(".*")
            index += 2
            continue
        if char == "*":
            pieces.append("[^/]*")
        elif char == "?":
            pieces.append("[^/]")
        else:
            pieces.append(re.escape(char))
        index += 1
    pieces.append(r"\Z")
    return re.compile("".join(pieces))


def branch_dispatches(patterns: tuple[str, ...], branch: str) -> bool:
    """Evaluate ordered positive/negative GitHub branch patterns."""

    if not patterns or not any(not pattern.startswith("!") for pattern in patterns):
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


def _workflow_with_on_block(on_block: str) -> str:
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
    def test_repository_workflow_has_exact_ordered_filter(self) -> None:
        text = WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertEqual(validate_agent_pr_filter(text), EXPECTED_BRANCH_PATTERNS)

    def test_ordered_filter_dispatch_matrix(self) -> None:
        dispatches = (
            "agent/task-hlr-002a-bootstrap-partition",
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

        for branch in dispatches:
            with self.subTest(branch=branch):
                self.assertTrue(branch_dispatches(EXPECTED_BRANCH_PATTERNS, branch))
        for branch in excluded + ignored:
            with self.subTest(branch=branch):
                self.assertFalse(branch_dispatches(EXPECTED_BRANCH_PATTERNS, branch))

    def test_ordered_evaluator_honors_reinclude(self) -> None:
        patterns = ("agent/**", "!agent/host-loop/**", "agent/host-loop/probes/**")
        self.assertFalse(
            branch_dispatches(patterns, "agent/host-loop/tasks/TASK-HLR-003")
        )
        self.assertTrue(
            branch_dispatches(
                patterns,
                "agent/host-loop/probes/123e4567-e89b-42d3-a456-426614174000",
            )
        )

    def test_reserved_namespace_positive_matrix(self) -> None:
        branches = {
            "agent/host-loop/tasks/TASK-HLR-002A": "task",
            "agent/host-loop/tasks/TASK-AF-014-REMEDIATION": "task",
            "agent/host-loop/leases/TASK-HLR-003": "lease",
            "agent/host-loop/probes/123e4567-e89b-42d3-a456-426614174000": "probe",
        }
        for branch, family in branches.items():
            with self.subTest(branch=branch):
                self.assertEqual(reserved_family(branch), family)

    def test_reserved_namespace_negative_matrix(self) -> None:
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
            "agent/host-loop/probes/..",
        )
        for branch in branches:
            with self.subTest(branch=branch):
                self.assertIsNone(reserved_family(branch))

    def test_parser_rejects_noncanonical_event_filters(self) -> None:
        invalid_blocks = {
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
            "extra filter": VALID_ON_BLOCK + "    paths:\n      - \"**\"\n",
            "alias": """\
on:
  push:
    branches: *agent-branches
""",
            "unquoted scalar": """\
on:
  push:
    branches:
      - agent/**
      - !agent/host-loop/**
""",
            "reversed order": """\
on:
  push:
    branches:
      - "!agent/host-loop/**"
      - "agent/**"
""",
            "missing negative": """\
on:
  push:
    branches:
      - "agent/**"
""",
            "missing positive": """\
on:
  push:
    branches:
      - "!agent/host-loop/**"
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
        for name, on_block in invalid_blocks.items():
            with self.subTest(name=name):
                with self.assertRaises(WorkflowContractError):
                    validate_agent_pr_filter(_workflow_with_on_block(on_block))


if __name__ == "__main__":
    unittest.main(verbosity=2)
