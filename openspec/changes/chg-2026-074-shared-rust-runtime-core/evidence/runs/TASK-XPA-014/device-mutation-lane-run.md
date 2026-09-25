# TASK-XPA-014 — one device mutation Job per Target at a time: the Target's mutation lane (M2, macOS, 2026-09-24)

TASK-XPA-014 remains in progress. Base: protected main `0e833256` (#2147). A safety gap S21 found
while porting the workspace patches (`evidence/runs/TASK-XPA-015/workspace-patch-run.md`, "Lane"):
Swift's engine runs a device mutation Job's steps inside `DeviceMutationLaneCoordinator` for its
Target, and the Rust runner had no such lane — `device_run.rs` took no lock, the daemon's
`claim_run` serializes one Job's runs only, and `DeviceHolds::mutation_reservation_guard`
serializes the consumption alone — so two Jobs could change one device at once. Everything here
runs over the shared fake HDC in fixed-root host fixtures; none of it is device evidence,
installed-Runtime activation or GJ acceptance (POL-VERIFY-001, POL-MODE-001).

## What a user sees

Before: a second gesture, port rule, debug HAP, native deployment, screen sequence or mutating
capture on a device another Job was changing ran beside it — each step of either could land
between the other's, and the second's capability consumption could meet the first's use still
pending and fail the Job. Now:

- A device-bound Job whose exact inputs select a step at or above `deviceMutation` waits for its
  Target, behind every such Job that asked first, and runs only once the one before it has
  concluded: its steps, its failure finalization, its terminal state and its settled capability
  use. Nothing of it is dispatched, consumed or written while it waits. Jobs on other Targets,
  and read-only and host-only Jobs, are not held up.
- A Job asked to cancel while it waits is answered at once and closes `cancelled` with nothing
  dispatched or consumed.
- A debug HAP's compensations, whether its run, a later `job.run` or a `job.reconcile` runs them,
  and a cleanup debt's readback and retry wait for the Target in the same way. A reconcile's
  read-only readback does not.

## Swift semantics (read from source; no new oracle)

The coordinator's own contract is pinned by Swift's
`DeviceTargetingContractTests.swift:230-360`; the engine's use of it is not recorded by any
fixture, so it is written here rule by rule from the source:

- **The coordinator.** `ArkDeckCore/DeviceTargeting.swift:641`
  `DeviceMutationLaneCoordinator`, an actor the engine owns one of
  (`RuntimeJobEngine.swift:1212`), in memory only. `withMutationLane(deviceID:requestID:)`
  (`:668-688`) acquires, marks the dispatch, runs the operation, and releases on return and on
  throw.
- **The key.** `deviceID` is `runtime.record.request.target.targetID` (`RuntimeJobEngine.swift:2059`,
  `:3194-3195`): the request's durable Target reference (`DurableTargetReference.targetID`,
  `RuntimeOperationModels.swift:36`) — not the connect key, not the observed identity. The
  request identity is the Job ID.
- **The scope.** `runOwned` (`RuntimeJobEngine.swift:1990`) computes
  `isMutation = effectiveEffect(descriptor, inputs) >= .deviceMutation` (`:2056-2058`;
  `CatalogOperationEffectResolver.effectiveEffect`, `RuntimeOperationCatalogTypes.swift:341`:
  the catalog minimum raised by every step the exact inputs select). `executeAdmittedSteps`
  (`:2254-2290`) runs `executeStepsWithTraceEvidence` — the step loop and a capture's two Trace
  snapshots — inside the lane for a mutation Job (`:2267`) and outside it otherwise.
  `finalizeDebugHAPFailure` (`:3184-3200`) enters the lane again for a debug HAP's compensations,
  reached from `runOwned`'s failure lanes after the step loop's lane was let go of (`:2109`,
  `:2130`, `:2153`), from `runOwned` for a `finalizing` Job (`:2017`) and from `reconcileOwned`
  (`:6208`, `:6300`, `:6635`, `:6788`). Not in any lane: `continueCleanupDebt` (`:5736-5905`,
  readback and retry), `reconcileOwned`'s readbacks (`:6172-`), and what follows the step loop —
  finalization, publication, the terminal transitions, `recordCapabilityOutcome` (`:2168-2243`).
- **The order.** The power assertion (`:2024-2032`) and the `preflight → running` transition
  (`:2037-2054`, journaled, not yet persisted) come first, then the ArkForge prewarm (`:2263`),
  then the lane (`:2267`); the capability is consumed inside it at the first mutation step,
  then the intent.
