# Flash admitted, run, parked and reconciled on the Rust Runtime through the lane seam (TASK-XPA-017, M4-F3/F4)

The Swift Flash run oracle (`rust/tests/fixtures/flash-run`, previous
change) records eight stories. This change serves five more of them on the
Rust Runtime, byte for byte: `canonical`, `alias`, `failures`, `cancel` and
`reconcile`. Together with `admission`, six of the eight now replay. The two
recovery stories wait for DEC-016, which needs a contract-input change.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| The oracle; Flash `job.submit` refused before issuance (M4-F0/F1) | Issuance and admission; the run through the lane seam; the reads of a Flash Job; restart parking; passive reconciliation and the resumed run | DEC-016 recovery with its contract fields; the production lane and the Rockchip host, which wait for the ArkForge client change; the Loader binding settlement |

The production daemon composes no lane yet, so it still refuses a Flash
before issuance (`FlashAdmitter { executes: false }`): nothing here reaches
a device, `arkforged` or an installed service. The replay composes the
lane's fakes.

## Admission

After every refusal of M4-F1, the Runtime issues its own destructive
capability as Swift's `automaticRuntimeCapability` does
(`capability_policy::issue_destructive`):

- The Target lineage must be clear: a use of the binding whose outcome is
  not settled blocks it.
- The policy identity is the catalog digest, the authorization scope and
  `ordinary`: `CAP-RT-POLICY-<40 of its uppercase SHA-256>-G<n>`.
- The generation walk is Swift's:
  - a live generation with a use left and a lineage that allows new
    execution is reused;
  - an unused expired one rolls to the next;
  - a pending or unknown last use returns the spent generation, which
    validation then refuses (fail closed);
  - a confirmed last use rolls to the next only when its Job ended
    `succeeded`, `recovered`, `cancelled` or `failed`;
  - a use proved safe to reflash rolls to the next, within sixteen serial
    attempts and four hours.
- A new generation is one use, for four hours, pinned to the exact plan
  digest, binding revision and Artifact facts.

The capability is validated for this execution. The Job is then admitted as
Swift admits it: its index row, `jobCreated` and `queued -> preflight`, and
its record, with no admission evidence. Nothing is consumed at submit.

## The run

`FlashRunner` runs an admitted Flash as Swift's `runOwned` does with a lane
composed:

- The running transition, then the lane's archive prewarm, started only once
  the Job is durably admitted and running.
- Every step in the Target's mutation lane, in catalog order:
  - the archive verified on the host;
  - the destructive intent bound to the Job's Runtime-owned capability;
  - the Loader transition and the way back out left to the lane's own plan.
- At `flash-partitions`:
  1. the prewarm is awaited;
  2. the capability is consumed against a freshly materialized plan and
     fresh facts;
  3. the daemon job is prepared, and its correlation made durable
     (`arkforge-runtime-state.json`) before the write-ahead intent;
  4. the one delegated drive runs, and its terminal receipt is validated and
     made durable before the step's outcome.
- The completed plan projected onto the readback, reboot, reconnect and
  postflight steps, each its own intent and outcome, the postflight's facts
  published first.
- The optional post-flash HiLog captured through the Rockchip host under its
  own intent, published with the window it was observed in.
- The finalization report, the terminal state and the capability use's
  outcome.

What stops a run is classified as Swift classifies it:

- An unknown outcome parks the Job in `waitingForRecovery` with its intent
  outstanding. It is never retried or replayed.
- A confirmed non-execution fails the Job with its use safe to reflash. Only
  the lane's own proof counts: the daemon job refused or not created, or the
  drive confirmed not executed. A prewarm refused before consumption
  consumed no use.
- A confirmed failure fails the Job.
- Anything else is answered as a refusal, and leaves the Job where it stood.

The record is persisted where Swift persists it, so the Job index counts the
same writes.

## The reads

`job.result` and `job.evidence` read a Flash as Swift reads it:

- the alias's unversioned reference resolves its descriptor;
- `actualStepKinds` are the kinds of the steps the journal confirms, in
  catalog order (`durableActualStepKinds`);
- a diagnostics capture the request did not select is intentionally
  omitted, not an integrity failure;
- each step product is named in the timeline (`artifact … -> ART-…`);
- the Job status names the alias's `workspaceKind` as `flash`.

## Restart and reconciliation

