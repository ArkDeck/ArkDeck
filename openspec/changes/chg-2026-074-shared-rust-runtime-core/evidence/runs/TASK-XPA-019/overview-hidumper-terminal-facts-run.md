# Overview hidumper row: the window-inventory Job's terminal facts

Base: protected main `9c58e484`. TASK-XPA-019 / SPK-8 remain incomplete. This slice fixes the
pre-existing defect that `clientkit-overview-capability-run.md` recorded and left unchanged
("Pre-existing defect found"). Every Runtime answer here comes from an in-process control plane
over scripted process receipts; nothing is device evidence (POL-VERIFY-001, POL-MODE-001).

## The defect

On a live Swift daemon the Overview's hidumper row always read `unknown` with "Runtime returned
incomplete terminal Debug facts", even when its read-only `debug.template@1` window-inventory Job
succeeded.

- `DebugTemplateJobExecution.run` (added by #1707) decoded the raw `job.run` result with
  `DebugRuntimeResponseDecoding.terminal`, which requires `timeline`.
- Since #1733, `job.run` answers `RuntimeJobReadProjection.status`, the `arkdeck.job-status/1`
  projection, which has no `timeline`. The published `job.run` result is closed and has none.
- #1733 moved the Debug workspace's `run(jobID:)` to `job.run` followed by
  `RuntimeAppReadResources.statusPresentation` (`job.show`, plus `job.timeline` pages when the
  timeline does not fit inline). It did not move this path.

## The change

- `DebugApplicationFacade.swift`: `DebugJobRunExecution.run(jobID:send:)` is the #1733 path, moved
  out of `DebugProductionApplicationProvider.run(jobID:)` unchanged. `job.run` must answer a result
  object, the terminal facts come from the status presentation, and the error mapping is the same.
  The provider's `run(jobID:)` and `DebugTemplateJobExecution.run` both call it, so the Debug
  workspace's requests, order and failure texts are unchanged.
- `DebugWindowInventoryJobRunner.swift`: `public init()` is unchanged, so the App composition is
  too. An internal `init(send:)` hands the transport to `DebugTemplateJobExecution.run` for tests.
- The ClientKit Overview facade, its row texts and states, the App and the UI fixture are
  untouched.

The runner now sends `job.submit`, `job.run` and `job.show`, and `job.timeline` only for a timeline
over the inline bound. The row reads:

| Runner result | Row |
| --- | --- |
| succeeded, outcome known | `available`, "debug.template@1 Job succeeded · <jobID>" |
| any other terminal state or an unknown outcome | `unknown`, "debug.template@1 Job <state> · <jobID>" |
| a Job status without its state or its outcome certainty | `unknown`, "Runtime returned incomplete terminal Debug facts" |
| a refusal or transport failure | `unknown`, that failure's text |

## The tests

`ArkDeckContractTests/DebugWindowInventoryJobRunnerContractTests` gains three tests. Each composes:
- `RuntimeControlPlaneHandler` (its public initializer) over a `RuntimeJobEngine` with the HDC
  observation provider, a facts port at binding revision 7, and a scripted process dispatcher that
  answers the binding confirmation and the `windowInventory` template;
- the real runner, whose transport encodes each request with `ArkDeckAgentXPC.requestFrame` and
  hands it to `handleLine`, the way the XPC transport reaches the daemon;
- the production `OverviewCapabilityProductionProvider` over that runner. Its own reads adopt one
  target, list no operation and refuse `trace.probe`; those rows are not asserted.

| Test | What it pins |
| --- | --- |
| A succeeded Job | Requests `job.submit`, `job.run`, `job.show`. The `job.run` answer is `arkdeck.job-status/1`, `succeeded`, `outcomeUnknown` false, `threadId` the Debug commands workspace thread, and no `timeline`. The dispatcher ran the binding confirmation, then `runDebugTemplate(.windowInventory)`. The row is `available`, "debug.template@1 Job succeeded · <jobID>". |
| A failed Job (template exit 1) | The row is `unknown`, "debug.template@1 Job failed · <jobID>". |
| An incomplete answer | The Job succeeds, and the transport withholds `state`, then `outcomeUnknown`, from `job.show`'s Job status. The row is `unknown`, "Runtime returned incomplete terminal Debug facts". |

Red before the fix: the same class against `origin/main`'s `DebugApplicationFacade.swift`, with
the runner's test initializer kept, fails 3 of 5 tests (6 assertions). The runner stops after
`job.submit` and `job.run`, and the succeeded and the failed Job both read `unknown`, "Runtime
returned incomplete terminal Debug facts": the live symptom.

## The schemas

### `job.run`: `threadId` widened from recorded frames

- The fix reads nothing from `job.run` but a result object, so `timeline` stays out of its schema.
  The daemon never emits one.
- The Job this runner submits is filed under the Debug commands workspace thread
  (`RuntimeWorkspaceThread.clientContext`), as the App's Debug HAP, logs and port-rule Jobs and its
  Trace, Device, Flash and UI-dump Jobs are, and `RuntimeJobReadProjection.status` answers it as
  `threadId`. The published `job.run` result pinned `threadId` to `null`, because no recorded
  `job.run` frame had run a threaded Job. `job.status` and `job.show` already publish `null` or a
  string.
- Against `origin/main`'s schemas (jsonschema 4.26), all 4 `job.run` frames this class records are
  refused, on `result/threadId` only. Its `job.submit` and `job.show` frames are valid.
- The Rust side rejects the same answer. `arkdeck-control` rewrites an answer outside its method's
  schema to `internalError` ("the result does not conform to the current contract"), and
  `arkdeck-client`'s `decode_response` refuses one, which the CLI reports as `protocolMalformed`.
  The Rust Job record projects `threadId` from the request's provenance too (`job_record.rs`
  `status()`), so `job.run` of a threaded Job reads as `internalError` from the Rust daemon and as
  `protocolMalformed` from the Rust CLI.

