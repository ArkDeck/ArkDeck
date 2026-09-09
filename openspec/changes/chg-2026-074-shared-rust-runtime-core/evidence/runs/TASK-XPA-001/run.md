# TASK-XPA-001 — run record

Change: CHG-2026-074-shared-rust-runtime-core (@r7 at the time of writing).
Acceptance: XPA-AC-3 (host part), XPA-AC-1 (control-plane frames only). Host contract evidence
only — not hardware, platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device
was contacted: the daemon under test runs inside the contract-test process on private state
directories.

Status after this PR: `in-progress`. The task was started on the maintainer's instruction once
`TASK-SVC-001` merged. `TASK-SVC-002`, `TASK-SVC-003` and `TASK-SVC-004` have since merged; the
third delivery below is their single re-recording and re-derivation, and it found that none of
the three moved a control-plane request, result or error shape. The journal contract for Rust is
verified against the post-SVC-002 reader in that section. Only the headless GJ-1..5 re-pass
remains, and it waits for a device window.

## Environment

| Fact | Value |
| --- | --- |
| Host | macOS 26.6.2 (25G83), Darwin 25.6.0, arm64, 8 CPUs; Swift 6.3.3; Python 3.14 (repository-pinned) |
| Build | SwiftPM debug through `Packages/ArkDeckKit/Scripts/run-swiftpm.sh` (the shared, lock-serialised cache) |
| Load while recording | one-minute load average 100–220 from other sessions' test runs on the same host; wall-clock-sensitive tests are therefore not counted below |
| Base | `main` at `600e4b72a016b38e3289103484208668e6690984` (after TASK-SVC-001, #1733) |
| Control registry | `Packages/ArkDeckKit/Contracts/control-protocol.json` blob `f47372feb9034ba17560b59d5dbde91206cb9aae`, `currentVersion` 1.0.0, contract identity `1054d17b598ce23003ebbdec4d42eb359b63016d6421709ba53c3f21f7c6558d`, 96 methods |
| Catalog digest | unchanged (`508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684`); this task publishes no operation and dispatches none |
| Device | none attached (`hdc list targets` → `[Empty]` on 2026-09-05) |

## What was published

- `spec/control/methods/<method>.json`, one per method of the single v1 control table, derived
  from frames the daemon really answered during a full contract-test run. Each carries
  `$defs.request` (parameters, closed to the fields a contract test exercised), `$defs.result`
  (closed to the fields the daemon emitted), `$defs.errorCode` (the codes recorded plus the ten
  generic refusals every method can answer), `$defs.errorDetails`, and the protocol version and
  contract identity it was derived under.
- `openspec/contracts/runtime-control-plane.schema.json`: `x-arkdeck-methodSchemaDirectory` and
  a `schema` path on every method row (bundle regenerated with
  `arkdeck maintainer contracts export`; only this file changed).
- The committed corpus `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/<method>.jsonl`:
  the smallest frame of every distinct request and response shape, at most 24 per method.
- The mechanism: `ControlFrameRecorder` (debug-only, `ARKDECK_CONTROL_FRAME_LOG`), the
  `frameObserver` seam on `RuntimeControlPlaneHandler`'s internal initialiser,
  `generate-control-contract.py --derive-method-schemas`, `ControlMethodSchemaContractTests`,
  and the `spec/` READMEs.
- Not published yet, by design: the journal contract for Rust (after SVC-002), and the
  post-SVC-002..004 re-derivations. The old 2.1.0 publication, version predicates, CLI
  `--require-protocol` leaves and journal generation union of the earlier unpushed attempt are
  dropped, as r6 requires.

## Recorded corpus

| Fact | Value |
| --- | --- |
| Recording (first delivery, #1735) | one full contract-test run (`run-swiftpm.sh test --parallel`, 2,434 tests) plus one run of `ControlMethodReachabilityContractTests`, both with `ARKDECK_CONTROL_FRAME_LOG` set; 150 per-process files, 1,218 lines, 2 torn tail lines skipped; 1,217 frames used |
| Recording (second delivery) | the eight success-path tests below, recorded on top of the first delivery's frames: 16 more frames, 1,233 used in total |
| Frames used | 1,233 dispatched frames; 20 distinct error codes observed |
| Methods | 96 of 96 have at least one frame and **96 of 96 publish a result shape**. After the first delivery 11 methods had no successful frame (`agent.abandon`, `agent.list`, `capability.inspect`, `cleanupDebt.continue`, `debug.evaluate`, `debug.start`, `debug.status`, `debug.template.run`, `job.reconcile`, `trace.probe`, `workspace.project.show`); the second delivery adds one control-plane success-path test per owner and re-derives, so no schema carries `x-arkdeck-unpublished` any more |
| Committed corpus | 96 files, 368 frames, 427 KiB: the smallest frame of every distinct request and response shape per method, at most 24 |
| Reachability | `ControlMethodReachabilityContractTests` dispatches every one of the 96 methods on a thin composition and requires a closed envelope; it is what guarantees the corpus never lacks a method |

## Artefacts

| File | SHA-256 |
| --- | --- |
| `spec/control/methods/` (96 files; sha256 over the sorted `sha256  name` lines) | first delivery `fe21797ac5591b260dc7edf6e344fa79c91e7160da41b2e1fad8c2a6f0b1d01d`; second delivery `7154f7ed8179d7373d5c23f869522bb8ce37dcb29f0849776627e9656d58e70c` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/` (96 files, same digest rule) | first delivery `5367692088c8ba7bb1fbd04c89a52c1bf7850612d9c034d5fd246cd235ab13e5`; second delivery `177c73935f9f2d88dd1b9faee326fc60973e1865c93f125d0658053b7bba608c` |
| success-path tests (second delivery): `DiagnosticsAndHAPContractTests.swift` / `RuntimeAgentExecutionContractTests.swift` / `RuntimeDebugInvocationContractTests.swift` / `CLIDebugProbeContractTests.swift` / `AgentDaemonContractTests.swift` | `d0e1985b29577ef7209bb2c5624c88156c0a0804c58cc4bdd78bfb02ac08839e` / `88952bec2a362e20e3df3303852a013f6456e9b864650d6db774b176f1ebfc78` / `0e9e321a1fd4402b1904d73302c8444fb871884514b3c5f58ff213fc6325105d` / `44fa961bdb8cc4a45dd298d5379e586dbbc41264c0f92ecfe94e1e235e8b4e91` / `90f1360e3ad9b6cf50a79faa2d294e6c8791640a7c553c4a67a960dbdc0e85fa` |
| `Packages/ArkDeckKit/Contracts/control-protocol.json` (unchanged input) | `c62460df5d4fc88dffe270d83f99cdef2bd35cdaeb3ec13667901142794c5015` |
| `openspec/contracts/runtime-control-plane.schema.json` (regenerated) | `528a9b202c0d35bfa2078a15710886061645553d98bb1aa686733ae91e271137` |
| `Packages/ArkDeckKit/Scripts/generate-control-contract.py` | `660fbdeed425b933560a72b7229bb59748121f6cf8fc16b833f75872f5d9af6f` |
| `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/ControlFrameRecorder.swift` | `103a7f8184019d6bb012cf26131720ccc952a325fb3cdbc99d1a2ba5c8ed951b` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ControlMethodSchemaContractTests.swift` | `e3a578a4ccc6ec533402dea864a54647d892eface1c7e99fb4bb48d61b472b87` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ControlMethodReachabilityContractTests.swift` | `58e5aa8281d713cbfdb12b765895fb6d120a6266df1a8600f66f3b061ba5a264` |
| `spec/control/README.md` / `spec/README.md` | `ed4044427103436677ba4721ac9f2ff8d8d5c3e7dad5be9622e3f002b60625ad` / `3ef2245bb8baf325170925f853b471f76c99047669adaf47973b6ea8342a2f3b` |
| third delivery (post-SVC-004): `spec/control/methods/` (96 files) / `Fixtures/ControlFrames/` (96 files, 368 frames, 427 KiB) | `b187495823a48c7f34ce6154b6fd8a18869c5488ed24e639acd6491b0ca35e61` / `fbbe5402857eb1e2751918ec9e8bf26e188572993bf20fa880743a165b3d19de` |
| third delivery: `Packages/ArkDeckKit/Scripts/generate-control-contract.py` | unchanged, byte-identical to main's |

## Commands run, and their results

| Command | Result |
| --- | --- |
| `python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --check` | exit 0 (the generated Swift vocabulary is byte-identical to main's) |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh build` | exit 0 |
| `arkdeck maintainer contracts export --contracts-directory openspec/contracts --fixtures-directory Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI` | `ok`; only `runtime-control-plane.schema.json` changed |
| `ARKDECK_CONTROL_FRAME_LOG=<dir> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --parallel` (recording run) | 2,434 tests, 5 failures, all in `ControlMethodSchemaContractTests` and `CLIMachineContractTests`, whose inputs (the schemas) did not exist yet; 1,122 frames recorded from 149 processes |
| `python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --derive-method-schemas <dir>` | `derived 96 method schemas from 1217 frames; corpus written` (after the reachability run added the 12 methods no other test reaches); `--check` exit 0 afterwards |
| `ARKDECK_CONTROL_FRAME_LOG=<dir> … test --filter ControlMethodReachabilityContractTests` (first run, code-set assertion too narrow) | exit 1: 47 assertion failures naming engine and coordinator codes (`invalidInput`, `operationUnavailable`) the handler's ten-code enum does not contain; the frames were recorded regardless and the assertion was relaxed to the closed-envelope contract |
| `… test --filter 'ControlMethodSchemaContractTests\|CLIMachineContractTests\|ControlMethodReachabilityContractTests'` without recording | 28 tests, 0 failures (the live-recording test skipped) |
| the same three classes with `ARKDECK_CONTROL_FRAME_LOG=<fresh dir>` | 28 tests, 0 failures; `testFramesRecordedByThisRunValidate` validated the 96 frames the run itself recorded |
| second delivery: the eight success-path tests with `ARKDECK_CONTROL_FRAME_LOG=<fresh dir>` | 8 tests, 0 failures; 16 frames; two compile-error rounds first (`await` inside XCTest autoclosures) |
| second delivery: `--derive-method-schemas` over the first delivery's frames plus the 16 | `derived 96 method schemas from 1233 frames; corpus written`; 14 schemas and 14 corpus files changed; `--check` exit 0 |
| second delivery: the three schema/machine-contract/reachability classes with a fresh recording | 28 tests, 0 failures; the live-recording test validated 96 frames |
| second delivery: `python3 scripts/ci/plan.py --run-local` | exit 0 (full-parallel lane 2,438 tests green in 115 s, the two serialised lanes and the ds lane green) |
| `sh scripts/check-sdd.sh` | 0 error(s), 0 warning(s), 121 acceptance IDs |
| `python3 scripts/check_pr_paths.py --preflight` | `TASK-XPA-001` |
| `python3 scripts/ci/plan.py --run-local` | exit 0 (planner, agent-PR workflow, SDD and catalog checks, the ds lane; `run-test-lane.sh full`: full-parallel 2,430 tests exit 0 in 119 s once the host load had dropped, plus the two serialised lanes) |

## Second delivery: success paths for the eleven result-unpublished methods

One test per owner, each inside the file that already composes that owner's fixture, each
driving the real handler through `handleFrame` so the frame a client reads back is what gets
recorded; the owner-level tests keep the semantics, these record the shapes and check that
nothing else happened (no dispatch, no Job, no connect key in the reply):

| Method(s) | Test | Owner composed |
| --- | --- | --- |
| `agent.list`, `agent.abandon` | `RuntimeAgentExecutionContractTests.testAgentListAndAbandonPublishTheirResultShapesThroughTheControlPlane` | `RuntimeAgentExecutionCoordinator` over the file's observation port (HAR pending, then abandoned by generation) |
| `debug.start`, `debug.evaluate`, `debug.status` | `RuntimeDebugInvocationContractTests.testDebugStartEvaluateAndStatusPublishTheirResultShapesThroughTheControlPlane` | `RuntimeDebugInvocationController` with the scripted driver; an observe candidate executes nothing |
| `debug.template.run` | `CLIDebugProbeContractTests.testDebugTemplateRunPublishesItsResultShapeThroughTheControlPlane` | a `DebugRuntimeProbing` fake answering `device.uptime` |
| `cleanupDebt.continue` | `DiagnosticsAndHAPContractTests.testCleanupDebtContinuePublishesItsResultShapeThroughTheControlPlane` | the file's scripted HAP job with cleanup debt, settled through the control plane |
| `job.reconcile` | `DiagnosticsAndHAPContractTests.testJobReconcilePublishesItsResultShapeThroughTheControlPlane` | the file's `outcomeUnknown` send, reconciled through the control plane (readback only) |
| `capability.inspect` | `DiagnosticsAndHAPContractTests.testCapabilityInspectPublishesItsResultShapeThroughTheControlPlane` | the installed E1 capability |
| `trace.probe` | `DiagnosticsAndHAPContractTests.testTraceProbePublishesItsResultShapeThroughTheControlPlane` | the file's `TraceRuntimeProbing` fake |
| `workspace.project.show` | `AgentDaemonContractTests.testARegisteredWorkspaceProjectShowsThroughTheControlPlane` | a registered project; the host root does not cross |

`DiagnosticsAndHAPContractTests` gained `@testable import ArkDeckAgentDaemon` for the handler.
Three further schemas changed as a side effect of the new frames (`agent.run`, `capability.list`,
`cleanupDebt.list` now have non-empty result samples).

## Finding: an unconfigured optional owner is reported as `internalError`

Recorded while writing the success-path tests, classified, not changed by this PR
(changing a method's refusal code is outside `TASK-XPA-001`'s purpose):

- `trace.probe` and `debug.template.run` answer `internalError` ("… probing is not configured")
  when the daemon composes no `traceRuntimeProbe` / `debugRuntimeProbe`. In production
  (`ArkDeckAgentDaemonMain/main.swift:562-649`) both probes are wired only inside the branch that
  runs when an HDC toolchain has been selected (`registry.startupSelection()`), so a daemon on a
  host without a selected toolchain answers these two methods with the bug-class code for a
  structural, operator-fixable condition. The agent family answers the same situation with
  `operationUnavailable` ("AgentExecution owner is unavailable"), and `target.adopt` /
  `device.observations` with `unknownMethod` naming the missing owner. Three codes for one
  condition; the CLI error registry maps each to a different next action.
- `debug.start`, `debug.evaluate`, `debug.status` and `recovery.flash-invocation.list` carry the
  same `internalError` branch, but `RuntimeDebugInvocationController` is constructed
  unconditionally (`main.swift:1250`), so that branch is reachable only in test compositions.

Recommendation for the owner of the control-plane refusal vocabulary (SVC-003 "normalize
evidence, debug and internal Provider formats", or the XPA-003 façade origin work): one code
for "owner not composed", `operationUnavailable`, with the missing owner named in the message,
and a contract test that composes the thin stack and asserts the code for every owner-gated
method. The per-method schemas published here record today's codes; re-deriving after the
change updates the enum.

## AC conclusion

- XPA-AC-3 (single-v1 control-plane parity, host part): every recorded frame of the single v1
  table validates against a per-method schema derived under the current contract identity;
  malformed, wrong-version, wrong-identity and unknown-method frames are refused before
  dispatch by `ControlProtocolContract` and are therefore never recorded (the corpus contains
  only dispatched frames). The Rust-side replay of the same corpus is `TASK-XPA-002`'s.
- XPA-AC-1 (byte-for-byte contract parity): the control-plane frame shapes now have a
  machine-readable statement a Rust generator can consume; durable document shapes are not
  covered here and wait for SVC-002..004.
- `TASK-XPA-001` stays `in-progress`: three re-derivations (after SVC-002, SVC-003, SVC-004), the
  journal contract (after SVC-002) and the device re-pass remain. Every method's result shape is
  published as of the second delivery.

## Third delivery: the re-derivation covering SVC-002, SVC-003 and SVC-004

The three re-derivations this task still owed are one run: the last schema
publication (#1737) predates all three SVC merges, so a single derivation on
`main` `eac476cdca4da29bc0b2e705f4697beeeefe8227` (after TASK-SVC-004, #1742)
covers them.

### Result: no control-plane shape moved

| Fact | Value |
| --- | --- |
| Base | `main` `eac476cd` (SVC-001..004 all merged and `done`) |
| Control registry | `control-protocol.json` blob `f47372fe…` and `ControlProtocolGenerated.swift` blob `6d3c1fb6…` — **both unchanged since the post-SVC-001 pin**; contract identity still `1054d17b…`, 96 methods |
| Recording | one full contract-test run with `ARKDECK_CONTROL_FRAME_LOG` set: 158 per-process files, 1,234 lines, 2 torn tail lines skipped, 1,233 frames used; the run itself was green (2,444 cases, exit 0), so no schema was stale enough to fail its own test |
| Derived | `derived 96 method schemas from 1233 frames; corpus written`; `--check` exit 0 |
| Schema delta vs the committed baseline | **2 of 96 files, 4 lines, all inside `x-arkdeck-sampleCounts`** (`agent.status` request 5→4 / result 4→3; `job.events` request 19→20 / result 16→17). No `$defs.request`, `$defs.result`, `$defs.errorCode` or `$defs.errorDetails` changed anywhere |
| Corpus delta vs the committed baseline | 51 of 96 files, 112 lines. Classified mechanically by comparing the recursive key/type shape multiset of every frame: **50 files are value-only** (a `generation` counter, an id, a sampled row), and the 51st (`artifact.list`) differs only because a different test's frame was sampled, one whose nullable `observationWindow` is `null` — which is why its schema did not change |
| `arkdeck maintainer contracts export` | `runtime-control-plane.schema.json` unchanged; the bundle is already in sync |
| Pinned suites | `ControlMethodSchemaContractTests`, `CLIMachineContractTests`, `ControlMethodReachabilityContractTests`: 28 tests, 0 failures, both without recording and with a fresh recording (the live test validated the 96 frames the run itself recorded) |
| `python3 scripts/ci/plan.py --run-local` | exit 0 on the committed tree: full-parallel 2,438 cases (66 s), process-identity race 1, Viewer scale 5, all exit 0; `check_sdd` 0 errors / 0 warnings / 121 acceptance IDs; the design-system lane green. The App build-for-testing lane was not selected — this diff touches no `ArkDeckApp/` path — and the one-minute load average was 3.25 on 8 cores throughout, so no lane result is load-suspect |
| `python3 scripts/check_pr_paths.py --preflight` | `TASK-XPA-001`, exit 0 over 56 changed paths, all inside this task's Allowed paths (`spec/**`, `Tests/ArkDeckContractTests/**`, `docs/design/**`, this change directory) |

So SVC-002 (durable records and recovery), SVC-003 (evidence, debug and internal
Provider formats) and SVC-004 (preferences and configuration) changed durable,
evidence and configuration shapes without moving a single control-plane request,
result or error shape. That is consistent with those tasks' own records — SVC-003
states "this Task changes no wire shape" — and it is now measured rather than
assumed.

### Finding: the corpus is a sample of a nondeterministic system, not a function of the contract

Measured, not inferred. Two independent recordings of the **same, unchanged**
tree were derived under identical conditions (each derivation from a clean
`git checkout` of the two output directories, so no run could inherit the
previous one's files):

| Comparison | Corpus files differing | Schema files differing |
| --- | --- | --- |
| same script, same frames, twice (control) | 0 | 0 |
| same script, two recordings of the same tree | **50 of 96** | 2 of 96 (sample counts) |

The deriver is deterministic given its input. The recording is not: frames carry
values a run produces — `agent.status` recorded `"generation":"9"` in one run and
`"generation":"6"` in the other, same length, same shape. `select the smallest
frame of each shape` then keeps whichever arrived first.

An ordering tie-break does not fix this, and I measured that too rather than
assuming it: making the corpus tie-break total (`(len, bytes)` instead of
first-seen) left the churn at 50 of 96, because the two runs did not observe the
same candidate values at all — the minimum of `{"9"}` and the minimum of `{"6"}`
are still different frames. That attempt also introduced a variable-shadowing bug
(`current` is already bound in the enclosing scope, so 95 of 96 schemas were
written with a whole frame in `x-arkdeck-protocolVersion`), which the same
measurement caught. Both the attempt and the bug were reverted; the generator in
this delivery is byte-identical to main's.

Consequence for this task's own deliverable — "the corpus used by every later XPA
differential test": a baseline that changes in half its files on every recording
cannot be read as a statement about the contract, and `TASK-XPA-002`'s Rust
replay of it inherits that churn. The statement about the contract lives in the
schemas, whose only delta here is a run-dependent sample counter.

Not changed by this delivery, because it is a design decision for the task owner
and this PR is a re-derivation: the options are (a) record with fixed counters and
ids so the frames are reproducible, (b) canonicalise the volatile fields when the
corpus is written, keeping the shape and dropping the sampled value, or (c) state
that the per-method schemas — not the corpus — are the differential baseline, and
let the corpus be an illustrative sample. `x-arkdeck-sampleCounts` has the same
property and would go with (c).

### Journal contract for Rust (was gated on SVC-002)

Verified rather than published: `openspec/contracts/journal-event.schema.json` is
already the single `1.0.0` contract (`$id` `journal-event-1.0.0.json`, no other
version string in the file), and after SVC-002 the Swift reader agrees exactly —
`JournalEvent.isSupportedSchemaVersion` is `value == "1.0.0"`
(`JournalEvent.swift:39-42`), where the pre-SVC scan recorded five accepted
generations. No file change was needed for this deliverable; the drift row that
recorded the conflict is corrected below.

### Baseline survey rows corrected

`docs/design/cross-platform/rust-core-cross-platform-architecture.md` is the
survey later XPA tasks consume. Three rows were falsified by the SVC merges and
each was re-verified against this tree before editing — no row was rewritten from
the assumption that a merge "must have" changed it:

| Row | Was | Is, and where it was checked |
| --- | --- | --- |
| 27 persistence layout | `capabilities/` doc `2.0.0`; `runtime-jobs.sqlite3` schema v2 | doc `1.0.0` (`RuntimeCapabilityStore.swift:147`); schema v1 (`RuntimeJobRepository.swift:53`) |
| 29 journal version drift | Swift accepts five generations; contract says `1.0.0` — classified `F（冲突）` | one generation on both sides, conflict resolved (`JournalEvent.swift:39-42`) |
| 32 machine contracts | 219 argv fixtures | 208 (`ls Fixtures/CLI/argv/*.json`), after SVC-004 removed the `runtime signing normalize` leaf and its §12 alias |

Only these three were checked; the rest of the survey is not re-verified by this
delivery and is not claimed to be current.

## Golden Journey

### Real-device window 2026-09-05 (DAYU200 attached): `BLOCKED_BY_PRODUCT_DEFECT`

The maintainer attached the DAYU200 and approved the two prerequisites the runbook needs (update
the installed Runtime to a build of `main`; run GJ-4 with the HardwareCampaign enabled). The
window never reached GJ-1: **the post-SVC-001 daemon cannot start on this host's store.**

| Fact | Value |
| --- | --- |
| Device | one DAYU200 visible to the pinned HDC (`hdc list targets -v`: USB, Connected), connect key redacted |
| Installed Runtime before | helper built 2026-09-03 (pre-SVC-001), daemon SHA-256 `b5931c7a144011222ea7934de48371e01cbe624cb1a31301bcd04e62fd24a4d6`; the current CLI reports it `daemonHealth: unreachable, malformedResponse("contractMismatch")` and refuses every business request with `protocolVersionUnsupported`, so the runbook's §1 update was mandatory |
| Helper built | `Distribution/macOS/build-local-helpers.sh` on `main` `e8c4f1df` (#1737), Developer ID 8AQTYW5FKR, hardened runtime; daemon SHA-256 `7dcffb14901a9c8c9d4e64c998b5b39c4340b0d9e44b5fad23e4f7b0dd3b42e5`, CLI `buildIdentity` `sha256:6735aa5b4572abddd09cb932ae18a873f8b0b76f89cf11cc3999c4b04488cd1f` |
| Update | `arkdeck runtime service update --daemon <helper>/ArkDeckCLI.app/Contents/Helpers/ArkDeckAgent.app --hdc <pinned hdc> --arkforge-bundle <registered bundle> --arktrace-descriptor <registered descriptor> --output json` → `ok`, receipt `daemonSHA256` `7dcffb14…`, campaign `""` |
| Failure | the daemon exits within a second of every launch; launchd (`KeepAlive`, 5 s throttle) restarted it 248 times before the job was booted out. `~/Library/Logs/ArkDeck/agentd.error.log`: `arkdeck-agentd failed to start: internalFailure("admitted job job-be448cb20f06aae340e1ccfe5275be81 has no readable durable record after recovery projection")`; the socket never appeared (`daemonHealth: socket_absent`), `doctor`, `operation list`, `target list`, `workspace project list` all `runtimeUnavailable` (`connect failed: errno 2`) |
| Root cause | `RuntimeRecoveryService.replay` (`RuntimeRecoveryService.swift:589-592`) throws when `RuntimeJobRecord.load` cannot decode `jobs/<id>/job-record.json`. The record passes the new `StrictJSONDuplicateValidator` (checked standalone: no duplicate keys, valid document) and its Codable field set is unchanged by SVC-001; what changed is `RuntimeOperationRequest.schemaVersion` — `"2.0.0"` → `"1.0.0"` in #1733 (`RuntimeOperationModelsV2.swift` → `RuntimeOperationModels.swift`) with an exact-match decoder (`schemaVersion must be exactly "1.0.0"`). Every durable job record on this host embeds its submission request with `"schemaVersion":"2.0.0"`: **2,041 of 2,041 records** (read-only scan), including the four non-terminal `waitingForRecovery` flash jobs of 2026-08-04, 08-04, 08-09 and 08-20 that start-up recovery must project. The first of them stops the daemon |
| Consequence | a host that ran any pre-SVC-001 Runtime cannot upgrade: with a parked job the daemon does not start; without one it would start but every historical `job show` / `job result` / `history` read of the 2,041 records would be `recordUnreadable`. This is the durable-record generation gap `TASK-SVC-002` ("Consolidate durable records and recovery on the current v1") owns; SVC-001's own acceptance never ran against a populated production store |
| Not attempted | terminating or editing the four parked jobs by hand so the new daemon can start — the runbook forbids rewriting historical unknown records, and the 2,037 terminal records would stay unreadable anyway |
| Rollback | the crash loop was booted out (`launchctl bootout gui/501/com.arkdeck.agentd`, after 248 attempts); no copy of the 2026-09-03 helper existed on disk, so a pre-SVC-001 helper was built from `main` `7955e745` (#1732, the last commit before #1733) with the same `build-local-helpers.sh`, daemon SHA-256 `65cb1083bc100d159724c4cf0ecfcf996b60e3bb57406beedf0d00de0ec2672b`, and installed with `runtime service update --daemon …` (`ok`). That daemon first refused to start too — `serverDidNotBecomeReady("managed HDC launch identity was not retained")` — because the crash-looping post-SVC-001 daemon had left an orphaned managed HDC server (`hdc -s 127.0.0.1:8710 -m`, pid 4563, parent launchd) holding the port; after that process was killed and the LaunchAgent bootstrapped again, the socket appeared within 6 s: `runtime service status` `daemonHealth.status: ok` (digest `508783ac…`, providers analyzer/arkforge/hdc/workspace), `doctor --deep --require-healthy` exit 0, `target list` shows `TGT-958780b2ffb7` r4, `runtime hdc status` available (3.2.0f). The host runs a pre-SVC-001 local helper now, not the 2026-09-03 notarised build; no durable record was edited |
| GJ-1..5, §2.1, §6a | not started; no Job was created under the new daemon (it never accepted a connection) |

Reproduction (any host with a pre-SVC-001 store): `arkdeck runtime service update --daemon
<post-#1733 helper>`; watch `agentd.error.log`. The exact failing line above is the daemon's own
message; the CLI's view is `runtime service status` → `daemonHealth.status: socket_absent`.

Routing: one product defect = one vertical task. The fix belongs to CHG-2026-075 `TASK-SVC-002`
(durable-record consolidation must read or migrate the `2.0.0` request documents before the
strict single-v1 decoder meets a populated store); until it lands, the XPA-001 device re-pass
and `TASK-SVC-005` cannot run on this host, and no host that ran the 2.x Runtime can take a
post-SVC-001 build. The maintainer decides whether SVC-002 or a dedicated task carries it.

The device re-pass stays open; this task advances no hop.

### Real-device windows 2026-09-08 and 2026-09-09 on the current digest

The device re-pass this task owes is the same headless runbook, on the same
digest, through the same single-v1 CLI that `TASK-SVC-005` runs for its own
acceptance, so the two are one set of windows rather than two. Recorded here by
reference, with the build each result was taken on; nothing is restated as
current beyond what those records claim.

| Journey | State on digest `508783ac…` | Build / contract identity | Record |
| --- | --- | --- | --- |
| GJ-1 Device Observe | `REAL_DEVICE_PASS` | `main` `6ba5a0b9` (2026-09-08), identity `1054d17b…`; §2.1 HAR crash-resume on `main` `eadb46b8` (2026-09-09), identity `8a662759…` — `job-06c4e41e…`, `job-49720bb2…` | `docs/design/references/single-v1/svc-acceptance-2026-09-08-published-main.md`, `…-2026-09-09-published-main.md` |
| GJ-2 HAP Debug | `REAL_DEVICE_PASS` (incl. the confirmed-failure compensation) | `main` `6ba5a0b9` → `16fe9617` (2026-09-08), identity `1054d17b…` — `job-458fadbe…`, `job-461b9ade…` | `svc-acceptance-2026-09-08-published-main.md` |
| GJ-3 Native Debug | `REAL_DEVICE_PASS` (positive and rollback legs) | same window — `job-a48fdb55…`, `job-5b91a6a9…` | same |
| GJ-4 Flash Recovery | `REAL_DEVICE_PASS` (2026-09-09 10:20Z) | published `main` `6e8c3ed5` (DEC-016 #1821 + #1822), identity `8a662759…`: `flash.full-restore@1` `job-6d1e329e44d4dfa1acf61921f9f2adad` admitted as a complete-overwrite recovery epoch under campaign `gj4-headless-20260909b`, terminal `recovered`, evidence `verified`, readback `OpenHarmony-7.0.0.37`, epoch `recovery-epoch-a985dcca…` superseding `job-c9274a31…`; postflight `observe.device@1` `job-9b2b7535…` succeeded at r2; the two refused attempts earlier that day (no Job) are in the same record | `docs/design/references/single-v1/gj-headless-rerun-2026-09-09.json` (GJ-4 runs 1 and 2), `svc-acceptance-2026-09-09-published-main.md` §GJ-4 |
| GJ-5 Bounded AI Debug Loop | `REAL_DEVICE_PASS` on the published Runtime | protected `main` `8a28f182` (2026-09-09 08:30Z, daemon `6035adcb…`, CLI `494e2a35…`), identity `8a662759…` — repro `job-88183e90…` … verify `job-89ffb2fb…`, after the same pass on `8c6a376c` + #1810 at 07:56Z | `docs/design/references/single-v1/gj-headless-rerun-2026-09-09.json` (runs 1 and 2) |

What this means for XPA-AC-3: every control-plane frame those windows exchanged
was answered by a daemon whose method table and per-method schemas are the ones
published here (identity `1054d17b…` for the 09-08 windows, `8a662759…` after
#1794/#1795 — the 96 earlier methods' request, result and error shapes are
identical under both, per AFA-001's diff record). The corpus committed under
`Fixtures/ControlFrames` is a contract-test sample and not a recording of these
device windows; the device records carry Job identities and digests, not frames.

The pins block above moved from `eac476cd` to `8c6a376c` for the same reason:
the control blobs changed with #1794 (`f47372fe…`→`9c5bec14…`,
`6d3c1fb6…`→`35c66af8…`), the identity to `8a662759…`, and the schema/corpus
directories were re-derived by #1795 under it (`spec/control/methods`
`47059447…`, `Fixtures/ControlFrames` `c8054a23…`, git-tree digests as in
`TASK-SVC-005/single-v1-baseline.md`). `generate-control-contract.py --check`
exits 0 on that tree.

GJ-4 passed on this digest on 2026-09-09 after the maintainer ruled (DEC-016,
#1821) and the ruling was implemented (#1822), so every Journey the task's
verification row names has a current real-device record and the task is
`done`. Nothing else is owed: the schemas, the corpus, the journal contract and
the pinned baseline are as the third delivery left them.

## Stop condition

Not triggered: no post-SVC frame or document shape changed, no method effect changed, and no
negotiation, downgrade, legacy reader or old authority returned.
