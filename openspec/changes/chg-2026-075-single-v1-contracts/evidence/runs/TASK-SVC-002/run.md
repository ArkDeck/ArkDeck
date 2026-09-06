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

`RuntimeJobEngine.jobListSnapshot` still decodes every ledger row with `try decodePersistedRecord`,
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

## Correction and escalation (2026-09-06)

### A factual error in the section above, corrected

Two sentences above said `job.list` routes through `RuntimeJobEngine.statusPage`.
It does not. `job.list` routes through `jobListSnapshot`
(`RuntimeJobResourceReader.swift:16`); `statusPage` is reachable only from
`RuntimeJobEngine.listJobs(pageSize:cursor:)`, and **that method has no
production caller at all** (verified across every Swift source). An implementer
following the record literally would have patched a dead surface. The sentences
are corrected in place; this note records that they were wrong when published.

### The read-surface repair was attempted, measured against the code, and withdrawn

It was implemented — unreadable rows listed as a distinct minimal shape, the page
returning — and it failed the suite against three tests that deliberately pin the
opposite:

| Test | What it pins |
| --- | --- |
| `AgentDaemonContractTests.testUnreadableJobRecordHasDistinctWireErrorFromMissingJob` | `job.status` **and** `job.list`, paged and unpaged, fail with `recordUnreadable`; a genuinely missing Job stays `notFound` |
| `RuntimeJobEngineContractTests.testUnreadablePersistedRecordIsDistinctFromMissingAcrossHistoryReads` | the same at the engine level, with the exact payload `jobRecordUnreadable(jobID)`; its XCTFail texts read "the unpaged history surface must fail loudly on a corrupt record" and "the paged history surface must use the same corrupt-record error" |
| `JobReadResourcesContractTests.testCurrentHistoryRejectsRetiredCreationSentinelAndTimestampDrift` | a row whose creation column drifts from its record stays unreadable |

The change was reverted rather than the assertions rewritten. Three further facts
came out of measuring it, and each is why this is a maintainer decision rather
than an implementer's:

1. **`job.list` is not a pure read.** `agentdRestartJobPreflight`
   (`ArkDeckRuntimeCommands.swift:725-760`) classifies only rows in `items` and
   requires each to carry `current`; on success the restart writes a durable
   proof with a hardcoded `"blockingJobCountBefore": .integer(0)`
   (`:551`). A page-level sidecar the preflight does not read converts "I could
   not read these records" into a written claim that nothing blocked the
   restart — exactly the manufactured recovery proof design.md §4 forbids.
2. **Marked rows inside `items` are rejected client-side anyway.**
   `CLIJobResources.swift:54` requires the envelope to have exactly seven keys
   and every item to be a full `arkdeck.job-summary/1`, so `arkdeck job list`
   would refuse the whole page before the operator saw it. The attempted
   implementation's tests covered the engine and the daemon handler and would
   not have caught this.
3. **The blast radius is six paths wider than #1745 assumed.** A sidecar needs
   `RuntimeSnapshotPager.swift` (or it appears on page 1 and vanishes on page 2,
   because the cursor branch returns `items: { [] }` without rescanning),
   `XPCConnectionBox.swift` (two exact seven-key gates feeding the App's Debug,
   Trace and UIDump panes), `ArkDeckCLI/**`, the headless runbook's §0 criterion,
   and `openspec/contracts/cli-page.schema.json` — a `additionalProperties:false`
   envelope shared by at least ten paged methods and owned by no task in this
   change. #1745 stated it adds "exactly `spec/control/methods/**` … and nothing
   else"; that assessment was short by those paths.

It is also not true that the read repair unblocks a device window on its own:
`doctor --require-healthy` exits 69 on such a host regardless, because every
unreadable record is a blocker finding and `ready = blockerCount == 0`.

### What this delivery does instead

Two things that improve the same operator's position without reversing any
pinned contract:

- The refusal names the Job. `RuntimeJobResourceReader` answers
  `recordUnreadable` with the Job id in the message instead of discarding the id
  the engine already had. It goes in the message rather than in `details`
  deliberately: a details object is a change to the published error shape, and
  it also makes `AgentClient` raise `structuredDaemonError` instead of
  `daemonError` — which the pinned wire test catches, so the first attempt at
  this failed against it. The published shape is unchanged, no schema is
  re-derived, and none of the three pinned tests changes.
- `doctor --deep` counts the whole ledger. The findings published in #1744 come
  from `recoverActiveJobs()`, whose query excludes terminal states, so on a
  store an earlier build wrote it named the few still-active Jobs and nothing
  about the terminal majority — which is what an operator meets first. `--deep`
  now reports one `runtime.durableRecordsUnreadable` blocker carrying the total
  and a bounded sample. One finding, not one per row.

### The decision still open