- **Waiting.** A FIFO queue per device, no deadline, no refusal (`acquire` `:832-886`; `release`
  `:901-918` hands the lane to the first waiter). `DeviceSessionHoldContractTests.swift:11-16`
  records the consequence measured on a device: two captures 0.05 s apart both succeeded, the
  second queued. Cancelling the waiting task leaves the queue with `.cancelled` (`:872-899`), but
  `job.cancel` never cancels the task (`:1946`): `requestCancel` (`:5131-5221`) makes
  `running → cancelRequested` durable at once, and the queued Job drains at its first step
  boundary once it has the lane (`:2476-2477`, `:2170-2197`), after any Trace snapshot.
- **Duplicates.** A request identity already queued on the device is `duplicateRequest`
  (`:855-860`); the same identity active on it and not dispatching re-enters (`:833-840`). Only a
  Job-shaped identity is also refused on other devices (`:841-854`); the engine passes
  `.opaque(jobID)`, which a Job with one Target never meets.
- **HDC lifecycle.** Independent: the interlock (`:1229`, acquired at `:5546-5567`) requires the
  current Jobs to be none, so a Job waiting in a lane — a current Job — blocks a restart; the
  interlock guards admission only (`:1772`, `:1878`), never `job.run`.

## Rust

- `device_lane.rs` (new): `DeviceMutationLanes`, one active holder and a FIFO of waiters per lane
  key under one mutex and condition variable. `enter` refuses a holder that already holds or
  awaits a lane, enters at once or waits, and hands back the guard `MutationLane`; the lane passes
  straight to the first waiter when the guard drops, so nobody overtakes. The guard owns the
  holder's place from the moment it is queued, so a panic while holding or while waiting lets go
  of it; the lock recovers from poisoning, since nothing panics inside an update. An optional
  abandonment predicate, re-read every 20 ms while waiting (a request to cancel has no channel into
  this lock), leaves the queue without the lane.
- `TargetStore` (the Target owner, one per daemon, shared by every HDC composition, the agent run
  threads included) keeps the lanes; `mutation_lane_key` folds a proven post-Flash alias into its
  canonical Target (`TargetDocument::mutation_lane_target`, a chain followed, a cycle refused);
  `enter_mutation_lane`, `mutation_lane_state` and `mutation_lane_queue` expose it.
- `device_run.rs`: `execute_device` enters the Job's lane when `effective_effect` of its inputs
  is at or above `deviceMutation` (holder: the Job ID) before `begin_steps`, and drops it after
  `settle_run`; the run's cancellation abandons the wait (`close_waiting`: the entry transition,
  the durable request, the drain, the held use settled). `conclude_hap_failure` enters it for a
  debug HAP finalizing from `finalizing` (`job.run`, `job.reconcile`), with no abandonment. A lane
  that cannot be entered refuses the run `resourceConflict` with the zero-dispatch proof, nothing
  written. `begin_steps` and the reused `drain` are the old inline code.
- `cleanup_debt_continue.rs`: the continuation enters the Job's Target lane before it reads the
  ledger or the Job (holder: `cleanup-debt:<job>:<residue>:<n>`, unique per call, so repeated
  continuations queue rather than refuse) and refuses before any device work without it.
- `job.reconcile`'s readback (`job_reconcile_device.rs`) is unchanged: read-only, no lane, as in
  Swift.

### Lock order and why nothing deadlocks