The derivation follows #2002's procedure:
- The input is the 7 committed corpus lines plus the 4 recorded `job.run` frames.
  `generate-control-contract.py --derive-method-schemas` runs on that one file, so no other file
  changes.
- The corpus is then written as the 7 committed lines, verbatim and in order, plus 2 recorded frames
  for the new shapes: the threaded succeeded answer and the threaded failed answer.

| | Before | After |
| --- | --- | --- |
| `$defs.result.properties.threadId` | `null` | `null` or string |
| `x-arkdeck-sampleCounts` | request 25, result 18, error 7 | request 11, result 8, error 3 |

Nothing else in `job.run.json` changed. The sample counts move because the input is the corpus
plus this class's frames, not the original whole-suite recording.

Checks:
- A structural comparison (a scratch script) of every method schema with `9c58e484`'s: 104 are
  byte-identical. `job.run` admits everything the base admitted, and its only widening is
  `threadId`.
- A derivation from the new corpus alone, in an isolated copy, reproduces the same `$defs`.
- Under the new schemas, with jsonschema 4.26: the 12 recorded frames, the 9 `job.run` corpus lines
  and all 796 corpus lines are valid.
- `rust/scripts/generate-contract.py --write` refreshed the checkout manifest
  (`spec/baselines/swift-single-v1.json`): 105 methods, 796 recorded shapes (794 before). `--check`
  passes. `ControlProtocolGenerated.swift` and `control_generated.rs` are unchanged.
- #2012 re-derived four control-action schemas while this slice was gated. On the rebase the manifest
  was taken from `9c58e484` and regenerated, and it differs from main's only by `job.run`.

### `trace.probe`: not changed here

- The Overview reads `targetId`, `bindingRevision`, `supportedTags` and, from each `tools` row,
  `tool`, `disposition`, `family`, `rawHelpSha256` and `detail`.
- The published result was derived from one frame of a test double
  (`DiagnosticsAndHAPContractTests.TraceProbe`). It answers `tools: []`, a null `rawHelp` and
  `rawHelpSha256`, and every parameter as a `"false"` value.
- Production's `FoundationTraceRuntimeProbe` answers otherwise:
  - `tools` always holds the hitrace and the bytrace row;
  - `rawHelp` and `rawHelpSha256` are strings whenever the hitrace help was read;
  - `tool` and `family` are null unless hitrace is capture-eligible;
  - a missing or unreadable parameter has a null `value`, and an unreadable one a string `detail`.
- So the schema admits the rows the Overview reads (`tools` is an array without an item schema) but
  does not describe them, and it refuses most production answers.
