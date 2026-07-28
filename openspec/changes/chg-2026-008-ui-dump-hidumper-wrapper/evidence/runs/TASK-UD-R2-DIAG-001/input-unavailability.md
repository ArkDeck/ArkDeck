# TASK-UD-R2-DIAG-001 input unavailability — the pinned raw is permanently gone (2026-07-28)

**This is not the diagnosis run.** Readiness r1 authorized exactly one
real-raw diagnosis run, hand-executed by the human maintainer over the
pinned exact input. This record establishes, from the maintainer's own
hand-executed offline searches, that this pinned input no longer exists
anywhere it could be found — so that run can never be executed, the
r1-pinned root-cause measurement is permanently unexecutable, and per the
readiness fail-closed clause the task status carrier drafts
`ready→blocked`. Nothing in this record is a diagnosis result, and nothing
here introduces, implies, or narrows any root-cause claim.

## Classification and scope

- Change/task: `CHG-2026-008-ui-dump-hidumper-wrapper` / `TASK-UD-R2-DIAG-001`.
- Acceptance/test: `INT-UD-R2-DIAG-001` / `TEST-INT-UD-R2-DIAG-001` — the
  humanOfflineDiagnosis half is hereby recorded as permanently
  unexecutable; the synthetic-contract half was closed by the
  implementation record and is unaffected.
- Evidence class: `humanOfflineSearch` (maintainer's hand-executed,
  read-only filesystem search on the capture host; no diagnosis CLI run,
  no device window, no repository write during the search).
- Trust chain: readiness r1 PR #679 (merge
  `d9aa14a6d8e73f16fabb7434db351c5e734923fe`), readiness r2 addendum PR
  #686 (merge `56d6dffb6ee85ebf163d2f6fd41c08b82294fa7a`), implementation
  + synthetic evidence PR #683 (merge
  `495c7356081a83d18538ae6fcdb3e3580134dfbf`, synthetic matrix 37/37 PASS;
  see `implementation-synthetic-run.md` in this directory, whose
  "Pending (maintainer-only)" section this record now resolves as
  impossible rather than pending).
- Search target (the readiness-pinned diagnosis input, #248 exact raw
  origin, capture sequence `16` remote sidecar): file name
  `16-SC-2.sidecar`, length `866256` bytes, SHA-256
  `ec6663e6b7d42053ba089ccbfa89df74cb183a5a583f80a69f103b047014b077`
  (tuple registered in
  `evidence/runs/TASK-UD-CAP-MUT-001/attempt-3-complete-20260721/capture-hashes.md`,
  `decisions/r2-element-tree-v1.md`, and the DECISION-001 run record).
- Result: **zero hits in every search below. The pinned exact input is
  permanently unavailable.**

## Hand-executed searches (2026-07-28, maintainer; command shapes, zero hits)

Per the readiness privacy rule the controlled receive path was never
recorded in the repository and is not recorded here; search scope is
stated at directory-area level and command shape only.

| # | Scope (directory-area level) | Command shape | Hits |
| --- | --- | --- | --- |
| 1 | host temporary directory area | `find /private/tmp -type f -name '16-SC-2.sidecar' -size 866256c` | 0 |
| 2 | `/private/tmp` and `/private/var/tmp` | `find /private/tmp /private/var/tmp -type f -size 866256c -exec shasum -a 256 {} \;`, output filtered for `ec6663e6` | 0 |
| 3 | `/private/tmp` and `/private/var/tmp` | `find /private/tmp /private/var/tmp -type f -name "*.sidecar"` | 0 |
| 4 | user home directory (executed before searches 1–3) | `find ~ -type f -size 866256c` with per-candidate SHA-256 filtering for the pinned digest, plus Spotlight `mdfind "kMDItemFSSize == 866256"` | 0 |

Search notes:

- Search 1 is the strongest single probe: the receive-time file name and
  the exact pinned byte length together, over the receive-time landing
  area. Zero hits.
- Search 2 enumerated every file of the exact pinned length in both
  temporary directory areas and hashed each candidate for comparison
  against the pinned digest; no candidate carried it. The hashed
  candidates were unrelated same-size files, not the controlled raw — no
  controlled-raw byte was read in this record's window, because none
  exists to read.
- Search 4 (user home + host-wide Spotlight size index) had already
  returned zero before the temporary-area sweeps; searches 1–3 completed
  the receive-area coverage on 2026-07-28.

## Background facts and timeline (why this is permanent, not transient)

