# TASK-NAV-001 contract run — repo-wide discovery and a truthful idle verdict

```text
task:      TASK-NAV-001
readiness: r1 (PR #589, merge f8a0444)
audit base: 17a9574a368e518ce475ef7d72135c3a6f71f2c7
implementation base: 74e7cf95416ed43c781e7247bfb2fbeb068c8148 (#591, the
           maintainer's D0 grade commit; rebased onto it and every
           observation below re-run on the merged tree)
scope:     host-only; offline; ZERO live GitHub writes; zero launchd/plist
           action; no Decision-Grade written by this carrier
date:      2026-07-27
```

## Source pins

Verified against the r1 contract before the first edit, both exact:

```text
scripts/host_loop/__main__.py  aa47dd45a29ac4531e4c38e3cbe84acaaf2b18a5
scripts/host_loop/worker.py    b9662c76a0948abb049d293b2b03948a8fb570a5
```

## Delivered surface

Three files, all inside the r1 Allowed paths. None of the NAV-002 partition
(`check_pr_paths.py`, `test_check_pr_paths.py`, `test_backends_cli.py`,
`test_discovery_contract.py`, `test_pr_envelope.py`, `test_support.py`) was
touched, and no existing test file was modified at all.

- `scripts/host_loop/__main__.py`
  - `--change` default `"CHG-2026-030-host-loop-runtime"` → `None`. Omitting
    the flag now means every active change; passing it keeps single-change
    semantics.
  - `active_change_ids()` — `changes/chg-*/tasks.md`, lexicographic. Archive is
    excluded by the glob shape, not by a filter a later edit could drop.
  - `discover_all()` — the union of the per-change reads, each candidate tagged
    with the change that declared it.
  - `canonical_change_id()` — directory name → the proposal's front-matter
    `id:`, reusing `pr_envelope._frontmatter_change_id` rather than parsing the
    field a second time.
  - `_explain_change()` — one renderer for both modes; `_explain` is a loop over
    it plus a summary line.
  - `_utc_stamp()`, `_round_line()` — pure functions, so the log format is
    testable without a credential or a network.
  - `_candidate_body_renderer()` — builds the envelope renderer per call from
    the selected candidate's change.
- `scripts/host_loop/worker.py`
  - `NEVER_CLAIM_ROOTS` = `{TASK-HLR-003, TASK-NAV-001, TASK-NAV-002}`.
  - `is_ready()` — one predicate, consumed by both `rejection_reasons` and the
    idle classifier.
  - `classify_no_claim()` — extracted from `select()`; the never-claim branch
    now filters on `ready`.
  - `select()` — evaluates change approval per candidate change; still returns
    on the first clean candidate, so at most one claim per round.
  - `TaskCandidate.change_id` — new, defaulted to `""`, so every pre-existing
    construction and fixture is unchanged.
- `scripts/host_loop/test_navigation_contract.py` — 43 tests.

## Contract items

| r1 item | Where it is pinned |
| --- | --- |
| ① repo-wide default + grouped explain + explicit `--change` unchanged | `DefaultScopeIsTheWholeRepository`, `OmittingTheFlagMeansEveryChange`, `TheLiveRepositoryIsScannedWhole` |
| ② one claim per round, per-change approval | `AggregationDoesNotWidenWhatIsClaimable` (8 cases, positive and negative) |
| ③ never-claim ready filter + regression | `TheIdleVerdictNamesOnlyReadyTasks` (6 cases) |
| ④ exact three-root `NEVER_CLAIM_ROOTS` | `NeverClaimRootsArePinnedByContent` (5 cases, content not length) |
| ⑤ timestamped, scoped idle/claim line | `TheRoundLineSaysWhenAndHowMuch` (6 cases) |

## The ③ red probe, reproduced and closed

Run against the audit base and against this tree, same input:

```text
audit base   done never-claim  -> onlyNeverClaimReady
                                 "only never-claim tasks are ready (['TASK-HLR-003'])"
             ready never-claim -> onlyNeverClaimReady
this tree    done never-claim  -> nothingReady   "no ready host-only task"
             ready never-claim -> onlyNeverClaimReady   (positive control held)
```

The pre-existing `SelfClaimStop` cases are the positive control the readiness
names, and they pass unmodified — their fixture defaults to `ready`, which is
exactly the case the branch must keep reporting.

## A defect this work found and fixed

