"""`python3 -m host_loop --once` — the entry point a scheduler invokes.

TASK-HLR-003 readiness r2 authorises this surface. One invocation performs at
most one round and exits; there is no internal loop, so a wedged round cannot
hold the host and the scheduler decides the cadence.

Exit codes, as r2 requires them to be distinguishable:

    0   dispatched          the round advanced a task
    10  no-dispatch         nothing claimable, or a gated/foreign-lease stop
    20  reconcile-required  an ambiguity stopped the lane; a human must look
    1   error               the run could not be set up at all

Everything the round touches goes through ApiPort/RefPort, so the frozen route
allowlist, the field allowlists and the ownership bindings remain the only path
to GitHub. This module adds no route and relaxes no allowlist.

Nothing here creates a launchd account, plist, job or socket, and nothing
loads, enables or kickstarts a scheduler: r2 keeps that in the separate D2
phase, and until it happens dispatch is 0 by construction because no scheduler
invokes this module.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
import uuid
from pathlib import Path

from .backends import (
    BackendError,
    SubprocessGitRunner,
    UrllibSender,
    body_renderer,
    branch_preparer,
    commit_writer,
    read_lease_record,
    read_token,
)
from .cursor import CursorError, CursorState, Truth, load, parse_machine_block
from .identity import ReconcileRequired
from .lease import LeaseError, LeaseManager, lease_ref
from .transport import ApiPort, OID_RE, RefPort, TransportError
from .worker import TaskCandidate, Worker, WorkerState

EXIT_DISPATCHED = 0
EXIT_ERROR = 1
EXIT_NO_DISPATCH = 10
EXIT_RECONCILE = 20

_TASK_HEADER_RE = re.compile(
    r"^##\s+(TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?)(?:\s|$)", re.MULTILINE
)
# A field value ends at whitespace OR at the punctuation the real tasks.md puts
# straight after it. `(\S+)` was greedy to whitespace only, so
# `- Status:ready（r2 corrective readiness）` parsed as `ready（r2` and the
# worker's `status == "ready"` gate could never be true for any task. The class
# is negated rather than alphanumeric so a CJK value such as `是` still yields a
# token to reject explicitly, instead of silently not matching.
_VALUE = r"([^\s：:,，。；;、（）()]+)"
# The separator before a value is horizontal whitespace ONLY. `\s*` matched a
# newline, so a field written with an empty value did not read as absent — the
# parser stepped over the line break and captured the first token of the prose
# below it. For Decision-Grade that manufactures a dispatchable D0 out of a
# sentence, which is the one value this reader must never invent.
_GAP = r"[ \t]*"
_FIELD_RE = {
    # `- Historical Status:` must not satisfy `Status:` — the real file carries
    # 18 of the former against 8 of the latter, and reading a superseded state
    # as current would be worse than reading none. The `^-\s*` anchor is what
    # keeps them apart.
    "status": re.compile(r"^-[ \t]*Status[:：]" + _GAP + _VALUE, re.MULTILINE),
    "hardware": re.compile(r"^-[ \t]*Hardware required[:：]" + _GAP + _VALUE,
                           re.MULTILINE),
    "grade": re.compile(r"^-[ \t]*Decision(?:-| )[Gg]rade[:：]" + _GAP + _VALUE,
                        re.MULTILINE),
}

# Hardware is a safety field, so its vocabulary is closed in both directions and
# anything outside it omits the task. The previous test was
# `.lower().startswith("yes")`, which mapped `是`, `必需`, `TBD` and a missing
# line alike to "no hardware needed" — a permissive default on exactly the field
# that decides whether an unattended loop may touch a task at all.
_HARDWARE_YES = frozenset({"yes", "true", "required", "是", "需要", "必需"})
_HARDWARE_NO = frozenset({"no", "false", "none", "否", "不需要", "无"})
_DEPENDS_RE = re.compile(r"^-\s*Depends on:\s*(.+?)(?=^-\s|\Z)", re.MULTILINE | re.DOTALL)
_ALLOWED_RE = re.compile(r"^-\s*Allowed paths:\s*(.+?)(?=^-\s|\Z)", re.MULTILINE | re.DOTALL)


_FENCE_RE = re.compile(r"^(?P<fence>```+|~~~+).*?^(?P=fence)[ \t]*$",
                       re.MULTILINE | re.DOTALL)


def _without_code_fences(text: str) -> str:
    """Blank out fenced blocks, preserving line count so offsets stay usable.

    Section splitting was fence-unaware, so a `## TASK-…` header quoted inside a
    fenced example became a real section: an invented candidate in discovery,
    and — worse — a fabricated id in done_task_ids, which is the set the
    dependency gate consults. Documentation could therefore satisfy a real
    task's prerequisite.
    """
    def blank(match: re.Match) -> str:
        return "\n" * match.group(0).count("\n")

    return _FENCE_RE.sub(blank, text)


def discover_candidates(repo_root: Path, change_id: str) -> list[TaskCandidate]:
    """Parse the change's active tasks.md into candidates.

    Included because an entry point that cannot obtain candidates is not an
    entry point — `--once` would exit no-dispatch unconditionally. It is
    deliberately a *reader*: it grants nothing, and the worker's own gates
    (approved change, ready status, host-only, dependencies, allowed paths,
    base pin, decision grade, never-claim) decide what may be claimed.

    A task whose fields cannot be parsed is omitted rather than defaulted, so a
    malformed header can never widen what is claimable. That sentence was
    previously true of the decision grade and false of `Hardware required`,
    where a missing or unrecognised value produced False — i.e. "host-only, go
    ahead". Absence now omits the task in both cases.

    The one thing this reader deliberately does NOT do is supply a decision
    grade. When `- Decision-Grade:` is absent the grade stays "unknown" and the
    worker refuses, because declaring a task's decision grade is a human
    judgement and inventing a default here would be the reader granting itself
    the authority it is written not to have.
    """
    tasks_file = repo_root / "openspec" / "changes" / change_id.lower() / "tasks.md"
    if not tasks_file.is_file():
        raise BackendError(f"active tasks file not found: {tasks_file}")
    text = _without_code_fences(tasks_file.read_text(encoding="utf-8"))

    candidates: list[TaskCandidate] = []
    sections = re.split(r"(?m)^##\s+", text)[1:]
    for section in sections:
        header = _TASK_HEADER_RE.match("## " + section)
        if header is None:
            continue
        task_id = header.group(1)
        status = _FIELD_RE["status"].search(section)
        if status is None:
            continue
        hardware = _FIELD_RE["hardware"].search(section)
        if hardware is None:
            continue  # undeclared hardware requirement: never claimable
        hardware_value = hardware.group(1).strip().lower()
        if hardware_value not in _HARDWARE_YES and hardware_value not in _HARDWARE_NO:
            continue  # undecidable safety field: never claimable
        grade = _FIELD_RE["grade"].search(section)
        depends = _DEPENDS_RE.search(section)
        if depends is None:
            # The last field whose absence silently meant "nothing blocks me".
            # status, hardware and allowed-paths all omit the task when
            # unparsable; this one collapsed to () and made the worker's
            # dependency gate vacuous. All eight real tasks declare it.
            continue
        allowed = _ALLOWED_RE.search(section)
        if allowed is None:
            continue  # no declared allowed paths: never claimable
        dependency_ids = tuple(sorted(set(
            _TASK_HEADER_RE.sub("", depends.group(1)) and
            re.findall(r"TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?", depends.group(1))
        ))) if depends else ()
        allowed_paths = tuple(re.findall(r"`([^`]+)`", allowed.group(1)))
        candidates.append(TaskCandidate(
            task_id=task_id,
            status=status.group(1),
            decision_grade=(grade.group(1) if grade else "unknown"),
            hardware_required=hardware_value in _HARDWARE_YES,
            dependencies=dependency_ids,
            allowed_paths=allowed_paths,
            base_pin=None,
        ))
    return candidates


def done_task_ids(repo_root: Path) -> frozenset[str]:
    """Every task recorded as done across active changes."""
    done: set[str] = set()
    changes = repo_root / "openspec" / "changes"
    for tasks_file in sorted(changes.glob("*/tasks.md")):
        text = _without_code_fences(tasks_file.read_text(encoding="utf-8"))
        for section in re.split(r"(?m)^##\s+", text)[1:]:
            header = _TASK_HEADER_RE.match("## " + section)
            status = _FIELD_RE["status"].search(section)
            if header and status and status.group(1).startswith("done"):
                done.add(header.group(1))
    return frozenset(done)


def observed_main(runner) -> str:
    code, out, err = runner(["git", "ls-remote", "origin", "refs/heads/main"])
    if code != 0 or not out.strip():
        raise BackendError(f"cannot observe protected main: {err.strip()[:160]}")
    oid = out.split()[0]
    if not OID_RE.match(oid):
        raise BackendError("unparsable main OID from ls-remote")
    return oid


def build_truth(api: ApiPort, runner, repo_root: Path, change_id: str,
                main_oid: str, candidates: list[TaskCandidate]) -> Truth:
    """Authoritative facts the cursor cache is validated against."""
    ready = frozenset(c.task_id for c in candidates if c.status.startswith("ready"))
    code, out, _err = runner(["git", "ls-remote", "origin",
                              "refs/heads/agent/host-loop/leases/*"])
    # A failed observation must not shrink the truth set. It used to leave
    # lease_map empty, and since reconcile clears a lease_ref that Truth does not
    # list, one flaky ls-remote read as "the lease is gone" and dropped the fence
    # from the cache. The PR half of this function already re-raises for exactly
    # this reason; the lease half did not.
    if code != 0:
        raise BackendError(
            "ls-remote of the lease namespace failed; refusing to build a Truth "
            "whose lease view may be incomplete"
        )
    lease_map: dict[str, str] = {}
    for line in out.strip().splitlines():
        parts = line.split()
        if len(parts) == 2 and OID_RE.match(parts[0]):
            lease_map[parts[1]] = parts[0]
    open_numbers: set[int] = set()
    for task in ready:
        head = f"agent/host-loop/tasks/{task}"
        try:
            for pull in api.list_open_pulls_for_head(head):
                number = pull.get("number")
                if isinstance(number, int):
                    open_numbers.add(number)
        except TransportError:
            # A lookup failure must not silently shrink the truth set, or the
            # cursor would "conflict" against an incomplete view.
            raise
    return Truth(main_oid=main_oid, ready_tasks=ready,
                 open_pr_numbers=frozenset(open_numbers), lease_oid_by_ref=lease_map)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python3 -m host_loop",
        description="Run one host-loop worker round and exit.",
    )
    parser.add_argument("--once", action="store_true", required=True,
                        help="perform exactly one round (the only supported mode)")
    parser.add_argument("--repo-dir", default=os.environ.get("ARKDECK_REPO"),
                        help="path to the ArkDeck checkout")
    parser.add_argument("--change", default="CHG-2026-030-host-loop-runtime")
    parser.add_argument("--owner", default="ArkDeck")
    parser.add_argument("--repo", default="ArkDeck")
    parser.add_argument("--cursor-issue", type=int,
                        default=_int_env("ARKDECK_HOST_LOOP_CURSOR_ISSUE"),
                        help="navigation Issue number; omitted means read-only cursor")
    parser.add_argument("--owner-run", default=os.environ.get(
        "ARKDECK_HOST_LOOP_OWNER", "host-loop/worker"),
        help="stable worker identity; the lease manager owns it")
    parser.add_argument("--ttl", type=int, default=900)
    return parser.parse_args(sys.argv[1:] if argv is None else argv)


def _int_env(name: str) -> int | None:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        if not args.repo_dir:
            raise BackendError("--repo-dir or ARKDECK_REPO is required")
        repo_root = Path(args.repo_dir).resolve()
        if not (repo_root / ".git").exists():
            raise BackendError(f"{repo_root} is not a git checkout")

        runner = SubprocessGitRunner(repo_dir=str(repo_root))
        refs = RefPort(remote="origin", _run=runner)
        api = ApiPort(owner=args.owner, repo=args.repo,
                      _send=UrllibSender(token=read_token()))

        write_commit = commit_writer(str(repo_root))
        leases = LeaseManager(refs, owner_run=args.owner_run,
                              now=lambda: int(time.time()),
                              commit_writer=write_commit, ttl_seconds=args.ttl)

        run_id = str(uuid.uuid4())
        candidates = discover_candidates(repo_root, args.change)
        main_oid = observed_main(runner)
        truth = build_truth(api, runner, repo_root, args.change, main_oid, candidates)

        cursor_state, cursor_body = _load_cursor(api, args.cursor_issue, main_oid)

        worker = Worker(
            api, leases,
            change_approved=lambda change_id: _change_is_approved(repo_root, change_id),
            done_tasks=lambda: done_task_ids(repo_root),
            read_envelope=_envelope_reader(repo_root),
            read_lease_record=read_lease_record(str(repo_root)),
            prepare_branch=branch_preparer(refs, str(repo_root), writer=write_commit),
            render_body=body_renderer(str(repo_root), change_id=args.change,
                                      producer=args.owner_run, run_id=run_id),
            now=lambda: int(time.time()),
            cursor_issue=args.cursor_issue,
            cursor_body=cursor_body,
        )
        result = worker.run_once(candidates, args.change, main_oid, cursor_state, truth)
    except (BackendError, TransportError, LeaseError, CursorError,
            ReconcileRequired) as error:
        print(f"host-loop: setup/round failure: {error}", file=sys.stderr)
        return EXIT_ERROR
    except Exception as error:  # noqa: BLE001 - a crash must not read as success
        print(f"host-loop: unexpected {type(error).__name__}: {error}", file=sys.stderr)
        return EXIT_ERROR

    print(f"host-loop: {result.state.value} task={result.task_id} "
          f"pr={result.pr_number} :: {result.detail}")
    if result.state == WorkerState.RECONCILE_REQUIRED:
        return EXIT_RECONCILE
    if result.dispatched:
        return EXIT_DISPATCHED
    return EXIT_NO_DISPATCH


def _load_cursor(api: ApiPort, issue_number: int | None, main_oid: str
                 ) -> tuple[CursorState, str]:
    """Load the navigation cursor, or start from a fresh in-memory one.

    A missing Issue number means no cursor is configured yet, which is not the
    same as an unreadable cursor: `cursor.load` still refuses a configured but
    broken Issue rather than minting a replacement.
    """
    if issue_number is None:
        return CursorState(
            cursor_main_oid=main_oid, candidate_task=None, lease_ref=None,
            lease_oid=None, pr_number=None, pr_head=None, review_run=None,
            last_observed_at=int(time.time()),
        ), ""
    state, issue = load(api, issue_number)
    return state, (issue.get("body") or "")


def _change_is_approved(repo_root: Path, change_id: str) -> bool:
    """A change is dispatchable only once its proposal records approval."""
    proposal = repo_root / "openspec" / "changes" / change_id.lower() / "proposal.md"
    if not proposal.is_file():
        return False
    for line in proposal.read_text(encoding="utf-8").splitlines()[:40]:
        match = re.match(r"^status:\s*(\S+)", line.strip())
        if match:
            return match.group(1) in ("approved", "verified")
    return False


def _envelope_reader(repo_root: Path):
    """Return (task, base_oid) from a PR body, or None when it carries none."""
    from .pr_envelope import EnvelopeError, parse_envelope

    def read(body: str):
        try:
            parsed = parse_envelope(body)
        except EnvelopeError:
            return None
        return parsed.envelope.task, parsed.envelope.base_oid

    return read


if __name__ == "__main__":
    sys.exit(main())
