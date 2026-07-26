# TASK-HLR-005 live pilot receipt — the loop's first real task PR

```text
task:       TASK-HLR-005
authority:  readiness r1 = #560 (merge 9bfbb72a…) + r2 S1-carrier correction =
            #562 (merge a3a68429…), both lvye APPROVED, auto_merge=null
date:       2026-07-26, single continuous session (S0 06:0xZ -> S8 06:41Z UTC)
actors:     maintainer lvye = S1 grade line, S6 batch issue #565, S7 merge;
            Agent = S0 preflight, S2/S4 foreground rounds, S3 one authorized
            implementation push, S5 reviewer driver, S8 recovery driver
pilot task: TASK-TAS-001 (CHG-2026-037), naturally arising per the r0 trigger
outcome:    end-to-end PASS; the shrink is merged on main as 877347f2…
```

## The run, step by step

- **S0 preflight (read-only, all green)**: `HEAD == live main 9bfbb72a…`;
  TAS-001's three source pins zero-drift; `agent/host-loop/**` refs = 0; both
  left-running units alive; App-identity baselines PRs=1/Issues=1; backend
  probe `claude --version` → `2.1.220`; `--explain @ chg-037` showed
  TAS-001 rejected solely on grade unknown.
- **S1 grade line (maintainer)**: hand-authored commit
  `e3270cb1a94db716b7a4bb12eaa058db34edf046` (+1 line `- Decision-Grade:D0。`),
  transported unmodified per the r2 carrier (OID invariant), bot PR #563,
  lvye APPROVED + squash merge `6ffa653a…`. Live bonus negative recorded on
  the way: the maintainer's earlier direct push travelled the Deploy Key
  alias and main **refused it (GH006)** — one more live probe of the
  agent-write boundary.
