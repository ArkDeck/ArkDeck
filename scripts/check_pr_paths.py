#!/usr/bin/env python3
"""Fail closed when a pull request exceeds its declared task paths.

TASK-MECH-004 keeps approval semantics unchanged: this is a read-only guard
against accidental scope expansion, not an authorization or approval oracle.
"""

from __future__ import annotations

import argparse
import datetime
import fnmatch
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


TASK_TOKEN_TEXT = r"TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?"
TASK_TOKEN_RE = re.compile(rf"(?<![A-Z0-9-])({TASK_TOKEN_TEXT})(?![A-Z0-9-])")
TASK_LINE_RE = re.compile(rf"^\s*Task:\s*({TASK_TOKEN_TEXT})\s*$", re.MULTILINE)
TASK_HEADER_RE = re.compile(rf"^##\s+({TASK_TOKEN_TEXT})(?:\s|$)", re.MULTILINE)
FULL_TASK_RE = re.compile(rf"^{TASK_TOKEN_TEXT}$")
FULL_OID_RE = re.compile(r"^[0-9a-fA-F]{40}$")
CALENDAR_DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
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
class GitTreeEntry:
    mode: str
    object_type: str
    oid: str
    path: str


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


def parse_task_definitions(
    repo_root: Path,
    documents: Iterable[tuple[Path, str]],
    *,
    source: str,
) -> dict[str, TaskDefinition]:
    definitions: dict[str, TaskDefinition] = {}
    for tasks_file, task_text in documents:
        headers = list(TASK_HEADER_RE.finditer(task_text))
        for index, header in enumerate(headers):
            task_id = header.group(1)
            if task_id in definitions:
                other = definitions[task_id].tasks_file
                raise CheckError(
                    f"task {task_id} is duplicated in {source}: {other} and {tasks_file}"
                )
            end = (
                headers[index + 1].start()
                if index + 1 < len(headers)
                else len(task_text)
            )
            definitions[task_id] = TaskDefinition(
                task_id=task_id,
                tasks_file=tasks_file,
                section=task_text[header.start() : end],
            )
    return definitions


def load_task_definitions(repo_root: Path) -> dict[str, TaskDefinition]:
    documents: list[tuple[Path, str]] = []
    changes_root = repo_root / "openspec" / "changes"
    for tasks_file in sorted(changes_root.glob("chg-*/tasks.md")):
        try:
            task_text = tasks_file.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise CheckError(f"cannot read active tasks file {tasks_file}: {error}") from error
        documents.append((tasks_file, task_text))
    return parse_task_definitions(
        repo_root,
        documents,
        source="active changes",
    )


def _run_git(repo_root: Path, arguments: Sequence[str], *, context: str) -> bytes:
    completed = subprocess.run(
        ["git", "-C", str(repo_root), *arguments],
        check=False,
        capture_output=True,
    )
    if completed.returncode != 0:
        stderr = completed.stderr.decode("utf-8", errors="replace").strip()
        raise CheckError(f"{context} failed: {stderr}")
    return completed.stdout


def git_tree_entries(repo_root: Path, oid: str, tree_path: str) -> tuple[GitTreeEntry, ...]:
    output = _run_git(
        repo_root,
        ["ls-tree", "-r", "-z", oid, "--", tree_path],
        context=f"git ls-tree {oid} -- {tree_path}",
    )
    entries: list[GitTreeEntry] = []
    for raw_record in output.split(b"\0"):
        if not raw_record:
            continue
        raw_metadata, separator, raw_path = raw_record.partition(b"\t")
        metadata = raw_metadata.split()
        if not separator or len(metadata) != 3:
            raise CheckError(
                f"git ls-tree {oid} -- {tree_path} returned a malformed entry"
            )
        try:
            mode, object_type, entry_oid = (
                value.decode("ascii") for value in metadata
            )
            path = raw_path.decode("utf-8")
        except UnicodeDecodeError as error:
            raise CheckError(
                f"git ls-tree {oid} -- {tree_path} returned a non-UTF-8 entry: {error}"
            ) from error
        if not FULL_OID_RE.fullmatch(entry_oid):
            raise CheckError(
                f"git ls-tree {oid} -- {tree_path} returned invalid object {entry_oid!r}"
            )
        entries.append(
            GitTreeEntry(
                mode=mode,
                object_type=object_type,
                oid=entry_oid.lower(),
                path=path,
            )
        )
    return tuple(entries)


