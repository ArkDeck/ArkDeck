# TASK-XPA-001 — run record

Change: CHG-2026-074-shared-rust-runtime-core (@r7 at the time of writing).
Acceptance: XPA-AC-3 (host part), XPA-AC-1 (control-plane frames only). Host contract evidence
only — not hardware, platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device
was contacted: the daemon under test runs inside the contract-test process on private state
directories.

Status after this PR: `in-progress`. The task was started on the maintainer's instruction once
`TASK-SVC-001` merged; it still depends on `TASK-SVC-002..004`, whose merges change durable and
evidence shapes that several methods carry in their results. Each of those merges is followed by
one re-recording and re-derivation (the commands below), and the journal contract for Rust is
published only after SVC-002 has consolidated the journal on its single v1.

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

## Golden Journey

Not executed: no DAYU200 was attached during delivery. The headless GJ-1..5 re-pass on the
current digest is recorded here when a device window exists; this task advances no hop.

## Stop condition

Not triggered: no post-SVC frame or document shape changed, no method effect changed, and no
negotiation, downgrade, legacy reader or old authority returned.
