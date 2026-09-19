# TASK-XPA-014 — recovery port, slice 2d-c: Rust `job.reconcile` for device-bound Jobs, replaying Swift's device and readback oracles

Change: CHG-2026-074-shared-rust-runtime-core@r11. The device-bound half of slice 2 of the
recovery port the maintainer ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`): `job.reconcile` of a parked device Job by fresh
facts and, for a port rule, its dedicated readback; `finishReconcile`'s device branches; and the
two repairs of a capability outcome a crash lost. Ported from the carriers the package names and
replaying the oracles slices 2d-a (`recovery-device-reconcile-oracle-run.md`) and 2d-b
(`recovery-readback-reconcile-oracle-run.md`) recorded. Host-local: the shared fake HDC, no device.

Base: protected main `3f033e83`, which holds slice 2b (#2071) and slice 2d-b (#2050): `job_recovery.rs`, `job_reconcile.rs` for analyzer Jobs,
`rust/tests/fixtures/readback-reconcile/` and the widened `job.reconcile` schema. Written on 2b's
first local head `93b5d284` (over `c96d024e`) and restacked twice without conflicts; the checks
below ran on 2b over #2050's rebased head `f7ee84a3` and main `655c8199` (#2063). Branch `agent/xpa-014-recovery-device-reconcile-20260919`.
No Swift, Catalog, spec, schema, control-frame or argv-corpus change.

## Already on main / delivered here / remaining

| Already on main, in 2b or in 2d-b | Delivered here | Remaining in the port |
| --- | --- | --- |
| The device oracle `rust/tests/fixtures/device-reconcile/` (#2040); the readback oracle and the widened `job.reconcile` answers (#2050) | `job_reconcile.rs` + `job_reconcile_device.rs`: `reconcileOwned`'s device branch (fresh facts, the parked action materialized, the HDC provider's decision, the dedicated readback) and `finishReconcile`'s device results | `job.run` resumption of a Job waiting at `resumeAtConfirmedSafeBoundary` (the resume lane) |
| The capability ledger's `resolvesUnknown` (#2034); the epoch store (#2025); the §G.4 preflight table (#2026, #2028) | `job_lineage_repair.rs`: `recordCapabilityOutcome`, `repairTerminalSafeToReflashLineageIfNeeded`, `repairTerminalCancelledLineageIfNeeded`, `repairProvablyTerminalCapabilityOutcomeGaps` (on reconcile, and at `job.submit` before materialization) | The debug HAP reconcile branches (failure finalization, compensation identity proof, its lineage repair); the native library, owned-path, package, staging and screen-sequence readbacks |
| 2b: restart carry-over (`recover_jobs`, `recover_active_jobs`) and analyzer `job.reconcile` | The Session publisher's `SessionManifestJournalValidator` rule for a reconcile decision's binding revision; the isolated daemon's reconciler composed with its HDC composition and capability store | The crash-window matrix over the Rust runner and reconciler |

## Ported exactly

`job.reconcile` of a device-bound Job (`observe.device@1`, `capture.diagnostics@1`, the pointer
gestures, the port rules, `capture.screen-sequence@1`; a debug HAP stays refused, see below):
- a terminal Job (Swift's non-resident branch): the writer's unbound-source Session retry as 2b
  ports it, otherwise `repairTerminalSafeToReflashLineageIfNeeded` then
  `repairTerminalCancelledLineageIfNeeded`, then its status; nothing is dispatched;
- a stuck cancellation settled and a Job whose outcome is known answered, as 2b ports them;
- an unknown outcome: the durable-decision completions (a `reconcileOutcome` without its
  transition; `resumeAtConfirmedSafeBoundary`; `finalizing`, now also recording the use
  `safeToReflash`), the legacy refusal, `waitingForRecovery -> reconciling`, the unfinished attempt
  or a new `reconcileStarted`; then the fresh-facts gate (`TargetStoreFactsPort.currentFacts` and
  `validateEvidenceFacts` through the HDC composition's Target facts; a failure is the facts
  error, or for a compensation intent `compensation lost original operation failure`); no input
  Artifact (Swift's `resolvedInputArtifact` is nil for these operations);
  `PersistedTypedProviderAction.materialize()` for the ported kinds, with Swift's required members
  and request bounds; the exact intent;
- the decision: a confirmed outcome the journal already correlates with the intent; otherwise, for
  an action below `deviceMutation`, `HDCObservationProviderAdapter.reconcile`'s read-only families
  (`observeTool`, `observeServer`, `listDeviceCandidates`, `observeDevice`, `queryProperty`,
  `observeStorage`, `captureHilog`, `captureUIDump`) confirmed not executed; for
  `injectPointerInput`, no dedicated readback: `mutation has no dedicated readback; original not
  resent`, nothing dispatched; for `createPortForward` and `removePortForward`,
  `reconciliationReadback` (`readPortForwardPresence`, which must be at most read-only) lowered under
  the reconcile's step identity `reconcile-<step[:72]>-<sha256(attempt)[:32]>`, dispatched once,
  and `verifyReconciliationReadback`: a definite presence equal to the one the change wanted is
  `confirmedCompleted ["postconditionPresent"]`, the other one `confirmedNotExecuted`, anything else
  `dedicated readback did not produce a definite presence`; a readback that cannot be lowered or
  dispatched is `dedicated readback failed: <error>; original not resent`;
- `finishReconcile` with the fresh facts' binding revision: `confirmedNotExecuted` journals the
  `reconciled-outcome` step outcome with semantic code `confirmedNotExecuted`, the
  `finalizeConfirmedFailure` decision and both transitions, fails the Job
  (`executionConfirmedNotPerformed`), resolves the use `safeToReflash` (`resolvesUnknown`) and
  publishes the Session; `confirmedCompleted` journals the succeeded step outcome (unless durable)
  and `resumeAtConfirmedSafeBoundary`, clears the failure and the finish time, and records no
  capability outcome (the use stays `outcomeUnknown`); `stillUnknown` journals the decision with no
  binding revision, returns to `waitingForRecovery` and re-records `outcomeUnknown` (a no-op once
  recorded);
- a reconcile that fails after its journal moved keeps what it journaled resident, as 2b ports it.

`repairProvablyTerminalCapabilityOutcomeGaps` runs in `job.submit` for an effect at or above
`deviceMutation` with an expected binding revision, after the idempotency lookup and before
materialization: every Job holding a `pending` or `outcomeUnknown` use at that revision, in
identity order, whose record names the Target at that revision, is repaired as a reconcile repairs
it; an unreadable record is skipped; a failure is `internalError` without the zero-dispatch proof,
as Swift's handler answers it.

The Session publisher now refuses, as Swift's `SessionManifestJournalValidator` does under the
Session's terminal lock and shards, a Manifest whose Journal holds a `reconcileOutcome` at a binding
revision the Manifest's binding history lacks (`storageUnavailable`,
`invalidManifest("journal binding revision does not exist in Manifest: <event>")`). The device
oracle's parked observation (reconciled at revision 1 before any step confirmed a binding) is
refused its Session exactly so: the Session directory keeps its Journal copy, audit and locks, no
Manifest and no catalog entry. The validator's other rules correlate the Journal's intents,
outcomes and finalized record with a Manifest composed from that same Journal.

## Refused, fail-closed (`rejected`, nothing written, nothing dispatched)

- A `debug.hap@1` Job, as 2b refuses it (its failure finalization, compensation reconcile and HAP
  lineage repair are not ported). At `job.submit`, a HAP Job's lost outcome is left as it is: the
  lineage gate then refuses the next mutation where Swift might have repaired it.
- A `deploy.native-library.app-owned@1` Job whose outcome is unknown (its readbacks need the
  deployment's resolved library and its own verdict table). A terminal one is repaired as any.
- A Job parked on an action whose reconcile is not ported, refused before the journal moves:
  `readPortForwardPresence`, `captureCrashIndex`, `captureCrashLog` (Swift's provider has no
  reconcile source for them and journals `no reconcile evidence source for <Swift's rendering of the
  action>`), `receiveOwnedArtifact`, the owned-path mutations (`captureTrace`,
  `captureComponentTree`, `captureScreenshot`, `cleanupOwnedRemotePath`), the screen sequence's
  (`captureScreenSequence`, `cleanupScreenSequence`), and every package, ability, staging and
  native-library action.
- A device-bound Job whose outcome is unknown, in an owner without an HDC composition, or admitted
  under a runtime capability in an owner without a capability store; a terminal Job whose lineage
  a repair may write, in an owner without a capability store.

## Tests

- `tests/device_reconcile.rs` replays `rust/tests/fixtures/device-reconcile/` whole: the six
  submit/run exchanges, `before/`, the two starts (`starts`, `restart/`, `secondRestart/`), the
  five reconciles and `steps/<name>/`, the refused tap, every read and capability read, and the
  final store, capability store, Sessions, storage owner, Artifacts, tree, Target document and
  the fake's calls, byte for byte; no start and no reconcile adds a call.
- `tests/readback_reconcile.rs`:
  - replays `rust/tests/fixtures/readback-reconcile/` step by step: every exchange, and after each
    of the fifteen steps `steps/<step>/` (index, Job files, capability store, the fake's calls so
    far). The two "outcome lost" steps write the capability files recorded at
    `steps/killedBefore.run/capabilities/` back, as the oracle does; then the reads and every
    file left;
  - a readback refused, unobservable or answered with a failed exit leaves the create parked with
    the reason journaled, one `fport ls` each, never the create, the use unchanged; the device's
    answer then concludes it with one more `fport ls`;
  - a Job parked on its rule's readback, and the same Job in an owner without an HDC composition,
    are refused with every file, the index and the fake's calls unchanged;
  - a Job cancelled after it consumed its use, whose outcome append is removed from the ledger,
    settles it `confirmed` on reconcile, byte for byte what its run wrote, with nothing dispatched.
- Unit tests: `job_reconcile_device.rs` (3: the materialization of every ported kind and its
  refusals, Swift's readback verdicts and dispatch-failure spellings, the reconcile step identity),
  `job_lineage_repair.rs` (1: an intent whose effect cannot be read counts as a mutation).
- `tests/job_reconcile.rs` and `tests/job_recovery.rs` construct the reconciler with no HDC
  composition and no capability store, and pass unchanged.

Mutation checks while writing the replays: without the submit-time repair the readback replay
fails at `steps/killedAfter.submit/index.json` (the create is refused); without the
`safeToReflash` outcome it fails at `steps/reconcileKilledBefore/capabilities/…ledger`; without
the publisher's validator rule the device replay fails at
`steps/reconcileObserveParked/index.json` (the record's publication marker).

## Local targeted checks

Per `AGENTS.md` the unified gate is the PR's CI. Locally, from `rust/`, with `CARGO_BUILD_JOBS=2`,
in this branch's own worktree and cargo target:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --locked -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd --all-targets -- -D warnings` | 0 | clean |
| `cargo test --locked -p arkdeck-hoststore` | 0 | 462 passed, 0 failed, 14 ignored; `device_reconcile` 1 and `readback_reconcile` 4 among them |
| `cargo test --locked -p arkdeck-control` | 0 | 23 passed, 0 failed |
| `cargo build --locked -p arkdeck-cli`, then `cargo test --locked -p arkdeck-agentd --bin arkdeck-agentd` | 0 | 41 passed, 0 failed |
| `cargo test --locked -p arkdeck-agentd --test job_recovery_process --test import_publication_process --test app_ingress_startup` | 0 | 3 passed, 0 failed: the daemon's analyzer reconcile, now composed with its HDC composition and capability store, and the two other process tests that start the isolated daemon over a Job store or at all |
| `python3 rust/scripts/check-contracts.py` (PyYAML and jsonschema) | 0 | published and candidate views pass |
| `sh scripts/check-sdd.sh` (repository root) | 0 | 0 errors, 0 warnings |

