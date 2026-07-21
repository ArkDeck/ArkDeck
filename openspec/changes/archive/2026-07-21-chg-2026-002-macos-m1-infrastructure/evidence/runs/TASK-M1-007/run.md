# TASK-M1-007 implementation run

## Run identity

- Task: `TASK-M1-007`
- Change: `CHG-2026-002-macos-m1-infrastructure@r7`
- Core baseline: `CORE-2.0.0`
- Base revision: `8c1311b8be74c0393c2d490f72c63ffa39b3cdb6`
- Branch: `agent/task-m1-007`
- Run window: `2026-07-19T11:22:52Z`–`2026-07-20T01:32:17Z`
  (`2026-07-19T19:22:52+0800`–`2026-07-20T09:32:17+0800`, Asia/Shanghai)
- Evidence class: `contract`; deterministic synthetic identity/connectKey values only
- Environment: macOS `26.5.2` (`25F84`), arm64; Swift `6.3.3`; SwiftPM; swift-format
  `6.3.0`; headless shell and local temporary directories
- Hardware/network classification: no real HDC, device, network, GUI, system authorization,
  destructive operation, or real-hardware evidence. The dedicated suites import no Process or
  Network API and launch no child process.

## Locked/readiness inputs

| Input | SHA-256 |
| --- | --- |
| `openspec/constitution.md` | `38c8e1613f251706ebb74019840bbf42a82b11720dd4efc44966ec451c793418` |
| `openspec/governance/enforcement.md` | `971a075f0eda6ccb431deea25a94038c3c8824d3727ae5b570bfd6fcc1f91fdf` |
| `openspec/verification/policy.md` | `3552989f7636bdf2ecf75c16c1291b33b8d420ae40bba86530d942947eacab41` |
| `openspec/baselines/CORE-2.0.0.yaml` | `07227da529608f26dcbbc8843f1623278b51cb3036cd93e1e9ed4af6f8880aa6` |
| `openspec/specs/device-targeting-auth/spec.md` | `f51c32cac9e226de0141cb08a084cccb5078f66035978557b7f57ddb878ec2ed` |
| `openspec/verification/acceptance-cases.yaml` | `a8b4e9c0e9fd0bdeb369db18261a8be31324151a68fa710a30e29183b50a476d` |
| `openspec/contracts/journal-event.schema.json` | `21df4c44b704d249c2228384b075a331346a4731d3f0b90f66ec8092dded8b19` |
| `openspec/contracts/manifest.schema.json` | `52be768697e75fc98a00a386345162af2e1a8ca3607b86f755adb766cf0ad489` |
| change `proposal.md` | `5111a5867110c72601aae018cd4cf335977c69f48028a1df0ad2d467c3ee7752` |
| change `tasks.md` (pre-run) | `0c103a39a23a3a6e1cfbe410b8ab94dec1e884e244ea76e74407622450434973` |
| change `verification.md` | `2b95572c2b23d741102b34fe0016973be92b7337d361a55599e7620feb110317` |
| change `design.md` | `b40e832fbd4f174ab28cc92e7fc6b8f612b955a473fb7c0b13dd746971be47bd` |
| change `scope.yaml` | `916524f3b789405be5fcb61cd671a33f2dd2bd8d9531dbe99484bf8a850840b2` |
| CHG-2026-014 `proposal.md` | `f30db1977a826e6a0c6e79d53aae0d015dd196048ac9857f42fd499f85278578` |
| CHG-2026-014 `tasks.md` | `4817ebaa76c520cb54bbeab2ff0be6b558ae6e253b7ae1af04d52232f576d39b` |
| `Packages/ArkDeckKit/Package.swift` | `4e34df76cfe88f3cd32bbf01d60e66b2240217828677a9fb962d5bc3381348f4` |
| Core `WorkflowStep.swift` | `db4fdbc25b69130bd70d26654d089bec653d30ef6edafb5cb05b972b6afde354` |
| Storage `JournalEvent.swift` | `f0f014b894e2f92233cf4cc22a944ca0f9a86a5712018c6f141c88d2d4fad4a9` |
| Storage `DurableFiles.swift` | `c37cc5daf2db60645ea1603c488b7bc33e9b5d8ac9dbaaaec56e841e8c21031f` |
| Storage `SessionAudit.swift` | `c2bcdf1d48f6fd22a83ca1731271fb4d08e6de70eecb1402438e8f5a29f3833b` |
| Storage `SessionManifest.swift` | `a0737c817fc40fbd85d9a185dfca52c314093509c1a46672abb72a3c6c697051` |

