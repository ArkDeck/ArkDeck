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
import datetime
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

# The scope label a repo-wide round reports itself under. It is a label, never a
# change id: every candidate a repo-wide round carries names its own change, and
# the per-change approval gate reads that, not this.
SCOPE_ALL = "all-active-changes"

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
# The colon class stays ASCII-only, deliberately. `status`, `hardware` and
# `grade` above accept `：` as well, and the live corpus writes `Depends on：`
# for the six TASK-BRC-* tasks, so these two fields silently drop them. That
# divergence is a real defect (ledger C-M7) but it is not in this task's scope,
# and widening the class here would enlarge the candidate set as a side effect
# of a fail-closed fix. Recorded for a separate carrier; behaviour preserved.
_DEPENDS_RE = re.compile(r"^-[ \t]*Depends on:" + _GAP + r"([^\n]*)$",
                         re.MULTILINE)
_ALLOWED_RE = re.compile(r"^-[ \t]*Allowed paths:" + _GAP + r"([^\n]*)$",
                         re.MULTILINE)
# A continuation line only carries field content when it is an indented list
# item. Both fields are legitimately written with an empty value followed by an
# indented `- \`path\`` list (34 occurrences across the live tasks.md files at
# 86f9e72b), so the region cannot simply be discarded; but the previous
# `(.+?)(?=^-\s|\Z)` DOTALL capture swallowed ordinary prose too, and then
# scraped it for TASK tokens and backticked paths. A sentence such as
# "曾考虑 `some/other/**` 但未批准" therefore became a declared allowed path,
# which is a claim gate reading its own footnotes as authorisation.
_LIST_ITEM_RE = re.compile(r"^[ \t]+[-*+][ \t]")
_BLOCK_STOP_RE = re.compile(r"^(?:-[ \t]|#{1,6}[ \t])")


def _field_block(section: str, match: "re.Match[str]") -> str:
    """Inline remainder plus the indented list items that continue it."""
    parts = [match.group(1)]
    for line in section[match.end():].splitlines()[1:]:
        if not line.strip():
            continue
        if _BLOCK_STOP_RE.match(line):
            break
        if _LIST_ITEM_RE.match(line):
            parts.append(line)
    return "\n".join(parts)


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
        depends_block = _field_block(section, depends)
        allowed_block = _field_block(section, allowed)
        if not depends_block.strip() or not allowed_block.strip():
            # Declared with an empty value and no list continuation: the field
            # is present but says nothing. Reading that as "no dependencies" or
            # "no path restriction" is the permissive default this reader must
            # never take, so the task is simply not a candidate.
            continue
        dependency_ids = tuple(sorted(set(re.findall(
            r"TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?", depends_block))))
        allowed_paths = tuple(re.findall(r"`([^`]+)`", allowed_block))
        if not allowed_paths:
            continue  # a value that declares no path is not a path allowlist
        candidates.append(TaskCandidate(
            task_id=task_id,
            status=status.group(1),
            decision_grade=(grade.group(1) if grade else "unknown"),
            hardware_required=hardware_value in _HARDWARE_YES,
            dependencies=dependency_ids,
            allowed_paths=allowed_paths,
            base_pin=None,
            change_id=change_id,
        ))
    return candidates


def active_change_ids(repo_root: Path) -> list[str]:
    """Every active change directory holding a tasks.md, in lexicographic order.

    `changes/chg-*` cannot match `changes/archive/<date>-<change>/`, so archived
    changes are excluded by the glob itself rather than by a filter that a later
    edit could drop. Order is deterministic because it decides which task a round
    reaches first when several are claimable, and a round that picked a different
    task each time for the same repository state would be untestable.
    """
    changes = repo_root / "openspec" / "changes"
    return sorted(path.parent.name for path in changes.glob("chg-*/tasks.md"))


def canonical_change_id(repo_root: Path, change_dir: str) -> str:
    """The identifier a PR envelope must carry for this change directory.

    The directory name and the change id are NOT the same string, and assuming
    they were is a live defect this function exists to prevent: the envelope
    validator resolves `Change` against each active proposal's front-matter
    `id:`, and `chg-2026-026-macos-rockchip-flash-ui` declares `CHG-2026-026`.
    The single-change round never noticed, because the change it was pinned to
    happens to be one where the two coincide
    (`chg-2026-030-host-loop-runtime` / `CHG-2026-030-host-loop-runtime`); a
    repo-wide round reaches the ones where they do not, and would have rendered
    an envelope that fails validation at claim time.

    The front-matter parser is imported rather than reimplemented: a second
    reader of the same field is exactly the drift this module keeps being bitten
    by, and `pr_envelope` is the side that decides whether the result is valid.
    """
    from .pr_envelope import _frontmatter_change_id

    proposal = (repo_root / "openspec" / "changes" / change_dir.lower()
                / "proposal.md")
    return _frontmatter_change_id(proposal.read_text(encoding="utf-8"), proposal)


