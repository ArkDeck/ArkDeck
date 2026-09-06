# TASK-SVC-002 execution record

Status: local implementation and required unified verification complete.
TASK-SVC-002 is marked done in this delivery for maintainer review. No
protected-main approval, change verification or hardware acceptance is claimed.

Base: `600e4b72a016b38e3289103484208668e6690984` (SVC-001 merged).
Branch: `agent/task-svc-002-single-v1-durable`. The initial working tree was
clean. The implementation was committed and rebased without conflicts onto
`e8c4f1dfdab34ad78bf38a9611e056964a106c8d` for PR delivery on 2026-09-05.
`git range-diff` confirmed the implementation patch was unchanged by rebase.

## Delivered behavior

- Journal, Manifest, JobState and capability storage use the complete current
  v1. Historical version tables, operation-selected Journal writers,
  authority/campaign readers and pre-authorization fingerprint reconstruction
  are removed. Current recovery states, optional host/observation fields,
  Artifact correlations and unknown-outcome refusal remain.
- SQLite creates only the final v1 table/index layout. Existing stores must
  match the columns, constraints, indexes, logical order and row counters.
  WAL/FULL, busy waits, atomic admission, increasing row versions and admission
  sequences remain. There is no migration, creation sentinel or legacy pager.
- Durable Job and capability readers reject unsupported nested fields,
  incomplete correlations and lineage/scope/use-budget drift. Current
  reservation/consumption/outcome, ledger checkpoints, idempotency and crash
  tests remain. Missing checkpoints beside a ledger cannot create empty state.
- The production daemon validates mutation-state continuity before admission
  and capability consumption. A state-root override, retired authority state,
  unsupported/unresolved configured or default Session history, dangling state
  links, and missing capability state beside mutation history all fail closed.
  Retained SQLite Job history is checked even when its Job directory is missing.
  Rejection preserves the original bytes and cannot release a target lane.
- Removed four archive spellings (`flash status`, `flash reconcile`,
  `legacy flash status`, `legacy flash reconcile`), their historical
  archive/reconciler/authority-ledger models and compatibility-only fixtures.
  Caller inventory confirmed the session-run lock had no current producer
  outside that retired reconciler. Current `RuntimeCapabilityStore` budget and
  fault coverage remains. `flash install-binding` and Runtime Job/Session,
  Flash and complete-overwrite recovery paths remain available.
- CLI contracts/fixtures were regenerated with the existing exporter. The
  current Journal and Manifest schemas, writers and validators are aligned.
  Storage documentation describes rejection, preservation and configuration.

## Scope and compatibility

The user accepted the concrete [scope supplement](scope-review.md) on
2026-09-05 for CLI main, command registry, daemon main and the two generated
CLI contracts. The review patch accidentally included the live binding
function between retired helpers; compilation caught the caller, and that
function was restored unchanged before the successful CLI build. No Task
allowlist, checker, Catalog, safety acceptance or historical change was altered.

Compatibility note: the approved single-format CHG-075 scoped delta supersedes
the old development-format decode promises. Current conservative
`outcomeUnknown` refusal and state-based failure projections do not select or
decode a historical format. SVC-003 evidence/descriptor labels and SVC-004
preferences/configuration remain outside this delivery.

## Final verification

On 2026-09-05, from the repository root:

```sh
python3 scripts/ci/plan.py --repo-root . --base-revision origin/main \
  --head-revision HEAD --merge-base --include-worktree --run-local
```

PASS, exit 0. Final log: `/tmp/svc002-complete-gate.log`.

- Public policy, generator, schema and wrapper checks: PASS.
- Swift full parallel lane: PASS, 2,416 scheduled cases, exit 0.
- Required serialized process-identity and Viewer lanes: PASS, 1 + 5 cases.
- Design-system tests: PASS, 83 cases, zero failures.
- App build-for-testing: PASS, `TEST BUILD SUCCEEDED`.
- Control contract generator `--check` and `git diff --check`: PASS.
- CLI exporter: PASS; the full suite verifies zero generated-contract drift
  and explicit `invalidCommand` results for the removed archive commands.