- **Restart.** A Flash the daemon finds in a lane-held state is parked in
  `waitingForRecovery` with its outcome unknown ("ArkForge execution state
  was process-owned; parked unknown; no redispatch"). The lane-held states
  include a confirmed boundary not yet resumed, as in Swift.
- **`job.reconcile`** (`FlashReconciler`) observes only the correlated daemon
  job:
  - A completed plan whose receipt validates confirms the intent, and the
    Job waits at its confirmed safe boundary.
  - A daemon job cancelled safely confirms the intent not executed: the Job
    fails, and its use is safe to reflash.
  - Anything else — no terminal, an unknown or failed terminal, an
    unreachable daemon, a receipt that does not validate — closes the attempt
    `waitingForRecovery` with `flash.recoveryProofMissing`. A model or build
    readback is never taken for proof.
- **The resumed run** takes over the use its first run consumed. It skips
  the steps the journal confirms, and projects the rest from the durable
  receipt; the lane is never asked to drive the plan again.

## The replay

Six of the oracle's eight stories now pass byte for byte, including every
answer, both call logs, the Job index, the tree and every file:

| Story | Exchanges |
| --- | --- |
| `admission` | 11 |
| `canonical` | 19 |
| `alias` | 7 |
| `failures` | 33 |
| `reconcile` | 21 |
| `cancel` | 8 |

A Flash record's timeline measures how long its run waited for the lane's
prewarm (`consume wait <ms> ms`), which the oracle labels in answers and
files. The Job index's `recordSHA256` hashes the record as the store holds
it, so under load a wait of 1 ms or more made a row differ (reproduced on the
third of ten runs beside six busy loops). The replay now holds such a row to
Swift's digest by the wait that reproduces it — the recorded one first, then
any single wait — every other byte of the record unchanged; ten runs under
the same load passed.

## Declared differences

- **Incidental files**: as declared by the oracle's change.
- **A resume without a restart.** Swift's resident Job keeps the steps it ran
  in memory, so it also skips the owned-mode steps of the first run
  ("resume skipped …"). This Runtime reads the journal, and delegates them
  again ("delegated …"). No dispatch or state differs. The oracle resumes
  only after a restart, where both read the journal.
- **DEC-016 is not in this slice.** An unresolved destructive intent on the
  binding blocks every later Flash through the capability lineage, as a
  refusal. Swift classifies it with its complete-overwrite admission. No
  story replayed here reaches it. For the same reason, a restart still
  refuses a complete-overwrite recovery Job a Swift daemon left, untouched.
- **A lease whose payload changed after admission.** This Runtime resolves
  the lease again at the prewarm and checks the payload against its digest,
  so it fails the Job as not executed before anything is consumed. Swift's
  lease resolution does not read the payload; it fails at the host
  verification step instead. Both fail closed, with no use consumed; the
  oracle does not record this case, since the two refusals cannot be made to
  match.

## Safety conditions and their tests

This change issues a destructive capability and drives the lane, so each
condition the maintainer set for it has its tests:

| Condition | Tests |
| --- | --- |
| Every refusal dispatches nothing | Every replayed exchange compares the lane's and the host's call logs with Swift's. `every_admission_refusal_is_swifts`: nine refused submits, no call, and the Job index and capability store as Swift's (nothing admitted or issued). `a_canonical_flash_runs_as_swifts` (`run.again`) and `a_flash_cancelled_before_it_runs_is_closed_as_swifts` (`first.run`): a Job that is not runnable is refused with `newDispatchCount: 0` and no call. `every_flash_failure_ends_as_swifts`: the prewarm refused or answered for another archive asks nothing but the prewarm and consumes no use. `a_flash_after_an_unknown_one_is_refused_by_its_lineage`: refused before admission, no call, index and capability store unchanged |
| An unknown outcome is never retried or replayed; recovery only as POL-RECOVERY-001 allows | `every_flash_failure_ends_as_swifts` (`nonCanonical`): parked `waitingForRecovery` after one drive. `a_lost_flash_is_reconciled_as_swifts`: the lost drive parked; the restart parks it without a call; reconcile only observes the correlated daemon job; no terminal, an unreachable daemon or a failed terminal without proof stay unknown (`flash.recoveryProofMissing`); only the canonical completed-plan receipt lets the Job resume, and the resumed run never asks the lane to drive again. `a_flash_after_an_unknown_one_is_refused_by_its_lineage`: while the use is unknown no later Flash of the binding is admitted; this slice admits no complete-overwrite recovery at all |
| Execution only in the per-Target mutation lane | `a_flash_runs_only_inside_its_targets_mutation_lane`: while another holder keeps the Target's lane, the run waits in its queue and nothing but the prewarm (which Swift starts before the lane) is asked of the lane; after the lane is free, the run drives the plan. A mutation that skips the lane fails it ("never reached: the Flash waiting in its Target's lane") |
| Only the fake lane | The production composition admits no Flash (`FlashAdmitter { executes: false }`): agentd `flash_plan_control` holds that a daemon without a lane refuses a Flash before admission and makes no Job directory. The replay composes `FakeLane` and `FakeHost` only; no test runs `arkforged` or reaches a device |
| The capability is the Runtime's own, one use, pinned to the exact plan | `every_admission_refusal_is_swifts` (`submit.callerCapability`): a caller-supplied capability is refused. `a_canonical_flash_runs_as_swifts`: the envelope Swift issues and the one this Runtime issues are the same bytes in the capability store (issuer `runtimeDefaultPolicy`, `maximumUses` 1, the exact plan digest, binding revision and Artifact facts, four hours); `capabilities.admitted` shows it unconsumed at submit; the use is consumed once, before the delegated drive (`capability consumed before first mutation` precedes the intent in the journal); `run.again` is refused without a second consumption; the second Flash rolls to a new generation. `every_flash_failure_ends_as_swifts`: each generation's use and outcome as Swift's ledger records them. At consumption the plan is materialized again against fresh facts and must equal the admitted digest, identity and binding |
| confirmedNotExecuted settles a use safe to reflash only on Swift's proofs | `every_flash_failure_ends_as_swifts`: the daemon job not created, bound to another attempt, or confirmed not executed by its drive, each with the capability store's document and ledger as Swift's. `a_lost_flash_is_reconciled_as_swifts`: the daemon job cancelled safely |

## Tests

| Test | What it holds |
| --- | --- |
| `flash_run.rs` `a_canonical_flash_runs_as_swifts`, `an_alias_flash_runs_as_swifts`, `every_flash_failure_ends_as_swifts`, `a_flash_cancelled_before_it_runs_is_closed_as_swifts`, `a_lost_flash_is_reconciled_as_swifts` | Their stories byte for byte |
| `flash_run.rs` `a_flash_runs_only_inside_its_targets_mutation_lane`, `a_flash_after_an_unknown_one_is_refused_by_its_lineage` | The lane and lineage conditions above |
| agentd `production_composition.rs` `an_enter_loader_transition_awaiting_the_binding_is_named_and_two_refuse_the_start` | The Job it parks is now seeded as a Runtime leaves one, with its journal (admission, the running transition, the enter-Loader intent, the park). The start used to refuse every Flash Job untouched, so the test's Job had no journal; now the start recovers a Flash as Swift does before naming it |
| `arkforge_job_state.rs` (unit) | The sidecar's strict round trip |
| `job_recovery.rs`, `rockchip_startup.rs`, `loader_binding_jobs.rs`, `post_flash_alias.rs`, `device_mutation_reconcile.rs`, `job_reconcile.rs`, `crash_window.rs` | Unchanged behaviour for every other Job |

## Local targeted checks

Run on this change over the oracle's head (#2223, `7beec0f3a` on `main`
`3315a9cba`). After the rebase onto `main` `dc709dc3e` (#2223 merged as
`4d0337b5d`, and #2224), fmt, clippy for the four crates, the replay (9
passed) and agentd's `production_composition` (12 passed) were run again.
Rebased again onto `main` `896565e97` (with #2230's Session publication
through `.staging`, which the five new stories publish and compare), fmt,
the four crates' tests and clippy were run again: exit 0 each
(`arkdeck-m4-pr2r-*.log`; the replay 9 passed). `main` `587127475` then adds
#2233, #2236 and #2237, none of which touches these crates.
Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| Rust replay | `cargo test -p arkdeck-hoststore --test flash_run` | 9 passed (`arkdeck-m4-pr2-test-flash-run.log`) |
| Lane mutation | `a_flash_runs_only_inside_its_targets_mutation_lane` with the lane skipped in `flash_run.rs`, then the source restored by digest | fails: "never reached: the Flash waiting in its Target's lane" |
| fmt | `cargo fmt --all --check` | exit 0 (`arkdeck-m4-pr2-fmt.log`) |
| clippy | `cargo clippy -p <crate> --all-targets -- -D warnings` for `arkdeck-provider-arkforge`, `arkdeck-hoststore`, `arkdeck-agentd`, `arkdeck-soak`; the four again for `x86_64-pc-windows-msvc` and `x86_64-unknown-linux-gnu` | exit 0 each (`arkdeck-m4-pr2-clippy-<crate>.log`, `…-clippy-{windows,linux}.log`). The first run flagged `manual_contains` in the new lane test, fixed |
| Crate tests | `cargo test --no-fail-fast -p <crate>` for the same four (after `cargo build -p arkdeck-cli`) | provider-arkforge 21, hoststore 636, soak 4 passed. agentd first failed the Loader-transition start test (its seeded Job had no journal, above); after seeding it, 178 passed (`arkdeck-m4-pr2-test-<crate>.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 (`arkdeck-m4-pr2-sdd.log`) |

No contract input changed.

## CI

- This change: its first run on `dc709dc3e` (run 36195562216) succeeded;
  the run on `587127475` is pending.
- #2223 (the oracle, head `7beec0f3a`): guard run 36192977193 and swift run
  36192977445 both succeeded, with the Swift lane replaying the new oracle
  (swift-tests 7m18s) and the macOS Rust workspace in 11m57s.

Host-process evidence only:

- The ArkForge lane and the Rockchip host are scripted; no `arkforged` runs.
- No device was used, and no installed service was touched.