Log: scratchpad `logs/checks-2dc-final.log`, SHA-256
`026c7219b416ace24617e5d19f622339bbdf4f8afb85279564468591e73a91db`, run on protected main
`3f033e83` with slice 2b merged (#2071). Earlier runs: over 2b on main `28d2016c`,
`checks-2dc-main.log` (hoststore 449 passed, 13 ignored), SHA-256
`b4a47244af40ac198cadcce8d4b7097c6523273562ae36ba68a64efb1cd08dcd`; over 2b on main `655c8199` with #2050's
rebased head, `checks-2dc-new.log` (the same counts), SHA-256
`2f5b3e4ef56eeffed347912d8201b346b08996b6708bf776fcc0afb7e31d4232`; over 2b on main
`6592bcce` with #2050's first head, `checks-2dc-trial.log` (hoststore 432 passed, 13 ignored;
control 22; the daemon binary 35), SHA-256
`477e846863b0cfeb9b660f94473abc7fb084ebab12cc2b0cd8a524b652d235a2`; the first, on the
uncommitted change over `93b5d284` (hoststore 430 passed, 12 ignored), `checks-2d-c.log`,
SHA-256 `8139fcfc24e7a0fc67a1e17ace0f9b7a3bee2154c2f5e61d7723827801ee8b22`. The provider crate is
unchanged, so its tests were not run. No contract input changed, so `generate-contract.py --check`
was not required. The Rust answers equal Swift's recorded frames, which #2050's widened
`job.reconcile` schema admits (all 17 kept frames, the device and readback oracles' included).

## CI

The PR's `guard` and `swift` aggregate (Rust lane): recorded after the run completes.

## For the maintainer

- **Swift refuses the Session of a device Job reconciled before a binding was confirmed.** The
  oracle's parked `observe.device@1` stopped at its host-only first step; its reconcile journals the
  fresh facts' binding revision on the `reconcileOutcome`, the Manifest composed from that Journal
  has no binding history, and `SessionManifestJournalValidator` refuses it. The Job's marker is
  `storageUnavailable` (not the unbound-source refusal `job.reconcile` retries), so its Session is
  never published. Recorded as Swift behaves and reproduced; it may be a Swift defect.
- **`PortAction::conclude()` in `arkdeck-provider-hdc` is not Swift's `verifyReconciliationReadback`.**
  For an indefinite readback it passes the readback's own reason through, where Swift journals
  `dedicated readback did not produce a definite presence`. The reconcile uses its own port of
  Swift's mapping; `conclude()` has no production caller (the provider's tests pin it).
