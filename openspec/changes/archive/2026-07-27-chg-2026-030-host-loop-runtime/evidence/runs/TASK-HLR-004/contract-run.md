# TASK-HLR-004 contract run — reviewer loop, recovery, batch gate (offline)

```text
task:      TASK-HLR-004
readiness: r1 (PR #553)
scope:     offline implementation + contract/fault tests; ZERO live GitHub
           writes; worker.py and __main__.py deliberately untouched
date:      2026-07-26
```

## Delivered surface

- `scripts/host_loop/reviewer.py` — `ReviewRequest`/`ReviewResult` (frozen,
  OID-validated, serialization always carries the NOT-a-GitHub-approval
  declaration), `ReviewerPort`, `SubprocessReviewerAdapter` (credential-free
  constructor by signature; pinned argv `[exe, -p, <prompt>]`; last-verdict
  parse; availability probe = `--version` only), `ReviewPhase` (the nine-row
  r1 failure matrix), `ReviewerLoop` (lookup-only intake), `BatchEntry` +
  `queue_for_batch` (the three CHG-2026-027 entry gates) + `render_batch_issue`
  (first-screen declaration verbatim).
- `scripts/host_loop/recovery.py` — `confirm_merged` (source A metadata ×
  source B main-history cross-confirmation, sha-null unique-subject fallback,
  every git failure ambiguous), `advance_allowed`, and the six-window
  `restart_decision` (`RestartObservation` holds re-observed facts only;
  elapsed time is not an input).
- `scripts/host_loop/test_reviewer_contract.py` (42 tests),
  `scripts/host_loop/test_recovery_contract.py` (31 tests).
- `scripts/host_loop/test_discovery_contract.py` — the stale point-in-time
  assertion (`TASK-HLR-003 == ready`, legitimately broken by #552) replaced
  by an independent-minimal-extraction comparison that still catches the
  truncated-value family, plus a permanently-stable done-set assertion. The
  r1 readiness records this defect and authorizes exactly this fix.

## Verification observed

- Full offline suite at the r1 audit base tree + this delta:
  **480 tests, OK, 1 expected failure** (the Decision-Grade gap marker,
  untouched). Baseline before this delta was 405 pass + 1 stale FAIL + 1
  expected failure, as the readiness records.
- `./scripts/check-sdd.sh` → 0 errors / 0 warnings / 111 acceptance IDs.
- Targeted mutation scan, in-place, baseline-green enforced, with controls:
  **12/12 mutants KILLED, negative control survived** —
  eligibility green-gate, same-session refusal (dispatch and intake),
  head-drift discard, duplicate recording, paused-on-RC, batch head/checks
  gates, approval-claim serialization, merged-flag truthiness, ancestry
  failure, unique-subject uniqueness, advance-on-ambiguity.
  M9 first SURVIVED against a weak assertion (both code paths reached
  `ambiguous` for a sha-less fixture); the test was strengthened to carry a
  confirmable sha and pin the detail to the flag's shape — the
  "suspect the assertion before the code" rule applied.
- HLR-REVIEW-001 shape: same-session review refused at BOTH layers;
  reviewer write/approve/merge incapability shown structurally — the loop
  driven to full completion against a port whose write methods raise
  (zero writes), and `len(ALLOWED_ROUTES) == 10` pinned by test so this
  module cannot widen the transport.
- HLR-RECOVERY-001 shape: the four never-sufficient negatives each named —
  branch deletion, elapsed time, an Issue claim, green CI — none can
  produce `advance_allowed`.
- Backend availability probe (readiness prerequisite ④, re-run):
  `claude --version` → exit 0, `2.1.220 (Claude Code)`; no repository,
  PR, Issue or ref interaction.

## Boundaries honestly stated

- No live review dispatch, no batch Issue write, no cursor write, no
  scheduler/unit/host change — the two left-running units are untouched and
  this delta is invisible to them until merged (and inert after merge:
  nothing imports the new modules on the `--once` path).
- The `batchQueued` → live navigation write, the live reviewer session and
  the legacy-creator migration remain TASK-HLR-005 scope per r5.
- This run is not a done claim; the `ready→done` flip is a separate PR under
  the r1-pinned recheck duties.