Mutation M9 survived the first test set, and chasing it surfaced a live bug
rather than a weak assertion. The PR envelope validator resolves its `Change`
field against each active proposal's front-matter `id:`, and a change directory
name is not that id: of the twelve active changes, `chg-2026-026-macos-rockchip-flash-ui`
declares `CHG-2026-026`. Tagging candidates with directory names would therefore
have rendered an envelope that fails validation the first time a repo-wide round
claimed a task in that change. The single-change round never met the difference,
because the change it was pinned to is one of the eleven where directory and id
agree. Fixed by `canonical_change_id()`, and pinned by
`TheEnvelopeNamesTheTasksOwnChange`, whose first case asserts the two
identifiers really do differ in this repository so the rest cannot go vacuous.

## Verification observed

- host_loop suite: **525 tests, OK, 1 expected failure** (audit-base baseline
  482 + 1 xf; 43 added, 0 existing tests modified).
- full `scripts/` discovery: **576 tests, OK, 1 expected failure** (baseline on
  clean main 533 + 1 xf).
- `./scripts/check-sdd.sh` → **0 errors / 0 warnings / 111 acceptance IDs**.
- `git diff --check` clean; working tree is exactly the three files above.
- Single-change `--explain` output is **byte-for-byte identical** to the
  audit-base implementation's, compared by running both against the same tree
  (`/usr/bin/diff`, no difference).
- Repo-wide `--explain` on this tree: `scanned changes=12 candidates=38`,
  `claimable=none`, exit 10; both navigation tasks report
  `never-claim: the readiness forbids claiming this task` ahead of their grade
  verdict.

## The ④ gate, proven live against the merged grade

`#591` put `- Decision-Grade:D0。` on both navigation tasks. On the merged tree,
with the audit-base `worker.py`/`__main__.py` and this repository's data:

```text
audit-base code   TASK-NAV-001: CLAIMABLE
                  TASK-NAV-002: CLAIMABLE
                  claimable=['TASK-NAV-001', 'TASK-NAV-002']
this tree         TASK-NAV-001: rejected
                      - never-claim: the readiness forbids claiming this task
                  TASK-NAV-002: rejected
                      - never-claim: the readiness forbids claiming this task
                  claimable=none
```

So the root additions are load-bearing, not decorative: without them the loop
would claim the two tasks that rewrite its own claim gate.

The ordering is safe by construction and was checked rather than assumed. On
merged `main` today those two tasks are claimable, but the deployed unit cannot
reach them: its plist passes no `--change`, so it still scans only
`CHG-2026-030-host-loop-runtime`. The change that widens the scan and the change
that adds the roots are the same commit, so no round can ever observe one
without the other.

## Mutation scan

In-place, baseline-green enforced before each mutant, original restored after.
**12/12 KILLED.**

| id | mutation | result |
| --- | --- | --- |
| M1 | drop `and is_ready(c.status)` from the never-claim branch | RED (2) |
| M2 | shrink `NEVER_CLAIM_ROOTS` back to one root | RED (10) |
| M3 | restore the literal `--change` default | RED (3) |
| M4 | drop the per-change approval scoping filter | RED (32 + 40 err) |
| M4b | one approval verdict for the whole round | RED (3 + 1 err) |
| M5 | drop the timestamp from the round line | RED (2) |
| M6 | drop the scope from the round line | RED (3) |
| M7 | let `archive/` back into the scan | RED (4 + 30 err) |
| M8 | stop tagging candidates with their change | RED (4 + 1 err) |
| M9 | stamp the envelope with the directory name | RED (2) |
| M9b | stamp the envelope with the round scope label | RED (1 err) |
| M10 | drop the ready gate from `rejection_reasons` | RED (8) |

M3 and M9 both survived the first test set. M3 was a missing assertion — every
case reached the navigation helpers directly and nothing pinned the default
itself, which is where the deployed defect lives; four cases were added.
M9 was the envelope-identifier bug above.

## Deployment and effects

- The LaunchAgent plist passes no `--change`
  (`ProgramArguments = [python3, -m, host_loop, --once, --repo-dir, <checkout>]`,
  read on the running host), so the default value *is* the deployment: this
  takes effect when the running checkout advances to a protected `main`
  containing it. **Zero launchd action; both left-running units untouched.**
- No foreground round was run against CHG-2026-039, per the r1 deployment
  clause. Every observation above is `--explain` (network-free, credential-free)
  or an offline unit test.
- Live GitHub writes: 0. Issue writes: 0. Lease/ref writes: 0. Device, HDC,
  USB, network dispatch: 0.
- This carrier writes no `Decision-Grade` line. Both navigation tasks are in
  `NEVER_CLAIM_ROOTS`, so once the maintainer's grade commit lands the loop
  still refuses them by the structural gate, which is what r1 item ④ asks for.
