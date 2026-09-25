# Agent executions whose evidence the published agent results had not sampled (TASK-XPA-015, macOS, 2026-09-26)

GJ-5's fake rehearsal of 2026-09-25 (`gj5-fake-rehearsal-2026-09-25.md`, Defect 2) found
`arkdeck agent run` exiting 70 with `internalError` "the result does not conform to the current
contract" (`details.method` `agent.status`) for Jobs that had succeeded: the workspace operations
and `input.tap@1`, `input.long-press@1`, `input.swipe@1`. The daemon's own conformance check
refused its `agent.status` answer.

This change records Swift's answers for those executions, and for executions of the same kinds
resumed after physical assistance. It widens, from those frames only, the four result schemas
that carry an execution's evidence: `agent.run`, `agent.status`, `agent.resume` and
`human-action.resume`. **It changes contract inputs**:
`spec/control/methods/{agent.run,agent.status,agent.resume,human-action.resume}.json`, ten lines
appended to their corpora under `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/`,
and the regenerated `spec/baselines/swift-single-v1.json`. These are outside this task's Allowed
paths, declared as #2161 declared its own.

Base: protected `main` `3315a9cba` (#2217), which holds #2197 (`f5c216e95`) and #2207 (`a3de6c316`);
developed on `a574e0654` (#2196).

## What a caller saw, and what was left on `main`

- The rehearsal ran on `cc5b5670` (#2151), before #2161 widened `agent.run` and `agent.status`
  for a host-only Job's Artifacts. On `a574e0654` the workspace copy already completes: `arkdeck
  agent run --operation workspace.prepare-isolated-copy@1` against the isolated Rust daemon exits
  0 (reproduced here; the new process test now holds it).
- The gestures still exited 70 on `a574e0654` (reproduced with a managed fake HDC and the
  development mutation authority). A gesture runs under the Runtime capability for its
  operation, which names no Artifact. Its evidence authority therefore carries
  `artifactDigest: null`, which the published `agent.status` result refused, and `agent.run`'s
  too.
- The same held after physical assistance, and further. A tap that names no target waits for a
  person to connect the device. Once it was connected, `agent resume` exited 70 at its
  `agent.status` read. Resuming the resolved action again (`agent resume`,
  `human-action resume`) exited 75 (`outcomeUnknown` over the wire's `internalError`): the
  published `agent.resume` and `human-action.resume` results are narrower still. They also refuse
  a host-only execution's null binding revision, stable identity, observation and first evidence
  step.

## Swift, the oracle

`AgentExecutionEvidenceOracleContractTests` (new) records
`rust/tests/fixtures/agent-execution-evidence/`: 44 exchanges, 20 calls to the fake device, 111
files. It drives the daemon's agent execution and human-action owners through the production
control plane over the shared fake HDC (`HDCOracleHarness`). A registered workspace project's
provider is composed beside them. `HDCOracleHarness.composition` gains `workspace:`, a provider
and its dispatch route, which the router serves as the daemon routes a registered project's
operations. The analyzer provider is composed as in #2161. The oracle records:

- the three gestures on the adopted Target, as `agent run --operation <gesture> --target <TGT>
  --inputs-file <file>` sends them;
- `workspace.prepare-isolated-copy@1` of the registered project, whose target is the project
  reference;
- a tap and a crash-signature analysis that name no target. Each waits for the device to be
  connected (`connectDevice`), is resumed once it is replugged, and is resumed again after
  completion by `agent.resume` and by `human-action.resume`.

Each run's Job is held until the oracle releases it: a gesture at its injection, the copy at its
isolation, the analysis in its analyzer. An answer read while the Job starts therefore keeps the
name of its Job state, not its value. Every Job's result, evidence and Artifacts are read last.

The device is the pointer oracle's (`PointerInputOracleContractTests.answers`, now internal; its
bytes are unchanged), with three additions:

- the tool's version (`-v`), which an adoption verifies;
- a `held` mode that holds the injection;
- an `offline` mode that lists the device offline.

The workspace presets are fixed scripts under the oracle's root, so no digest of this host's
tools enters the profile.

What Swift answers:

- A gesture's authority is `runtimeCapability` with `artifactDigest: null`.
- A host-only execution (the copy, the analysis) has a null binding revision, stable identity,
  observation and first evidence step.
- The execution's `job.outstandingResidueCount` is null.
- The second and later gestures' Sessions fail to publish (`sourceIntegrityFailed`), as in the
  committed pointer oracle.

The oracle was recorded once (r1) and then compared byte for byte (r2).

## Contract inputs

Only the four methods were re-derived with `generate-control-contract.py --derive-method-schemas`,
over their committed corpus plus, for every result signature the corpus lacked, the smallest
recorded frame of that signature (script `derive_kept.py` in the session's scratchpad). The
checks:

- The corpora are append-only: every committed line is kept in place, and ten are appended.
- The schema derived from the final corpus equals the one derived from the corpus plus every
  recorded frame (`$defs` identical).
- The generator's own selection over the final corpus keeps every line it kept of the committed
  corpus, and every new one. No line is lost to the 32-shape cap.
- Structurally, each new schema admits everything the old one admitted. `request`, `errorCode`
  and `errorDetails` are byte-identical; only `result` and `x-arkdeck-sampleCounts` change. The
  sample counts now count the corpus lines, as in #2161.

| Method | Corpus lines | Result members that now also admit `null` |
|---|---|---|
| `agent.run` | 28 → 30 | `evidence.authority.artifactDigest` |
| `agent.status` | 12 → 15 | `evidence.authority.artifactDigest` |
| `agent.resume` | 15 → 18 | `evidence.authority.artifactDigest`; `artifacts[].bindingRevision`, `artifacts[].stableIdentitySha256`; `evidence.artifacts[].bindingRevision`, `evidence.artifacts[].stableIdentitySha256`; `evidence.bindingRevision`, `evidence.firstEvidenceStepAtUtc`, `evidence.observation` |
| `human-action.resume` | 26 → 28 | the same eight as `agent.resume` |

`human-action.resume`'s corpus already held two lines of one shape: two HDC restart
control-action results appended by #2101. A derivation over the corpus alone keeps one of them.
Appending leaves both.

Against the old schemas, jsonschema 4.26 (the validation venv) refused 11 of the 26 recorded
execution frames:

- `agent.run`: 3 of 10;
- `agent.status`: 4 of 10;
- `agent.resume`: 2 of 4;
- `human-action.resume`: 2 of 2.

Against the new schemas it admits all of them, the 18 Job and Artifact reads (which the published
schemas already admitted), both recordings' frames and the four corpora.

- Baseline: `generate-contract.py --write` gives 105 methods, 1019 recorded shapes and contract
  identity `1d7d101e83fe`; `--check` exits 0.
- The machine-contract bundle is unaffected: `arkdeck maintainer contracts check` (Rust, this
  build) reports clean, with 235 checked, 0 drifted, 0 missing and 0 unexpected, so no export was
  needed.

Other `agent.*` results do not carry evidence. `agent.list` rows already admit a null binding
revision and target. `agent.abandon` answers only an execution that owns no Job.

## Rust

No production change: the Rust owners already answer these executions as Swift does once the
schemas admit them.

- `rust/crates/arkdeck-agentd/tests/agent_run_cli_process.rs` (new) runs the real `arkdeck` CLI
  against the real daemon on an isolated development root. The root has a managed fake HDC, the
  development mutation authority and a development USB relations file. The test covers:
  - a workspace project registered through the CLI; the daemon restarts, and `agent run` of
    `workspace.prepare-isolated-copy@1` completes;
  - the three gestures on the adopted Target, each completed under its operation's capability
    with `artifactDigest: null`, and each injection acknowledged once;
  - the tap sent again under its identity, answered by `agent.run` with no new injection;
  - a tap that names no target: it waits for the device (exit 75), `agent resume` completes it
    once the device is connected, and `agent resume` and `human-action resume` of the resolved
    action answer the completed execution with no new injection.

  Every completion exits 0 with the Job `succeeded` and the evidence verified. The fake is
  `rust/tests/fixtures/managed-hdc/fake-hdc.c`, whose new `DRIVER` option execs a script for every
  command that is not the server's. The server the daemon launched and proved thus stays that
  executable, while the oracle's device (`agent-execution-evidence/hdc-answers.sh`) answers its
  clients. The contract a view compiled decides what the test expects: before the widening, a
  published view's merge base refuses the daemon's own answer (`internalError`, the CLI exits 70),
  and the test then also asserts it is in that view.
- Before the widening, the test fails at the first gesture ("agent.status must publish
  input.tap@1").
- The Rust daemon's completed answers have Swift's shape: the same members and JSON types as the
  oracle's `tap.status` and `isolate.status`, read after durable completion
  (`job.outstandingResidueCount` null in both).

## A race the process test found, fixed apart

The first `check-contracts.py` pass failed in its candidate view on the new process test. The tap
right after the workspace copy was refused before admission (`admissionDenied` "Session storage
is being updated", zero dispatch). `agent run` returns once the owned Job is terminal, while the
run still publishes that Job's Session under the Session storage lock. The admission read the
storage status without waiting for that lock, where Swift's `validateMutationState` waits. The
coordinator ruled that the fix goes in its own PR, #2207 (TASK-XPA-014), which merged first as
`a3de6c316`. This branch is rebased on it; the test changes nothing for it.

## Checks (local, targeted)

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-vj-rust-target`, logs `/private/tmp/arkdeck-vj-logs/`.
All on this branch rebased on `da76e3e8e` (#2215). After the rebase onto `3315a9cba` (#2216 and #2217,
which touch no contract input), `generate-contract.py --check`, `cargo fmt --all --check`, the
`arkdeck-agentd` clippy and `agent_run_cli_process` (3 of 3) ran again: all pass.

Contract and SDD:
- The Swift baseline regenerated after the rebase: `generate-contract.py --write` then `--check`,
  exit 0. It holds 105 methods and 1020 shapes, contract identity `1d7d101e83fe`; the one shape
  more than before the rebase is #2197's. The four methods' corpora and schemas are unchanged on
  `main` since this branch was cut, so their derivation stands.
- `cargo fmt --all --check`: exit 0 (`c-fmt.log`).
- `sh scripts/check-sdd.sh` (validation venv): exit 0.
- `arkdeck maintainer contracts check --contracts-directory openspec/contracts
  --fixtures-directory Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI`: clean, 235
  checked, none drifted, missing or unexpected (`c-contracts-check.json`).
- jsonschema 4.26 over both Swift recordings' frames and the four corpora: all admitted.

Rust:
- `cargo clippy -p arkdeck-contract -p arkdeck-agentd -p arkdeck-provider-hdc -p arkdeck-hoststore
  --all-targets -- -D warnings`: exit 0 (`c-clippy.log`).
- `cargo test -p arkdeck-contract -p arkdeck-control -p arkdeck-agentd -p arkdeck-cli -p arkdeck-client
  -p arkdeck-soak -p arkdeck-provider-hdc -p arkdeck-hoststore --no-fail-fast`: exit 0, 197
  suites, 1484 passed, 0 failed, 14 ignored (the ignores already existed) (`c-test.log`).
- `agent_run_cli_process` alone: 10 of 10.
  - Before #2207, about one run in twenty refused the tap (the section above).
  - On the published schemas it fails at the first gesture. With only `artifactDigest` widened by
    hand (a diagnostic, reverted), 8 of 8 passed once the step-kind assertion was fixed.
- `check-contracts.py` (validation venv, `--output-dir /private/tmp/arkdeck-vj-contract-check`),
  on `da76e3e8e`: exit 0, "Published and candidate contract checks passed" (`c-check-contracts.log`).
  - The published view is at the merge base `da76e3e8e`; the candidate view is at this checkout.
  - The two views ran 452 suites together: 3446 passed, 0 failed, 36 ignored. The process test
    passed in both, expecting the published schemas to refuse the gestures in the first.
  - The read-only host check and every owner check reported `PASS`.

Swift (a window granted by the coordinator session; one SwiftPM process at a time):
- `run-swiftpm.sh test --filter AgentExecutionEvidenceOracleContractTests`, recording (r1)
  with `ARKDECK_CONTROL_FRAME_LOG`: exit 0.
- `--filter 'AgentExecutionEvidenceOracleContractTests|ControlMethodSchemaContractTests'` with a
  fresh frame log (r2): exit 0. The oracle compares byte for byte, and all five schema tests pass,
  `testFramesRecordedByThisRunValidate` included.

Not run: the App, which calls none of the four methods, and a device.

## CI

Pending.