def load_task_definitions_at_commit(
    repo_root: Path, oid: str
) -> dict[str, TaskDefinition]:
    documents: list[tuple[Path, str]] = []
    for entry in git_tree_entries(repo_root, oid, "openspec/changes"):
        parts = entry.path.split("/")
        if not (
            len(parts) == 4
            and parts[:2] == ["openspec", "changes"]
            and parts[2].startswith("chg-")
            and parts[3] == "tasks.md"
        ):
            continue
        if entry.object_type != "blob":
            raise CheckError(
                f"base active tasks path {entry.path} is not a blob"
            )
        raw_text = _run_git(
            repo_root,
            ["cat-file", "blob", entry.oid],
            context=f"git cat-file blob {entry.oid} for {entry.path}",
        )
        try:
            task_text = raw_text.decode("utf-8")
        except UnicodeDecodeError as error:
            raise CheckError(
                f"base active tasks file {entry.path} is not UTF-8: {error}"
            ) from error
        documents.append((repo_root / entry.path, task_text))
    return parse_task_definitions(
        repo_root,
        documents,
        source=f"base active changes at {oid}",
    )


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


def _archive_child_names(entries: Iterable[GitTreeEntry]) -> set[str]:
    prefix = "openspec/changes/archive/"
    children: set[str] = set()
    for entry in entries:
        if entry.path.startswith(prefix):
            children.add(entry.path[len(prefix) :].split("/", 1)[0])
    return children


def _valid_archive_target_name(target_name: str, change_name: str) -> bool:
    if len(target_name) <= 11 or target_name[10] != "-":
        return False
    date_text = target_name[:10]
    if not CALENDAR_DATE_RE.fullmatch(date_text):
        return False
    try:
        datetime.date.fromisoformat(date_text)
    except ValueError:
        return False
    return target_name[11:] == change_name


def _entries_relative_to(
    entries: Iterable[GitTreeEntry], root: str
) -> dict[str, GitTreeEntry]:
    prefix = f"{root}/"
    relative: dict[str, GitTreeEntry] = {}
    for entry in entries:
        if not entry.path.startswith(prefix):
            raise CheckError(
                f"git tree entry {entry.path!r} is not below expected root {root!r}"
            )
        relative_path = entry.path[len(prefix) :]
        if not relative_path or relative_path in relative:
            raise CheckError(
                f"git tree below {root} has duplicate or empty relative path {relative_path!r}"
            )
        relative[relative_path] = entry
    return relative


def reject_archive_copy_for_active_task(
    repo_root: Path,
    context: PullRequestContext,
    task: TaskDefinition,
    changed_paths: Sequence[str],
) -> None:
    change_name = task.change_directory.relative_to(repo_root).name
    archive_prefix = "openspec/changes/archive/"
    if not any(path.startswith(archive_prefix) for path in changed_paths):
        return
    base_children = _archive_child_names(
        git_tree_entries(repo_root, context.base_oid, "openspec/changes/archive")
    )
    head_children = _archive_child_names(
        git_tree_entries(repo_root, context.head_oid, "openspec/changes/archive")
    )
    newly_added = sorted(head_children - base_children)
    if newly_added:
        raise CheckError(
            f"atomic archive fallback rejected copied change {change_name}: "
            "active-root residue remains at head while new archive target(s) were added: "
            + ", ".join(newly_added)
        )


