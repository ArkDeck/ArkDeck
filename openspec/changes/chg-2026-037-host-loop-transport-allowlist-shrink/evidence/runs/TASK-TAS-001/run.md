# TASK-TAS-001 run — allowlist shrink, delivered by the host-loop pilot

```text
task:      TASK-TAS-001
readiness: r1 (#559, merge 1c6581b163ce64a0c91405a5bc98325f99d6aa50)
carrier:   host-loop pilot envelope PR #564 — claimed by the loop itself
           (App identity arkdeck-host-loop-runtime-901708a7[bot]), per the
           r1-recorded carrier expectation and the CHG-2026-030 TASK-HLR-005
           orchestration
merged:    877347f212ab0bffa9924801a037b3256f1eea56 (lvye APPROVED exact head
           f6bf27d64bfe3aa4efc47ac9ebbcf7dbe42dfb66, squash, auto_merge=null,
           merged_at 2026-07-26T06:39:00Z)
grade:     Decision-Grade D0, hand-written by the maintainer (commit
           e3270cb1…, transported OID-invariant, approved via #563)
date:      2026-07-26
```

## Implementation-contract compliance (r1, item by item)

- ① exactly the two bare-list routes removed from `ALLOWED_ROUTES`
  (`GET /repos/{owner}/{repo}/pulls`, `GET /repos/{owner}/{repo}/issues`),
  10 → 8; transport.py otherwise byte-identical.
- ② the measured reaction surface held: exactly the three pinned assertion
  sites were synced (two in `test_backends_cli.NoNewRouteOrEscapeHatch`, one
  in `test_reviewer_contract`); **no fourth failure appeared** at any point.
- ③ the two bare-list `RouteViolation` regression tests added — the dead
  capability is now an explicit refusal.
- ④ post-implementation suite = **482 tests OK + 1 expected failure**
  (480 − 0 + 2, the r1-pinned count), measured at the PR head in a clean
  worktree, again at the merge (`877347f2…`) and again at the current flip
  base; `check-sdd` 0 errors / 0 warnings / 111 acceptance IDs; the PR diff
  was exactly the three allowed source files (+21/−7).

## Verification table results

- **TAS-ROUTE-001: PASS.** `ALLOWED_ROUTES` is exactly the 8-entry set,
  asserted by content (not cardinality); `assert_route_allowed` refuses both
  bare-list templates (regression tests green); `route_inventory` /
  `forbidden_capability_count` negatives remain 0.
- **TAS-BEHAVIOR-001: PASS.** Every public-method contract test passed
  unmodified — `POST /pulls` and `POST /issues` (same template, different
  method key) were untouched by the GET removals, exactly as the design's
  structural argument predicted; full suite green; guard and the exact-head
  `allowed-paths` diff check green.

## Live delivery facts (cross-reference)

The full claim→review→merge→recovery lifecycle of PR #564 — including the
independent-session APPROVE at the exact head, the navigation-only batch
Issue #565, the maintainer-only merge and the post-merge lease recovery — is
recorded once, in
`openspec/changes/chg-2026-030-host-loop-runtime/evidence/runs/TASK-HLR-005/pilot-run.md`
and its receipts; this run does not restate it. The shrink has been live on
protected main since `877347f2…`; the live loop's subsequent rounds import
the 8-route transport with its pinned tests green.

Not a done claim; the `ready→done` flip is the separate next PR.