- The reconcile of `readPortForwardPresence`, `captureCrashIndex` and `captureCrashLog` is refused
  because Swift journals its own debug rendering of the action there (T2 text in a T0 file).
- A reconcile that finishes a Job but cannot record its capability outcome leaves Swift's Job
  resident, so Swift's next reconcile also publishes its Session; the Rust owner keeps no resident
  set for it and answers its status unpublished (the same edge 2b noted for recovery).
- A `componentDetail` UI dump's persisted identifiers are checked as 1–20 ASCII digits; Swift's ICU
  `$` would also admit one trailing line terminator, which no writer produces.

## Not in this slice

- The resume lane: `job.run` of a Job waiting at `resumeAtConfirmedSafeBoundary`. Until it lands,
  a confirmed-completed mutation's use stays `outcomeUnknown` and the lineage blocks every new
  mutation on that binding, as the readback oracle records for Swift before its resume.
- The crash-window matrix (Rust and Swift, before and after the intent, before and after the
  consume, and between the reconcile's journal, record and capability outcome).
- The debug HAP reconcile branches and its lineage repair; the native library, owned-path, package,
  staging and screen-sequence readbacks; `cleanupDebt.continue`'s recovered row and the other M2/M4
  follow-ups 2b lists.
- A Rust CLI `job reconcile` leaf.
