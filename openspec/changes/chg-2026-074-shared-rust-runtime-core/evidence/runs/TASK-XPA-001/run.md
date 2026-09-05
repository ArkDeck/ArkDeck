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
| Recording | one full contract-test run (`run-swiftpm.sh test --parallel`, 2,434 tests) plus one run of `ControlMethodReachabilityContractTests`, both with `ARKDECK_CONTROL_FRAME_LOG` set; 150 per-process files, 1,218 lines, 2 torn tail lines skipped |
| Frames used | 1,217 dispatched frames: 986 successes, 231 refusals, 20 distinct error codes observed |
| Methods | 96 of 96 have at least one frame; 85 publish a result shape; 11 have no successful frame yet and carry `x-arkdeck-unpublished` on `$defs.result` (request, error code and error-detail shapes are published): `agent.abandon`, `agent.list`, `capability.inspect`, `cleanupDebt.continue`, `debug.evaluate`, `debug.start`, `debug.status`, `debug.template.run`, `job.reconcile`, `trace.probe`, `workspace.project.show` — each needs a control-plane contract test of its success path |
| Committed corpus | 96 files, 354 frames, 416 KiB: the smallest frame of every distinct request and response shape per method, at most 24 |
| Reachability | `ControlMethodReachabilityContractTests` dispatches every one of the 96 methods on a thin composition and requires a closed envelope; it is what guarantees the corpus never lacks a method |

## Artefacts

| File | SHA-256 |
| --- | --- |
| `spec/control/methods/` (96 files; sha256 over the sorted `sha256  name` lines) | `fe21797ac5591b260dc7edf6e344fa79c91e7160da41b2e1fad8c2a6f0b1d01d` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/` (96 files, same digest rule) | `5367692088c8ba7bb1fbd04c89a52c1bf7850612d9c034d5fd246cd235ab13e5` |
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
| `sh scripts/check-sdd.sh` | 0 error(s), 0 warning(s), 121 acceptance IDs |
| `python3 scripts/check_pr_paths.py --preflight` | `TASK-XPA-001` |
| `python3 scripts/ci/plan.py --run-local` | exit 0 (planner, agent-PR workflow, SDD and catalog checks, the ds lane; `run-test-lane.sh full`: full-parallel 2,430 tests exit 0 in 119 s once the host load had dropped, plus the two serialised lanes) |

## AC conclusion

- XPA-AC-3 (single-v1 control-plane parity, host part): every recorded frame of the single v1
  table validates against a per-method schema derived under the current contract identity;
  malformed, wrong-version, wrong-identity and unknown-method frames are refused before
  dispatch by `ControlProtocolContract` and are therefore never recorded (the corpus contains
  only dispatched frames). The Rust-side replay of the same corpus is `TASK-XPA-002`'s.
- XPA-AC-1 (byte-for-byte contract parity): the control-plane frame shapes now have a
  machine-readable statement a Rust generator can consume; durable document shapes are not
  covered here and wait for SVC-002..004.
- `TASK-XPA-001` stays `in-progress`: three re-derivations, the journal contract and the device
  re-pass remain.

## Golden Journey

Not executed: no DAYU200 was attached during delivery. The headless GJ-1..5 re-pass on the
current digest is recorded here when a device window exists; this task advances no hop.

## Stop condition

Not triggered: no post-SVC frame or document shape changed, no method effect changed, and no
negotiation, downgrade, legacy reader or old authority returned.