- **S2 claim round (foreground, explicit `--change`)**: exit 0 —
  `prOpen task=TASK-TAS-001 pr=564`. Lease created fence=1; stable branch
  `agent/host-loop/tasks/TASK-TAS-001` = empty commit `7d98f0c4…` on the
  frozen base `6ffa653a…`; **PR #564 authored by
  `arkdeck-host-loop-runtime-901708a7[bot]`** — the App identity's first
  real task PR — with a complete envelope (`Task`, `Base-OID` = live main,
  `Head-OID`, `Decision-Grade: D0`, `Depends-On: none`, Attribution).
  Reserved-branch coexistence: legacy `agent-pr.yml` runs for this branch
  = **0** while ordinary `agent/*` branches kept receiving bot auto-PRs the
  same hour (#560/#562 carriers themselves).
- **S3 implementation push (the one authorized write)**: `f6bf27d6…` onto the
  task branch — exactly the r1 contract diff (two route deletions, three
  assertion sites synced to 8, two bare-list `RouteViolation` regression
  tests; 3 files, +21/−7).
- **S4 relay + drill (receipts `s4-*.txt`)**: same-owner round adopted the
  unique PR and re-dispatched checks (no second PR ever); **stale-fence
  drill**: a second worker identity (`host-loop/worker-second`) got
  `exit 10 — lease held by live owner 'host-loop/worker'; no dispatch`,
  zero writes; final round reached
  `checksGreen … this is NOT merge permission; the maintainer merges`.
  Checks at exact head `f6bf27d6…`: `pull_request`-event `guard` +
  `allowed-paths` both success (the r1-F1 body-update→`edited` mechanism's
  first live proof); push-event `allowed-paths` = `skipped` is the known
  bot-PR event gap, observed alongside, not a failure.
- **S5 independent review (receipt `s5-review.json`)**: first authorized live
  dispatch of a separate `claude` session
  (`host-loop/reviewer-bc49cc95…` ≠ worker run). Verdict **APPROVE bound to
  exact head `f6bf27d6…`**, serialized with the NOT-a-GitHub-approval
  declaration; no GitHub review API was ever called. The reviewer honestly
  caveated that its sandbox could not execute the full suite; the Agent
  closed that gate per repo convention with a clean-worktree checkout of the
  exact head: **482 tests OK + 1 expected failure, `routes: 8`**, plus
  main-checkout `check-sdd` 0/0/111 and CI's exact-head green.
- **S6 batch (maintainer)**: Issue **#565 `batch-20260726-1`**, body rendered
  by `queue_for_batch`/`render_batch_issue` after the three entry gates
  passed (green checks + independent APPROVE at exact head + complete
  digest), first-screen declaration verbatim, navigation only.
- **S7 merge (maintainer, sole approval carrier)**: lvye APPROVED exact head
  and squash-merged → `877347f212ab0bffa9924801a037b3256f1eea56`,
  `merged_at 2026-07-26T06:39:00Z`, `auto_merge=null`. GitHub auto-deleted
  the task branch.
- **S8 recovery (receipt `s8-recovery.json`)**: dual-source confirmation —
  metadata (`merged=true`, `merge_commit_sha=877347f2…`) × main history
  (ancestry + squash subject `(#564)`) agree → confirmed. **CAS negative**:
  deleting the lease with the stale mid-pilot OID `5145a415…` was
  **Refused ("stale expected OID")** and the lease was untouched; the
  observed lease showed **fence=7** (seven real CAS writes across the pilot)
  and expired; takeover (PR identity requeried, exact OID) advanced fence to
  8 under `host-loop/recovery`; release deleted the lease at its exact OID;
  final `agent/host-loop/**` refs = **0**.

## The four r5-transferred obligations — closed

1. **Live first-PR proof**: a uniquely-leased worker created a complete-
   envelope task PR on `agent/host-loop/tasks/**` and its first
   `pull_request`-event checks ran green at exact head (S2–S4). CLOSED.
2. **Old-creator coexistence (live)**: reserved branch zero legacy runs/PRs
   while ordinary branches' bot auto-PR kept working the same hour (S2).
   CLOSED.
3. **Lease CAS live sufficiency (r1-F4)**: create + repeated renewals
   (fence reached 7) + takeover + exact-OID delete, plus one stale-OID
   refusal observed — ≥3 CAS operation kinds and a real negative. CLOSED.
4. **Legacy creator migration**: prerequisite (the live proof) is now
   satisfied; the carrier stays a maintainer-decided governance PR
   (`agent-pr.yml` is a forbidden path for this task). Per r1 the done
   condition is two-valued: executed, or explicitly deferred on record in
   the done PR. PENDING THE MAINTAINER'S CALL — not silently claimed.

## Honest register

- Phase 4 (cursor Issue) was carved out of the pilot by r1; every pilot round
  ran with a read-only cursor and **zero Issue writes by the runtime**
  (#565 was maintainer-authored navigation). Cursor live-write proof stays a
  separate future authorization; hand-seeding feasibility is measured
  (render/parse round-trip PASS) and on file.
- The reviewer's suite-execution caveat and the Agent's synthesized backstop
  are both recorded above; neither replaces the other.
- The worktree `check-sdd.sh` run hit the known `/private/tmp` missing-yaml
  environment issue; the guard verdict comes from the main checkout and CI,
  both green.
- No auto-merge anywhere; CI green was never treated as merge permission
  (the loop itself printed that sentence at checksGreen); the independent
  APPROVE was never a GitHub approval.
- The live left-running units ran their ordinary empty rounds throughout,
  untouched — parallel evidence of staging stability during a live pilot.

## Receipt manifest (sha256)

```text
1f22fcf8c083272643fbba1e715dcebd11887028bf537de829b5688d0712c421  s2-claim.txt
10fb6b25e8b2877ca879ee550e026cc25081cb5639ff609f8227710fa78a5ece  s4-foreign-lease-drill.txt
67f4b18409b940798fd53a3dec80d248de1ad6f74d81f509a4f471d2127cde31  s4-checksgreen.txt
3b83eb8664be7631b58071bdb0eb4d9536ee8c18f464727d7d235a857ebe24be  s5-review.json
5f3a127a113e863555b06244c81c187a4f06c1f03310b19fb4718f2ed380f266  s8-recovery.json
```

This receipt is not a done claim. The `ready→done` flips (HLR-005, then
TAS-001) and the change verifies (chg-037, chg-030) are separate PRs.