## Output hashes

| Deliverable | SHA-256 |
| --- | --- |
| `Sources/ArkDeckCore/DeviceTargeting.swift` | `9f56a0b937acaba1950100cb6275ecf5a002065faf3c58ee5e19a675790d6759` |
| `Sources/ArkDeckOpenHarmony/HDCDeviceCommand.swift` | `28f6b259a7e9b29cb3d8e0bac09d860b8355b43f231770424265275953c48ccd` |
| `Sources/ArkDeckWorkflows/DeviceBindingJournalAdapter.swift` | `a2c9e151a4ec9bcb34c49e304fa3c50ad2bc9828fe2d5b6fed7d7f8027e6f8cf` |
| `Tests/ArkDeckCoreTests/DeviceTargetingContractTests.swift` | `eb2bb38380d032379488fdf343b86acea442e82dbd4ec2940051ba629dc325fd` |
| `Tests/ArkDeckContractTests/DeviceBindingContractTests.swift` | `f9cc37ec86d9f98cd1b0f31f96aa90a260c5b880c55ed3adc52e509d32146c5e` |

Paths in this table are relative to `Packages/ArkDeckKit/`.

## Work completed and measured results

- Implemented validated immutable `OriginalTargetSnapshot`, revisioned
  `CurrentDeviceBinding`, monotonic `DeviceBindingHistory`, unforgeable package-level durable
  binding receipts, canonical identity hashes, and a manifest-compatible original-target/binding
  history projection. Reopen rejects a caller-supplied history unless every revision is backed by
  an exact locked `bindingConfirmed` event.
- Implemented Core-owned USB policy. The exhaustive four-boolean threshold matrix evaluated 16
  combinations and allowed exactly 1; zero/multiple candidates, missing serial/fingerprint/
  topology/mode evidence, and profile relaxation all remained awaiting confirmation. A profile
  can require more evidence or manual confirmation but cannot make a failed Core vector eligible.
- Implemented TCP/UART fail-closed recovery. TCP retains the replacement candidate identity for
  diff presentation and always requires explicit confirmation after disconnect; an endpoint not
  explicitly added is separately rejected. UART node/adapter recreation never auto-resumes.
- Implemented exact typed HDC argv materialization from the same `WorkflowStep` durably written as
  `stepIntent`; callers cannot provide a separate argument array. The closed mapping currently
  accepts only the registered reboot step and derives `shell reboot [targetMode]`. A read-only
  `probeDevice` step cannot carry or dispatch `shell reboot`, and the journal records the exact
  reboot kind/arguments used by the successful synthetic dispatch.
- Bound every dispatch to journal-backed current authority. The workflow adapter mints an intent
  only after the exact typed `stepIntent` append, rejects intents not minted by that adapter,
  reopens the locked journal before every persistence/dispatch authority decision, and derives the
  current state, sequence, identity disposition, and consumed intent IDs from durable events rather
  than cached actor state. Authority is checked again after acquiring the coordinator dispatch
  fence and immediately before materialization. A revision-1 intent persisted before a revision-2
  rebind was rejected with dispatch count 0; revision 2 then produced exactly one synthetic
  executor-seam receipt. A second in-memory intent that already had a confirmed durable outcome and
  a `succeeded` journal state was rejected before dispatcher entry even though lane release had not
  yet been called; terminal-window dispatch count was 0.
