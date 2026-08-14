#!/usr/bin/env python3
"""Preflight and fail closed when a pull request exceeds declared task paths.

TASK-MECH-004 keeps approval semantics unchanged: this is a read-only guard
against accidental scope expansion, not an authorization or approval oracle.

``--preflight`` compares two commits before push/PR creation. A local run
requires an explicit Task in the final commit subject; the Agent PR workflow
may use ``--infer-task`` only as a fail-closed fallback when exactly one
base-tree active Task covers the complete diff.

A vertical change that introduces a new OpenSpec Task is not allowed to use
that head-only Task as authority.  Instead, its commit must declare one
base-tree active Task that covers every production/test path.  The guard may
then admit only the new change's own four review documents and its matching
``evidence/runs/<new-task-id>/`` namespace as a self-describing supplement.
The head Task must describe the complete diff, but never authorises it.

Known residual (TASK-DEC-004, ledger B-H2): both workflows check out the
head being reviewed and run *this file* from that checkout, so a task whose
Allowed paths include `scripts/**` can change the checker and its tests in
the same pull request the changed checker then judges. Task definitions now
come from the base tree, which removes the allowlist half of that loop, but
the code half remains structural and is not closed here — breaking it needs
the guard to run from a trusted checkout, which is its own change. Until
then the compensating control is human review of any diff touching this
file.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import subprocess
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


TASK_TOKEN_TEXT = r"TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?"
TASK_TOKEN_RE = re.compile(rf"(?<![A-Z0-9-])({TASK_TOKEN_TEXT})(?![A-Z0-9-])")
# `[ \t]*`, never `\s*`: a `\s*` field separator matches across a newline, so
# a body containing a bare `Task:` line would bind whatever token starts the
# next line.
TASK_LINE_RE = re.compile(rf"^[ \t]*Task:[ \t]*({TASK_TOKEN_TEXT})[ \t]*$", re.MULTILINE)
TASK_HEADER_RE = re.compile(rf"^##\s+({TASK_TOKEN_TEXT})(?:\s|$)", re.MULTILINE)
FULL_TASK_RE = re.compile(rf"^{TASK_TOKEN_TEXT}$")
FULL_OID_RE = re.compile(r"^[0-9a-fA-F]{40}$")
CALENDAR_DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
ALLOWED_PATHS_RE = re.compile(
    r"^- Allowed paths(?:\([^\n)]*\)|（[^\n）]*）| after readiness)?[:：](.*)$",
    re.MULTILINE,
)
BACKTICK_PATH_RE = re.compile(r"(?:(本\s+change)\s*)?`([^`\n]+)`")

# An Allowed paths block ends at the next top-level bullet or any heading. A
# tab-indented bullet and a `*` bullet end it too: neither is the space-indented
# `- ` sub-item the corpus uses for declaration lines.
BLOCK_TERMINATOR_RE = re.compile(r"^(?:- |#{1,6}[ \t]|\t+[-*+] |[ \t]*\* )")
# Sub-items and the `- Allowed paths:` line itself are declaration lines: a
# prose prefix such as `修改`/`新增` precedes the path they declare.
DECLARATION_LINE_RE = re.compile(r"^[ \t]+- ")
# Annotations are parenthesised and routinely wrap across lines.
ANNOTATION_RE = re.compile(r"（[^（）]*）|\([^()]*\)", re.DOTALL)
PROSE_WORD_RE = re.compile(r"[A-Za-z][A-Za-z0-9./-]*|[一-鿿]+")
# The closed connective set that may sit between two tokens of one wrapped
# list. Anything else means prose has started and the list has ended.
LIST_CONNECTIVES = frozenset({"与", "和"})
# A 40-hex token is a pinned blob recorded next to the file it pins, never a
# path: no repository path is named that way.
PINNED_BLOB_RE = re.compile(r"^[0-9a-f]{40}$")
VERTICAL_CHANGE_DIRECTORY_RE = re.compile(
    r"^openspec/changes/(chg-[a-z0-9]+(?:-[a-z0-9]+)*)$"
)
VERTICAL_CHANGE_REQUIRED_FILES = frozenset(
    {"proposal.md", "design.md", "tasks.md", "verification.md"}
)
VERTICAL_IMPLEMENTATION_PATTERNS = (
    "Packages/**",
    "ArkDeckApp/**",
    "ArkDeckAppUITests/**",
    "ArkDeck.xcodeproj/**",
    "Catalog/**",
)

# The sensitive-path table lives next to this script so guard code and guard
# data travel in the same checkout and the same `scripts/**` protection domain
# (TASK-DEC-001). Loading is fail-closed: a missing or malformed file is a
# CheckError on every run, never a silent fallback to a built-in default.
CONFIG_SCHEMA = "arkdeck-automation-config/v1"
CONFIG_PATH = Path(__file__).resolve().parent / "automation_config.json"
CONFIG_KEYS = frozenset({"schema", "sensitive_paths"})

# Maintainer-authorized one-time bootstrap for the change that introduces
# preflight itself. It is deliberately a three-part fuse: exact old main,
# exact agent branch, and exact complete diff. Once this pull request lands,
# main moves away from this OID and the exception can never match again.
BOOTSTRAP_EXCEPTION_BASE_OID = "f5a37c22db3539db3c1ba6f331103bd66fe8e0d8"
BOOTSTRAP_EXCEPTION_HEAD_REF = "agent/pr-path-preflight"
BOOTSTRAP_EXCEPTION_PATHS = (
    ".github/workflows/agent-pr.yml",
    "AGENTS.md",
    "scripts/check_pr_paths.py",
    "scripts/test_agent_pr_workflow.py",
    "scripts/test_check_pr_paths.py",
)


class CheckError(ValueError):
    """A named, user-correctable PR scope violation."""


def load_sensitive_patterns(config_path: Path = CONFIG_PATH) -> tuple[str, ...]:
    try:
        raw_text = config_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise CheckError(
            f"cannot read automation config {config_path}: {error}"
        ) from error
    try:
        config = json.loads(raw_text)
    except json.JSONDecodeError as error:
        raise CheckError(
            f"cannot parse automation config {config_path}: {error}"
        ) from error
    if not isinstance(config, dict):
        raise CheckError(
            f"automation config {config_path} top level must be a JSON object"
        )
    if config.get("schema") != CONFIG_SCHEMA:
        raise CheckError(
            f"automation config {config_path} schema must be {CONFIG_SCHEMA!r}"
        )
    unknown_keys = sorted(set(config) - CONFIG_KEYS)
    if unknown_keys:
        raise CheckError(
            f"automation config {config_path} has unknown keys: "
            + ", ".join(unknown_keys)
        )
    patterns = config.get("sensitive_paths")
    if not isinstance(patterns, list) or not patterns:
        raise CheckError(
            f"automation config {config_path} sensitive_paths must be a "
            "non-empty list"
        )
    if any(not isinstance(pattern, str) for pattern in patterns):
        raise CheckError(
            f"automation config {config_path} sensitive_paths entries must "
            "all be strings"
        )
    duplicates = sorted({p for p in patterns if patterns.count(p) > 1})
    if duplicates:
        raise CheckError(
            f"automation config {config_path} sensitive_paths has duplicate "
            "entries: " + ", ".join(duplicates)
        )
    return tuple(patterns)


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


@dataclass(frozen=True)
class PreflightResult:
    check: CheckResult
    declaration_source: str


def _string(value: object, field: str) -> str:
    if not isinstance(value, str):
        raise CheckError(f"pull_request {field} must be a string")
    return value


def _load_json(path: Path, label: str) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CheckError(f"cannot parse {label} {path}: {error}") from error


def pull_request_context_from_object(pull_request: object) -> PullRequestContext:
    if not isinstance(pull_request, dict):
        raise CheckError("pull_request must be an object")

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


def load_pull_request_context(event_path: Path) -> PullRequestContext:
    event = _load_json(event_path, "pull_request event")
    pull_request = event.get("pull_request") if isinstance(event, dict) else None
    if not isinstance(pull_request, dict):
        raise CheckError("event has no pull_request object")
    context = pull_request_context_from_object(pull_request)
    # Shape only used to be checked here; identity was not. The consumer of
    # this mode triggers on `edited`, and editing the base branch is an
    # `edited` event, so an unvalidated event was a self-service way to pick
    # which commits the guard would compare against.
    if pull_request.get("state") != "open":
        raise CheckError("pull_request state must be open")
    if pull_request.get("merged") is not False:
        raise CheckError("pull_request merged must be false")
    base = pull_request.get("base")
    head = pull_request.get("head")
    base_repository = _repository_name(base.get("repo"), "base.repo")
    head_repository = _repository_name(head.get("repo"), "head.repo")
    if base_repository != head_repository:
        raise CheckError(
            "pull_request base and head repositories differ: "
            f"{base_repository} vs {head_repository}"
        )
    return context


def assert_base_is_ancestor(repo_root: Path, context: PullRequestContext) -> None:
    """Refuse a base that is not an ancestor of the head being reviewed.

    `git diff base..head` reports what head has that base lacks. Point base
    at a side branch that already carries the offending file and the file
    drops out of the diff entirely — measured live, the offending PR then
    passed. A base off the head's own history is either that substitution or
    a branch left behind by an advanced main; both are answered by rebasing.
    """
    completed = subprocess.run(
        [
            "git",
            "-C",
            str(repo_root),
            "merge-base",
            "--is-ancestor",
            context.base_oid,
            context.head_oid,
        ],
        check=False,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise CheckError(
            f"pull_request base {context.base_oid} is not an ancestor of head "
            f"{context.head_oid}; rebase the branch on the base commit"
        )


def _positive_integer(value: object, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise CheckError(f"pull_request {field} must be a positive integer")
    return value


def select_unique_pull_request_number(
    pages_path: Path, *, allow_zero: bool
) -> int | None:
    pages = _load_json(pages_path, "paginated pull_request list")
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise CheckError("paginated pull_request list must be an array of page arrays")

    numbers: list[int] = []
    for page in pages:
        for pull_request in page:
            if not isinstance(pull_request, dict):
                raise CheckError("paginated pull_request list contains a non-object entry")
            numbers.append(_positive_integer(pull_request.get("number"), "number"))

    if not numbers and allow_zero:
        return None
    if len(numbers) != 1:
        raise CheckError(
            f"expected exactly one open pull_request after create-or-find, found {len(numbers)}"
        )
    return numbers[0]


def _repository_name(value: object, field: str) -> str:
    if not isinstance(value, dict):
        raise CheckError(f"pull_request {field} must be an object")
    return _string(value.get("full_name"), f"{field}.full_name")


def validate_pull_request_identity(
    pull_request: object,
    *,
    expected_repository: str,
    expected_number: int,
    expected_base_ref: str,
    expected_head_ref: str,
    expected_head_oid: str,
    expected_author: str,
) -> PullRequestContext:
    if not isinstance(pull_request, dict):
        raise CheckError("pull_request must be an object")
    if not FULL_OID_RE.fullmatch(expected_head_oid):
        raise CheckError("expected head OID must be a full 40-hex OID")
    if _positive_integer(pull_request.get("number"), "number") != expected_number:
        raise CheckError("pull_request number does not match the selected PR")
    if pull_request.get("state") != "open":
        raise CheckError("pull_request state must be open")
    if pull_request.get("merged") is not False:
        raise CheckError("pull_request merged must be false")

    base = pull_request.get("base")
    head = pull_request.get("head")
    author = pull_request.get("user")
    if not isinstance(base, dict) or not isinstance(head, dict):
        raise CheckError("pull_request base/head objects are missing")
    if not isinstance(author, dict):
        raise CheckError("pull_request user must be an object")

    if _string(base.get("ref"), "base.ref") != expected_base_ref:
        raise CheckError("pull_request base.ref does not match expected base")
    if _repository_name(base.get("repo"), "base.repo") != expected_repository:
        raise CheckError("pull_request base repository does not match expected repository")
    if _string(head.get("ref"), "head.ref") != expected_head_ref:
        raise CheckError("pull_request head.ref does not match the pushed branch")
    if _repository_name(head.get("repo"), "head.repo") != expected_repository:
        raise CheckError("pull_request head repository does not match expected repository")
    if _string(head.get("sha"), "head.sha").lower() != expected_head_oid.lower():
        raise CheckError("pull_request head.sha does not match the pushed commit")
    if _string(author.get("login"), "user.login") != expected_author:
        raise CheckError("pull_request author does not match expected bot identity")

    return pull_request_context_from_object(pull_request)


def _fold_confusables(text: str) -> str:
    """NFKC plus every Unicode dash folded to ASCII `-`.

    NFKC alone is not enough here: U+2011 (non-breaking hyphen) normalises
    to U+2010, still not the ASCII hyphen the task grammar requires, so the
    token stays invisible. Folding the whole `Pd` category catches the
    hyphen family; look-alike letters from other scripts are a wider
    problem this does not claim to solve.
    """
    folded = unicodedata.normalize("NFKC", text)
    return "".join(
        "-" if unicodedata.category(character) == "Pd" else character
        for character in folded
    )


def _confusable_task_tokens(text: str) -> set[str]:
    """Task tokens that appear only after confusable characters are folded.

    A title carrying U+2011 instead of `-` renders as a task declaration to
    a human while `TASK_TOKEN_RE` finds nothing, so the ambiguity check
    cannot see the disagreement and the guard silently runs some other
    task's allowlist. Neither reading is trustworthy: report the conflict.
    """
    folded = _fold_confusables(text)
    if folded == text:
        return set()
    return set(TASK_TOKEN_RE.findall(folded)) - set(TASK_TOKEN_RE.findall(text))


def resolve_task_declaration(context: PullRequestContext) -> str | None:
    for field, text in (("title", context.title), ("body", context.body)):
        confusable = _confusable_task_tokens(text)
        if confusable:
            rendered = ", ".join(sorted(confusable))
            raise CheckError(
                f"PR {field} contains a confusable task token that only "
                f"resolves after Unicode normalisation: {rendered}"
            )

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


def _mask_annotations(block: str) -> str:
    """Blank out parenthesised annotations, preserving line structure.

    Annotations wrap across lines, so the mask has to run over the whole
    block; replacing newlines would merge lines and misalign every
    subsequent one against its raw counterpart.
    """
    return ANNOTATION_RE.sub(
        lambda match: re.sub(r"[^\n]", " ", match.group(0)), block
    )


def extract_allowed_patterns(repo_root: Path, task: TaskDefinition) -> tuple[str, ...]:
    """Read the declared path patterns, refusing to absorb surrounding prose.

    Every backtick token in the block used to become a glob, so a sentence
    that merely mentions `scripts/**` handed the task that surface. The
    block is now read as a delimited list: the `- Allowed paths:` line and
    its `- ` sub-items are declaration lines and contribute their tokens,
    while a wrapped continuation contributes only the tokens that precede
    its first prose word — once prose starts, the list has ended.
    """
    matches = list(ALLOWED_PATHS_RE.finditer(task.section))
    if not matches:
        raise CheckError(f"task {task.task_id} has no Allowed paths line")
    if len(matches) > 1:
        raise CheckError(f"task {task.task_id} has multiple Allowed paths lines")

    match = matches[0]
    raw_lines = [match.group(1)]
    for line in task.section[match.end() :].splitlines():
        if BLOCK_TERMINATOR_RE.match(line):
            break
        raw_lines.append(line)
    masked_block = _mask_annotations("\n".join(raw_lines))
    # Matched over the whole block, not line by line: a `本 change` marker may
    # sit at the end of one line with the token it qualifies on the next, and
    # splitting first would silently rebase that pattern on the repository root.
    line_starts = [0]
    for line in masked_block.split("\n")[:-1]:
        line_starts.append(line_starts[-1] + len(line) + 1)

    change_relative = task.change_directory.relative_to(repo_root).as_posix()
    patterns: list[str] = []
    cursor = 0
    ended_lines: set[int] = set()
    for token in BACKTICK_PATH_RE.finditer(masked_block):
        index = max(i for i, start in enumerate(line_starts) if start <= token.start(2))
        if index in ended_lines:
            continue
        if index > 0 and not DECLARATION_LINE_RE.match(raw_lines[index]):
            gap_from = max(line_starts[index], cursor)
            gap = set(PROSE_WORD_RE.findall(masked_block[gap_from : token.start()]))
            if gap - LIST_CONNECTIVES:
                ended_lines.add(index)
                continue
        cursor = token.end()
        path_pattern = token.group(2).strip()
        if not path_pattern or PINNED_BLOB_RE.fullmatch(path_pattern):
            continue
        if token.group(1):
            path_pattern = f"{change_relative}/{path_pattern}"
        patterns.append(path_pattern)

    if not patterns:
        raise CheckError(f"task {task.task_id} Allowed paths yields zero backtick path tokens")
    return tuple(patterns)


def glob_regex(pattern: str, *, ignore_case: bool = False) -> re.Pattern[str]:
    """Translate a path glob, with `*` confined to one path segment.

    `fnmatch` lets a single `*` cross `/`, which silently widened every
    single-star declaration into a recursive one. `**` still crosses. The
    semantics here match `test_agent_pr_workflow._glob_regex`, the
    independent implementation that already had it right; a parity test
    pins the two against each other.
    """
    pieces = [r"\A"]
    index = 0
    while index < len(pattern):
        character = pattern[index]
        if character == "*" and pattern[index + 1 : index + 2] == "*":
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
    return re.compile("".join(pieces), re.IGNORECASE if ignore_case else 0)


def path_matches(
    path: str, patterns: Iterable[str], *, ignore_case: bool = False
) -> bool:
    return any(
        glob_regex(pattern, ignore_case=ignore_case).match(path)
        for pattern in patterns
    )


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
    *,
    config_path: Path = CONFIG_PATH,
    head_definitions: dict[str, TaskDefinition] | None = None,
) -> CheckResult:
    # Loaded unconditionally: a broken sensitive-path table must fail every
    # check run, including task-declared PRs that would never consult it.
    sensitive_patterns = load_sensitive_patterns(config_path)
    # `git diff -z` already returns repository-relative paths with `/` as the
    # directory separator. On Unix a backslash is a legal filename byte, so
    # rewriting it would turn a root file such as `scripts\outside.py` into a
    # false in-scope path under `scripts/**`.
    repository_paths = tuple(changed_paths)
    task_id = resolve_task_declaration(context)
    if task_id is None:
        # Case-insensitive on the sensitive side only. `Scripts/x.py` and
        # `.GitHub/x.yml` are the same files to a case-insensitive checkout
        # and were sailing past this table. The Allowed paths side stays
        # case-sensitive: matching more loosely there would widen a task's
        # authorised surface, the opposite direction.
        offenders = sorted(
            path
            for path in repository_paths
            if path_matches(path, sensitive_patterns, ignore_case=True)
        )
        if offenders:
            raise CheckError(
                "PR has no task declaration and touches sensitive paths: "
                + ", ".join(offenders)
            )
        return CheckResult(None, repository_paths, sensitive_patterns)

    # The allowlist comes from the base tree, never from the tree under
    # review. Read from head, one commit could widen its own Allowed paths
    # to `**` and touch anything in the same breath — measured live, it
    # passed. The head tree still supplies one bit: whether the task is
    # still active there, which is what distinguishes an archive move from
    # an ordinary change.
    base_definitions = load_task_definitions_at_commit(repo_root, context.base_oid)
    task = base_definitions.get(task_id)
    if task is None:
        raise CheckError(
            f"declared task {task_id} does not exist in an active change at the "
            "base commit; archive-only tasks are not authority, and neither is a "
            "task created or restored by the pull request under review"
        )
    # The head side is read from the checkout, not resolved out of git: it
    # decides only whether this is an archive move, and both branches below
    # re-derive everything they trust from the two trees themselves. Keeping
    # it here also keeps the guard usable from a shallow clone, where the
    # head commit may be the only object present.
    if head_definitions is None:
        head_definitions = load_task_definitions(repo_root)
    relocation_paths: frozenset[str] = frozenset()
    if task_id in head_definitions:
        reject_archive_copy_for_active_task(
            repo_root, context, task, repository_paths
        )
    else:
        relocation_paths = verify_atomic_archive_fallback(repo_root, context, task)
    allowed_patterns = extract_allowed_patterns(repo_root, task)
    offenders = sorted(
        path
        for path in repository_paths
        if path not in relocation_paths and not path_matches(path, allowed_patterns)
    )
    if offenders:
        supplement_patterns = vertical_change_supplement_patterns(
            repo_root,
            context,
            repository_paths,
            offenders,
            base_definitions=base_definitions,
            base_allowed_patterns=allowed_patterns,
        )
        if supplement_patterns is None:
            raise CheckError(
                f"declared task {task_id} has paths outside Allowed paths: "
                + ", ".join(offenders)
            )
        allowed_patterns = allowed_patterns + supplement_patterns
    return CheckResult(task_id, repository_paths, allowed_patterns)


def vertical_change_supplement_patterns(
    repo_root: Path,
    context: PullRequestContext,
    repository_paths: Sequence[str],
    offenders: Sequence[str],
    *,
    base_definitions: dict[str, TaskDefinition],
    base_allowed_patterns: Sequence[str],
) -> tuple[str, ...] | None:
    """Validate a narrow head-only change/evidence supplement.

    The base Task remains the only authority for production and test paths.
    A new Task can describe the complete vertical delivery, but the only paths
    it may add beyond the base allowlist are its own previously absent change
    directory and its exactly matching evidence namespace.
    """

    # Do not let an uncommitted checkout edit supply the descriptive Task used
    # to judge a committed PR head.  The head commit is always present when its
    # OID is being reviewed, including in shallow CI checkouts.
    committed_head_definitions = load_task_definitions_at_commit(
        repo_root, context.head_oid
    )
    new_task_ids = sorted(set(committed_head_definitions) - set(base_definitions))
    if len(new_task_ids) != 1:
        return None
    new_task = committed_head_definitions[new_task_ids[0]]
    try:
        change_directory = new_task.change_directory.relative_to(repo_root).as_posix()
    except ValueError:
        return None
    if VERTICAL_CHANGE_DIRECTORY_RE.fullmatch(change_directory) is None:
        return None
    if git_tree_entries(repo_root, context.base_oid, change_directory):
        raise CheckError(
            "vertical change supplement directory already exists in the base tree: "
            + change_directory
        )

    def active_change_roots(oid: str) -> frozenset[str]:
        roots: set[str] = set()
        for entry in git_tree_entries(repo_root, oid, "openspec/changes"):
            parts = entry.path.split("/")
            if (
                len(parts) >= 3
                and parts[:2] == ["openspec", "changes"]
                and parts[2].startswith("chg-")
            ):
                roots.add("/".join(parts[:3]))
        return frozenset(roots)

    added_change_roots = active_change_roots(context.head_oid) - active_change_roots(
        context.base_oid
    )
    if added_change_roots != {change_directory}:
        rendered = ", ".join(sorted(added_change_roots)) or "none"
        raise CheckError(
            "vertical change supplement must introduce exactly its one change "
            f"directory; added change roots: {rendered}"
        )

    archive_entries = git_tree_entries(
        repo_root, context.base_oid, "openspec/changes/archive"
    )
    archived_task_ids: set[str] = set()
    archived_change_slugs: set[str] = set()
    archived_slug_re = re.compile(
        r"(chg-[a-z0-9]+(?:-[a-z0-9]+)*)$"
    )
    for entry in archive_entries:
        parts = entry.path.split("/")
        if len(parts) >= 4 and parts[:3] == ["openspec", "changes", "archive"]:
            slug_match = archived_slug_re.search(parts[3])
            if slug_match is not None:
                archived_change_slugs.add(slug_match.group(1))
        if entry.path.endswith("/tasks.md") and entry.object_type == "blob":
            raw_text = _run_git(
                repo_root,
                ["cat-file", "blob", entry.oid],
                context=f"git cat-file archived tasks {entry.path}",
            )
            try:
                task_text = raw_text.decode("utf-8")
            except UnicodeDecodeError as error:
                raise CheckError(
                    f"archived tasks file {entry.path} is not UTF-8: {error}"
                ) from error
            archived_task_ids.update(TASK_HEADER_RE.findall(task_text))
    change_slug = change_directory.rsplit("/", 1)[-1]
    if new_task.task_id in archived_task_ids:
        raise CheckError(
            "vertical change supplement reuses an archived Task ID: "
            + new_task.task_id
        )
    if change_slug in archived_change_slugs:
        raise CheckError(
            "vertical change supplement resurrects an archived change slug: "
            + change_slug
        )

    evidence_directory = f"evidence/runs/{new_task.task_id}"
    supplement_patterns = (
        f"{change_directory}/**",
        f"{evidence_directory}/**",
    )
    if any(
        not (
            path.startswith(f"{change_directory}/")
            or path.startswith(f"{evidence_directory}/")
        )
        for path in offenders
    ):
        return None
    if not any(
        path.startswith(f"{evidence_directory}/") for path in repository_paths
    ):
        raise CheckError(
            "vertical change supplement must include evidence under "
            f"{evidence_directory}/"
        )

    # A supplement cannot turn a proposal-only diff into a vertical delivery.
    # At least one base-authorised sensitive product/guard path must travel in
    # the same commit.
    base_authorised = tuple(
        path
        for path in repository_paths
        if path_matches(path, base_allowed_patterns)
    )
    if not any(
        path_matches(path, VERTICAL_IMPLEMENTATION_PATTERNS)
        for path in base_authorised
    ):
        raise CheckError(
            "vertical change supplement requires a base-authorised production "
            "or test implementation path in the same diff"
        )

    if git_tree_entries(repo_root, context.base_oid, evidence_directory):
        raise CheckError(
            "vertical change supplement evidence directory already exists in the "
            "base tree: " + evidence_directory
        )
    head_entries = git_tree_entries(repo_root, context.head_oid, change_directory)
    evidence_entries = git_tree_entries(
        repo_root, context.head_oid, evidence_directory
    )
    if not evidence_entries:
        raise CheckError(
            "vertical change supplement has no committed evidence under "
            f"{evidence_directory}/"
        )
    unsafe_supplement_entries = sorted(
        entry.path
        for entry in (*head_entries, *evidence_entries)
        if entry.object_type != "blob" or entry.mode != "100644"
    )
    if unsafe_supplement_entries:
        raise CheckError(
            "vertical change supplement files must be non-executable regular files: "
            + ", ".join(unsafe_supplement_entries)
        )
    entry_by_path = {entry.path: entry for entry in head_entries}
    required_paths = {
        f"{change_directory}/{filename}"
        for filename in VERTICAL_CHANGE_REQUIRED_FILES
    }
    missing = sorted(required_paths - set(entry_by_path))
    if missing:
        raise CheckError(
            "vertical change supplement is missing required review documents: "
            + ", ".join(missing)
        )
    extra_change_paths = sorted(set(entry_by_path) - required_paths)
    if extra_change_paths:
        raise CheckError(
            "vertical change supplement directory must contain exactly the four "
            "review documents; extra paths: " + ", ".join(extra_change_paths)
        )
    try:
        descriptive_patterns = extract_allowed_patterns(repo_root, new_task)
    except CheckError as error:
        raise CheckError(
            f"vertical change supplement task {new_task.task_id} is malformed: {error}"
        ) from error
    undescribed = sorted(
        path for path in repository_paths if not path_matches(path, descriptive_patterns)
    )
    if undescribed:
        raise CheckError(
            f"vertical change supplement task {new_task.task_id} does not describe "
            "the complete diff: " + ", ".join(undescribed)
        )
    return supplement_patterns


def one_time_bootstrap_result(
    context: PullRequestContext,
    changed_paths: Sequence[str],
    *,
    config_path: Path = CONFIG_PATH,
) -> CheckResult | None:
    """Return the pinned bootstrap exception, or ``None`` on any mismatch."""

    # Keep the configuration fail-closed even on the one authorized exception.
    load_sensitive_patterns(config_path)
    repository_paths = tuple(changed_paths)
    if (
        context.base_oid != BOOTSTRAP_EXCEPTION_BASE_OID
        or context.head_ref != BOOTSTRAP_EXCEPTION_HEAD_REF
        or tuple(sorted(repository_paths))
        != tuple(sorted(BOOTSTRAP_EXCEPTION_PATHS))
    ):
        return None
    return CheckResult(None, repository_paths, BOOTSTRAP_EXCEPTION_PATHS)


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


def resolve_git_revision(repo_root: Path, revision: str) -> str:
    if not revision:
        raise CheckError("git revision must not be empty")
    raw_oid = _run_git(
        repo_root,
        [
            "rev-parse",
            "--verify",
            "--end-of-options",
            f"{revision}^{{commit}}",
        ],
        context=f"git rev-parse {revision}",
    )
    try:
        oid = raw_oid.decode("ascii").strip()
    except UnicodeDecodeError as error:
        raise CheckError(
            f"git revision {revision!r} resolved to non-ASCII output"
        ) from error
    if not FULL_OID_RE.fullmatch(oid):
        raise CheckError(
            f"git revision {revision!r} did not resolve to one full commit OID"
        )
    return oid.lower()


def git_commit_declaration_text(repo_root: Path, oid: str) -> tuple[str, str]:
    raw_message = _run_git(
        repo_root,
        ["show", "-s", "--format=%s%x00%b", oid],
        context=f"git show declaration text for {oid}",
    )
    try:
        message = raw_message.decode("utf-8")
    except UnicodeDecodeError as error:
        raise CheckError(f"commit {oid} message is not UTF-8") from error
    title, separator, body = message.partition("\0")
    if not separator:
        raise CheckError(f"commit {oid} declaration text has no field separator")
    return title.rstrip("\n"), body.rstrip("\n")


def _base_task_coverage(
    repo_root: Path,
    base_oid: str,
    changed_paths: Sequence[str],
) -> tuple[tuple[str, tuple[str, ...]], ...]:
    coverage: list[tuple[str, tuple[str, ...]]] = []
    definitions = load_task_definitions_at_commit(repo_root, base_oid)
    for task_id, task in definitions.items():
        try:
            patterns = extract_allowed_patterns(repo_root, task)
        except CheckError:
            # A malformed or path-less task cannot be an inferred authority.
            # Explicitly declaring it still returns its precise parse error
            # through check_paths().
            continue
        offenders = tuple(
            path for path in changed_paths if not path_matches(path, patterns)
        )
        coverage.append((task_id, offenders))
    return tuple(coverage)


def _coverage_hint(
    coverage: Sequence[tuple[str, tuple[str, ...]]],
    changed_count: int,
) -> str:
    exact = sorted(task_id for task_id, offenders in coverage if not offenders)
    if exact:
        return "base-tree task(s) covering the full diff: " + ", ".join(exact)

    partial = sorted(
        (
            len(offenders),
            task_id,
            offenders,
        )
        for task_id, offenders in coverage
        if len(offenders) < changed_count
    )
    if not partial:
        return "no base-tree active task covers any part of the diff"

    rendered: list[str] = []
    for _, task_id, offenders in partial[:3]:
        outside = ", ".join(offenders[:5])
        if len(offenders) > 5:
            outside += f", ... (+{len(offenders) - 5})"
        rendered.append(f"{task_id} (outside: {outside})")
    return "closest base-tree task(s): " + "; ".join(rendered)


def preflight_paths(
    repo_root: Path,
    base_oid: str,
    head_oid: str,
    *,
    head_ref: str = "",
    allow_bootstrap: bool = False,
    config_path: Path = CONFIG_PATH,
) -> PreflightResult:
    title, body = git_commit_declaration_text(repo_root, head_oid)
    declaration_context = PullRequestContext(
        title=title,
        body=body,
        # Preflight intentionally ignores the legacy descriptive branch
        # fallback. The generated PR body carries the exact selected Task, so
        # a branch suffix can neither invent a task nor override the commit.
        head_ref="",
        base_oid=base_oid,
        head_oid=head_oid,
    )
    assert_base_is_ancestor(repo_root, declaration_context)
    changed_paths = git_changed_paths(repo_root, base_oid, head_oid)
    if not changed_paths:
        raise CheckError(
            f"preflight diff {base_oid}..{head_oid} is empty; no PR should be created"
        )

    explicit_task = resolve_task_declaration(declaration_context)
    coverage = _base_task_coverage(repo_root, base_oid, changed_paths)
    committed_head_definitions = load_task_definitions_at_commit(repo_root, head_oid)
    if explicit_task is not None:
        try:
            result = check_paths(
                repo_root,
                declaration_context,
                changed_paths,
                config_path=config_path,
                head_definitions=committed_head_definitions,
            )
        except CheckError as error:
            hint = _coverage_hint(coverage, len(changed_paths))
            raise CheckError(f"{error}; {hint}") from error
        return PreflightResult(result, "explicit")

    if allow_bootstrap:
        bootstrap_context = PullRequestContext(
            title=title,
            body=body,
            head_ref=head_ref,
            base_oid=base_oid,
            head_oid=head_oid,
        )
        bootstrap = one_time_bootstrap_result(
            bootstrap_context,
            changed_paths,
            config_path=config_path,
        )
        if bootstrap is not None:
            return PreflightResult(bootstrap, "bootstrap")

    sensitive_patterns = load_sensitive_patterns(config_path)
    sensitive_paths = tuple(
        path
        for path in changed_paths
        if path_matches(path, sensitive_patterns, ignore_case=True)
    )
    if not sensitive_paths:
        return PreflightResult(
            CheckResult(None, changed_paths, sensitive_patterns),
            "none",
        )

    candidates = sorted(task_id for task_id, offenders in coverage if not offenders)
    if not candidates:
        hint = _coverage_hint(coverage, len(changed_paths))
        raise CheckError(
            "preflight found no base-tree active task whose Allowed paths "
            "cover the full diff; sensitive paths: "
            + ", ".join(sensitive_paths)
            + f"; {hint}"
        )
    if len(candidates) > 1:
        raise CheckError(
            "preflight found multiple base-tree active tasks whose Allowed paths "
            "cover the full diff: "
            + ", ".join(candidates)
            + "; add exactly one Task ID to the final commit subject"
        )

    inferred_task = candidates[0]
    inferred_context = PullRequestContext(
        title=title,
        body=f"Task: {inferred_task}\n",
        head_ref="",
        base_oid=base_oid,
        head_oid=head_oid,
    )
    result = check_paths(
        repo_root,
        inferred_context,
        changed_paths,
        config_path=config_path,
        head_definitions=committed_head_definitions,
    )
    return PreflightResult(result, "inferred")


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--event", type=Path)
    source.add_argument("--pull-request", type=Path)
    source.add_argument("--pull-list", type=Path)
    source.add_argument(
        "--preflight",
        action="store_true",
        help="validate a commit range before push or PR creation",
    )
    parser.add_argument(
        "--base-revision",
        help="base commit/ref for --preflight; must be an ancestor of head",
    )
    parser.add_argument(
        "--head-revision",
        help="head commit/ref whose message and complete diff are preflighted",
    )
    parser.add_argument(
        "--infer-task",
        action="store_true",
        help=(
            "workflow-only fallback: accept exactly one full-diff base-tree "
            "Task candidate when the commit subject omits Task"
        ),
    )
    parser.add_argument(
        "--allow-bootstrap",
        action="store_true",
        help=(
            "permit only the pinned one-time preflight bootstrap tuple; "
            "all base/head/path mismatches fall through to the normal guard"
        ),
    )
    parser.add_argument("--allow-zero", action="store_true")
    parser.add_argument("--identity-only", action="store_true")
    parser.add_argument("--expected-repository")
    parser.add_argument("--expected-number", type=int)
    parser.add_argument("--expected-base-ref")
    parser.add_argument("--expected-head-ref")
    parser.add_argument("--expected-head-oid")
    parser.add_argument("--expected-author")
    return parser.parse_args(argv)


def _required_pull_request_expectations(args: argparse.Namespace) -> dict[str, object]:
    fields = {
        "expected_repository": args.expected_repository,
        "expected_number": args.expected_number,
        "expected_base_ref": args.expected_base_ref,
        "expected_head_ref": args.expected_head_ref,
        "expected_head_oid": args.expected_head_oid,
        "expected_author": args.expected_author,
    }
    missing = sorted(name.replace("_", "-") for name, value in fields.items() if value is None)
    if missing:
        raise CheckError(
            "pull_request API mode is missing expectations: " + ", ".join(missing)
        )
    return fields


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    repo_root = args.repo_root.resolve()
    try:
        if args.preflight:
            if args.allow_zero or args.identity_only:
                raise CheckError(
                    "--allow-zero/--identity-only are invalid with --preflight"
                )
            if args.base_revision is None or args.head_revision is None:
                raise CheckError(
                    "--preflight requires --base-revision and --head-revision"
                )
            base_oid = resolve_git_revision(repo_root, args.base_revision)
            head_oid = resolve_git_revision(repo_root, args.head_revision)
            preflight = preflight_paths(
                repo_root,
                base_oid,
                head_oid,
                head_ref=args.expected_head_ref or "",
                allow_bootstrap=args.allow_bootstrap,
            )
            if preflight.declaration_source == "inferred":
                if not args.infer_task:
                    raise CheckError(
                        "final commit subject has no explicit Task ID; inferred "
                        f"{preflight.check.task_id}; amend the subject, for example "
                        f"`fix({preflight.check.task_id}): ...`"
                    )
                print(
                    "check_pr_paths: PREFLIGHT: inferred "
                    f"{preflight.check.task_id} from base-tree Allowed paths; "
                    "workflow fallback will add it to the initial PR body",
                    file=sys.stderr,
                )
            elif preflight.declaration_source == "bootstrap":
                print(
                    "check_pr_paths: PREFLIGHT: matched the maintainer-authorized "
                    "one-time base/head/path bootstrap tuple",
                    file=sys.stderr,
                )
            print(
                "bootstrap"
                if preflight.declaration_source == "bootstrap"
                else preflight.check.task_id or "none"
            )
            return 0

        if (
            args.base_revision is not None
            or args.head_revision is not None
            or args.infer_task
        ):
            raise CheckError(
                "--base-revision/--head-revision/--infer-task are valid only "
                "with --preflight"
            )
        if args.pull_list is not None:
            if args.allow_bootstrap:
                raise CheckError("--allow-bootstrap is invalid with --pull-list")
            if args.identity_only:
                raise CheckError("--identity-only is invalid with --pull-list")
            number = select_unique_pull_request_number(
                args.pull_list, allow_zero=args.allow_zero
            )
            print("none" if number is None else number)
            return 0

        if args.allow_zero:
            raise CheckError("--allow-zero is valid only with --pull-list")
        if args.event is not None:
            if args.allow_bootstrap:
                raise CheckError("--allow-bootstrap is invalid with --event")
            if args.identity_only:
                raise CheckError("--identity-only is valid only with --pull-request")
            context = load_pull_request_context(args.event)
            assert_base_is_ancestor(repo_root, context)
        else:
            expectations = _required_pull_request_expectations(args)
            pull_request = _load_json(args.pull_request, "pull_request API response")
            context = validate_pull_request_identity(
                pull_request,
                **expectations,
            )
            if args.identity_only:
                # Print the number carried by the validated API response, not
                # the expectation we passed in. Echoing the input made the
                # caller's read-back comparison true by construction.
                print(_positive_integer(pull_request.get("number"), "number"))
                return 0

        changed_paths = git_changed_paths(repo_root, context.base_oid, context.head_oid)
        bootstrap_matched = False
        if args.allow_bootstrap:
            bootstrap_result = one_time_bootstrap_result(context, changed_paths)
            if bootstrap_result is not None:
                result = bootstrap_result
                bootstrap_matched = True
            else:
                result = check_paths(repo_root, context, changed_paths)
        else:
            result = check_paths(repo_root, context, changed_paths)
    except CheckError as error:
        print(f"check_pr_paths: ERROR: {error}", file=sys.stderr)
        return 1

    declaration = (
        "none (one-time bootstrap)"
        if bootstrap_matched
        else result.task_id or "none (docs/governance-only)"
    )
    print(
        "check_pr_paths: PASS; "
        f"task={declaration}; changed_paths={len(result.changed_paths)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
