#!/usr/bin/env python3
"""Fail closed when a pull request exceeds its declared task paths.

TASK-MECH-004 keeps approval semantics unchanged: this is a read-only guard
against accidental scope expansion, not an authorization or approval oracle.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


TASK_TOKEN_TEXT = r"TASK-[A-Z0-9]+-[0-9]{3}"
TASK_TOKEN_RE = re.compile(rf"(?<![A-Z0-9-])({TASK_TOKEN_TEXT})(?![A-Z0-9-])")
TASK_LINE_RE = re.compile(rf"^\s*Task:\s*({TASK_TOKEN_TEXT})\s*$", re.MULTILINE)
TASK_HEADER_RE = re.compile(
    r"^##\s+(TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?)(?:\s|$)",
    re.MULTILINE,
)
FULL_TASK_RE = re.compile(rf"^{TASK_TOKEN_TEXT}$")
FULL_OID_RE = re.compile(r"^[0-9a-fA-F]{40}$")
ALLOWED_PATHS_RE = re.compile(
    r"^- Allowed paths(?:\([^\n)]*\)|（[^\n）]*）| after readiness)?[:：](.*)$",
    re.MULTILINE,
)
BACKTICK_PATH_RE = re.compile(r"(?:(本\s+change)\s*)?`([^`\n]+)`")

SENSITIVE_PATTERNS = (
    "Packages/**",
    "ArkDeckApp/**",
    "ArkDeckAppUITests/**",
    "scripts/**",
    ".github/**",
)


class CheckError(ValueError):
    """A named, user-correctable PR scope violation."""


@dataclass(frozen=True)
class PullRequestContext:
    title: str
    body: str
    head_ref: str
    base_oid: str
    head_oid: str


@dataclass(frozen=True)
class TaskDefinition:
    task_id: str
    tasks_file: Path
    section: str

    @property
    def change_directory(self) -> Path:
        return self.tasks_file.parent


@dataclass(frozen=True)
class CheckResult:
    task_id: str | None
    changed_paths: tuple[str, ...]
    allowed_patterns: tuple[str, ...]


def _string(value: object, field: str) -> str:
    if not isinstance(value, str):
        raise CheckError(f"pull_request {field} must be a string")
    return value


def load_pull_request_context(event_path: Path) -> PullRequestContext:
    try:
        event = json.loads(event_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CheckError(f"cannot parse pull_request event {event_path}: {error}") from error

    pull_request = event.get("pull_request") if isinstance(event, dict) else None
    if not isinstance(pull_request, dict):
        raise CheckError("event has no pull_request object")

    base = pull_request.get("base")
    head = pull_request.get("head")
    if not isinstance(base, dict) or not isinstance(head, dict):
        raise CheckError("pull_request base/head objects are missing")

    title = _string(pull_request.get("title"), "title")
    body_value = pull_request.get("body")
    if body_value is None:
        body = ""
    else:
        body = _string(body_value, "body")
    head_ref = _string(head.get("ref"), "head.ref")
    base_oid = _string(base.get("sha"), "base.sha")
    head_oid = _string(head.get("sha"), "head.sha")
    if not FULL_OID_RE.fullmatch(base_oid) or not FULL_OID_RE.fullmatch(head_oid):
        raise CheckError("pull_request base/head SHA must each be a full 40-hex OID")

    return PullRequestContext(
        title=title,
        body=body,
        head_ref=head_ref,
        base_oid=base_oid.lower(),
        head_oid=head_oid.lower(),
    )


def resolve_task_declaration(context: PullRequestContext) -> str | None:
    body_tasks = TASK_LINE_RE.findall(context.body)
    title_tasks = TASK_TOKEN_RE.findall(context.title)
    explicit_tasks = set(body_tasks) | set(title_tasks)
    if len(explicit_tasks) > 1:
        rendered = ", ".join(sorted(explicit_tasks))
        raise CheckError(f"PR title/body declare multiple distinct tasks: {rendered}")

    if body_tasks:
        return body_tasks[0]
    if title_tasks:
        return title_tasks[0]

    branch_prefix = "agent/task-"
    if not context.head_ref.startswith(branch_prefix):
        return None
    slug = context.head_ref[len(branch_prefix) :]
    candidate = f"TASK-{slug.upper()}"
    if not FULL_TASK_RE.fullmatch(candidate):
        raise CheckError(
            f"branch task declaration {context.head_ref!r} normalizes to invalid {candidate!r}"
        )
    return candidate


def load_task_definitions(repo_root: Path) -> dict[str, TaskDefinition]:
    definitions: dict[str, TaskDefinition] = {}
    changes_root = repo_root / "openspec" / "changes"
    for tasks_file in sorted(changes_root.glob("chg-*/tasks.md")):
        try:
            text = tasks_file.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise CheckError(f"cannot read active tasks file {tasks_file}: {error}") from error
        headers = list(TASK_HEADER_RE.finditer(text))
        for index, header in enumerate(headers):
            task_id = header.group(1)
            if task_id in definitions:
                other = definitions[task_id].tasks_file
                raise CheckError(
                    f"task {task_id} is duplicated in active changes: {other} and {tasks_file}"
                )
            end = headers[index + 1].start() if index + 1 < len(headers) else len(text)
            definitions[task_id] = TaskDefinition(
                task_id=task_id,
                tasks_file=tasks_file,
                section=text[header.start() : end],
            )
    return definitions


def extract_allowed_patterns(repo_root: Path, task: TaskDefinition) -> tuple[str, ...]:
    matches = list(ALLOWED_PATHS_RE.finditer(task.section))
    if not matches:
        raise CheckError(f"task {task.task_id} has no Allowed paths line")
    if len(matches) > 1:
        raise CheckError(f"task {task.task_id} has multiple Allowed paths lines")

    match = matches[0]
    block_lines = [match.group(1)]
    remainder = task.section[match.end() :].splitlines()
    for line in remainder:
        if line.startswith("- ") or line.startswith("## "):
            break
        block_lines.append(line)
    block = "\n".join(block_lines)

    change_relative = task.change_directory.relative_to(repo_root).as_posix()
    patterns: list[str] = []
    for token in BACKTICK_PATH_RE.finditer(block):
        path_pattern = token.group(2).strip()
        if not path_pattern:
            continue
        if token.group(1):
            path_pattern = f"{change_relative}/{path_pattern}"
        patterns.append(path_pattern)

    if not patterns:
        raise CheckError(f"task {task.task_id} Allowed paths yields zero backtick path tokens")
    return tuple(patterns)


def path_matches(path: str, patterns: Iterable[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def check_paths(
    repo_root: Path,
    context: PullRequestContext,
    changed_paths: Sequence[str],
) -> CheckResult:
    normalized_paths = tuple(path.replace("\\", "/") for path in changed_paths)
    task_id = resolve_task_declaration(context)
    if task_id is None:
        offenders = sorted(
            path for path in normalized_paths if path_matches(path, SENSITIVE_PATTERNS)
        )
        if offenders:
            raise CheckError(
                "PR has no task declaration and touches sensitive paths: "
                + ", ".join(offenders)
            )
        return CheckResult(None, normalized_paths, SENSITIVE_PATTERNS)

    definitions = load_task_definitions(repo_root)
    task = definitions.get(task_id)
    if task is None:
        raise CheckError(f"declared task {task_id} does not exist in an active change")
    allowed_patterns = extract_allowed_patterns(repo_root, task)
    offenders = sorted(
        path for path in normalized_paths if not path_matches(path, allowed_patterns)
    )
    if offenders:
        raise CheckError(
            f"declared task {task_id} has paths outside Allowed paths: "
            + ", ".join(offenders)
        )
    return CheckResult(task_id, normalized_paths, allowed_patterns)


def git_changed_paths(repo_root: Path, base_oid: str, head_oid: str) -> tuple[str, ...]:
    completed = subprocess.run(
        [
            "git",
            "-C",
            str(repo_root),
            "diff",
            "--no-renames",
            "--name-only",
            "-z",
            f"{base_oid}..{head_oid}",
            "--",
        ],
        check=False,
        capture_output=True,
    )
    if completed.returncode != 0:
        stderr = completed.stderr.decode("utf-8", errors="replace").strip()
        raise CheckError(f"git diff {base_oid}..{head_oid} failed: {stderr}")
    try:
        decoded = completed.stdout.decode("utf-8")
    except UnicodeDecodeError as error:
        raise CheckError(f"git diff returned a non-UTF-8 path: {error}") from error
    return tuple(path for path in decoded.split("\0") if path)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--event", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    repo_root = args.repo_root.resolve()
    try:
        context = load_pull_request_context(args.event)
        changed_paths = git_changed_paths(repo_root, context.base_oid, context.head_oid)
        result = check_paths(repo_root, context, changed_paths)
    except CheckError as error:
        print(f"check_pr_paths: ERROR: {error}", file=sys.stderr)
        return 1

    declaration = result.task_id or "none (docs/governance-only)"
    print(
        "check_pr_paths: PASS; "
        f"task={declaration}; changed_paths={len(result.changed_paths)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