def discover_all(repo_root: Path, change_ids: list[str]) -> list[TaskCandidate]:
    """Candidates from every named change, each tagged with its change.

    This is the whole of "repo-wide discovery": the gates are unchanged and still
    live in `rejection_reasons`, and the per-change approval check still runs —
    `select()` reads the tag. Widening the input cannot widen what is claimable,
    and it cannot claim more than one task, because `select()` returns on the
    first clean candidate.

    A change whose tasks.md cannot be read is not silently skipped; discovery is
    a reader and a partial view of the repository would make an idle verdict a
    lie about the changes it never managed to look at.
    """
    candidates: list[TaskCandidate] = []
    for change_id in change_ids:
        candidates.extend(discover_candidates(repo_root, change_id))
    return candidates


def done_task_ids(repo_root: Path) -> frozenset[str]:
    """Every task recorded as done, in active AND archived changes.

    The archived half is not optional. `changes/*/tasks.md` does not match
    `changes/archive/<date>-<change>/tasks.md`, so archiving a change used to
    make every task inside it read as NOT done — permanently and silently.
    Measured consequence: TASK-RPT-001 and TASK-RPT-002 are both done and both
    archived, so TASK-HLR-001A's and TASK-HLR-002A's declared dependencies could
    never be satisfied again. Fail-closed, hence not dangerous, but it wedges the
    loop for good and nothing reports it.

    A task is done when a change says so; whether that change has since been
    archived is a filing fact about the change, not a retraction of the task.
    """
    done: set[str] = set()
    changes = repo_root / "openspec" / "changes"
    for tasks_file in sorted(list(changes.glob("*/tasks.md"))
                             + list(changes.glob("archive/*/tasks.md"))):
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
    # Every candidate's head, not just the ready ones. reconcile treats this set
    # as total and clears a cursor pr_number it does not list, so restricting the
    # lookup to `ready` meant a task that flipped to blocked or done while its PR
    # was still open produced the correction "pr_number N is not open; cleared" —
    # a false statement of fact in the one log that exists to explain cache
    # divergence. The lease half two blocks up already refuses to build a Truth
    # from an incomplete view; this half was constructing one deliberately.
    open_numbers: set[int] = set()
    for task in sorted({c.task_id for c in candidates}):
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
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--once", action="store_true",
                     help="perform exactly one round")
    mode.add_argument("--explain", action="store_true",
                      help="print the per-gate verdict for every candidate and "
                           "exit; performs no network call and needs no credential")
    parser.add_argument("--repo-dir", default=os.environ.get("ARKDECK_REPO"),
                        help="path to the ArkDeck checkout")
    # No default change. The literal that used to sit here was
    # CHG-2026-030-host-loop-runtime, and once every task in it reached done the
    # scheduled unit — whose plist passes no --change — scanned a finished change
    # for 31 consecutive rounds and reported idle each time. Omitting the flag now
    # means "every active change"; passing it keeps the single-change semantics
    # every existing caller and test relies on.
    parser.add_argument("--change", default=None,
                        help="restrict the round to one change; omit to scan "
                             "every active change")
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