def verify_atomic_archive_fallback(
    repo_root: Path,
    context: PullRequestContext,
    task: TaskDefinition,
) -> frozenset[str]:
    active_root = task.change_directory.relative_to(repo_root).as_posix()
    change_name = task.change_directory.name
    archive_root = "openspec/changes/archive"

    base_archive_entries = git_tree_entries(repo_root, context.base_oid, archive_root)
    head_archive_entries = git_tree_entries(repo_root, context.head_oid, archive_root)
    base_children = _archive_child_names(base_archive_entries)
    head_children = _archive_child_names(head_archive_entries)
    newly_added = sorted(head_children - base_children)

    if not newly_added:
        preexisting = sorted(
            target
            for target in head_children & base_children
            if _valid_archive_target_name(target, change_name)
        )
        if preexisting:
            raise CheckError(
                "atomic archive fallback rejected pre-existing target(s): "
                + ", ".join(preexisting)
            )
        raise CheckError(
            f"atomic archive fallback for {change_name} has no newly added archive target"
        )
    if len(newly_added) != 1:
        raise CheckError(
            "atomic archive fallback has ambiguous newly added targets: "
            + ", ".join(newly_added)
        )

    target_name = newly_added[0]
    if not _valid_archive_target_name(target_name, change_name):
        raise CheckError(
            f"atomic archive fallback target {target_name!r} must be named "
            f"YYYY-MM-DD-{change_name} with a valid date"
        )
    target_root = f"{archive_root}/{target_name}"

    base_target_entries = git_tree_entries(repo_root, context.base_oid, target_root)
    if base_target_entries:
        raise CheckError(
            f"atomic archive fallback rejected pre-existing target {target_root}"
        )

    base_active_entries = git_tree_entries(repo_root, context.base_oid, active_root)
    if not base_active_entries:
        raise CheckError(
            f"atomic archive fallback base active root {active_root} has no tracked entries"
        )
    head_active_entries = git_tree_entries(repo_root, context.head_oid, active_root)
    if head_active_entries:
        residue = ", ".join(entry.path for entry in head_active_entries)
        raise CheckError(
            f"atomic archive fallback rejected active-root residue/copy: {residue}"
        )

    head_target_entries = git_tree_entries(repo_root, context.head_oid, target_root)
    base_relative = _entries_relative_to(base_active_entries, active_root)
    head_relative = _entries_relative_to(head_target_entries, target_root)
    missing = sorted(base_relative.keys() - head_relative.keys())
    extra = sorted(head_relative.keys() - base_relative.keys())
    if missing or extra:
        details: list[str] = []
        if missing:
            details.append("missing=" + ", ".join(missing))
        if extra:
            details.append("extra=" + ", ".join(extra))
        raise CheckError(
            "atomic archive fallback rejected partial/extra move: " + "; ".join(details)
        )

    mode_mismatches: list[str] = []
    type_mismatches: list[str] = []
    mutated: list[str] = []
    for relative_path in sorted(base_relative):
        base_entry = base_relative[relative_path]
        head_entry = head_relative[relative_path]
        if base_entry.mode != head_entry.mode:
            mode_mismatches.append(relative_path)
        if base_entry.object_type != head_entry.object_type:
            type_mismatches.append(relative_path)
        if base_entry.oid != head_entry.oid:
            mutated.append(relative_path)
    if mode_mismatches or type_mismatches or mutated:
        details = []
        if mode_mismatches:
            details.append("mode mismatch=" + ", ".join(mode_mismatches))
        if type_mismatches:
            details.append("object-type mismatch=" + ", ".join(type_mismatches))
        if mutated:
            details.append("mutated=" + ", ".join(mutated))
        raise CheckError(
            "atomic archive fallback rejected non-identical entries: "
            + "; ".join(details)
        )

    return frozenset(
        [entry.path for entry in base_active_entries]
        + [entry.path for entry in head_target_entries]
    )


def check_paths(
    repo_root: Path,
    context: PullRequestContext,
    changed_paths: Sequence[str],
) -> CheckResult:
    # `git diff -z` already returns repository-relative paths with `/` as the
    # directory separator. On Unix a backslash is a legal filename byte, so
    # rewriting it would turn a root file such as `scripts\outside.py` into a
    # false in-scope path under `scripts/**`.
    repository_paths = tuple(changed_paths)
    task_id = resolve_task_declaration(context)
    if task_id is None:
        offenders = sorted(
            path for path in repository_paths if path_matches(path, SENSITIVE_PATTERNS)
        )
        if offenders:
            raise CheckError(
                "PR has no task declaration and touches sensitive paths: "
                + ", ".join(offenders)
            )
        return CheckResult(None, repository_paths, SENSITIVE_PATTERNS)

    definitions = load_task_definitions(repo_root)
    task = definitions.get(task_id)
    relocation_paths: frozenset[str] = frozenset()
    if task is None:
        try:
            base_definitions = load_task_definitions_at_commit(
                repo_root, context.base_oid
            )
        except CheckError as error:
            raise CheckError(
                f"declared task {task_id} does not exist in an active change; "
                f"base lookup failed closed: {error}"
            ) from error
        task = base_definitions.get(task_id)
        if task is None:
            raise CheckError(
                f"declared task {task_id} does not exist in an active change or "
                "the base active changes; archive-only tasks are not authority"
            )
        relocation_paths = verify_atomic_archive_fallback(repo_root, context, task)
    else:
        reject_archive_copy_for_active_task(
            repo_root, context, task, repository_paths
        )
    allowed_patterns = extract_allowed_patterns(repo_root, task)
    offenders = sorted(
        path
        for path in repository_paths
        if path not in relocation_paths and not path_matches(path, allowed_patterns)
    )
    if offenders:
        raise CheckError(
            f"declared task {task_id} has paths outside Allowed paths: "
            + ", ".join(offenders)
        )
    return CheckResult(task_id, repository_paths, allowed_patterns)


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