- Added an explicit unresolved-mutation recovery barrier to rebind, mutation-intent persistence,
  mutation dispatch, and the final lane-acquisition/dispatch authority checks. An outstanding
  mutation intent is treated as outcome-uncertain once this adapter has entered its dispatcher, or
  whenever reopen cannot prove that the outstanding intent was never dispatched. In either case
  the adapter durably enters `waitingForRecovery`, rejects rebind and further mutation before their
  journal/device seams, and does not migrate or release the original device lease. Locally minted
  intents that are durably written but have not entered dispatch remain distinguishable and do not
  incorrectly block a valid pre-dispatch rebind. The remediation scenario dispatched once on
  synthetic device A without writing `stepOutcome`; rebind confirmations stayed at 1, new mutation
  intents stayed at 0, current revision stayed at 1, a second A-bound Job remained
  `queued(deviceLaneBusy)`, and all additional executor dispatch counts stayed 0.
- Made durable rebind consume the Core `DeviceRebindPolicy` decision before any candidate or
  confirmation append. Weak USB evidence cannot be persisted under `corePolicy`; TCP/UART reject
  `corePolicy` bindings and require an explicit user-confirmed candidate (with TCP explicit-add
  evidence). Three policy-bypass vectors produced zero durable confirmations; an explicit user TCP
  selection produced one valid revision-2 confirmation.
- Implemented durable binding/rebind/ambiguity adapters using only the locked
  `bindingCandidate`/`bindingConfirmed`/`bindingRejected`, `stepIntent`, state-transition and
  reconcile event families plus the generic Session audit seam. Initial target, old/new
  connectKey, evidence, confirmation, revision and manifest binding history survive reopen.
- Fault injection failed the `bindingConfirmed` append after candidate and audit intent
  durability. Durable receipt count remained 0 and reopen returned
  `incompleteDurableBindingChain(1)` rather than treating the candidate/audit intent as a binding.
  A separate rebind fault left one stale revision-2 intent; retrying with a second candidate
  durably confirmed revision 2, and reopen selected only the intent whose binding and candidate
  chain exactly matched that confirmation.
- Identity disposition is now adapter-owned and restored from the locked journal chain rather than
  accepted from a command caller. Persisting two rejected candidates moves the adapter to durable
  `awaitingRebindConfirmation`; both a pre-existing mutation intent and a newly requested mutation
  fail closed before dispatch, including after reopen. Only a policy-authorized, durably confirmed
  user selection plus the recorded state transitions clears the ambiguity and permits a new intent.
- Integrated the process-shared per-device mutation lane into the actual journal-backed dispatch
  seam. The lane key is the Core-defined SHA-256 projection of the current durable binding's
  nonempty stable device serial after surrounding-whitespace removal and Unicode canonical
  normalization, never immutable original identity, caller-chosen `targetID`, endpoint, mode, or
  arbitrary observation attributes. `SERIAL-A` and a whitespace-padded `SERIAL-A` mapped to one
  lane. Because the accepted identity contract permits a serialless user-confirmed snapshot, that
  snapshot remains valid binding data but mutation preflight now checks the current binding and
  fails before `stepIntent` persistence: durable mutation intents and outstanding intents were both
  0. The complete identity snapshot remains the exact durable binding/audit hash and is not
  weakened by this separate coordination projection.