Whether the History listing keeps failing loudly on an unreadable row, or returns
the page with those rows reported, given (1) above. Recommended shape if it
returns: page-level, and shipped in the same PR as the restart-preflight and
proof fix, or not at all. Both halves cannot ship under one Task today.

### Verification of this delivery

| Command / check | Result |
| --- | --- |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --parallel` | PASS, exit 0, 2,446 cases, zero failures — including the three pinned tests, none of which was modified |
| `JobReadResourcesContractTests.testAnUnreadableRecordIsNamedByTheWireErrorAndCountedByDeepDoctor` | PASS: the read still refuses with `recordUnreadable`, the message now names the Job, `details` stays absent, `doctor --deep` publishes one `runtime.durableRecordsUnreadable` blocker with the total and a bounded sample, and a shallow report does not |
| `python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --check` | exit 0, and no per-method schema changed: this delivery alters no published shape, so nothing was re-derived |
| `python3 scripts/ci/plan.py --run-local` | **PASS**, exit 0: full-parallel 2,440 cases (95 s), process-identity race 1, Viewer scale 5, all exit 0; App lane `TEST BUILD SUCCEEDED`; `check_sdd` 0 errors / 0 warnings / 121 acceptance IDs |
| `python3 scripts/check_pr_paths.py --preflight` | **PASS**: resolves exactly `TASK-SVC-002`, exit 0, over 5 changed paths — `RuntimeJobResourceReader.swift`, `AgentDaemon.swift`, `RuntimeJobEngine.swift`, `JobReadResourcesContractTests.swift` and this run record — all inside this Task's Allowed paths. |

No device was contacted. Whether the recorded host can run a device window is
unchanged by this delivery and is stated above as still open.

## Second follow-up fix (2026-09-06): refusing a store must not rewrite it

Submitted under this Task's ID and Allowed paths, per TASK-SVC-005's rule for a product defect
found after the implementation merged. TASK-SVC-002 stays `done`; this adds no scope to it.

### How it surfaced

Measuring what the merged single-v1 build actually does to the Golden Journey host's real state,
rather than to a fixture. That host's store is
`~/Library/Application Support/ArkDeck/Agentd`: 1891 job directories, a 14.6 MB
`runtime-jobs.sqlite3` at `PRAGMA user_version = 2`, and a live 16,512-byte write-ahead log. The
`runtime_job` table there carries `admission_sequence` and `created_at_order_key` as trailing
nullable columns, because a build between `70f22170` (#1709, which moved the repository to
schema 2) and `a4cdda44` (#1739, this Task, which moved it back to 1 and deleted the migration)
added them with `ALTER TABLE`. Current `main` declares both inline and `NOT NULL`, so the store is
refused. That refusal is intended: Deliverable 4 and design.md §4 both require the single layout
with `user_version=1` and the removal of the upgrade path.

What was not intended is what the refusal does on the way out. Copying that store to a scratch
directory and running `arkdeck-agentd --state-dir <copy>` built from `64cd8144`:

| | `runtime-jobs.sqlite3` sha256 | `-wal` |
| --- | --- | --- |
| the copy, untouched | `f3d9e6a0…c1f84ba` | 16,512 bytes |
| after one refusing start | `f06be0db…7687965b` | 0 bytes |
| after a second refusing start | `f06be0db…7687965b` | 0 bytes |

The refusal rewrote 14.6 MB of database and emptied the log, then reported
`original state is preserved at …`. The second run being stable identifies the cause exactly: the
first open recovered the write-ahead log and the close checkpointed it back into the database.

### Why the existing tests could not see it

`RuntimeJobRepository.init` already ordered this correctly for the hazard it knew about —
`// Validate existing bytes before any journal-mode change or schema write.` at the call to
`bootstrapSchemaIfNeeded`, ahead of `configure()`. That guard stops this build from issuing
`PRAGMA journal_mode`. It cannot stop SQLite's own behaviour: opening a WAL database read-write
recovers the log, and closing the last read-write connection checkpoints it, neither of which is
a statement this code executes.

`CurrentDurableStorageContractTests.testSameVersionWrongColumnsIndexesOrConstraintsAreRefusedWithoutRewriting`
asserts byte equality across a refusal, including for the `PRAGMA user_version=2` case, and it
passes. It passes because its fixture is built through the file-local `sql(_:at:)` helper, which
opens, executes and closes — and that close checkpoints. By the time the test captures `original`
there is no log left to checkpoint, so the assertion cannot fail. The invariant was pinned against
a fixture that structurally cannot exhibit the condition.

### The first attempt at this was wrong, and CI caught it

