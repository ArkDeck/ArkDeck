"""Merge-OID recovery and crash-restart decisions (TASK-HLR-004).

design §5: a PR's closed/merged fact must be cross-confirmed from GitHub merge
metadata AND from a full merge OID in protected main's history. Branch
deletion, elapsed time, an Issue saying so and green CI are all insufficient —
each has a named negative test. Only after confirmation may the caller release
the lease and advance the cursor.

The r1 readiness pins the two sources:

  source A  typed PR lookup metadata: `merged`, `merged_at`,
            `merge_commit_sha` — measured to sometimes become null later
            while `merged=true` stays, so it is NEVER sufficient alone;
  source B  protected main git history: the candidate OID must be an
            ancestor of the observed main head and its squash subject must
            carry `(#N)`; when source A's sha is null, source B must locate
            the merge commit UNIQUELY by that subject convention.

Any missing or conflicting side is `ambiguous`, which the caller must treat
as reconcile-required: zero lease release, zero cursor advance.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Sequence

from .transport import OID_RE

# Bounded history scan for the sha-null fallback. Squash merges land on main
# in order; a merge older than this window is found by ancestry long before
# the scan matters, and an unbounded scan would hide a pathological state.
_HISTORY_SCAN_LIMIT = "500"


@dataclass(frozen=True)
class MergeConfirmation:
    confirmed: bool
    ambiguous: bool
    merge_oid: str | None
    detail: str


def _not_merged(detail: str) -> MergeConfirmation:
    return MergeConfirmation(False, False, None, detail)


def _ambiguous(detail: str) -> MergeConfirmation:
    return MergeConfirmation(False, True, None, detail)


def _confirmed(oid: str, detail: str) -> MergeConfirmation:
    return MergeConfirmation(True, False, oid, detail)


def _subject_carries(subject: str, pr_number: int) -> bool:
    """True only when the subject ENDS with `(#N)`, the squash convention.

    Substring matching failed both ways. A later commit that merely mentions
    the number — "follow-up: address feedback from (#42)" — satisfied source B
    in the sha-null fallback, so an unrelated commit could be confirmed as the
    merge; and when the real squash and a mention both sat inside the history
    window, two matches read as ambiguous and stopped the lane. GitHub places
    `(#N)` at the end of a squash subject, which is what the r1 pin means by
    locating the commit uniquely.
    """
    return subject.rstrip().endswith(f"(#{pr_number})")


def confirm_merged(
    pr: dict,
    pr_number: int,
    main_oid: str,
    runner: Callable[[Sequence[str]], tuple[int, str, str]],
) -> MergeConfirmation:
    """Cross-confirm one PR's merge from metadata AND main history.

    `pr` is the typed `get_pull` payload (untrusted data). `main_oid` is the
    caller's observed protected-main head (from `observed_main`, i.e. an
    ls-remote fact, not a local branch). `runner` is the git runner; every
    git failure is ambiguous, never a default.
    """
    if not isinstance(pr_number, int) or isinstance(pr_number, bool) or pr_number < 1:
        return _ambiguous("pr_number is not a positive int")
    if not isinstance(main_oid, str) or not OID_RE.match(main_oid):
        return _ambiguous("observed main OID is not a full 40-hex OID")

    merged = pr.get("merged")
    if merged is not True:
        # `1`, `"true"` and a missing key all fail closed: the platform sends
        # a real boolean, so anything else is a malformed payload, and bool is
        # the one type where isinstance(int) tricks slip through.
        if isinstance(merged, bool) or merged is None:
            return _not_merged("GitHub metadata does not say merged")
        return _ambiguous(f"merged flag has a non-boolean shape: {merged!r}")

    sha = pr.get("merge_commit_sha")
    if sha is not None:
        if not isinstance(sha, str) or not OID_RE.match(sha):
            return _ambiguous(f"merge_commit_sha is malformed: {sha!r}")
        code, _out, _err = runner(["git", "merge-base", "--is-ancestor", sha,
                                   main_oid])
        if code != 0:
            return _ambiguous(
                "metadata names a merge commit that is not an ancestor of "
                "observed main; the two sources disagree")
        code, out, _err = runner(["git", "show", "-s", "--format=%s", sha])
        if code != 0:
            return _ambiguous("cannot read the merge commit's subject")
        subject = out.strip().splitlines()[0] if out.strip() else ""
        if not _subject_carries(subject, pr_number):
            return _ambiguous(
                f"merge commit subject does not carry (#{pr_number}); "
                "identity not established")
        return _confirmed(sha, "metadata sha confirmed by ancestry and subject")

    # Source A degraded (sha null, merged still true): source B must locate
    # the squash commit uniquely by the `(#N)` subject convention.
    code, out, _err = runner(["git", "log", "--format=%H%x09%s", "-n",
                              _HISTORY_SCAN_LIMIT, main_oid])
    if code != 0:
        return _ambiguous("cannot scan protected main history")
    matches: list[str] = []
    for line in out.splitlines():
        oid, _tab, subject = line.partition("\t")
        if OID_RE.match(oid.strip()) and _subject_carries(subject, pr_number):
            matches.append(oid.strip())
    if len(matches) == 1:
        return _confirmed(matches[0],
                          "sha-null fallback: unique subject match in history")
    if not matches:
        return _ambiguous(
            "metadata says merged but no main commit carries the subject; "
            "the two sources disagree")
    return _ambiguous(
        f"{len(matches)} main commits carry (#{pr_number}); not unique")


def advance_allowed(confirmation: MergeConfirmation) -> bool:
    """Lease release / cursor advance strictly requires a confirmed merge."""
    return confirmation.confirmed is True


# --------------------------------------------------------- restart decisions
class RestartWindow(str, Enum):
    """The five crash windows retained by the host-loop worker."""

    AFTER_ACQUIRE = "afterAcquire"
    PR_CREATE_TIMEOUT = "prCreateTimeout"
    BODY_UPDATE = "bodyUpdate"
    HEARTBEAT = "heartbeat"
    MERGE_OBSERVATION = "mergeObservation"


class RestartAction(str, Enum):
    RESUME = "resume"
    ADOPT_EXISTING_PR = "adoptExistingPr"
    STOP = "stop"
    RELEASE_AND_ADVANCE = "releaseAndAdvance"


@dataclass(frozen=True)
class RestartObservation:
    """What a restarted worker has RE-OBSERVED, not what it remembers.

    Every field is an observation made after the restart; defaults are the
    fail-closed absence of the observation.
    """

    fence_intact: bool = False
    open_pr_count: int | None = None
    merge: MergeConfirmation | None = None


def restart_decision(window: RestartWindow,
                     observed: RestartObservation) -> tuple[RestartAction, str]:
    """Fail-closed continuation decision for each crash window.

    Time elapsed is deliberately NOT an input: nothing here may resume or
    advance because a while has passed.
    """
    if window is RestartWindow.AFTER_ACQUIRE:
        if observed.fence_intact:
            return RestartAction.RESUME, "lease fence re-verified; resume"
        return RestartAction.STOP, "lease fence not re-verified; stop"

    if window is RestartWindow.PR_CREATE_TIMEOUT:
        # design §3: search by stable identity and adopt the UNIQUE existing
        # PR; zero or more than one both stop — never a second create.
        if not observed.fence_intact:
            return RestartAction.STOP, "lease fence not re-verified; stop"
        if observed.open_pr_count == 1:
            return (RestartAction.ADOPT_EXISTING_PR,
                    "unique existing PR adopted by stable identity")
        return (RestartAction.STOP,
                f"{observed.open_pr_count!r} PRs found for the identity; a "
                "second PR is never created")

    if window is RestartWindow.BODY_UPDATE:
        if observed.fence_intact and observed.open_pr_count == 1:
            return RestartAction.RESUME, "fence and unique PR re-verified"
        return RestartAction.STOP, "fence or unique-PR fact missing after restart"

    if window is RestartWindow.HEARTBEAT:
        if observed.fence_intact:
            return RestartAction.RESUME, "fence still owned; resume"
        return (RestartAction.STOP,
                "fence expired or lost; takeover has its own exact-OID rules "
                "and this restart does not shortcut them")

    if window is RestartWindow.MERGE_OBSERVATION:
        merge = observed.merge
        if merge is None:
            return RestartAction.STOP, "no merge confirmation was re-observed"
        if merge.confirmed:
            return (RestartAction.RELEASE_AND_ADVANCE,
                    "merge cross-confirmed; release the lease and advance")
        if merge.ambiguous:
            return (RestartAction.STOP,
                    f"merge observation is ambiguous: {merge.detail}")
        return RestartAction.RESUME, "not merged yet; keep observing"

    return RestartAction.STOP, f"unknown restart window {window!r}"  # pragma: no cover