- 2026-07-21: attempt-3 Phase A capture window. Capture sequence `16`
  received the owned remote sidecar to a host temporary-directory-area
  location outside every repository ("owned sidecar received and
  full-file sensitive scan PASS", attempt-3 run record), and the exact
  removal of the remote copy followed as sequence `17`. The pinned tuple
  above is the only registered identity of those bytes.
- The host temporary directory area is subject to macOS periodic
  reclamation (files unaccessed for roughly 3 days) and is cleared on
  reboot; it is excluded from Time Machine backups.
- 2026-07-28: the searches above — 7 days after capture, beyond the
  unaccessed-reclamation horizon, with zero hits in the receive area, the
  sibling temporary area, the user home, and the host-wide Spotlight size
  index.
- Conclusion: the pinned exact input is permanently unavailable. There is
  no registered copy, and the diagnosis input gate (measured length and
  SHA-256 must equal the pinned tuple exactly; any mismatch is
  `INPUT_HASH_MISMATCH` with zero output) makes every substitute input
  unusable by design — the gate working as designed is what converts
  "file gone" into "measurement permanently unexecutable".

## Consequence under readiness r1 (fail-closed)

- The one authorized real-raw diagnosis run can never be executed. The
  r1-pinned root-cause measurement — raw-data vs pipeline over the old
  raw — is permanently unexecutable.
- This is strictly stronger than the inconclusive branch r1 already
  legislated for: r1's done clause requires a binary conclusion exactly
  `raw-data` or `pipeline`, and forces the status PR to draft
  `ready→blocked` when a run happened but could not determine. A run that
  can never happen can a fortiori never produce the binary conclusion, so
  the same fail-closed direction applies: the status carrier drafts
  `ready→blocked` (blocked reason: pinned-input-unavailable), following
  the stop-and-propose fail-closed status precedent (M0B-002 revert,
  PD-002 #158 lineage).

## Unaffected surfaces; no new claim

- The delivered tool (`scripts/ui_dump_diagnosis/` three files), the
  synthetic matrix result (37/37 PASS), and the #683 implementation
  evidence remain valid host-only contract evidence. This record does not
  negate, weaken, or reopen them.
- This record does not reopen or reinterpret the #263/#267 truthful
  negative, the #248 capture evidence, or any readiness r1/r2 pin; those
  records remain unmodified history.
- This record introduces no new root-cause claim: it does not assert
  raw-data, does not assert pipeline, and does not assert any mixture.
  The binary question for the old raw is permanently unmeasurable — that
  unmeasurability is the only new fact registered here.
- This record authorizes nothing: both follow-up branches stay
  unauthorized. Any revival requires a new proposal revision (maintainer
  review/merge) which must honestly register that the old raw's
  raw-data-vs-pipeline root cause is permanently unmeasurable and can
  only narrow the revival path to the re-capture direction (a fresh
  device-window capture producing a new pinned raw and a new diagnosis
  object under its own readiness). The status carrier this record rides
  in does not draft that revision.

## Counters

| Counter | Value |
| --- | --- |
| Agent controlled-raw read | `0` |
| Human diagnosis CLI executions over any real raw | `0` |
| `diagnose.py` dispatch (any real input, by anyone) | `0` |
| Installed HDC / device / network / GUI / mutation / destructive dispatch | `0` each |
| Controlled-raw path occurrences in session/repository/evidence | `0` |

## Repository gates (carrier worktree)

Measured twice over the same three-file carrier set: first at drafting
base `0d36375f875fae327f32860d60f0c4727b84a58c`, then re-measured after
`main` advanced during the drafting window (#691/#692, entirely inside
`chg-2026-041` — zero overlap with this change's files or this task's
live declaration) and the unchanged carrier was rebased onto
`8855a85d66ce1bb6d7324a6ab07dbb52f45f5896`.

| Check | Result |
| --- | --- |
| `scripts/check-sdd.sh` (shared `.venv-sdd` interpreter) | `PASS` both bases; `0` errors, `0` warnings, `111` acceptance IDs |
| `git diff --check` (staged carrier tree) | `PASS` both bases; clean |
| `check_pr_paths` local simulation (declared `TASK-UD-R2-DIAG-001`; file set = this file + `tasks.md` + `verification.md`) | `PASS` at both base trees; `changed_paths=3`, every path inside the task's 8-pattern live declaration |
| Guard suites at this head (`test_check_pr_paths.py` / `test_check_sdd.py` / `host_loop`) | `PASS`; 49/49, 48/48, suite OK |
| Sensitive-literal review of this diff | `PASS`; no controlled receive path (directory-area level only), no raw bytes, no device serial, connect key, token, or nonce |

Gate ordering note: `tasks.md` cites this file's SHA-256. The hash was
computed over the frozen final content of this file, the citation was
inserted into `tasks.md` afterwards, and the gates above were re-run
green after insertion and again after the rebase.
