# TASK-XPA-014 — agent physical-assistance oracle (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: protected main `5e3b7f7a`; no stack. Every request and
answer here is synthetic host data over `/bin/sh` scripts; nothing is device evidence
(POL-VERIFY-001, POL-MODE-001). No Rust code changes. This is the r11 Swift-only oracle for the
runbook §2.1 path of milestone M1: executions that name no target, the physical-assistance actions
they raise, `agent.resume`, `human-action.list`/`show`/`resume`, and `agent.abandon` of a waiting
execution. The control schemas its frames extend are re-derived from them, so the Rust slices that
serve this path change no Swift file.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| The agent execution and lifecycle oracles (#1925, #1944); the Rust `agent.run`/`agent.status` (#1932), `agent.list`/`agent.abandon` (#1945) and their CLI leaves (#1935, #1946) | `AgentHumanActionOracleContractTests` and `rust/tests/fixtures/agent-human-action/`; `HDCOracleHarness` composes an independent USB observation and the daemon's human-action owner, and labels the identities the owners mint at random; the extended control schemas re-derived | The Rust store's typed actions, the Target observation owner with USB relations and adoption, the resume path, the human-action owner and its routes (lane A, next); `target.adopt`/`target.availability`; `runtime.hdc.*` |

## The oracle

`AgentHumanActionOracleContractTests.testSwiftResumesAndAbandonsPhysicalAssistanceOverTheSharedFakeDevice`
adopts the fake device (connect key `a`×32, tool version 3.2.0d, `TGT-3ba3f5f43b92`) before anything
else, as the runbook's device was adopted before. It composes the daemon's agent execution owner,
its Target observation owner and its human-action owner over the harness's engine on the oracle's
fixed clock (`2026-09-14T00:00:00.000Z`). Every execution names no target and runs
`observe.device@1` with the runbook's `--maximum-wait 5m`.

| Exchange | Method | Answer |
| --- | --- | --- |
| `connect.run` (mode `offline`, no USB relation) | `agent.run` | `waitingForHuman`, generation 3: a `connectDevice` action (`physicalConnection`, `device.notObserved`), which `nextAction` names with its resume reference |
| `connect.rerun`, `connect.status` | `agent.run`, `agent.status` | the same action; the run again only reads the budget (generation 4) |
| `connect.list`, `connect.show` | `human-action.list` (by owner), `human-action.show` | the one waiting action |
| `connect.waiting` | `agent.list` (`waitingForHuman`) | the execution, without its action |
| `connect.resume` (mode `heldServer`, relation on attachment 18) | `agent.resume` | the fresh probe adopts the device — the target unchanged, `TGT-3ba3f5f43b92` at revision 1 — and the execution owns its Job (`jobOwned`, generation 10; the Job state labelled) |
| `connect.completed` (after the release) | `agent.status` | `completed`, generation 11, the Job `succeeded`, its evidence `verified` and three Artifacts |
| `connect.resolved` | `human-action.show` | the action `resolvedByFreshProbe` |
| `connect.again`, `connect.againByAction` | `agent.resume`, `human-action.resume` | the resolved action resumed again: the execution as it is, without a write |
| `connect.selection` | `human-action.resume` | a selection the action never offered: `invalidInput` |
| `trust.run` (mode `unauthorized`, attachment 19) | `agent.run` | `waitingForHuman`: a `trustDevice` action (`deviceTrustPrompt`) |
| `trust.abandonStale`, `trust.abandon` | `agent.abandon` | at generation 1: `resourceConflict`; at 3: `abandoned`, generation 4, its action `expired` |
| `trust.expired`, `trust.resume`, `trust.resumeByAction`, `trust.rerun` | `human-action.show`, `agent.resume`, `human-action.resume`, `agent.run` | the action `expired`; both resumes `humanActionExpired`; the run answers as abandoned |
| `ambiguous.run` (mode `twoDevices`, attachments 20 and 21) | `agent.run` | a `selectDevice` action (`ambiguousIdentity`) whose two choices name the two connect keys |
| `ambiguous.missing`, `ambiguous.foreign` | `agent.resume` | without a selection, and with one it never offered: `invalidInput` |
| `unproven.run` (mode `normal`, no relation) | `agent.run` | `admissionDenied`: nothing proves the connected candidate's physical identity |
| `refuse.*` (10) | `human-action.list`, `.show`, `.resume`, `agent.resume` | an owner filter without its kind or of an unknown kind, a zero page size, a 257-byte cursor, an unknown or malformed identity, and a resume without its action: `invalidInput`, `invalidCursor` or `resourceNotFound` |

Every owner refusal carries `phase: preAdmission` and `newDispatchCount: 0`. The fake received 13
calls: the device list of each probe, the adoption's tool and device reads, and the Job's five calls.

Recorded (`ARKDECK_RUST_AGENT_HUMAN_ACTION_RECORD=/private/tmp/xpa014-agent-human-action-oracle-r1`,
installed as `rust/tests/fixtures/agent-human-action/`, 44 files). `cases.json` holds the target, the
one Job id, the four execution ids and the 33 exchanges. Beside it are the fake and its calls, the
Target document, the Job index and files, the Artifacts, the Session and the storage owner, and the
four execution records. Their actions and observations are labelled: three actions (`<har-1>` to
`<har-3>`) with their resume references, two choices and four observations. No unlabelled identity
is left in any file. A second recording (`-r2`) is identical (`diff -r`).

## The harness change

- `composition(...)` takes `usbRelations:` (none by default) and `humanActions:` (off by default).
  The Target observation owner brackets every device list with the oracle's USB observation, and
  the daemon's `RuntimeHumanActionResourceCoordinator` is composed over the executions with its
  pages under `human-action-snapshots`, as the daemon composes it
  (`ArkDeckAgentDaemonMain/main.swift`). The existing oracles pass neither and are unchanged.
- `RandomIdentities`. The identities the owners mint at random — `har-`, `resume-`, `candidate-` and
  `obs-` before a lowercase UUID (`AgentExecutionCoordinator.swift`'s `raiseAction`,
  `TargetObservationCoordinator.swift`'s `stamp`) — read as `<har-1>`, `<resume-1>`,
  `<candidate-1>` and `<obs-1>` by the order they first appear in: each answer's canonical text in
  exchange order, then each recorded file's text in path order. A request records the label of the
  identity it sent, so a replay sends its own identity for it. `files(...)` labels the files when it
  is given the labeller; a file that is not text, or names no such identity, is unchanged.
- This oracle's fake answers (`hdc-answers.sh`; the driver is unchanged): `list targets -v` in the
  modes `offline`, `unauthorized` and `twoDevices`, and mode `heldServer`, which holds a Job at
  `checkserver` — the Job's second call, and one the bootstrap observation never makes — before the
  capture oracle's answers. An exchange that follows a change of the USB observation records it
  (`usbRelations`: serial, location, attachment, vendor and product), as `mode` records the fake's.

## The control shapes

The whole Swift suite was recorded with `ARKDECK_CONTROL_FRAME_LOG` (`run-swiftpm.sh test
--parallel`, 245 frame files), this oracle among them in compare mode. Its only failing test is
`testFramesRecordedByThisRunValidate` against main's schemas, with 27 failures.
- 17 are this oracle's frames of five methods: `agent.run` (a result naming a waiting action),
  `agent.resume` (its result, a request with a selection, `invalidInput` and `resourceNotFound`), and
  `human-action.list`, `human-action.show` and `human-action.resume` (their results, requests and
  refusals).
- The other 10 are shapes other lanes record outside `swift test --parallel`, as #1925 and #1944
  found: `artifact.export` (`outcomeUnknown`, `sensitiveAccessDenied`), and `health`,
  `runtime.bundle.*` and `runtime.tool.*` request parameters. Those methods keep main's schemas.

`agent.status`, `agent.list` and `agent.abandon` admit this oracle's frames already and keep main's
schemas. So only the five are re-derived, by #1925's procedure: each from the whole recording's
frames of that method together with its committed corpus. A structural check (types, properties,
required members, enums, `anyOf`) found that each new schema admits everything main's did, and
every refusal code either publishes has a corpus frame.

| Method | Refusal codes added | Corpus lines |
| --- | --- | --- |
| `agent.run` | — (a result naming a waiting action and its `nextAction`) | 21 → 26 |
| `agent.resume` | `invalidInput`, `resourceNotFound` | 8 → 11 |
| `human-action.list` | `invalidCursor`, `invalidInput` | 2 → 7 |
| `human-action.show` | `invalidInput`, `resourceNotFound` | 3 → 5 |
| `human-action.resume` | `invalidInput`, `resourceNotFound` | 10 → 14 |

Three committed lines gave way to frames of the same shape from this recording: one answered
`agent.run`, `agent.resume` and `human-action.show` each, recorded by other suites. No Rust test
names a corpus line. `rust/scripts/generate-contract.py --write` refreshed the checkout
manifest (`spec/baselines/swift-single-v1.json`): 105 methods, 695 recorded shapes (676 before).

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Oracle, recorded twice | `ARKDECK_RUST_AGENT_HUMAN_ACTION_RECORD=/private/tmp/xpa014-agent-human-action-oracle-r{1,2} run-swiftpm.sh test --filter AgentHumanActionOracleContractTests` | 1 test, 0 failures each; the two recordings identical (`diff -r`), r1 installed |
| Every oracle on the harness, compare mode | `run-swiftpm.sh test --filter` the agent execution, lifecycle, observe, capture, debug HAP, native library and post-flash alias oracles, and this one against its installed fixture | 8 tests, 0 failures: the seven others' fixtures unchanged by the harness change |
| Whole Swift suite, recorded | `ARKDECK_CONTROL_FRAME_LOG=/private/tmp/xpa014-frames-har-r1 run-swiftpm.sh test --parallel` | 245 frame files; the only failing test is `testFramesRecordedByThisRunValidate` against main's schemas (27 failures, above) |
| Oracles and schemas, compare mode | `ARKDECK_CONTROL_FRAME_LOG=<the recording's 95 frames of the five methods> run-swiftpm.sh test --filter '(<the five agent oracles>\|ControlMethodSchemaContractTests)'` | 10 tests, 0 failures: the committed corpus is valid under the new schemas, and so are the recording's 95 frames and the 143 this run recorded |
| Rust manifest | `rust/scripts/generate-contract.py --write`, then `--check` | 105 methods, 695 recorded shapes; the check passes |
| Rust contract and control tests | `cargo test -p arkdeck-contract -p arkdeck-control` | all pass |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local` (merge base `5e3b7f7a`), with `ARKDECK_PYTHON` naming
`.venv-sdd` and the planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema
4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `a1b5b6f7` | `gate exit=0`: the common checks and SDD, the Swift lane (full parallel, 2,672 tests, then the serialized lanes), the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 2,037 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-agent-human-action-oracle-gate-20260914-r1.log`, SHA-256 `0d9d46c99a23d9a68bbc76f006bd2be9c69855cb5a496dfa8a29ffb3c45086fe` |

The amend after r1 only fills in this row.

## Not run, and why

- **No Rust replay yet.** The Rust daemon answers `agent.resume` and `human-action.*` with the
  control foundation's `rejected`, refuses an execution without a target, and does not read a record
  that holds an action. Lane A's next slices serve them and replay this fixture.
- **Selecting a device.** A resume with a valid selection needs the second device's identity
  readback and adoption; the oracle records the refusals of a missing and a foreign selection.
- **Expiry by time.** The owners run on the oracle's frozen clock, so no deadline passes.
- **Control-action approvals.** The human-action owner is composed without control-action resources
  (`runtime.hdc.restart`'s approvals), which remain.
- **A restart while an action waits.** Restart semantics stay out of the Rust port until L.1
  item 13 is decided.
- No device, no real HDC: the fake answers what the daemon asks.