- Nothing validates `trace.probe` today. The Swift client does not. The Rust daemon does not route
  it and answers `rejected`, and the Rust CLI has no `trace probe` leaf.
- Publishing the production shape needs frames from the production probe, over the shared fake HDC
  or a scripted runner, and belongs with the Rust `trace.probe` route. No frame was recorded here, so
  the schema is not widened.

## Local targeted checks

| Check | Command | Result |
| --- | --- | --- |
| Targeted, after the fix | `ARKDECK_CONTROL_FRAME_LOG=<fresh dir> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'DebugWindowInventoryJobRunnerContractTests\|DebugApplicationFacadeContractTests\|OverviewCapabilityApplicationFacadeContractTests\|DebugTemplateOperationContractTests'` | 45 tests, 1 failure: the new succeeded test pinned the persisted binding-confirmation action's connect key, which is a placeholder, so it now matches the action's case as `DebugTemplateOperationContractTests` does. The class re-run: 5 tests, 0 failures, recording `control-frames-5199.jsonl` (12 frames, SHA-256 `760f277f3c45fe6be3b2a2ca8bc6b99d9d1f621cc71e4726ecb3d5bbd54430fa`) |
| Red before the fix | the class against `origin/main`'s `DebugApplicationFacade.swift` | 5 tests, 3 failing (6 assertions), as above |
| Schemas and frames, Swift | `ARKDECK_CONTROL_FRAME_LOG=<the 12 recorded frames> run-swiftpm.sh test --filter 'ControlMethodSchemaContractTests\|DebugWindowInventoryJobRunnerContractTests'` | 10 tests, 0 failures. `testFramesRecordedByThisRunValidate` checked the 12 seeded frames (its class runs first) |

This slice also ran the full local unified gate, before #2015 made the PR's CI the gate:
`plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base
--include-worktree --run-local`, through the host's serialized gate queue, with `ARKDECK_PYTHON`
and the planner from a virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0.

- r2, the final run: on `12602f67`, merge base and `origin/main` `9c58e484`, 2026-09-19
  20:04:49–20:31:47 CST (load 7.5 at start). **Exit 0.**
- Lanes: swift, App build-for-testing, design-system and rust (7 changed files).
- SwiftPM full lane: 2704 tests without failure, plus the serialized process-identity race (1) and
  viewer-scale (5) lanes.
- App build-for-testing: `** TEST BUILD SUCCEEDED **`.
- rust: `generate-contract.py --check`, `cargo fmt`, `cargo clippy -D warnings`, and the workspace
  tests: 922 passed, 0 failed, 16 ignored over 127 test binaries. `check-contracts.py` ran the
  published view (the merge base's inputs) and the candidate view (this checkout's), 922 passed
  each, and its isolated host checks passed ("Published and candidate contract checks passed").
  `cargo deny` and `cargo vet` passed.
- design-system: 83/83. `check-sdd`: 0 errors, 0 warnings.
- Log:
  `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/gate-r2.log`,
  SHA-256 `0edd56a35c5782e31aacdebc7737de9540f374cd562e26c304a63c39ecf256f6`.
- r1 ran the same commit on `2b88705f` (as `d778eedb`, 19:35:59–19:58:17 CST) with exit 0: swift
  2702 + 1 + 5, rust 918 passed. #2009–#2012 then landed, and the rebase took main's manifest (see
  "The schemas"), so r2 re-ran the combined tree.

## CI

PR #2014, opened by the bot from `agent/overview-hidumper-terminal-facts-20260919`. On head
`d86f9071` (base `9c58e484`) all 12 checks passed:

| Workflow run | Jobs | Conclusion |
| --- | --- | --- |
| Swift CI `35443177797` | `plan`, `swift-tests`, `app-build`, `ds-interactions`, `rust-checks` (Rust workspace on macos-26, ubuntu-latest and windows-latest; Rust host-independent checks), and the required `swift` aggregate | success |
| SDD Guard `35443177746` | the required `guard`, `ds-tokens` | success |
| Agent PR `35443177715` | `open-pr` | success |

The commit that adds this section changes only this file, and CI runs again on it.

## Not run

- The Overview and HDC UI suites. The Overview UI tests launch with `--ui-test-hdc-diagnostics`,
  whose fixture provider is unchanged.
- A live daemon, an installed App or a device.