The full lane uses its standard configuration; optional long stress suites were
not enabled. UI assertions were not run because the change targets durable
storage and CLI behavior, not App presentation. Hardware is not required for
this Task, and no device operation or UI action was executed. All fault and
recovery results here are host fixture results, not real-device evidence.

## Acceptance results

| Acceptance | Result and evidence |
| --- | --- |
| SVC-AC-04 | PASS for durable consumers: strict Job decoding rejects retired authority, absent original authorized requests and correlation drift; current read-only and capability paths pass. |
| SVC-AC-05 | PASS: current Journal/Manifest/recovery round trips, exact SQLite layout and logical counters, capability budgets/lineage/checkpoints, Session export and retention pass in the full suite. |
| SVC-AC-06 | PASS: old-version and same-version shape collisions, missing indexes/checkpoints, dangling paths, SQLite-only mutation history, torn-tail/crash/fault cases and raw-byte preservation pass; unknown intent is not replayed, invalid recovery proofs dispatch zero new destructive actions, valid independent recovery retains supersession behavior. |

Retired schema fixtures remain byte-identical to the base contracts (comparison
and SHA-256 checked), allowing the frozen historical corpus to retain its pins:

- Journal: `21df4c44b704d249c2228384b075a331346a4731d3f0b90f66ec8092dded8b19`.
- Manifest: `52be768697e75fc98a00a386345162af2e1a8ca3607b86f755adb766cf0ad489`.

No existing raw Artifact, hardware evidence or production authority state was
modified or relabeled.

## Development failures resolved

Earlier full/focused runs were not green: history fixtures initialized the
index after writing Jobs, HDC Manifest fixtures/producers still used the old
actor shape, and retired reader tests awaited scope consent. Those fixtures
and the current producer were corrected, the temporary startup diagnostic was
reverted, and the approved obsolete-reader removal was completed. The first
post-consent focused run scheduled 165 tests and found one error-type mismatch
in the new symlink guard; the implementation now preserves the established
`RuntimeCapabilityStoreError.ioFailure` contract without weakening its test.

The first post-consent unified gate passed 2,415 parallel Swift cases plus six
serialized cases and the App build (`/tmp/svc002-approved-gate.log`). Subsequent
review added the SQLite-only history regression, then reran the complete gate
successfully as recorded above. Earlier red runs remain earlier red runs;
focused rechecks were not substituted for the final complete result.

## Rebase and PR delivery

