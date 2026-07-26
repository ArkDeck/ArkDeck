"""Independent reviewer loop, review gate and batch handoff (TASK-HLR-004).

design §4, second row — this module owns everything past checksGreen:

    checksGreen -> reviewRequested -> reviewRecorded -> batchQueued
    review REQUEST_CHANGES/BLOCKED -> workerPaused
    any ambiguity                  -> reconcileRequired

Hard rules encoded here, each with a contract test:

* the reviewer is a DIFFERENT session from the worker: a result whose
  reviewer run equals the requesting run is refused, and the production
  adapter refuses to dispatch under the requester's own run id;
* the reviewer process receives no integration credential — the adapter
  constructor accepts no token and no ApiPort, and this loop performs zero
  GitHub writes (its ApiPort use is lookup-only);
* an `APPROVE` here is the CHG-2026-027 independent pre-merge review
  conclusion, NEVER a GitHub approval — every serialized result carries that
  declaration, and nothing in this module can construct a review/merge route
  (the transport allowlist is untouched);
* batch navigation is written only when checks are green AND the independent
  review is APPROVE at the exact head AND the digest is complete — the three
  entry gates of the canonical batch template, which this module renders but
  never posts (live Issue writes belong to TASK-HLR-005).
"""

from __future__ import annotations

import hashlib
import inspect
import subprocess
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Protocol

from .transport import OID_RE
from .worker import classify_checks

VERDICT_APPROVE = "APPROVE"
VERDICT_REQUEST_CHANGES = "REQUEST_CHANGES"
VERDICT_BLOCKED = "BLOCKED"
VERDICTS = frozenset({VERDICT_APPROVE, VERDICT_REQUEST_CHANGES, VERDICT_BLOCKED})

# Serialized with every result. The words are load-bearing: a batch digest or
# receipt quoting a result must carry them, so a reader can never mistake the
# independent AI conclusion for platform approval authority.
NOT_GITHUB_APPROVAL = (
    "independent pre-merge review conclusion per CHG-2026-027; "
    "NOT a GitHub approval and not merge permission"
)

# The verdict must be the LAST verdict line of the reviewer transcript, on a
# line of its own. Requiring the last occurrence makes a transcript that
# discusses several candidate verdicts resolve deterministically.
_VERDICT_LINE = "VERDICT:"
_REASON_LINE = "REASON:"


class ReviewState(str, Enum):
    """Continuation of worker.WorkerState past checksGreen (design §4)."""

    REVIEW_REQUESTED = "reviewRequested"
    REVIEW_RECORDED = "reviewRecorded"
    BATCH_QUEUED = "batchQueued"
    WORKER_PAUSED = "workerPaused"
    RECONCILE_REQUIRED = "reconcileRequired"
    # Failure-matrix row 2: a stale-head result discards the review and the
    # candidate returns to discovery; nothing is recorded.
    DISCOVER = "discover"
    NOT_ELIGIBLE = "notEligible"


class ReviewContractError(RuntimeError):
    """A result violated the review contract (same session, bad verdict...)."""


class AdapterFailure(RuntimeError):
    """The reviewer backend crashed, timed out or produced no parseable verdict."""


def _require_oid(value: str, name: str) -> str:
    if not isinstance(value, str) or not OID_RE.match(value):
        raise ReviewContractError(f"{name} must be a full 40-hex OID")
    return value


