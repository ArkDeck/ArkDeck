# The missing Session producer, and the half of it this change delivers — 2026-09-08

- Task: TASK-SVC-002
- Base: protected `main` `abc24e1d` (#1786).
- Design: [session-publication-scope-review.md](session-publication-scope-review.md),
  the reviewed and merged specification for exactly this work.
- Preceding record: [session-unaccounted-diagnosis-2026-09-08.md](session-unaccounted-diagnosis-2026-09-08.md),
  which made the blocked surface diagnosable and explicitly did not publish anything.

## What was verified before writing anything

`SessionStorageTerminalFinalizer` had exactly one non-test declaration — its own
— and its only callers were `SessionArtifactStorageContractTests`:

```
$ grep -rn "SessionStorageTerminalFinalizer" Packages/ArkDeckKit/Sources Packages/ArkDeckKit/Tests
Sources/ArkDeckStorage/HostStorage.swift:806:  package struct SessionStorageTerminalFinalizer
Sources/ArkDeckStorage/HostStorage.swift:1190:  (doc comment)
Tests/ArkDeckContractTests/SessionArtifactStorageContractTests.swift: 5 construction sites
```

`RuntimeJobEngine` had no reference to `StorageClaim`, `HostStorageCoordinator`,
`SessionStore`, `SessionLayout` or any Sessions root at all; its `finalize-session`
step is a no-op that appends one timeline line, and `publishFinalizeArtifacts`
writes only Runtime Artifacts. `SessionStorageApplicationRuntime.production` had
zero callers. So the seam existed end to end and nothing drove it.

## What this change delivers

**A production writer, wired into the one funnel every terminal Job passes
through.** `RuntimeJobEngine.statusAndReleaseTerminalRuntime` — the single point
all seventeen terminal returns go through, after the capability outcome is
settled and before the runtime is released — now publishes the Job's Session.

The publication itself is `RuntimeSessionPublicationWriter` in
`Sources/ArkDeckWorkflows/RuntimeSessionPublication.swift`, and it runs the
reviewed phases in the reviewed order:

1. Reserve metadata and finalization headroom from a host storage coordinator
   before anything is created. An unavailable claim persists `awaitingStorage`
   and writes nothing.
2. Compose the Manifest proposal from the Job's own record and Journal, before
   a byte exists under the Sessions root. A Job whose facts cannot render the
   current contract never creates a Session directory: the claim is cancelled
   unbound and the failure is recorded with its exact reason.
3. Freeze `checkpointSeal` over the authoritative record and its synced Journal
   prefix, then set `proposal`, and write the fixed owner-only auxiliary file
   `session-manifest.proposal.json` in the existing Job directory.
4. Append the last `finalized` Journal record, referring to the proposal hash.
   The Manifest does not hash the complete Journal — that would be a cycle —
   so `journalSeal` binds it separately.
5. Create the Session, copy identical Journal bytes, publish and read back the
   Manifest through the existing `SessionStorageTerminalFinalizer`, register
   with the same configured owner, read the exact catalog entry, persist the
   receipt, and only then release the claim.

`HostStorageCoordinator.performWithClaim` could not be used: it releases the
claim as soon as its finalizer returns, which would give the headroom back
before registration. `beginTerminalFinalization(claimID:disposition:)` was added
beside it so the publication can stop optional writes and pin its disposition
without releasing; release still requires the minted receipt through the
existing `completeRecoveredFinalization`.

**A durable ownership marker.** `RuntimeJobRecord.sessionPublicationRecord`
carries the reviewed record: sessionId, catalogDigest, policyGeneration, root
(path/device/inode/volumeIdentity, never in public Job output), the derived
`yyyy/mm/<sessionId>` relative path, the opened Session's device/inode, a
nonempty per-volume claim list, phase, checkpointSeal, proposal, journalSeal,
receipt and failure. Absence is the only thing that means `unavailable`, and
absence is never repaired into ownership.

**One observable result.** `sessionPublication` is a required, non-null,
four-key object on every Job status and summary — `state`, `manifestSha256`,
`catalogGeneration`, `reasonCode`, nullable values as explicit `null` — with
the state/reason table from the scope review. Its single validator lives in
`Sources/ArkDeckCore/RuntimeSessionPublicationContract.swift`, package-only, and
is used by the exact Job decoder (`CLIJobResources`), the run/wait/watch
consumer (`CLIJobEvents`) and the Agent's compact projection
(`CLIAgentExecutions`). `AgentDaemon.executionResultProjection` adds the same
fact to its compact job object, making seven keys.

## Verification

All commands from the worktree root, on the rebased branch.

| Command | Result |
| --- | --- |
| `swift build --package-path Packages/ArkDeckKit` | exit 0 |
| `swift test --package-path Packages/ArkDeckKit --filter RuntimeSessionPublicationContractTests` | 9 tests, 0 failures |
| `swift test … --filter 'SessionArtifactStorageContractTests\|SessionResourceContractTests\|SessionExportContractTests\|SessionCleanupContractTests\|CurrentDurableStorageContractTests\|RuntimeStorageResourceContractTests\|SessionSettingsContractTests'` | 109 tests, 0 failures |
| `swift test … --filter 'CLIMachineContractTests\|ControlMethodSchemaContractTests\|ControlMethodReachabilityContractTests\|AgentDaemonContractTests\|AgentRuntimeExecutorContractTests'` | 139 tests, 1 skipped, 1 ad-hoc-invocation failure (below) |
| `swift test … --filter CLIWorkspaceContinuationContractTests` | 6 tests, 0 failures |
| `ARKDECK_CONTROL_FRAME_LOG=<dir> swift test … --filter 'RuntimeSessionPublicationContractTests\|JobReadResourcesContractTests\|AgentRuntimeExecutorContractTests\|ControlMethodReachabilityContractTests\|ControlMethodSchemaContractTests\|CLIMachineContractTests'` | 82 tests, 0 failures — including `testFramesRecordedByThisRunValidate` against the newly derived schemas |
| `python3 scripts/check_pr_paths.py --repo-root . --preflight --base-revision origin/main --head-revision HEAD` | exit 0, `TASK-SVC-002` |

### The unified local planner

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`
selected the common, swift, app, design-system and rust lanes.

- Common checks, `check-sdd.sh`, the Catalog generator check and the
  design-system tests: passed.
- Swift lane, `run-test-lane.sh full`: `exitCode=0; testCount=2500` for the
  parallel group, plus the two serialized groups (`exitCode=0`, 1 and 5 tests).
  `AgentDaemonContractTests.testHilogAnalyzerRunsMultipleJobsInOneDaemonSession`
  passes here. Under a plain ad-hoc `swift test --filter` in the same worktree
  it fails with `analyzer.toolIdentityDrift` — identically with every change of
  this branch stashed, so that failure belongs to the ad-hoc invocation's
  products directory, not to this change.
- App lane, `run-xcodebuild.sh`: `** TEST BUILD SUCCEEDED **`.
- Rust lane: `generate-contract.py --check`, `cargo fmt`, `cargo fetch
  --locked` and `cargo clippy --workspace --all-targets -- -D warnings` all
  passed. `cargo test --workspace` then failed on two `corpus_parity` tests —
  see below. The planner stops on first failure, so the lane's remaining
  members did not run in that invocation.

### The Rust corpus pin, which this change cannot update

```
---- source_schema_and_corpus_files_match_the_selected_input_manifest ----
contract input file drift:
  Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/agent.resume.jsonl
---- all_methods_and_recorded_shapes_in_the_input_manifest_replay_through_rust ----
recorded shape counts: agent.resume  left {errors 4, requests 8} right {errors 3, requests 7}
```

`spec/baselines/swift-single-v1.json` pins every corpus and schema file to a
protected-`main` commit (currently `50dd15e9`), and
`rust/scripts/generate-contract.py --write` regenerates it only *from* such a
commit. Any Swift change that re-derives the corpus therefore disagrees with
the pin until the Rust side re-aligns after merge. That is not new: #1773
changed the corpus under this same gate, and #1778 (TASK-XPA-002) re-pinned
afterwards with the subject "realign contract baseline, CRLF grammar and rust
CI lane". Neither `spec/baselines/**` nor `rust/**` is in TASK-SVC-002's
Allowed paths, and the pin is not supposed to be written from a branch, so this
change does not touch either.

The substance was verified instead through the sanctioned candidate view:
`rust/scripts/check-contracts.py` materializes published and candidate input
views and runs the current Rust implementation against both. Its **candidate
view** — this branch's schemas and corpus — passed `cargo clippy --workspace
--all-targets --locked -- -D warnings`, `cargo test --workspace --locked`
(including all eight `corpus_parity` tests) and `cargo build --workspace
--bins --locked`. The script as a whole still exits non-zero here because
`check-readonly.py` needs `jsonschema`, which this host's `.venv-sdd` does not
have; that step fails identically for the **published** view, so it is a local
environment gap and not a property of this change.

**Handoff:** after this merges, TASK-XPA-002 needs to re-run
`python3 rust/scripts/generate-contract.py --write --baseline-revision <merged main commit>`
so `cargo test --workspace` is green on the checkout again.

### What the new suite actually proves

`RuntimeSessionPublicationContractTests` uses the production Engine, the
production Artifact store, the configured `RuntimeSessionStorageStore` owner and
the real writer. It runs a real host-only Job (`analyzer.extract-crash-signature@1`)
through `submit` and `run`; no prebuilt finalized fixture is handed to the
catalog anywhere in it.

- The published Session exists under `<root>/2026/07/session-<jobId>/` with a
  `manifest.json`, its `journal.jsonl` is byte-identical to the Job's own, the
  catalog holds exactly one entry, and `job.status` reports `published` with the
  manifest digest and canonical decimal generation the catalog actually has.
- `session list`, `session show`, `session export preview` and
  `session export apply` all succeed against that Session through the same
  owner. This is the complete `Job → Session → exact finalized export` loop
  the scope review names, at the owner boundary.
- The control plane publishes the receipt on `job.status`, `job.show`,
  `job.result`, `job.list` and `job.run`, validated by the same closed contract.
- An engine composed with **no** writer reports `unavailable` /
  `noCurrentPublicationRecord` and leaves the Sessions root empty. There is no
  fixture writer to fall back to.
- A pre-existing manifest-less Session, in the exact shape the reference host
  carries, keeps its bytes, its mtimes to the nanosecond and its missing
  manifest while a new Session is published beside it. It is not adopted, not
  repaired, not moved and not registered; it stays `unaccountedSessionCount: 1`.
- Repeating a publication returns the same receipt and does not advance the
  catalog generation.
- A `recovered` Job and an `outcomeUnknown` Job are both refused with
  `failed`/`contractViolation` and no Session is created.
- The wire contract refuses: an unrecorded key, a missing key, a published
  receipt that also carries a reason, a forged digest, a non-canonical decimal
  generation, `published` with no receipt, `publicationUncertain` reported as a
  confirmed failure, a failure reason reported as pending, and an unpublished
  state.

### Schemas and corpus

The twelve method shapes were re-derived from frames a real contract-test run
recorded (`ARKDECK_CONTROL_FRAME_LOG` over the whole `ArkDeckContractTests`
target, 1 371 frames, all 96 methods), then narrowed to the ten files that
actually changed:

```
python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py \
  --derive-method-schemas <frames>
```

`spec/control/methods/{job.list,job.reconcile,job.result,job.run,job.show,job.status,agent.run,agent.status,agent.resume,human-action.resume}.json`
and the matching corpus files. Every other method's schema and corpus was
restored, so this change churns nothing it did not alter.

## What is not delivered, and why

This is a coherent subset of the reviewed slice. It is a complete behaviour loop
on its own — a Job becomes a Session and that Session is listable, showable and
exportable — but the following parts of the scope review are **not** here.

1. **Manifest execution evidence (`runtimeAuthority`, `recoveryEpoch`).** The
   scope review's "Current Manifest execution evidence" section adds a required
   nullable `runtimeAuthority` with fourteen fields, the `completeOverwriteRecovery`
   six-field context and the nineteen-field `recoveryEpoch`. None of it is
   implemented. The consequence is exact and fail-closed: the Manifest's
   `executionAuthority` stays `standardAgent` — which is what the Job's own
   `jobCreated` Journal record says, and the Journal cross-validator requires
   them to match — so a Job with an executed destructive Step cannot produce a
   valid Manifest and is refused rather than published.
2. **Device-bound Sessions.** `manifestTarget` refuses with
   `sourceIntegrityFailed` for any Job with a device effect or a confirmed
   binding. The current Manifest contract requires an `hdc` toolchain with
   `source`, `path`, `sha256`, `clientVersion`, `serverVersion`, `endpoint`,
   `serverGeneration` and `serverOwnership`; the Job record carries only
   `toolVersion` and `toolSHA256` (on `RuntimeEvidenceObservation`). Those facts
   live with the HDC server lifecycle, not the Job. Rather than invent them,
   the producer refuses. **Today only host-only Jobs publish a Session.**
3. **`recovered` Jobs.** The locked Manifest `status` vocabulary is
   `planned|succeeded|failed|cancelled|interrupted`, and the `finalized` Journal
   record must carry the same word as the Manifest. There is no `recovered`.
   Filing it as `succeeded` would erase exactly the distinction a recovery epoch
   exists to preserve, so it is refused with `contractViolation`. The scope
   review's sentence "the Manifest and receipt retain recovered" cannot be
   satisfied without extending that vocabulary; that is item 1's territory.
4. **Session Artifacts.** The published Manifest declares `artifacts: []`.
   Runtime Artifacts stay in the Artifact store with their own index and
   lineage; copying them under the Session root is a separate byte-moving step.
   Declaring them without copying would publish relative paths that do not
   exist.
5. **Export `source` and `catalogStatus`.** The two new required closed objects
   on `session.export.preview`/`apply`, the `unaccountedSessionContent` blocker
   disclosure and the `previewDigest` recomputation over them are not
   implemented. Export works on a published Session exactly as it did before.
6. **App History.** `RuntimeHistoryApplicationFacade`, `XPCConnectionBox`,
   `DiagnosticSessionUIFixture`, `RuntimeHistoryView`, `HistoryLocalizable.xcstrings`
   and `AppShellUITests` are untouched. The History facade decodes leniently, so
   nothing there broke; it simply does not show the publication fact yet.
7. **`RuntimeAgentExecutionReceipt.sessionPublication`.** The executor's receipt
   does not carry the nullable fact. Only the daemon's compact job object does.
8. **Admission refusal for a missing writer.** The scope review expects a
   production build with no composed writer to fail admission, and the soak
   fixture to switch to an explicit `.fixture(stateDirectory:)`. That is not
   done: about ninety existing engine constructions use
   `Configuration.init(stateDirectory:)`, and converting them was out of this
   slice's budget. Instead, absence is *reported*: those Jobs answer
   `unavailable` / `noCurrentPublicationRecord`, and there is no fixture writer
   for anything to silently fall back to. `ArkDeckRuntimeSoakFixture/main.swift`
   is therefore unchanged.
9. **Crash-window tests.** The scope review enumerates nine crash points (claim
   upgrade, copy/partial, checkpoint, proposal, terminal/finalized, Journal
   copy, manifest rename/fsync, registration, receipt/release). This change
   ships the phase machine and the durable marker that make them meaningful,
   and asserts the two idempotency properties that matter most — a receipt is
   never re-minted and never re-registered — but does not inject faults at each
   boundary. A publication that fails after the Session root is bound
   deliberately retains its claim rather than releasing headroom without a
   receipt.

### One residual that will surface later

The derived schemas publish only the shapes a recorded frame carried.
`job.status/show/result/list/run` now carry both the `published` and the
`unavailable` shape, because the new suite records a real receipt through the
control plane. `job.reconcile`, `agent.run`, `agent.status`, `agent.resume` and
`human-action.resume` carry only the `unavailable` shape: no contract test drives
an Agent execution or a reconciliation through an engine that has a composed
writer. When one does — or when a frame recording is taken against the
production daemon, which now always composes one — `ControlMethodSchemaContractTests`
will red on those five and the schemas need re-deriving with the command above.
That is the gate working as designed, not a latent defect, but it is a known
future red and is recorded here so nobody has to rediscover it.

## SVC acceptance

- **SVC-AC-05** (current Job → formal Session → exact finalized export) is met
  *for host-only Jobs on a host contract fixture*: the new suite runs that whole
  path through the production Engine and owner. It is not met for device Jobs
  (item 2) and this is not a `REAL_DEVICE_PASS` — no hardware was involved, and
  the reference host's own Sessions root has not been re-measured with a daemon
  built from this branch.
- **SVC-AC-10**'s Session half is correspondingly partial for the same reason.