The post-rebase unified gate passed, exit 0, with 2,430 scheduled parallel
Swift cases, six serialized cases, all 83 design-system cases, public checks
and App `TEST BUILD SUCCEEDED`. Log: `/tmp/svc002-rebased-gate.log`.
Before push, the required path preflight refused exactly the five previously
user-reviewed scope additions because it reads the Task allowlist from main.
The [scope supplement PR #1738](https://github.com/ArkDeck/ArkDeck/pull/1738)
records only those accepted paths for maintainer review. It was created by
`github-actions[bot]`, is ready for review, and its checks passed. The implementation initially remained local because the path checker requires
the allowlist in the base tree.

PR #1738 merged as `ac8681dd72f0bcc48a8f6b1778aefcbc39a0e3e8` on 2026-09-05.
The implementation was rebased onto that commit without conflict; `git range-diff`
confirmed the patch was identical. The only tree difference from the verified
implementation was the merged Task scope document. The existing full-gate
results therefore cover the unchanged production/test/schema files; final
scope/document checks and the base-tree path preflight passed before push.

## Follow-up fix (2026-09-06): an unreadable durable record must fail closed, not fail dead

Submitted under this Task's ID and Allowed paths per TASK-SVC-005's rule for a
product defect found after the implementation merged. TASK-SVC-002 stays `done`;
this adds no scope to it.

### How it surfaced

`openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-001/run.md`
("Real-device window 2026-09-05") records a host where the post-SVC-001 daemon
could not start: TASK-SVC-001 pinned `RuntimeOperationRequest.schemaVersion` to
exactly `1.0.0`, and all 2,041 durable job records on that host embed a `2.0.0`
request. Start-up recovery threw on the first non-terminal one, the process
exited, and launchd restarted it 248 times. The socket never appeared, so every
CLI query answered `runtimeUnavailable` and the operator got no diagnosis at all.

### What was actually wrong

`RuntimeJobRecord.load` throws both for "no record was written here" and for "a
record is here this build cannot decode". `RuntimeRecoveryService` read it
through `try?` at four sites, which collapses the two, and the four sites then
did three different things with the same collapsed answer:

| Site | Was | Consequence |
| --- | --- | --- |
| `replay` (589) | `try?` then `throw .internalFailure` | **fail dead**: the bug-class code for the operator's own durable state, thrown out of a plain `for` loop in `RuntimeJobEngine.recover(records:)`, so one record aborted recovery for all 2,040 others and the daemon exited before binding its socket |
| `unresolvedDestructiveIntents` (166) | `try?` then `continue` | walked past silently in the scan whose purpose is to prove no destructive intent is outstanding on a target |
| capability-lineage scan (277) | `try?` then `throw .blocked` | already correct |
| historical-recovery candidates (331) | `try?` then dropped by `compactMap` | narrows candidates only; dropping an unusable one is the safe direction |

An earlier reading of this record claimed site 166 left the complete-overwrite
admission gate open. That was overstated and is corrected here: `continue` also
leaves the job out of `journalDestructiveJobIDs` (188), and the capability scan's
skip condition (266-274) is exactly membership in that set, so a job invisible to
the journal scan reaches 277-291 and is refused there. The gap 166 actually left
is narrower — a job with an unreadable record and no capability ledger entry —
and it is closed below.

### What changed

- `RuntimeJobRecord.state(in:)` answers three ways (`absent` / `readable` /
  `unreadable(reason)`) and never throws. Every caller that decides what to do
  next reads it instead of collapsing `load`'s two failures.
- `replay` refuses an unreadable record with `RuntimeJobEngineError.jobRecordUnreadable`,
  naming the Job and the reason, and keeps `internalFailure` for the genuinely
  inconsistent case (`absent` after the projection repair ran). The wire code for
  the first is `recordUnreadable` with `provesZeroNewDispatch`.
- `unresolvedDestructiveIntents` refuses an unreadable record by name
  (`completeOverwriteRecovery.unreadableHistoricalRecord`) instead of continuing.
  A record it cannot read is one whose binding it cannot match to this target or
  rule out, so the proof may not be assembled around it.
- `RuntimeJobEngine.recover(records:)` sets unreadable records aside **before**
  either existing loop reads them, and publishes them as
  `quarantinedJobRecords`. The two loops are otherwise untouched, so recovery of
  readable and absent records behaves exactly as before.
- The daemon names each quarantined Job on stderr at start-up and keeps serving —
  the shape the artifact-retention sweep sixteen lines below already uses ("A
  failure here must not stop the daemon from serving, but it is not swallowed
  either"). `doctor` publishes one `runtime.jobRecordUnreadable` blocker finding
  per Job with its id, reason and effect.
- Quarantined Job IDs are added to the active set handed to
  `collectGarbage(activeJobIDs:)`. Omitting them — the obvious form of "just skip
  it" — would have widened the retention sweep over the evidence of the very
  Jobs an operator needs to diagnose.

Nothing is migrated, deleted, truncated or rewritten: a quarantined Job is not
live, is not runnable, and its bytes are asserted unchanged by the test below.
The refusal is not relaxed; only its blast radius is.

### Deliberately not in this change

- **The read surface.** `RuntimeJobEngine.statusPage` maps the page with
  `try decodePersistedRecord(persisted)`, so one unreadable row still fails a
  whole `job list` / History page. Marking the row instead requires a decision
  about the published `job.list` result shape, which is a wire change and would
  need the per-method schemas re-derived again (TASK-XPA-001 just re-derived them,
  and its owner has an in-flight change to the deriver). It is a separate PR with
  its own shape decision, and it is required before a device window: a host with
  a 2.x store stops at the first `job list` even with this fix.
- Sites 277 and 331 keep their current behaviour, which is already the safe
  direction in both cases.

### Verification

| Command / check | Result |
| --- | --- |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --parallel` | PASS, exit 0, 2,445 cases, zero failures |
| `RuntimeJobEngineContractTests.testARecordThisBuildCannotReadIsQuarantinedRatherThanTakingRecoveryDown` | PASS. It admits two Jobs, rewrites one record's embedded request label to the retired `2.0.0`, reopens the engine, and asserts the readable Job recovers, the other is quarantined with a reason, its bytes are unchanged, and it is not runnable. **Verified to be a real regression test**: with the quarantine block removed the same test fails (1 failure), and passes with it. |
| `python3 scripts/ci/plan.py --run-local` | **PASS**, exit 0 on the committed tree: full-parallel 2,439 cases (68 s), process-identity race 1, Viewer scale 5, all exit 0; App lane `TEST BUILD SUCCEEDED`; `check_sdd` 0 errors / 0 warnings / 121 acceptance IDs; design-system lane green. One-minute load average was 5.0 on 8 cores, so no lane result is load-suspect. |
| `python3 scripts/check_pr_paths.py --preflight` | **PASS**: resolves exactly `TASK-SVC-002`, exit 0, over 7 changed paths — `RuntimeJobRecord.swift`, `RuntimeRecoveryService.swift`, `RuntimeJobEngine.swift`, `ArkDeckAgentDaemon/AgentDaemon.swift`, `ArkDeckAgentDaemonMain/main.swift`, `ArkDeckContractTests/**` and this change directory — all inside this Task's Allowed paths. |

No device was contacted and no daemon was installed: this is host contract
evidence. Whether the recorded host can now take a post-SVC build is not claimed
here — it needs the read-surface fix above and then an actual run on that host.

## Open: two decisions this Task cannot take for itself

Recorded here so they are not lost between sessions. Neither is answered by
this Task, and neither is assumed in any delivered code.

### 1. The read surface needs one path this Task does not hold

`RuntimeJobEngine.statusPage` still maps a page with `try decodePersistedRecord`,
so one record this build cannot decode still fails a whole `job list` / History
page. On a host whose store predates the current durable shape that is every
page, which is why the follow-up fix above lets the daemon start but does not yet
let it be used: the headless runbook's §0 ledger criterion
(`arkdeck job list --page-size 1000`, `docs/design/cli-golden-journey-headless-runbook.md:26-27`)
is the first thing a device window runs.

The honest repair returns the page and names what it could not project. It cannot
mark the row: `RuntimeJobStatus.operationReference` and `.targetID` are required
and exist only inside the record, so a marked row would have to invent them — the
exact failure this whole change is removing. The shape that does not invent
anything is page-level: `job.list` gains `unreadable: [{ jobId, reason }]`
alongside `items`, one entry per record the page could not project, matching the
`runtime.jobRecordUnreadable` `doctor` findings the fix above already publishes.

That is a change to a published result shape, so the per-method schema must be
re-derived in the same PR — `Packages/ArkDeckKit/Scripts/generate-control-contract.py --derive-method-schemas`
writes `spec/control/methods/*.json`. This Task holds
`openspec/contracts/runtime-control-plane.schema.json`, `Packages/ArkDeckKit/Contracts/**`
and `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**` (which covers the frame
corpus the same command rewrites) but not `spec/control/methods/**`, and
TASK-XPA-001 holds `spec/**` but not `RuntimeJobEngine.swift`. Splitting the work
across the two Tasks would land a wire change whose published schema is stale
until the second PR merges — the destructive intermediate state this change's
execution contract forbids ("不先提交仅版本号/仅删handler的破坏性中间态").

The revision this record travels with adds exactly `spec/control/methods/**` to
this Task's Allowed paths. Nothing else is requested, and no code is delivered on
the assumption that it is granted.

### 2. Complete-overwrite recovery on a host that ran a 2.x Runtime

With the follow-up fix above the daemon starts on such a host, but
complete-overwrite recovery admission now refuses its historical records by name
(`completeOverwriteRecovery.unreadableHistoricalRecord`) — correctly: a record it
cannot read is one whose outstanding destructive intent it cannot rule out. The
consequence is that GJ-4 cannot be admitted on any host that ever ran a 2.x
Runtime. The two ways out are a read or migration path for `2.0.0` request
documents, which this Task's own record states it does not provide ("There is no
migration, creation sentinel or legacy pager"), or a fresh state directory, which
discards the history the 2026-09-02 coverage matrix depends on. Both are scope
decisions for the maintainer. TASK-XPA-001's owner is raising the same question
from the device side.