A run holds its Job's slot (the daemon's `running`/`reconciling` maps, released before the run
starts; `claim_run` unchanged) → the Target's lane, waited for → the capability reservation
guard while it consumes → each store's own lock inside a call (the journal's manifest lock per
append, the Job store, the capability store, the Target owner's transaction locks, the Artifact
store). The lane comes before any Target transaction: `enter_mutation_lane` reads the lane's key
in a Target transaction of its own that has ended — both Target locks let go of — before the
wait begins, so no Target lock is held while a lane is awaited; no transaction's closure enters
a lane or opens another transaction; a holder takes Target transactions (each facts read) inside
its lane. This holds whether Target transactions refuse a held lock or, as #2147 makes them,
wait for it. The lane's mutex is innermost: held only inside its methods, where nothing is waited
for but its condition variable and the only foreign code is the abandonment predicate, which
locks the run's `RunCancellation` alone. Nothing holding a lane waits for another Job's run or
reconcile slot, another lane (a Job has one Target; `perform_hap_failure_finalization` never
re-enters), or the HDC lifecycle interlock, which is only ever tried (`try_read`/`try_write`). A
`job.run` waiting out a reconcile (#2138) that waits for a lane waits for a holder that waits for
neither.

## Differences from Swift (declared)

- **The key folds aliases.** A request naming a post-Flash alias waits in its canonical Target's
  lane; Swift keys by the name, so a canonical Target and its alias — one device, whose route
  may use the alias's key — would not wait for each other. Strictly more waiting.
- **Entered before the running transition.** Nothing is written while a Job waits; its
  `steps-start` and `startedAtUTC` mark when it entered (Swift: journaled before the wait). A
  crash while waiting leaves the Job at the boundary it was admitted or reconciled to.
- **Held to the settled use.** Swift lets go after the step loop and enters again for a debug
  HAP's finalization, so another Job could run between a failed step and its compensations (a
  second install of the same bundle, then the first's uninstall), and the next Job could consume
  while the previous use was still pending and fail on its lineage. Rust holds the lane through
  the failure finalization, finalization, the terminal state and the capability outcome; the
  Session is published after it, as in Swift.
- **Cancelled while waiting.** The run itself writes the entry transition, the durable request and
  the drain, without the lane and without touching the device (Swift drains once it has the lane,
  taking a capture's Trace snapshots first).
- **Cleanup debt continuations take the lane**, so a readback's verdict cannot go stale before its
  retry. Swift's take none.
- **A holder already holding or awaiting any lane is refused**, zero dispatch (Swift re-enters one
  active on the same device; unreachable in the daemon, which runs one Job once at a time).

## Tests

- `device_lane` unit tests (6): arrival order and hand-off; other keys not held up; one holder,
  one lane; an abandoned waiter leaves without the lane; a panicking holder hands its lane on; a
  waiter panicking in its predicate leaves the queue (no ghost is handed the lane).
- `target_owner` unit test: a Job naming the alias waits in its canonical Target's lane.
- `tests/device_mutation_lane.rs` (new, 4), the pointer oracle's root with a second adopted
  Target and each gesture's first dispatch held on a gate only the test opens; every wait is for
  the fact it names:
  - two gestures on one Target: the second, run while the first is held inside its gesture,
    waits in the lane with no call, no running transition and no use; then the first's use is
    consumed and settled before the second's is consumed, and every call of the first precedes
    every call of the second. The runners read their clock through a probe that, should the
    first Job ever read it after the second was handed the lane — a lane let go of before the
    use was settled, which settling's last clock read would show — holds the first until the
    second's run has ended, so that ordering fails every time rather than on a slow host;
  - gestures on two Targets: the second Target's gesture runs to `succeeded` while the first is
    held;
  - a gesture cancelled while it waits is answered while the first holds the lane, and closes
    `cancelled` (`steps-start`, the durable request, `safe-boundary`, `steps-drained`) with no
    call, intent or use;
  - the lane is free again after a confirmed failure, a panic in the executor (caught as the
    daemon catches it) and a park on an unknown outcome.
- `tests/device_mutation_reconcile.rs` (+3): the recorded scenarios replayed with the Target's
  lane held by the test around one exchange, released once the exchange is seen waiting in the
  queue; every answer and snapshot is still Swift's byte for byte:
  - `reconcileNotInstalled`: the `bm dump` readback ran before the release (Swift reconciles
    unlaned); the finalization's `rm -f` of the staged package only after it;
  - `installed.resume` and the port rule's `create.resume`: no call before the release;
  - `debt.continue`: no call before the release.
- `tests/pointer_input_run.rs`: `concurrent_gestures_cannot_bypass_another_capability_pending_use`
  removed. It ran a second gesture while the first was held inside its gesture and required the
  second to fail on the first's pending use — exactly the overlap the lane now forbids (it would
  wait forever for a first run that waited for it). The one-after-another test replaces it.

## Mutation checks

`scratchpad/s22/mutate.py` over the final tests, every source restored by checksum: 10 of 10 caught,
on the tree before and after the rebase onto #2147 (`/private/tmp/arkdeck-s22-mutations/`).

| Mutation | Where | Caught by |
| --- | --- | --- |
| No lane: every Job runs unlaned | `device_run.rs` `mutation_lane` | the one-after-another test (the second Job's `list targets -v` while the first is held); the cancel test; the held-lane replays of the reconcile and both resumes ("never waited for its Target's lane") |
| Wrong identity: the lane keyed by the requesting Job | `target_owner.rs` `enter_mutation_lane` | the same tests, the debt continuation's replay and the alias test |
| Wrong identity: the Target's name as written, aliases not folded (Swift's key) | `target_owner.rs` `mutation_lane_key` | the alias test (the alias's Job never waits) |
| Wrong identity: one key for every Target | `target_owner.rs` `enter_mutation_lane` | the two-Targets test (the other Target's Job waits behind the first), and every test that reads the Target's own lane |
| A Job that did not succeed keeps its lane (failure and park paths) | `device_run.rs` `execute_device` | the release test (the lane is not free after the confirmed failure) |
| An unwinding holder or waiter keeps its place (no release on panic) | `device_lane.rs` `Drop` | the two panic unit tests and the release test's panic case |
| A waiting Job ignores a request to cancel | `device_run.rs` `execute_device` | the cancel test (the canceller is not answered while the first holds the lane) |
| A cleanup debt continuation takes no lane | `cleanup_debt_continue.rs` | the debt continuation's held-lane replay |
| A debug HAP's failure finalization takes no lane | `device_run.rs` `conclude_hap_failure` | the reconcile's held-lane replay (its `rm -f` sent outside the lane) |
| The lane let go of before the use is settled (Swift's release point) | `device_run.rs` `execute_device` | the one-after-another test, through the clock probe: the second Job consumes while the first's use is pending and fails on its lineage |

## Local targeted checks

With `CARGO_BUILD_JOBS=2` and the target `/private/tmp/arkdeck-1330-rust-target` (no other tree
builds into it), on the tree rebased onto #2147; logs are `/private/tmp/arkdeck-s22-*.log`.

| Check | Command | Exit | Log |
|---|---|---|---|
| Format | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | `arkdeck-s22-fmt.log` |
| Lints | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` | 0 | `arkdeck-s22-clippy.log` |
| Tests | `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --no-fail-fast`: 80 targets, 692 passed, 0 failed, the 14 existing ignored (`device_mutation_lane` 4, `device_mutation_reconcile` 17, `pointer_input_run` 8, the hoststore unit tests 296 with the lane's and the alias's, and #2147's `overlapping_transactions_wait_for_each_other`) | 0 | `arkdeck-s22-tests.log` |
| The same before the rebase | as above, on `72fd46b6`: 80 targets, 691 passed, 0 failed, the 14 existing ignored | 0 | `arkdeck-s22-tests-prerebase.log` |
| Mutations | `scratchpad/s22/mutate.py`, every source restored by checksum | 10/10 caught, before and after the rebase | `/private/tmp/arkdeck-s22-mutations/` |
| SDD | `sh scripts/check-sdd.sh` | 0 | `arkdeck-s22-check-sdd.log` |

No fake HDC, daemon or root of these tests was left behind or running: the installed agentd and
its HDC server, which no test touches, were the only such processes. Not run:
`generate-contract.py --check` and `check-contracts.py`, as no contract input changed (no
schema, corpus, ControlFrames or CLI argv); `check-corpus-replay.py`, as the isolated daemon
admits no device mutation (it has no mutation owner; see `screen-sequence-run-run.md`) and the
read-only oracles it replays take no lane; Swift, the App, signing, the installed service and
real devices, none of which this change touches.

## CI

PR #2149, head `7e8085010`, merged as `93feeb0f8`: Agent PR 36034252376, SDD Guard
36034252254 (`guard`, `ds-tokens`) and Swift CI 36034252893 all succeeded (plan; Rust
host-independent checks; Rust workspace on ubuntu-latest, windows-latest and macos-26; `swift`
aggregate; swift-tests, ds-interactions and app-build skipped by the plan).

## Not in this slice

- An engine-level Swift oracle of two contending Jobs was not recorded: the coordinator's contract
  test pins its semantics and no fixture records the engine's use of it; the rules above cite the
  source. Recording one would take a Swift slot and a gated fake.
- Found while writing this slice and fixed apart by #2147: a Target owner transaction refused
  (`Target storage is being updated`) when another thread of the same process held its lock, so
  two device Jobs on different Targets reading their facts at once, or a run beside `target.list`,
  could fail a step or a lane entry. #2147 makes each transaction wait for the locks, as Swift's
  blocking `flock` does; the lock order above holds under either behaviour.