The first version of this change inspected every existing store over a read-only connection.
That is wrong, and the swift-tests lane on PR #1747 failed with
`ioFailure("Runtime SQLite query [14]: unable to open database file")` across
`AgentDaemonContractTests`. Measured cause, reproduced locally and then reduced to `sqlite3`:

    sqlite3 a.db "PRAGMA journal_mode=WAL; CREATE TABLE t(x); INSERT INTO t VALUES(1);"
    rm -f a.db-shm a.db-wal
    sqlite3 "file:a.db?mode=ro" "SELECT count(*) FROM t;"
    Error: in prepare, unable to open database file (14)

A read-only connection cannot create the shared-memory index a write-ahead log is read through,
and a clean close removes that index. So the first version refused to open every store that had
been shut down cleanly — which is the ordinary case, and strictly worse than the defect it fixed.
`PRAGMA locking_mode=EXCLUSIVE` does not lift it (`disk I/O error (10)`), and neither of the two
SQLite controls that would suppress the checkpoint is usable here: `sqlite3_db_config` with
`SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE` is `unavailable: Variadic function is unavailable` in Swift,
and `sqlite3_file_control` with `SQLITE_FCNTL_PERSIST_WAL` only prevents the log's deletion —
measured, the checkpoint still ran (4,096 → 8,192 bytes, log truncated).

This was avoidable: the storage suite was run before pushing but the full suite was not, because
the host was under load. The failing cases are deterministic and would have been caught.

### What changed

`Packages/ArkDeckKit/Sources/ArkDeckStorage/RuntimeJobRepository.swift`:

- `init(stateDirectory:)` establishes the layout of an existing file over a read-only connection
  before opening one that can write, added as `inspectingReadOnly(_:)`. A read-only connection
  cannot checkpoint, so a store this build ends up refusing is left exactly as found. It uses
  `BEGIN DEFERRED`: an inspection needs a snapshot, and `BEGIN IMMEDIATE` would ask a connection
  that must not write for a write lock.
- That inspection runs only when the shared-memory index is already on disk. The index is what
  decides, because it is present exactly when a log is pending: a clean close removes the log and
  the index together. When it is absent there is nothing to checkpoint, and the ordinary
  read-write open closes leaving the database byte-identical anyway — measured separately, a
  read-write open and close of a WAL-mode database with no pending log leaves its sha256
  unchanged. So the two branches cover the two states between them, and neither writes to a store
  that has not been accepted.
- The requirements a store must meet are stated once, in `requireCurrentLayout()`, and called from
  both the read-only inspection and the existing write-side `bootstrapSchemaIfNeeded(isNew:)`. The
  version guard, the `sqlite_schema` comparison and the row-ordering scan are unchanged; they
  moved. Two copies of that contract would be free to drift, which is the failure this change
  exists to remove.
- `chmod(url.path, 0o600)` now runs only after an existing store has been accepted, so a refused
  store is not touched at all.

Nothing about which stores are accepted changed. The refusal text, its error case and the
preserved-path fact are the same.

### Verification

- `CurrentDurableStorageContractTests.testARefusedStoreWithALiveWriteAheadLogIsNotRewrittenByTheRefusal`
  builds the previous build's layout — `user_version=2` with both newest columns added by
  `ALTER TABLE` — copies the database, log and shared-memory files while the writer still holds
  them, so the copy carries a live log exactly as a running daemon's directory does, and asserts
  the database and the log are byte-identical after the refusal. **Verified to be a real
  regression test**: on `64cd8144` it fails with the database at 4,096 → 16,384 bytes and the log
  at 41,232 → 0 bytes; with the change it passes.
- The same measurement repeated against a fresh copy of the host's real 1891-record store: same
  refusal, `f3d9e6a0…c1f84ba` and the 16,512-byte log both unchanged afterwards.
- `CurrentDurableStorageContractTests.testAStoreReopenedWithoutASharedMemoryIndexIsStillAccepted`
  pins the case CI caught: admit a Job, close the repository, delete the log and the index, and
  reopen. It fails against the first version of this change and passes against the delivered one.
- `arkdeck-agentd --state-dir` against an empty directory still starts and stays up, so the
  accepted path is unaffected; `testNewV1RetainsIdempotencyRowVersionsAndLogicalOrderAfterRestart`
  and the other eleven cases in the file pass unchanged.

### Still open after this change, and separate from it

This fix makes the refusal honest. It does not make it survivable. On that same host the daemon
still exits during composition, `com.arkdeck.agentd.plist` carries `KeepAlive` with
`ThrottleInterval 5`, so launchd restarts it every five seconds, the socket is never bound, and
every CLI command answers `runtimeUnavailable` with no indication of the cause — including
`doctor`, which is where #1744's `runtime.jobRecordUnreadable` findings and #1746's
`runtime.durableRecordsUnreadable` census would otherwise be read. design.md §4 requires that
"现有未决状态不可读时，原 target lane/整个相关 Runtime mutation 面 fail closed"; it requires the
mutation surface to fail closed, not the process to exit. That gap is tracked separately.