- Elevated lane ownership from one dispatcher call to the exclusive Job. The adapter acquires one
  lease on the Job's first mutation and retains it after the command returns, including command
  failure, until a lifecycle call reopens the locked journal and proves a terminal state with no
  torn tail, outstanding intent, unknown outcome, or recovery requirement. A caller cannot release
  a running Job's lane by supplying state; early release returned `mutationJobNotDurablyTerminal`.
  Coordinator leases now carry an adapter-owner generation plus a global dispatch-in-progress
  fence. A reopened adapter may adopt the same Job only while no command is executing; adoption
  invalidates the old owner, and the superseded owner cannot enter the dispatcher. Reopen identity
  is the structured enum case `job(sessionID:jobID:)`; the two fields are compared independently
  and cannot collide with each other or with the public opaque-request namespace. A structured Job
  identity is globally unique across physical-device lanes, and terminal reopen locates the actual
  active lease by that identity rather than guessing its device key.
- The actual seam test ran two independent Jobs with distinct target aliases and identity snapshots
  that differed by `mode` (`normal`/`updater`) and raw serial whitespace while retaining the same
  normalized serial, daemon fingerprint, USB topology, and connectKey. Their complete identity
  hashes differed but their stable physical key was identical. The Job identifiers were the
  adversarial pairs `(sessionID: "a:b", jobID: "c")` and `(sessionID: "a", jobID: "b:c")`:
  delimiter concatenation collided once as `a:b:c`, while structured request identities had zero
  collisions. Job B was started after Job A's first command returned and A's journal remained
  `running`; B was still observably queued as `deviceLaneBusy` and dispatcher start count remained
  1. Job A was then destroyed; a reopened adapter with no local lease adopted and released the
  coordinator's existing Job lease only after the durable `succeeded` lifecycle. Job B then ran;
  maximum executor concurrency was 1 and the final lane was empty.
- The identity-changing seam first dispatched Job A on physical serial A and durably recorded its
  confirmed `stepOutcome` while the exclusive Job-lifetime lease remained on A, then durably
  user-confirmed a TCP rebind to physical serial B.
  Job B had been bound to serial B since creation and entered B's lane first. Job A released its
  stale A lease, queued on B as `deviceLaneBusy`, and did not enter the dispatcher until Job B was
  durably terminal and released. The stale A-lane state was absent after migration, both current
  durable bindings projected to the same B key, and maximum current-device concurrency was 1. The
  original Job A adapter was then destroyed; a reopened adapter located and released its migrated
  B lease without relying on original serial A.
- A disconnect observation with zero candidates is no longer a no-op. The adapter immediately
  closes its identity gate, durably transitions `running -> waitingForDevice`, records a generic
  audit outcome, and restores the unconfirmed disposition after reopen. USB, TCP and UART vectors
  each rejected a mutation intent created before disconnect; combined executor dispatch count was 0.
- Implemented the per-device mutation lane actor. The property run exercised 96 operations over
  4 synthetic devices: same-device maximum was 1, cross-device overall maximum was 4, one queued
  cancellation never entered its operation, a thrown operation released its lane, and final
  active/queued counts were both 0. A separate ownership handoff proved that adoption is rejected
  while dispatch is active, succeeds afterward, invalidates the old owner, rejects one Job identity
  acquiring a second physical-device lane, and remains releasable without a caller-supplied key.
- Replaced fixed-count `Task.yield()` queue polling in both actual dispatch-seam tests with a
  coordinator-owned checked-continuation observer. Actor serialization makes the state check and
  observer registration atomic, and each active/queued/cancel/release transition resumes matching
  observers. The dedicated suite therefore waits on the exact `queued(deviceLaneBusy)` event rather
  than scheduler timing; no fixed-yield loop remains.
- Dedicated dispatch counters: real HDC `0`, real device `0`, network `0`, external process `0`,
  destructive dispatch `0`. Successful command results are in-memory synthetic executor seam
  receipts, not Process/device dispatches.
- Dedicated temporary Session roots were local synthetic data and were removed by test cleanup.
  Reopen was exercised for revision 2, immutable original target, ambiguity audit, confirmation
  failure, active Job-lease takeover, identity-migrated lease lookup, and terminal cleanup.

## Commands and results