def _require_text(value: str, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ReviewContractError(f"{name} must be non-empty text")
    return value


@dataclass(frozen=True)
class ReviewRequest:
    """Immutable review request. Frozen so a dispatched request cannot drift."""

    change: str
    task: str
    pr_number: int
    head_oid: str
    base_oid: str
    checks_digest: str
    requested_by_run: str

    def __post_init__(self) -> None:
        _require_text(self.change, "change")
        _require_text(self.task, "task")
        if not isinstance(self.pr_number, int) or isinstance(self.pr_number, bool) \
                or self.pr_number < 1:
            raise ReviewContractError("pr_number must be a positive int")
        _require_oid(self.head_oid, "head_oid")
        _require_oid(self.base_oid, "base_oid")
        _require_text(self.checks_digest, "checks_digest")
        _require_text(self.requested_by_run, "requested_by_run")


@dataclass(frozen=True)
class ReviewResult:
    """Immutable review result, bound to the exact head it reviewed."""

    verdict: str
    reviewer_run: str
    head_oid: str
    recorded_at: int
    reasons: tuple[str, ...] = field(default_factory=tuple)

    def __post_init__(self) -> None:
        if self.verdict not in VERDICTS:
            raise ReviewContractError(
                f"verdict must be one of {sorted(VERDICTS)}, got {self.verdict!r}")
        _require_text(self.reviewer_run, "reviewer_run")
        _require_oid(self.head_oid, "head_oid")
        if not isinstance(self.recorded_at, int) or isinstance(self.recorded_at, bool):
            raise ReviewContractError("recorded_at must be an int epoch")
        if not isinstance(self.reasons, tuple):
            raise ReviewContractError("reasons must be a tuple")

    def serialize(self) -> dict:
        """Archival form. Always carries the not-an-approval declaration."""
        return {
            "verdict": self.verdict,
            "reviewer_run": self.reviewer_run,
            "head_oid": self.head_oid,
            "recorded_at": self.recorded_at,
            "reasons": list(self.reasons),
            "github_approval": False,
            "declaration": NOT_GITHUB_APPROVAL,
        }


class ReviewerPort(Protocol):
    """The single injected surface through which a review is obtained."""

    def request_review(self, request: ReviewRequest) -> ReviewResult:  # pragma: no cover
        ...


def checks_digest(check_runs: list[dict]) -> str:
    """Deterministic digest over (name, status, conclusion) of every run."""
    canon = sorted(
        (str(run.get("name")), str(run.get("status")), str(run.get("conclusion")))
        for run in check_runs
    )
    return hashlib.sha256(repr(canon).encode("utf-8")).hexdigest()


class SubprocessReviewerAdapter:
    """Production adapter: one separate reviewer session per request.

    Deliberately credential-free: the constructor accepts NO token, NO ApiPort
    and NO sender — the reviewer reads the repository worktree/PR facts that the
    prompt carries and nothing else. A contract test inspects this signature, so
    adding a credential parameter is a test failure, not a review nit.

    TASK-HLR-004 pins the argv/output contract and the availability probe only.
    No live dispatch happens in this task's tests; the runner is injected.
    """

    def __init__(
        self,
        *,
        executable: str,
        run_id_factory: Callable[[], str],
        runner: Callable[..., tuple[int, str, str]] | None = None,
        timeout_seconds: int = 1800,
        workdir: str | None = None,
    ) -> None:
        self._executable = _require_text(executable, "executable")
        self._run_id_factory = run_id_factory
        self._runner = runner or self._subprocess_runner
        self._timeout = timeout_seconds
        self._workdir = workdir

    @staticmethod
    def _subprocess_runner(argv: list[str], *, timeout: int,
                           cwd: str | None) -> tuple[int, str, str]:  # pragma: no cover
        try:
            proc = subprocess.run(argv, capture_output=True, text=True,
                                  timeout=timeout, cwd=cwd)
        except (OSError, subprocess.TimeoutExpired) as error:
            return 124, "", str(error)
        return proc.returncode, proc.stdout, proc.stderr

    @staticmethod
    def availability_probe(
        executable: str,
        runner: Callable[..., tuple[int, str, str]] | None = None,
    ) -> tuple[bool, str]:
        """Read-only backend probe: `<executable> --version`, nothing else.

        Creates no PR, no Issue, no ref and touches no repository content —
        the TASK-HLR-004 prerequisite (4) shape.
        """
        run = runner or SubprocessReviewerAdapter._subprocess_runner
        code, out, err = run([executable, "--version"], timeout=60, cwd=None)
        line = (out or err).strip().splitlines()
        version = line[0] if line else ""
        return (code == 0 and bool(version)), version

    def build_argv(self, request: ReviewRequest) -> list[str]:
        """The pinned dispatch shape: executable + print-mode + one prompt arg.

        The prompt is data in a single argv slot; nothing from the PR is ever
        interpolated into a shell string (design §1 rule 4).
        """
        return [self._executable, "-p", self._prompt(request)]

    @staticmethod
    def _prompt(request: ReviewRequest) -> str:
        return (
            "You are the INDEPENDENT pre-merge reviewer (CHG-2026-027). "
            "Review the following pull request strictly at its exact head.\n"
            f"change: {request.change}\n"
            f"task: {request.task}\n"
            f"pr_number: {request.pr_number}\n"
            f"head_oid: {request.head_oid}\n"
            f"base_oid: {request.base_oid}\n"
            f"checks_digest: {request.checks_digest}\n"
            "Your conclusion is navigation only and is NOT a GitHub approval.\n"
            "Output contract: any number of `REASON: <text>` lines, then a "
            "final line `VERDICT: APPROVE` or `VERDICT: REQUEST_CHANGES` or "
            "`VERDICT: BLOCKED`.\n"
        )

    def request_review(self, request: ReviewRequest) -> ReviewResult:
        reviewer_run = self._run_id_factory()
        if reviewer_run == request.requested_by_run:
            # The worker session may not review its own work. Refusing at
            # dispatch time keeps the violation from ever producing a result.
            raise ReviewContractError(
                "reviewer run equals the requesting worker run; the same "
                "session may not review its own work (HLR-REVIEW-001)")
        code, out, err = self._runner(self.build_argv(request),
                                      timeout=self._timeout, cwd=self._workdir)
        if code != 0:
            raise AdapterFailure(f"reviewer backend exited {code}")
        verdict, reasons = self._parse(out)
        return ReviewResult(verdict=verdict, reviewer_run=reviewer_run,
                            head_oid=request.head_oid, recorded_at=0,
                            reasons=reasons)

    @staticmethod
    def _parse(transcript: str) -> tuple[str, tuple[str, ...]]:
        verdict = None
        reasons: list[str] = []
        for line in transcript.splitlines():
            stripped = line.strip()
            if stripped.startswith(_REASON_LINE):
                reasons.append(stripped[len(_REASON_LINE):].strip())
            elif stripped.startswith(_VERDICT_LINE):
                verdict = stripped[len(_VERDICT_LINE):].strip()
        if verdict not in VERDICTS:
            raise AdapterFailure(
                f"no parseable final verdict in reviewer output ({verdict!r})")
        return verdict, tuple(reasons)


class ReviewPhase:
    """Drives one candidate from checksGreen through the review gate.

    Enforces the r1 failure matrix row by row; every ambiguity funnels to
    reconcileRequired with zero further dispatch, mirroring the worker round.
    """

    def __init__(self, port: ReviewerPort, *, now: Callable[[], int]) -> None:
        self._port = port
        self._now = now
        self._recorded: dict[int, ReviewResult] = {}

    # -- eligibility (failure-matrix row 6) --------------------------------
    @staticmethod
    def eligibility(pr: dict, check_runs: list[dict]) -> tuple[bool, str]:
        """prOpen + complete metadata + green checks, else not eligible.

        Not-eligible performs NO external interaction at all: the reviewer is
        never dispatched for a candidate that has not earned it.
        """
        number = pr.get("number")
        if not isinstance(number, int) or isinstance(number, bool):
            return False, "pr number is not an int"
        if pr.get("state") != "open" or pr.get("merged") is True:
            return False, "pr is not open"
        head = (pr.get("head") or {}).get("sha")
        if not isinstance(head, str) or not OID_RE.match(head):
            return False, "head sha is not a full OID"
        base = (pr.get("base") or {}).get("ref")
        if base != "main":
            return False, f"base ref is {base!r}, not main"
        if not (pr.get("body") or "").strip():
            return False, "pr body is empty; envelope metadata incomplete"
        state = classify_checks(check_runs)
        if state != "green":
            return False, f"checks are {state}, not green"
        return True, "eligible"

    # -- the gate ----------------------------------------------------------
    def run(self, pr: dict, check_runs: list[dict], *, change: str, task: str,
            requested_by_run: str) -> tuple[ReviewState, ReviewResult | None, str]:
        ok, why = self.eligibility(pr, check_runs)
        if not ok:
            return ReviewState.NOT_ELIGIBLE, None, why

        number = pr["number"]
        head = pr["head"]["sha"]
        base_oid = (pr.get("base") or {}).get("sha")
        if not isinstance(base_oid, str) or not OID_RE.match(base_oid):
            return (ReviewState.NOT_ELIGIBLE, None,
                    "base sha is not a full OID; metadata incomplete")

        # Failure-matrix row 7: the first recorded result stands; a later one
        # is refused rather than silently replacing it.
        if number in self._recorded:
            return (ReviewState.REVIEW_RECORDED, self._recorded[number],
                    "duplicate review refused; the first recorded result stands")

        request = ReviewRequest(
            change=change, task=task, pr_number=number, head_oid=head,
            base_oid=base_oid, checks_digest=checks_digest(check_runs),
            requested_by_run=requested_by_run,
        )
        try:
            result = self._port.request_review(request)
        except AdapterFailure as error:
            # Row 1: crash/timeout/no verdict -> reconcile, no retry.
            return (ReviewState.RECONCILE_REQUIRED, None,
                    f"reviewer adapter failed: {error}")
        except ReviewContractError as error:
            # Row 3/4 at dispatch or construction time.
            return (ReviewState.RECONCILE_REQUIRED, None,
                    f"review contract violation: {error}")
        except Exception as error:  # noqa: BLE001 - unexpected shapes fail closed
            return (ReviewState.RECONCILE_REQUIRED, None,
                    f"unexpected {type(error).__name__} from reviewer adapter: "
                    f"{error}; treated as reconcile-required")

        if not isinstance(result, ReviewResult):
            return (ReviewState.RECONCILE_REQUIRED, None,
                    "adapter returned a foreign object, not a ReviewResult")
        if result.reviewer_run == requested_by_run:
            # Row 4: a same-session result is refused even if an adapter
            # manufactured one.
            return (ReviewState.RECONCILE_REQUIRED, None,
                    "review result carries the worker's own run id; refused "
                    "(HLR-REVIEW-001)")
        if result.head_oid != head:
            # Row 2: the head moved between request and result. The stale
            # conclusion is discarded, nothing is recorded, the candidate
            # returns to discovery.
            return (ReviewState.DISCOVER, None,
                    "review head does not match the candidate head; stale "
                    "result discarded")

        self._recorded[number] = result
        if result.verdict in (VERDICT_REQUEST_CHANGES, VERDICT_BLOCKED):
            # Row 5: an unfavourable independent review pauses the lane.
            return (ReviewState.WORKER_PAUSED, result,
                    f"independent review returned {result.verdict}; worker paused")
        return (ReviewState.REVIEW_RECORDED, result,
                "independent review APPROVE recorded (not a GitHub approval)")


class ReviewerLoop:
    """Read-only intake: find open task PRs whose checks are done, then review.

    Zero GitHub writes by construction — this loop only ever calls the typed
    lookup methods. A contract test drives it against a port whose write
    methods raise, proving the property rather than asserting it.
    """

    def __init__(self, api, phase: ReviewPhase, *, change: str,
                 worker_run: str) -> None:
        self._api = api
        self._phase = phase
        self._change = change
        self._worker_run = worker_run

    def review_once(self, ready_tasks: list[str]) -> list[tuple[str, ReviewState, str]]:
        outcomes: list[tuple[str, ReviewState, str]] = []
        for task in ready_tasks:
            head_branch = f"agent/host-loop/tasks/{task}"
            pulls = self._api.list_open_pulls_for_head(head_branch)
            if not pulls:
                outcomes.append((task, ReviewState.NOT_ELIGIBLE, "no open task PR"))
                continue
            if len(pulls) > 1:
                outcomes.append((task, ReviewState.RECONCILE_REQUIRED,
                                 f"{len(pulls)} open PRs share one task head"))
                continue
            number = pulls[0].get("number")
            if not isinstance(number, int) or isinstance(number, bool):
                outcomes.append((task, ReviewState.RECONCILE_REQUIRED,
                                 "open PR carries a non-int number"))
                continue
            pr = self._api.get_pull(number)
            head = (pr.get("head") or {}).get("sha") or ""
            runs = self._api.list_check_runs(head) if OID_RE.match(head) else []
            state, _result, detail = self._phase.run(
                pr, runs, change=self._change, task=task,
                requested_by_run=self._worker_run)
            outcomes.append((task, state, detail))
        return outcomes


# ---------------------------------------------------------------- batch gate
class BatchNotEligible(RuntimeError):
    """Raised with every failed entry gate, so a caller sees the full list."""

    def __init__(self, reasons: tuple[str, ...]) -> None:
        super().__init__("; ".join(reasons))
        self.reasons = reasons


_GRADES = frozenset({"D0", "D1", "D2"})

# The template's first-screen declaration, carried verbatim into any rendered
# batch body. Navigation only; nothing here is approval semantics.
BATCH_DECLARATION = (
    "- 本 issue 与其中的每条 digest **仅是导航**，不承载任何批准语义；\n"
    "- 队列中的**每个 PR 仍由维护者逐项对 exact head review 并单独 merge**，\n"
    "  唯一批准载体 = 维护者对该 PR 的 review/merge；\n"
    "- **CI 绿 ≠ 批准；digest 完整 ≠ 批准；任何等级（含 D0）不存在 auto-merge**；\n"
    "- 遇拒停链：某项被拒绝或要求修改时，digest 声明依赖它的后续项本轮不合，\n"
    "  被拒项回炉走正常修复；无依赖关系的其余项可继续；\n"
    "- close 本 issue 仅表示导航归档，不改变任何 PR、任务或 change 状态。\n"
)


@dataclass(frozen=True)
class BatchEntry:
    """One complete digest entry. Constructing one PROVES field completeness."""

    grade: str
    change: str
    task: str
    summary: str
    base_oid: str
    head_oid: str
    files_readback: tuple[str, ...]
    risk: str
    evidence_ptr: str
    pr_number: int
    title: str

    def __post_init__(self) -> None:
        problems = []
        if self.grade not in _GRADES:
            problems.append(f"grade {self.grade!r} is not one of {sorted(_GRADES)}")
        for name in ("change", "task", "summary", "risk", "evidence_ptr", "title"):
            value = getattr(self, name)
            if not isinstance(value, str) or not value.strip():
                problems.append(f"{name} is empty")
        for name in ("base_oid", "head_oid"):
            value = getattr(self, name)
            if not isinstance(value, str) or not OID_RE.match(value):
                problems.append(f"{name} is not a full 40-hex OID")
        if not self.files_readback:
            problems.append("files_readback is empty")
        if not isinstance(self.pr_number, int) or isinstance(self.pr_number, bool) \
                or self.pr_number < 1:
            problems.append("pr_number is not a positive int")
        if problems:
            raise BatchNotEligible(tuple(problems))


def queue_for_batch(entry: BatchEntry, *, checks_state: str,
                    review: ReviewResult) -> str:
    """The three entry gates, then the rendered digest section.

    Gate 1: applicable checks all green. Gate 2: independent-session review is
    APPROVE at the EXACT entry head (a moved head invalidates the old APPROVE).
    Gate 3: the digest is complete — proven by the BatchEntry construction.
    Rendering is all this function does; posting the navigation Issue is a
    TASK-HLR-005 live concern.
    """
    reasons = []
    if checks_state != "green":
        reasons.append(f"checks are {checks_state}, not green")
    if review.verdict != VERDICT_APPROVE:
        reasons.append(f"independent review is {review.verdict}, not APPROVE")
    if review.head_oid != entry.head_oid:
        reasons.append("review head does not match the entry head; the old "
                       "APPROVE is invalid after a head move")
    if reasons:
        raise BatchNotEligible(tuple(reasons))

    files = "、".join(entry.files_readback)
    return (
        f"### 项 <N>：PR #{entry.pr_number} — {entry.title}\n\n"
        "| 字段 | 内容 |\n| --- | --- |\n"
        f"| Grade | {entry.grade} |\n"
        f"| Change/Task | `{entry.change}` / `{entry.task}` |\n"
        f"| 内容 | {entry.summary} |\n"
        f"| Base/Head OID | `{entry.base_oid}` / `{entry.head_oid}` |\n"
        f"| Files read-back | {files} |\n"
        f"| 风险与影响面 | {entry.risk} |\n"
        f"| Evidence/测试指针 | {entry.evidence_ptr} |\n"
        f"| Review | {review.verdict} by `{review.reviewer_run}` @ "
        f"`{review.head_oid}`（{NOT_GITHUB_APPROVAL}） |\n"
    )


def render_batch_issue(entries: list[str]) -> str:
    """A full navigation body: verbatim declaration first, then the entries."""
    body = "## 首屏声明（每个批次 issue 正文必须原样携带）\n\n" + BATCH_DECLARATION
    for index, section in enumerate(entries, start=1):
        body += "\n" + section.replace("### 项 <N>：", f"### 项 {index}：", 1)
    return body


def adapter_is_credential_free(adapter_cls=SubprocessReviewerAdapter) -> bool:
    """True when the adapter constructor accepts no credential-shaped input."""
    names = set(inspect.signature(adapter_cls.__init__).parameters)
    forbidden = {"token", "api", "api_port", "sender", "credential", "secret"}
    return not (names & forbidden)
