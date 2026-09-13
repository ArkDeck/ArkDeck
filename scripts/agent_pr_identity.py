#!/usr/bin/env python3
"""Select and validate the bot pull request for a pushed agent branch.

``.github/workflows/agent-pr.yml`` opens the pull request for an ``agent/**``
push as ``github-actions[bot]`` and then has to act on *that* pull request and
no other. This module is the identity half of the retired PR allowed-paths
guard (``scripts/check_pr_paths.py``, TASK-MECH-004 … TASK-DSE-001; retired by
CHG-2026-077 / TASK-RPG-001), kept because the workflow still needs it.

``--pull-list``
    The paginated ``GET /pulls?head=owner:branch`` result, slurped into an
    array of page arrays. Prints the one open pull request number, ``none``
    with ``--allow-zero`` when there is none yet, and fails on any other count
    or shape.

``--pull-request``
    One ``GET /pulls/{number}`` response. Fails closed unless repository,
    number, base ref, head ref, head OID and author all match the expectations
    passed on the command line; prints the number carried by the response,
    never the expectation echoed back.

``--commit-task``
    The first task token in the subject of the given commit, or ``none``. The
    workflow copies it into the pull request body as ``Task: …``. It is
    traceability only: nothing looks the token up, nothing is authorised by it
    and no push is refused because of it.

Untrusted pull request fields (title, body, head ref) are read from JSON files
here and never interpolated into a shell; the workflow passes only file paths
and its own expectations on the command line. Standard library only, so the
runner needs no install step.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


# Byte-identical to scripts/host_loop/instance.py TASK_TOKEN_TEXT;
# scripts/host_loop/test_token_parity.py fails if the two ever drift.
TASK_TOKEN_TEXT = r"TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?"
TASK_TOKEN_RE = re.compile(rf"(?<![A-Z0-9-])({TASK_TOKEN_TEXT})(?![A-Z0-9-])")
FULL_OID_RE = re.compile(r"^[0-9a-fA-F]{40}$")


class IdentityError(ValueError):
    """A deterministic, operator-correctable identity failure."""


@dataclass(frozen=True)
class PullRequestContext:
    title: str
    body: str
    head_ref: str
    base_oid: str
    head_oid: str


def _string(value: object, field: str) -> str:
    if not isinstance(value, str):
        raise IdentityError(f"pull_request {field} must be a string")
    return value


def _load_json(path: Path, label: str) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise IdentityError(f"cannot parse {label} {path}: {error}") from error


def _positive_integer(value: object, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise IdentityError(f"pull_request {field} must be a positive integer")
    return value


def _repository_name(value: object, field: str) -> str:
    if not isinstance(value, dict):
        raise IdentityError(f"pull_request {field} must be an object")
    return _string(value.get("full_name"), f"{field}.full_name")


def pull_request_context_from_object(pull_request: object) -> PullRequestContext:
    if not isinstance(pull_request, dict):
        raise IdentityError("pull_request must be an object")

    base = pull_request.get("base")
    head = pull_request.get("head")
    if not isinstance(base, dict) or not isinstance(head, dict):
        raise IdentityError("pull_request base/head objects are missing")

    title = _string(pull_request.get("title"), "title")
    body_value = pull_request.get("body")
    body = "" if body_value is None else _string(body_value, "body")
    head_ref = _string(head.get("ref"), "head.ref")
    base_oid = _string(base.get("sha"), "base.sha")
    head_oid = _string(head.get("sha"), "head.sha")
    if not FULL_OID_RE.fullmatch(base_oid) or not FULL_OID_RE.fullmatch(head_oid):
        raise IdentityError("pull_request base/head SHA must each be a full 40-hex OID")

    return PullRequestContext(
        title=title,
        body=body,
        head_ref=head_ref,
        base_oid=base_oid.lower(),
        head_oid=head_oid.lower(),
    )


def select_unique_pull_request_number(
    pages_path: Path, *, allow_zero: bool
) -> int | None:
    pages = _load_json(pages_path, "paginated pull_request list")
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise IdentityError("paginated pull_request list must be an array of page arrays")

    numbers: list[int] = []
    for page in pages:
        for pull_request in page:
            if not isinstance(pull_request, dict):
                raise IdentityError("paginated pull_request list contains a non-object entry")
            numbers.append(_positive_integer(pull_request.get("number"), "number"))

    if not numbers and allow_zero:
        return None
    if len(numbers) != 1:
        raise IdentityError(
            f"expected exactly one open pull_request after create-or-find, found {len(numbers)}"
        )
    return numbers[0]


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
        raise IdentityError("pull_request must be an object")
    if not FULL_OID_RE.fullmatch(expected_head_oid):
        raise IdentityError("expected head OID must be a full 40-hex OID")
    if _positive_integer(pull_request.get("number"), "number") != expected_number:
        raise IdentityError("pull_request number does not match the selected PR")
    if pull_request.get("state") != "open":
        raise IdentityError("pull_request state must be open")
    if pull_request.get("merged") is not False:
        raise IdentityError("pull_request merged must be false")

    base = pull_request.get("base")
    head = pull_request.get("head")
    author = pull_request.get("user")
    if not isinstance(base, dict) or not isinstance(head, dict):
        raise IdentityError("pull_request base/head objects are missing")
    if not isinstance(author, dict):
        raise IdentityError("pull_request user must be an object")

    if _string(base.get("ref"), "base.ref") != expected_base_ref:
        raise IdentityError("pull_request base.ref does not match expected base")
    if _repository_name(base.get("repo"), "base.repo") != expected_repository:
        raise IdentityError("pull_request base repository does not match expected repository")
    if _string(head.get("ref"), "head.ref") != expected_head_ref:
        raise IdentityError("pull_request head.ref does not match the pushed branch")
    if _repository_name(head.get("repo"), "head.repo") != expected_repository:
        raise IdentityError("pull_request head repository does not match expected repository")
    if _string(head.get("sha"), "head.sha").lower() != expected_head_oid.lower():
        raise IdentityError("pull_request head.sha does not match the pushed commit")
    if _string(author.get("login"), "user.login") != expected_author:
        raise IdentityError("pull_request author does not match expected bot identity")

    return pull_request_context_from_object(pull_request)


def _run_git(repo_root: Path, arguments: Sequence[str], *, context: str) -> bytes:
    completed = subprocess.run(
        ["git", "-C", str(repo_root), *arguments],
        check=False,
        capture_output=True,
    )
    if completed.returncode != 0:
        stderr = completed.stderr.decode("utf-8", errors="replace").strip()
        raise IdentityError(f"{context} failed: {stderr}")
    return completed.stdout


def resolve_git_revision(repo_root: Path, revision: str) -> str:
    if not revision:
        raise IdentityError("git revision must not be empty")
    raw_oid = _run_git(
        repo_root,
        ["rev-parse", "--verify", "--end-of-options", f"{revision}^{{commit}}"],
        context=f"git rev-parse {revision}",
    )
    try:
        oid = raw_oid.decode("ascii").strip()
    except UnicodeDecodeError as error:
        raise IdentityError(
            f"git revision {revision!r} resolved to non-ASCII output"
        ) from error
    if not FULL_OID_RE.fullmatch(oid):
        raise IdentityError(
            f"git revision {revision!r} did not resolve to one full commit OID"
        )
    return oid.lower()


def commit_task_declaration(repo_root: Path, revision: str) -> str | None:
    """The first task token in the commit subject, or ``None``.

    Informational by design: a subject with several tokens yields the first
    (the ``type(TASK-…):`` convention puts the declared one there), a subject
    with none yields ``None``, and a subject that is not valid UTF-8 is read
    with replacement characters rather than refused — none of these may stop
    a pull request from being opened.
    """
    oid = resolve_git_revision(repo_root, revision)
    raw_subject = _run_git(
        repo_root,
        ["show", "-s", "--format=%s", oid],
        context=f"git show subject for {oid}",
    )
    subject = raw_subject.decode("utf-8", errors="replace")
    match = TASK_TOKEN_RE.search(subject)
    return match.group(1) if match else None


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--repo-root", type=Path, required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument(
        "--pull-list",
        type=Path,
        help="paginated, slurped GET /pulls result; prints the unique open number",
    )
    source.add_argument(
        "--pull-request",
        type=Path,
        help="one GET /pulls/{number} response; validated against --expected-*",
    )
    source.add_argument(
        "--commit-task",
        metavar="REVISION",
        help="print the first task token of this commit's subject, or none",
    )
    parser.add_argument(
        "--allow-zero",
        action="store_true",
        help="with --pull-list: print none instead of failing on zero candidates",
    )
    parser.add_argument("--expected-repository")
    parser.add_argument("--expected-number", type=int)
    parser.add_argument("--expected-base-ref")
    parser.add_argument("--expected-head-ref")
    parser.add_argument("--expected-head-oid")
    parser.add_argument("--expected-author")
    return parser.parse_args(argv)


_EXPECTATION_FIELDS = (
    "expected_repository",
    "expected_number",
    "expected_base_ref",
    "expected_head_ref",
    "expected_head_oid",
    "expected_author",
)


def _required_pull_request_expectations(args: argparse.Namespace) -> dict[str, object]:
    fields = {name: getattr(args, name) for name in _EXPECTATION_FIELDS}
    missing = sorted(name.replace("_", "-") for name, value in fields.items() if value is None)
    if missing:
        raise IdentityError(
            "pull_request identity mode is missing expectations: " + ", ".join(missing)
        )
    return fields


def _reject_expectations(args: argparse.Namespace, mode: str) -> None:
    given = sorted(
        name.replace("_", "-")
        for name in _EXPECTATION_FIELDS
        if getattr(args, name) is not None
    )
    if given:
        raise IdentityError(
            f"--{'/--'.join(given)} are valid only with --pull-request, not {mode}"
        )


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    repo_root = args.repo_root.resolve()
    try:
        if args.pull_list is not None:
            _reject_expectations(args, "--pull-list")
            number = select_unique_pull_request_number(
                args.pull_list, allow_zero=args.allow_zero
            )
            print("none" if number is None else number)
            return 0

        if args.allow_zero:
            raise IdentityError("--allow-zero is valid only with --pull-list")

        if args.commit_task is not None:
            _reject_expectations(args, "--commit-task")
            print(commit_task_declaration(repo_root, args.commit_task) or "none")
            return 0

        expectations = _required_pull_request_expectations(args)
        pull_request = _load_json(args.pull_request, "pull_request API response")
        validate_pull_request_identity(pull_request, **expectations)
        # Print the number carried by the validated API response, not the
        # expectation we passed in. Echoing the input made the caller's
        # read-back comparison true by construction.
        print(_positive_integer(pull_request.get("number"), "number"))
        return 0
    except IdentityError as error:
        print(f"agent_pr_identity: ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