| Command | Result |
| --- | --- |
| `xcrun swift-format lint --strict <five TASK-M1-007 Swift files>` | PASS, 0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter DeviceTargetingContractTests` | PASS, 6 tests / 0 failures; USB matrix 16/1, normalized serial equality, owner-generation handoff, and lane property 96/max 1 |
| `swift test --package-path Packages/ArkDeckKit --filter DeviceBindingContractTests` | PASS, 10 tests / 0 failures; unresolved post-dispatch mutation outcome enters `waitingForRecovery`, blocks rebind/new mutation, retains A's lane and queues a competing A Job; identity-changing A-to-B rebind after confirmed outcome migrates the retained lease, queues behind B's original Job with current-device max 1, and reopens to release the migrated B lease; both queue assertions use checked-continuation state signals; terminal-window dispatch 0, reopened terminal cleanup, serialless pre-intent rejection, actual Job-lifetime serialization across aliases/modes/raw serial whitespace and colliding delimiter-form Job IDs, zero-candidate disconnect, stale-revision, typed-step, transport-policy, ambiguity and fault/reopen |
| `swift test --package-path Packages/ArkDeckKit` | PASS, 249 tests / 0 failures / 1 existing opt-in manual sleep/wake skip |
| `ARKDECK_PYTHON=/opt/homebrew/anaconda3/bin/python3 scripts/check-sdd.sh` | PASS, 0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | PASS |
| allowed-path and import/process/network/real-HDC static scan | PASS; exactly five task Swift deliverables plus this run and the permitted `tasks.md` reference; production imports are only Core/CryptoKit/Foundation/OpenHarmony/Storage |

The first unqualified `scripts/check-sdd.sh` attempt stopped before validation because PATH
`python3` lacked PyYAML. The repository's `ARKDECK_PYTHON` override was then pointed at the
already-installed Anaconda Python with PyYAML `6.0`; the checker completed with the PASS result
above. No dependency was installed and no source result was reclassified.

One sandboxed dedicated-test rerun stopped before manifest compilation because the existing
SwiftPM/Clang module cache was outside the workspace write boundary. The exact test command was
rerun with controlled access to those existing cache directories and passed 6/0; this was an
environment precondition failure, not a source or test assertion failure, and installed nothing.

One intermediate identity-migration test revision attempted reopen while the original adapter's
Session audit writer was intentionally still live. Storage rejected it with
`Session audit already has an active writer`; the test was corrected to destroy the original
adapter before reopen, matching the supported takeover lifecycle, and the final dedicated run
passed. No product assertion or safety gate was weakened.

The first unresolved-outcome remediation run executed all 10 binding tests and reported two test
fixture/expectation failures: the zero-candidate reopen assertion still expected the older identity
error instead of the now-required recovery error, and the ambiguity cleanup used an unregistered
synthetic outcome-result string. The test was updated to assert the durable
`waitingForRecovery` state on reopen and to use the locked `failed` outcome vocabulary. The exact
dedicated command was rerun at 10/0 before the 249-test full-package PASS. These were test-contract
corrections after the recovery barrier behaved fail-closed; no production gate was relaxed.

The required full-package regression runs existing fake-HDC and process-fixture child tests. Those
results remain pre-existing fake/contract regression evidence and are not counted as
TASK-M1-007 evidence. The two dedicated TASK-M1-007 suites themselves launch no child and import
no Process/Network implementation.

## Acceptance conclusions

| Test ID | Evidence | Conclusion |
| --- | --- | --- |
| `TEST-AC-DEV-001-01` | value/history Codable round-trip plus durable initial target/revision 1 and revision 2 reopen; later selection is a distinct immutable value | PASS (`contract`) |
| `TEST-AC-DEV-002-01` | revision-1 typed intent persisted, revision 2 journal/audit confirmed, stale intent rejected by current durable authority with dispatch 0; new intent dispatches exact `-t synthetic-usb-updater` | PASS (`contract`) |
| `TEST-AC-DEV-002-02` | missing/cross-device/mismatched durable-intent vectors plus read-only `probeDevice`/`shell reboot` mismatch; all reject before executor and the successful argv is derived from the exact journaled reboot step | PASS (`contract`) |
| `TEST-AC-DEV-003-01` | complete USB Core threshold is the sole eligible truth-table row; subsequent command uses only durable revision 2 | PASS (`contract`) |
| `TEST-AC-DEV-003-02` | missing USB evidence and multi-candidate vectors remain awaiting; the durable adapter rejects weak `corePolicy` persistence before candidate/confirmation append | PASS (`contract`) |
| `TEST-AC-DEV-004-01` | Core bindings cannot encode TCP `corePolicy`; durable rebind requires explicit endpoint-add plus exact user-confirmed candidate; TCP disconnect with zero candidates durably enters `waitingForDevice` and old-intent dispatch is 0 | PASS (`contract`) |
| `TEST-AC-DEV-005-01` | Core bindings cannot encode UART `corePolicy`; rebuilt node/adapter remains explicit-confirmation-only; UART disconnect with zero candidates durably enters `waitingForDevice` and old-intent dispatch is 0 | PASS (`contract`) |
| `TEST-AC-DEV-006-01` | two ambiguous candidates and awaiting state are durable; adapter-derived identity blocks both an already-persisted and new mutation, including after reopen; only a policy-authorized durable rebind clears ambiguity; confirmation fault mints no receipt | PASS (`contract`) |
| `TEST-AC-DEV-008-01` | 96-operation coordinator property plus owner-generation handoff and actual journal-backed dispatch seams: a mutation dispatched without durable outcome enters `waitingForRecovery`, rejects rebind/new mutation, retains serial A and leaves another A Job queued; after a confirmed outcome, a retained serial-A lease migrates on durable identity-changing rebind and queues behind the Job originally bound to serial B, with stale A lane absent and current-device max 1; exact queue events use actor/continuation signals rather than yield polling; normal/updater snapshots with raw serial whitespace map to one key; delimiter-colliding `(a:b,c)`/`(a,b:c)` Jobs remain distinct and B queues after A's command returns; terminal journal/outcome blocks cached-intent dispatch before explicit release; serialless current binding persists no mutation intent; after Job A is destroyed, reopened A locates/adopts/releases its terminal lease, then queued Job B runs; final lane empty | PASS (`contract`) |

All nine conclusions bind to the same working-tree implementation represented by the five output
hashes above. They do not satisfy `AC-DEV-007-01`, M1-006, `MAC-M1-HDC-001`, M1-008, any platform
conformance case, or any hardware/support/release claim.

## Deviations and residual risk

- No Core Requirement, AC, contract/schema, baseline, integration/platform profile, fixture,
  package dependency or existing source file changed. No ADR was required.
- This task intentionally stops at pure value/policy/actor, locked-storage adapter and synthetic
  executor-seam contracts. Wiring the typed command to a real HDC/Process adapter remains outside
  scope and requires independent consumer/integration readiness.
- A future product Job lifecycle owner must invoke
  `releaseExclusiveMutationLaneAfterDurableTerminal()` after writing its terminal journal path.
  Omitting that call retains the lease and fails closed by blocking later mutation Jobs; it cannot
  create a second same-device lane.
- An unresolved mutation deliberately leaves the original lease held and normal dispatch disabled.
  Progress requires the existing locked reconcile or audited-abandonment workflow to establish a
  durable outcome/safe boundary and eventually reach an authorized terminal release; this adapter
  does not invent a local recovery bypass.
- The full suite's one skip is the pre-existing manual production sleep/wake observation harness;
  it is unrelated to the nine contract AC and was not reclassified.
- This run does not mark the task `done`. `ready -> done` remains a separate status-only PR after
  maintainer review of the implementation and evidence.