def _utc_stamp(epoch: int) -> str:
    """UTC ISO-8601, second precision, explicit `Z`.

    The round's single output line carried no time and no scope, so a log
    holding 31 identical idle lines could not be told apart from one line a
    stuck tail repeated, and nothing in it said how much of the repository the
    idle verdict actually covered. Both are now on the line.
    """
    return datetime.datetime.fromtimestamp(
        epoch, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _round_line(stamp: str, *, changes: int, candidates: int, result) -> str:
    """Assemble the round's one log line. Pure, so its format is testable.

    Inlined in the print it could only be checked by running a whole round,
    which needs a credential and a network; a contract test would then either
    not exist or assert against the source text of the print, which proves
    nothing.
    """
    return (f"host-loop: {stamp} "
            f"scope=changes:{changes},candidates:{candidates} "
            f"{result.state.value} task={result.task_id} "
            f"pr={result.pr_number} :: {result.detail}")


def _candidate_body_renderer(repo_root: str, *, fallback_change: str,
                             producer: str, run_id: str):
    """Render the envelope under the *selected task's* change id.

    `body_renderer` binds a change at construction time, but a repo-wide round
    does not know which change it will claim from until `select()` has returned.
    Binding the round's scope label instead would stamp every envelope with a
    change the task does not belong to, and that field is what the PR body
    contract and the reviewer read. So the renderer is built per call, from the
    candidate. A candidate with no change id (a single-change round, and every
    pre-existing caller) falls back to the round's scope, which is the change id
    those callers passed.
    """
    def render(candidate, base_oid: str, head_oid: str) -> str:
        change_dir = getattr(candidate, "change_id", "") or fallback_change
        change_id = canonical_change_id(Path(repo_root), change_dir)
        return body_renderer(repo_root, change_id=change_id, producer=producer,
                             run_id=run_id)(candidate, base_oid, head_oid)

    return render


def _int_env(name: str) -> int | None:
    """Absent means "not configured"; present-but-unparsable means stop.

    Collapsing both to None made a typo in ARKDECK_HOST_LOOP_CURSOR_ISSUE
    disable the whole cursor subsystem in silence: no load, no
    rebuild-and-validate against the real Issue, no persistence, and an exit
    code indistinguishable from a healthy round. The operator set the variable,
    so the intent to use a cursor is not in doubt — only the value is.
    """
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return None
    try:
        return int(raw)
    except ValueError:
        raise BackendError(
            f"{name} is set to {raw!r}, which is not an integer") from None


def _explain(repo_root: Path, args, runner) -> int:
    """Print the per-gate verdict for every candidate. No network, no credential.

    The r3 D2 readiness requires the window's receipt to carry a per-gate
    enumeration, because `exit 10` conflates "no candidates", "every candidate
    rejected" and "only never-claim tasks are ready". Before this mode existed
    that requirement was undecidable: nothing in the repository could produce the
    observation the gate asked for.

    Exit 0 when at least one candidate is claimable, 10 when none is — the same
    convention as a real round, so a scheduler wrapper can compare the two.
    """
    # A dry run must not reach the NETWORK; a local subprocess is fine. An
    # earlier version hand-parsed .git/HEAD and crashed with NotADirectoryError,
    # because in a git worktree `.git` is a FILE holding a gitdir pointer, not a
    # directory. git itself knows where its HEAD is; ask it.
    code, out, _err = runner(["git", "rev-parse", "HEAD"])
    local_oid = out.strip() if code == 0 and OID_RE.match(out.strip()) else ""
    done = done_task_ids(repo_root)

    if args.change:
        # Single-change output is unchanged, byte for byte. An explicit --change
        # is how a human interrogates one change and how the existing contract
        # tests drive this mode; widening its output would be a silent change to
        # an interface those tests describe.
        approved, claimable, only_grade, _count = _explain_change(
            repo_root, args.change, done=done, local_oid=local_oid,
            done_line_after_header=True)
        if not approved:
            print("change is not approved; nothing is dispatchable regardless")
            return EXIT_NO_DISPATCH
        if only_grade:
            print(f"one Decision-Grade line from claimable: {sorted(only_grade)}")
        print(f"claimable={sorted(claimable) or 'none'}")
        return EXIT_DISPATCHED if claimable else EXIT_NO_DISPATCH

    change_ids = active_change_ids(repo_root)
    print(f"done_task_ids={len(done)} (active + archived changes)")
    claimable: list[str] = []
    only_grade: list[str] = []
    total = 0
    for change_id in change_ids:
        _approved, change_claimable, change_only_grade, count = _explain_change(
            repo_root, change_id, done=done, local_oid=local_oid,
            done_line_after_header=False)
        claimable.extend(change_claimable)
        only_grade.extend(change_only_grade)
        total += count
    print(f"scanned changes={len(change_ids)} candidates={total}")
    if only_grade:
        print(f"one Decision-Grade line from claimable: {sorted(only_grade)}")
    print(f"claimable={sorted(claimable) or 'none'}")
    return EXIT_DISPATCHED if claimable else EXIT_NO_DISPATCH


def _explain_change(repo_root: Path, change_id: str, *,
                    done: frozenset[str], local_oid: str,
                    done_line_after_header: bool
                    ) -> tuple[bool, list[str], list[str], int]:
    """Print one change's group and return (approved, claimable, only_grade, n).

    Both modes render a candidate the same way because they call this one
    function; the repo-wide mode is a loop over it plus a summary, not a second
    renderer that could drift from the single-change one.

    An unapproved change contributes nothing claimable, but its candidates are
    still enumerated: "why is this task not moving" is a question an operator
    asks about unapproved changes too, and a repo-wide scan that hid them would
    make the change look absent rather than unapproved.
    """
    from .worker import GATED_GRADES, rejection_reasons

    candidates = discover_candidates(repo_root, change_id)
    approved = _change_is_approved(repo_root, change_id)
    print(f"change={change_id} approved={approved} "
          f"local_head={local_oid or 'unknown'} (advisory; no ls-remote)")
    if done_line_after_header:
        print(f"done_task_ids={len(done)} (active + archived changes)")

    claimable: list[str] = []
    only_grade: list[str] = []
    for candidate in candidates:
        reasons = rejection_reasons(candidate, done=done, main_oid=local_oid)
        if not reasons:
            if approved:
                claimable.append(candidate.task_id)
            print(f"  {candidate.task_id}: CLAIMABLE")
            continue
        print(f"  {candidate.task_id}: rejected")
        for reason in reasons:
            print(f"      - {reason}")
        # Stated loudly because it inverts the safety story: for these tasks the
        # missing Decision-Grade line is the ONLY thing standing between the loop
        # and a claim, so filling the field in is a per-task human judgement.
        if (len(reasons) == 1 and candidate.decision_grade not in GATED_GRADES
                and "decision grade" in reasons[0]):
            only_grade.append(candidate.task_id)
    if not approved and not done_line_after_header:
        print(f"  change {change_id} is not approved; "
              "nothing in it is dispatchable regardless")
    return approved, claimable, only_grade, len(candidates)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        if not args.repo_dir:
            raise BackendError("--repo-dir or ARKDECK_REPO is required")
        repo_root = Path(args.repo_dir).resolve()
        if not (repo_root / ".git").exists():
            raise BackendError(f"{repo_root} is not a git checkout")

        runner = SubprocessGitRunner(repo_dir=str(repo_root))

        if args.explain:
            # Returns BEFORE read_token() and before any port is constructed, so
            # a dry run cannot make a network call and cannot require the
            # credential the window has not staged yet. main_oid is read from the
            # local HEAD rather than ls-remote for the same reason.
            return _explain(repo_root, args, runner)

        refs = RefPort(remote="origin", _run=runner)
        api = ApiPort(owner=args.owner, repo=args.repo,
                      _send=UrllibSender(token=read_token()))

        write_commit = commit_writer(str(repo_root))
        leases = LeaseManager(refs, owner_run=args.owner_run,
                              now=lambda: int(time.time()),
                              commit_writer=write_commit, ttl_seconds=args.ttl)

        run_id = str(uuid.uuid4())
        change_ids = ([args.change] if args.change
                      else active_change_ids(repo_root))
        scope = args.change or SCOPE_ALL
        candidates = discover_all(repo_root, change_ids)
        main_oid = observed_main(runner)
        truth = build_truth(api, runner, repo_root, scope, main_oid, candidates)

        cursor_state, cursor_body = _load_cursor(api, args.cursor_issue, main_oid)

        worker = Worker(
            api, leases,
            change_approved=lambda change_id: _change_is_approved(repo_root, change_id),
            done_tasks=lambda: done_task_ids(repo_root),
            read_envelope=_envelope_reader(repo_root),
            read_lease_record=read_lease_record(str(repo_root)),
            prepare_branch=branch_preparer(refs, str(repo_root), writer=write_commit),
            render_body=_candidate_body_renderer(
                str(repo_root), fallback_change=scope,
                producer=args.owner_run, run_id=run_id),
            now=lambda: int(time.time()),
            cursor_issue=args.cursor_issue,
            cursor_body=cursor_body,
        )
        result = worker.run_once(candidates, scope, main_oid, cursor_state, truth)
    except (CursorError, ReconcileRequired) as error:
        # cursor.py's contract calls a missing Issue, an unparsable machine
        # block and any conflict reconcile-required, and the same CursorError
        # raised fifteen lines later inside run_once already exits 20. Exiting 1
        # here told the scheduler "transient setup problem, retry" for exactly
        # the corruption the design says a human must look at.
        print(f"host-loop: reconcile required: {error}", file=sys.stderr)
        return EXIT_RECONCILE
    except (BackendError, TransportError, LeaseError) as error:
        print(f"host-loop: setup/round failure: {error}", file=sys.stderr)
        return EXIT_ERROR
    except Exception as error:  # noqa: BLE001 - a crash must not read as success
        print(f"host-loop: unexpected {type(error).__name__}: {error}", file=sys.stderr)
        return EXIT_ERROR

    print(_round_line(_utc_stamp(int(time.time())), changes=len(change_ids),
                      candidates=len(candidates), result=result))
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
        # Same punctuation trap the task fields carry: `(\S+)` runs to the next
        # whitespace, so `status: approved # ratified` reads as `approved` but
        # `status:approved（注）` or `status:approved#x` reads as a token that
        # matches nothing and silently makes an approved change unapprovable.
        # _VALUE stops at the punctuation the real files use.
        match = re.match(r"^status:" + _GAP + _VALUE, line.strip())
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
