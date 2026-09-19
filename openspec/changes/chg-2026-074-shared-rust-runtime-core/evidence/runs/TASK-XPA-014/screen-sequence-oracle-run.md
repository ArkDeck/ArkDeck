# TASK-XPA-014 — M2 run record: the `capture.screen-sequence@1` Swift oracle (S0)

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M2 (GJ-2/3), lane B. Slice S0 of the
screen-sequence port: record, from Swift and over the shared fake HDC driver, the T0 oracle that the
Rust host-store slice (S1) replays, so that S1 changes no Swift file. Host measurement only — not
hardware, platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device, no real HDC, no
HDC server and no daemon process: `HDCOracleHarness` composes the standalone daemon's engine
in-process, and every capability is minted by that engine under the oracle's fixed temporary root.

Base: protected main `05861555` (#2003). Branch `agent/xpa-014-screen-sequence-oracle-20260919`, no
stack. Files:
- `ScreenSequenceOracleContractTests.swift` (new);
- `HDCOracleHarness.swift` (two opt-in parameters, below);
- `rust/tests/fixtures/screen-sequence/` (new, 46 files);
- this record.

No Rust, Catalog, spec, schema, control-frame or production Swift change.

## What was missing (re-verified on `05861555`)

The 2026-09-15 map holds on this base.
- **Swift.** `capture.screen-sequence@1` is a `deviceMutation` under standing issuance. It has nine
  steps, none optional and no finalize step:
  - host storage preflight;
  - the three evidence steps;
  - device storage preflight;
  - capture (`captureRemoteFile`), receive (`receiveFile`) and cleanup;
  - `postprocess-index`.

  It declares two products: `frames.tar` (raw, sensitive, file-backed, from the receive step) and
  `sequence.json` (from finalization).
- **Rust.** `arkdeck-provider-hdc` `capture_files.rs` has the three legs:
  - `CaptureScreenSequence`;
  - the receive, with its host landing;
  - `CleanupScreenSequence`.

  The host store never claims them:
  - `device_steps.rs` claims steps through `StepAction::{Hdc, Pointer, Port}` only, with no arm for
    the file legs, and its `lower` answers any `FilePlan` other than one process with "did not
    lower to one process". The map placed the receive refusal in `job_plan.rs`; it has since moved.
  - The operation is in none of `DEVICE_OPERATIONS` (`device_steps.rs`), `MATERIALIZED`
    (`job_plan.rs`) or `READABLE` (`job_result.rs`).
  - `HdcComposition` has no receive root.
- **Oracle.** No oracle under `rust/tests/fixtures/` held the operation, and the shared fake
  answered none of its calls.

## Two opt-in harness parameters

Two facts of the recording host reach the recorded bytes.

**The landing root of received files.** Swift's default is
`FileManager.default.temporaryDirectory/arkdeck-receive`, a per-user `/var/folders/…/T/` path.
- The receive argv names it: `file recv <remote> <root>/<remote basename>`.
- The receive step's `argumentSummary` is part of the materialized plan.
- So the plan digest follows the root, and so does the id of the automatic capability
  (`CAP-RT-POLICY-<fingerprint>-G1`).

**How long each child ran.** The dispatcher measures it on the host's monotonic clock. The capture
verdict keeps every still's duration (`%.3f`) and the rate, and these reach:
- the Job record's `screenSequence`;
- `sequence.json`, and with it its digest and its content-derived Artifact id;
- the Artifact indexes and the Job index's record digests.

Both are parameters of `HDCOracleHarness.composition` in `HDCOracleHarness.swift`, and both are nil
by default:
- **`hostReceiveRoot: URL?`**
  - Composes the provider through its public initializer,
    `HDCObservationProviderAdapter(factsPort:hostReceiveRoot:)`. The bundled code-sign helper and
    the native-library availability therefore stay as in the default composition.
  - Records whatever is left under the root as `receive/…` entries of `tree.json`, and the root's
    path as `provenance.receiveRoot`.
- **`fixedInvocationSeconds: Double?`**
  - Wraps the process dispatcher in `FixedDurationDispatcher`, a test-only decorator in the same
    file.
  - The decorator reports every child at that duration, and a sequence at the sum of its
    children's, as the process dispatcher does. It forwards everything else unchanged: exits,
    output, the landed file, `unavailableReason` and progress.
  - Recorded as `provenance.invocationSeconds`.

This oracle passes:
- `/private/tmp/arkdeck-hdc-oracle/receive`, the `<root>/receive` path that the native-library
  oracle's helper composition already used;
- 0.5 s.

**Defaults unchanged.** With both parameters nil, `composition` takes the path it took before:
- `HDCObservationProviderAdapter(factsPort:)`, or the helper initializer with `<root>/receive` when
  an oracle names a helper;
- the undecorated `DescriptorBoundProcessDispatcher`;
- no new entry in `tree.json` or `provenance.json`.

Measured on the same build: every oracle that uses the harness reproduces its unchanged checked-in
fixture byte for byte.
- These ten compose through it: `ObserveDevice`, `CaptureDiagnostics`, `DebugHap`, `NativeLibrary`,
  `PointerInput`, `PortForward`, `AgentExecution`, `AgentHumanAction`, `AgentLifecycle` and
  `TargetAdoption`.
- These two only record through it: `HDCStatus` and `PostFlashAlias`.

**Why each parameter is needed.** Each was left out once and the oracle recorded again. The result
was compared with the oracle; neither variant was kept.
- Without `hostReceiveRoot`, 13 of the 46 files differ:
  - the plan digest `b1c13bfc…` becomes `e67b81fa…`;
  - all three capability ids change;
  - with them `cases.json`, `hdc-invocations.log`, the capability checkpoint and ledger, the Job
    index and all seven Job records differ.
- Without `fixedInvocationSeconds`:
  - the three `sequence.json` bytes differ, for example durations `0.035, 0.011, 0.008` at
    55.56 frames a second;
  - so do their Artifact ids and the three Artifact indexes;
  - so do the four Job records that captured, the Job index, `cases.json` and `provenance.json`.

## What Swift records

`ScreenSequenceOracleContractTests.testSwiftCapturesAScreenSequenceOfTheSharedFakeDevice` sets up as
the other HDC oracles do:
- It adopts one device (`a`×32, tool 3.2.0d).
- It runs on the harness clock, `2026-09-14T00:00:00Z`. The other HDC oracles use the same clock, so
  a Rust replay can use `support::fixed_now` unchanged.
- It holds the fixed root `/private/tmp/arkdeck-hdc-oracle` under its lock, and removes the root
  afterwards.

Then:
1. It plans every case's request through `job.plan`.
2. It admits and runs the cases that have a mode, under the Runtime's default policy capability,
   with the fake answering in that mode. It submits `afterUnknown` and records the refusal.
3. It reads every Job's `job.result`, `job.evidence` and `artifact.list`.
4. It reads `cleanupDebt.list`, then `capability.list` and each `capability.inspect`.

That makes 51 exchanges:
- 10 plans, 8 submissions and 7 runs;
- 7 of each read (result, evidence, Artifact list);
- one debt list, one capability list and 3 inspections.

The fake is `HDCOracleFake`, the committed POSIX sh driver that every HDC oracle shares (SHA-256
`208ff918…`). It is not the SwiftPM-built `ArkDeckFakeHDCFixture`, whose identity changes on every
build.

### What the fake answers

Its answers (`hdc-answers.sh`) keep the device's `/data/local/tmp` as `device-tmp/` beside the log.
- `mkdir -p` makes the frame directory.
- Each `snapshot_display` writes a still that is one line naming itself and its size, and answers
  with the device's `file type: …, width: …, height: …` line.
- `tar -c` collects the stills in capture order. The fake's archive is the stills' bytes, not a tar:
  nothing the Runtime does reads the archive's format.
- `ls -l` lists the archive.
- `file recv` copies the archive to the host path its argv names.
- `rm -f` removes exactly the paths named, `rmdir` removes only an empty directory, and `ls -ld`
  reads the directory back.

Exit status:
- A device command that fails exits 1.
- The two readbacks answer an absent path with the listing grammar and exit 0, as HDC 3.2 reports
  its client's status. The provider's presence parser requires exit 0.

### The cases

| Case | Inputs | Mode | Ends | Device calls and what differs |
| --- | --- | --- | --- | --- |
| captured | `frameCount 3` (JPEG by default) | normal | succeeded | 15 calls: 4 evidence and storage reads; `mkdir -p`; 3 × `snapshot_display -t jpeg -f …/000N.jpeg`; `tar -c -f <archive> -C <frames> .`; `ls -l`; `file recv`; `rm -f` of the 3 stills; `rm -f` of the archive; `rmdir`; `ls -ld`. `frames.tar` is 57 bytes and `sequence.json` 205 bytes. |
| scaled | `frameCount 2`, `imageType png`, `width 360`, `height 640`, `displayId 0` | normal | succeeded | 14 calls; each still is `snapshot_display -t png -w 360 -h 640 -i 0 -f …/000N.png`. `frames.tar` is 34 bytes. |
| gap | `frameCount 4` | gap | succeeded | The second still exits 1, which is a gap and not a failure. `capturedFrameCount 3` of 4, `framesMissing 1`, `observedFramesPerSecond 1.5`. The archive holds stills 1, 3 and 4. |
| lowStorage | `frameCount 3` | lowStorage | failed | 4 calls. `df -k` leaves 16 KiB: `insufficientDeviceStorage: requires 134217728 bytes; 16384 available`. No capability use is consumed and `job.evidence` has `authority: null`. |
| emptyArchive | `frameCount 3` | emptyArchive | failed | 10 calls ending at `ls -l`: `emptyScreenSequence: tar left a zero-byte archive at …`. No receive, no cleanup, no compensation and no debt, so the frame directory, its stills and the empty archive stay on the device. |
| residue | `frameCount 3` | residue | failed | 15 calls. The device puts `.nomedia` in the frame directory, so `rmdir` refuses and `ls -ld` still lists the directory: `sequenceCleanupResidue: … still exists after cleanup`. `frames.tar` is already published; `sequence.json` is never produced. `outstandingResidueCount 0` and no debt. |
| missingArchive | `frameCount 3` | missingArchive | waitingForRecovery | 10 calls. `tar` exits 1 and writes nothing; `ls -l` answers not-found. The capture's outcome is unknown and its durable intent is left outstanding (`outcomeUnknown`, `awaitRuntimeReconciliation`, `nextAction reconcile`). `job.result` answers `resultNotReady`. |
| afterUnknown | `frameCount 3` | — | admission refused `admissionDenied` | Nothing sent. The message: "automatic Runtime target lineage is blocked: lineageBlocked(\"target binding has unresolved capability CAP-RT-POLICY-8AE3…-G1 use 4 outcome outcomeUnknown\")". |
| halfScaled | `frameCount 3`, `width 360` | — | plan refused `invalidInput` | "typed plan preflight failed before authorization: malformed(field: \"width/height\", detail: \"a scaled sequence needs both dimensions\")" |
| singleFrame | `frameCount 1` | — | plan refused `invalidInput` | "input frameCount is below minimum 2" |

In total the driver received 84 calls.

`halfScaled` and `singleFrame` go beyond the eight cases the map listed. They pin where the
lone-dimension refusal happens (the typed plan preflight, at `job.plan`) and its exact text, which S1
must reproduce.

### Files

`rust/tests/fixtures/screen-sequence/` holds:
- `cases.json`: the target, the cases, the seven Job ids and the 51 exchanges;
- the fake and every call it received;
- the Target document and the Job index;
- every Artifact: four `frames.tar` and three `sequence.json`, each with its Job's `index.json`;
- every Job file;
- the capability checkpoint, ledger and lock;
- the Sessions root and the storage owner, which hold only their catalog and locks;
- `tree.json` and `provenance.json`.

Every path is Windows-safe. No file names this host, its user or home directory.

## Facts the recording settled

1. **No Session, as the map said.**
   - All six terminal Jobs answer `sessionPublication: {state: failed, reasonCode:
     sourceIntegrityFailed}`.
   - The parked Job answers `{state: unavailable, reasonCode: noCurrentPublicationRecord}`.
   - `sessions/` holds only the retention catalog and its lock.
2. **One plan digest, and one capability, per set of inputs.**
   - The plan is materialized under the Job id `job-authorization-envelope`, so equal inputs plan
     to one digest and one automatic capability.
   - The `frameCount 3` capability was used by `captured`, `emptyArchive`, `residue` and
     `missingArchive` (uses 1–4); `scaled` and `gap` used one each.
   - The use is consumed at "capability consumed before first mutation", after the storage
     preflight. `lowStorage` therefore consumes none.
3. **The evidence reads are not session-carried.** Every Job re-reads its target, model, firmware
   and storage: four calls before each capture.
4. **The journalled arguments.**
   - Capture: `{catalogId: trace-presets, actionId: custom, parameters: {frameCount, imageType,
     framesDirectory}, artifactId: artifact-capture-screen-sequence, ownedRemotePath: <archive>}`.
   - Receive: `{remotePath, artifactId: artifact-receive-screen-sequence, localRelativePath:
     artifacts/raw/frames.tar}`.
   - Cleanup: `{remotePath: <archive>, framesDirectory, ownershipEvidenceId: owned-<job>}`.
   - All three journal `compensationDescriptors: []`, although the Catalog declares
     `bestEffortCleanup` for the capture and cleanup steps.
   - The parked Job keeps `recoveryAction` of kind `hdc.captureScreenSequence`, with `{frameCount,
     framesDirectory, imageType, jobId, nonce, remotePath, stepId}`.
5. **An empty archive fails at the capture and leaves the device dirty** (not in the map).
   - Nothing cleans up after it: no cleanup step, no compensation and no debt (`cleanupDebt.list`
     is empty).
   - The device keeps the frame directory, its three stills and the zero-byte archive.
6. **Residue fails the Job after `frames.tar` is published**, with no debt and no compensation, as
   the map said.
   - `sequence.json` is then missing (`missingRequiredArtifacts: [sequence.json]`, evidence
     `artifactIntegrityFailed`).
   - `outstandingResidueCount` is 0.
7. **The landing copy does not outlive the publication.** Each received archive's host copy is
   removed once `frames.tar` is published, so `receive/` is empty at the end and `tree.json` has no
   `receive/…` entry.
8. **`sequence.json` is Foundation `JSONEncoder` output** with `.sortedKeys, .prettyPrinted`.
   - Format: `"key" : value`, a two-space indent, no trailing newline.
   - `observedFramesPerSecond` is the record's `captured / Σ durations`, written as a JSON number:
     `2` or `1.5`.
   - `framesMissing` is requested − captured.
   - `job.result` and `job.evidence` carry no `screenSequence`. Only the Job record and
     `sequence.json` do.

## Measurement

```
run-swiftpm.sh test --filter 'ArkDeckContractTests.ScreenSequenceOracleContractTests'
  record into /private/tmp/xpa014-screen-sequence-oracle-r1       1 test, 0 failures
  record again into …-r2                                          identical to r1 (diff -r)
run-swiftpm.sh test --filter 'ArkDeckContractTests\..*OracleContractTests'
  r1 installed; the new oracle compares, every other oracle
  compares against its unchanged fixture                          21 tests, 0 failures
```

Recording sets `ARKDECK_RUST_SCREEN_SEQUENCE_RECORD` to the new directory.

Every expectation of the cases held on the first recording. `CFFIXED_USER_HOME` pointed at a
scratch home for every run, and nothing touched the installed daemon's state.

### Unified local gate

`scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base
--include-worktree --run-local` ran through the host's serialized gate queue. The virtual
environment supplied both `ARKDECK_PYTHON` and the planner.

- **Run:** r1, 2026-09-19 18:21:28–18:29:33 CST, exit 0.
- **Heads:** HEAD `6698d5c708f181d1551ea88ccb330ea6a9b04327`; origin/main and merge base
  `05861555dae00a06cd3087bf2473b8b71bd52e7b`.
- **Log:**
  `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/screen-sequence-oracle-gate-r1.log`
- **Log SHA-256:** `5afbd966896ba4fcb712cdb3c1bd19fcd6be54942632333a7a26d6099f5856d6`.

The plan selected the Swift, Rust and design-system lanes. All of these passed:
- **Swift.** The full parallel run: 2,695 tests, exit 0. This oracle ran as test 2,429 of 2,695.
  Then the process-identity-race lane (1 test) and the viewer-scale lane (5 tests).
- **Rust, formatting and lint.** `generate-contract.py --check` (105 methods, 775 recorded shapes,
  contract identity `1d7d101e83fe…`), `cargo fmt --check`, `cargo fetch --locked`, and Clippy with
  `-D warnings`.
- **Rust, tests.** The workspace tests and the published and candidate contract checks: 128 test
  binaries, 938 passed, 0 failed, 16 ignored.
- **Rust, supply chain.** `cargo deny` and `cargo vet`.
- **The rest.** Design system, 83 of 83; `check-sdd`, with 0 errors and 0 warnings; the catalog
  generator check.

## What S1 must do

These follow from the fixture. Swift records no cleanup debt and runs no compensation for this
operation, so S1 adds neither; the parked Job stays parked, since recovery is not part of S1.
- **Composition.**
  - Add a receive root to `HdcComposition` and to agentd. The daemon's root must be spelled as
    Swift's `FileManager.default.temporaryDirectory` spells it (`…/T/arkdeck-receive`); otherwise
    the same request plans to a different digest and capability under the two runtimes.
  - The replay places the root at `provenance.receiveRoot`.
  - Its dispatcher reports every child at `provenance.invocationSeconds` (500 ms), as
    `FixedDurationDispatcher` does.
- **Planning.**
  - Add `capture.screen-sequence@1` to `MATERIALIZED`.
  - Lower the receive step with its landing path, under `job-authorization-envelope`.
  - Refuse `halfScaled` and `singleFrame` with the recorded texts.
- **Running.**
  - Add `capture.screen-sequence@1` to `DEVICE_OPERATIONS`, and keep it out of
    `EVIDENCE_OPERATIONS`.
  - Add a `StepAction::File` claim for the three legs, gated to this operation.
  - Journal the three argument arms above, with empty compensation descriptors.
  - Consume the capability use after the storage preflight and before the capture intent.
  - Set `screenSequence` from the capture summary.
  - Publish `frames.tar` file-backed, then remove the landing copy.
  - Write `sequence.json` at finalization, on success only.
  - Park `missingArchive` with its intent outstanding, and refuse `afterUnknown` with the recorded
    lineage message.
- **Reading.** Add the operation to `READABLE`.
- **Capability replay.** `capability_write.rs` can add `screen-sequence` to the stores it replays.

## For the maintainer

1. **The gap rule reads each still's exit status, which HDC 3.2 does not report.**
   `DEVICE-COMMAND-FACTS.md` (row D2) records that `hdc shell` returns the client's exit code, so on
   the measured device a refused still exits 0 and is counted as captured. The oracle's `gap` mode
   exits 1 to pin Swift's rule as written.

   Likewise, a real `tar -c` of a directory writes a non-empty archive even with no stills in it,
   so `emptyScreenSequence` may never fire on a device.

   Should the verdict count the stills in the archive or in the directory instead? Until the
   Catalog or the provider changes, the Rust port reproduces the rule as recorded.
2. **A failed capture leaves the device dirty with no debt.** A capture that fails on an empty
   archive leaves the frame directory, its stills and the archive on the device. Nothing records
   it: no cleanup, no compensation, no debt. The Catalog's `bestEffortCleanup` on the capture
   materializes as `compensationDescriptors: []`. Residue after cleanup is the same class (map
   item).

   Should either run the exact cleanup or record debt? This is a design §L.1 candidate, not a Rust
   decision.
3. **The plan digest depends on where received files land.** The materialized plan digest, and so
   the automatic capability, depend on the host landing root, a per-user temporary directory. The
   same request therefore plans differently for another user, another host, or a changed
   `TMPDIR`. This is the same class as the code-sign helper's path in `m2-oracles-run.md` (fact 3).

## Not run, and why

- **No Rust replay.** That is S1.
- **No device, real HDC or real archive.** The fake answers what the daemon asks, and its archive
  is synthetic.
- **Not oracled:**
  - cancellation;
  - reconciliation of the parked Job;
  - a receive that fails: an empty file, one over the 64 MiB cap, or no landed file. The fake
    always lands the archive.
  - a timeout;
  - `totalArtifactByteBudget` other than its default;
  - the Artifact quota refusing the host preflight.
