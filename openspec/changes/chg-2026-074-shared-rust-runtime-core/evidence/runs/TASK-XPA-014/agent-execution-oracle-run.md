# TASK-XPA-014 — agent execution oracle with an explicit target, and the M1 control frames (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: protected main `eedc0a0a`, which carries the
`observe.device@1` oracle (#1918), the capture oracle with `HDCOracleHarness` (#1921) and the M2 oracles that extended the harness (#1924); no stack. Every request and
answer here is synthetic host data over `/bin/sh` scripts; nothing is device evidence
(POL-VERIFY-001, POL-MODE-001). No Rust code changes: this is the r11 Swift-only oracle for the
agent execution layer of Golden Journey 1, and the control-method schemas the Rust gate enforces
are re-derived from its frames, so that the Rust `artifact.list` and `agent.run`/`agent.status`
slices that follow change no Swift file.

## Already on main / this slice / still remaining

| Already on main (and on the base PRs) | This slice | Still remaining for M1 |
| --- | --- | --- |
| The shared fake HDC and the `observe.device@1` oracle (base PR), `HDCOracleHarness` and the `capture.diagnostics@1` oracle (base PR); the Rust `observe.device@1` engine (lane A, open) | `HDCOracleHarness.composition(…, agentExecutions: true)`: the daemon's agent execution owner and the Target observation owner composed as `main.swift` composes them, on the oracle's clock, and the owner's directory recorded; `AgentExecutionOracleContractTests` and `rust/tests/fixtures/agent-execution/`; the `agent.run`, `agent.status`, `artifact.list` and `job.result` schemas re-derived from its frames | Rust `artifact.list` and Rust `agent.run`/`agent.status` with the CLI's `agent run`/`agent status` (lane A, next), Rust `capture.diagnostics@1`; the runbook §2.1 HAR path (`agent.run` without a target, `human-action.*`, `agent.resume`), `device candidates`, `target adopt/show/availability`, `runtime service verify` and `runtime.hdc.*` |

## The oracle

`AgentExecutionOracleContractTests.testSwiftRunsAgentExecutionsOverTheSharedFakeDevice` adopts the
fake device (connect key `a`×32, tool version 3.2.0d, `TGT-3ba3f5f43b92`) and sends Golden Journey
1's two runs as the runbook (§2) and the Swift CLI's `runtimeExecutionIntent` send them: `agent
run --operation observe.device@1 --target <TGT> --maximum-wait 5m` and the same with
`capture.diagnostics@1` and `{"durationSeconds": 5}` — the target without a binding revision
(the owner pins the current one into the Job request), the budget `"300000"`, no request file.
The owner is the daemon's `RuntimeAgentExecutionCoordinator` over the harness's engine, with the
oracle's fixed clock (`2026-09-14T00:00:00.000Z`), so every record's `createdAt`, `deadline` and
`lastObservedAt` are fixed.

A run answers once its Job is owned (generation 6, `jobOwned`) while the Job starts in the
background, so the fake holds the Job's first call — mode `held`: every call waits until the oracle
creates `released`, and a Job calls one at a time, so `-v` for `observe.device@1` and `list targets
-v` for `capture.diagnostics@1` is the one held. The oracle reads the running execution while the
call is held, releases it and waits for the execution's durable completion (generation 7,
`completed`, the owner's last write). The Job state the accepted run reads is any state before the
held call, so the oracle keeps its name (`<jobState>` in `jobState`, `job.state`, `job.outcome`),
not its value; nothing else in that answer depends on timing (the residue count is refreshed only on
cleanup paths and the Session publication fact only at finalization).

| Exchange | Method | Answer |
| --- | --- | --- |
| `observed.run`, `captured.run` | `agent.run` | `jobOwned`, generation 6, the Job owned (state labelled) |
| `observed.running`, `captured.running` | `agent.status` | `jobOwned`, Job `running` (the call held) |
| `observed.status`, `captured.status` | `agent.status` | `completed`, Job `succeeded`, evidence `verified`, the Artifacts |
| `observed.rerun`, `captured.rerun` | `agent.run` | the same intent again: the completed execution, no new dispatch |
| `observed.conflict`, `captured.conflict` | `agent.run` | budget `"600000"` under the same identity: `idempotencyConflict` with `executionId` |
| `observed.result/evidence/artifacts`, `captured.…` | `job.result`, `job.evidence`, `artifact.list` | the owned Jobs' reads |
| `observed.page1..3` | `artifact.list` | the observed Job's three Artifacts one per page; `hasMore` and a string `nextCursor` until the last |
| `observed.otherQuery` | `artifact.list` | page 1's cursor with another page size: `invalidCursor` (the pager) |
| `observed.foreignCursor` | `artifact.list` | `not-a-cursor`: `invalidCursor` (the pager) |
| `observed.emptyCursor` | `artifact.list` | `""`: `invalidCursor` "Artifact cursor is malformed" (the handler) |
| `observed.absentOwner` | `artifact.list` | a Job that does not exist: `resourceNotFound` |
| `unadopted.run` | `agent.run` | a target never adopted: `resourceNotFound`; the execution stays `orchestrating` at generation 2 |
| `staleBinding.run` | `agent.run` | `expectedBindingRevision: 2` against 1: `bindingRevisionStale`; `orchestrating` at generation 2 |
| `budgetOutOfBound.run` | `agent.run` | budget `"0"`: `invalidInput`, no execution |
| `unpublishedOperation.run` | `agent.run` | `observe.device@2`: `invalidInput`, no execution |
| `rejectedInputs.run` | `agent.run` | `capture.diagnostics@1` with `durationSeconds: 0`: `invalidInput` "typed operation inputs were rejected", no execution |
| `absentExecution.status` | `agent.status` | `resourceNotFound` |

Every owner refusal carries `phase: preAdmission` and `newDispatchCount: 0` (`artifactOwner` for
the Artifact refusals). The refused intents send only published field names with a wrong value
(a range, a revision, an identity), because a frame's parameters enter the derived request schema
whether it is answered or refused.

Recorded (`ARKDECK_RUST_AGENT_EXECUTION_RECORD=/private/tmp/xpa014-agent-execution-oracle-r3`,
installed as `rust/tests/fixtures/agent-execution/`, 76 files): `cases.json` (the target, the two
Job ids, the two execution ids and 29 exchanges; a request sending a cursor names the exchange
whose page minted it, `<nextCursor of observed.page1>`, and a page's cursor and snapshot revision
are labelled), the fake and its 11 calls, `targets-state/targets.json`, `store/index.json` and
every Job file, every Artifact, the two Sessions and the storage owner, the four execution records
(`agent-executions/execution-<sha256(executionId)>.json`, 0600, in a 0700 directory with the empty
`snapshots` pager directory), `tree.json` and `provenance.json`. A replay reads `mode` (the fake's
mode for that exchange; `held` removes `released` first) and `before` (`heldCall`: wait for the held
call; `release`: create `released` and wait for the execution record to say `completed`).

Runs: r1 and r2, both with the first guard (below), match byte for byte; r3 and r4, with the final
guard, match byte for byte (`diff -r`), and r3 is the installed fixture. In compare mode the
oracle passes beside the observe and capture oracles and the schema tests (7 tests, 0 failures),
and inside the whole Swift suite run in parallel (2,671 tests), whose only failures were
`testFramesRecordedByThisRunValidate` against main's schemas — what that recording was for.

The first recording held only the `-v` call, which is `observe.device@1`'s first; the fake's call
log showed that `capture.diagnostics@1` never calls `-v` (its first step is
`confirm-evidence-target`, as in the capture oracle's own log), so its running execution was read
by luck, not by construction. The guard now holds every call of a held run; r1 and r3 differ only
in `hdc-answers.sh` and the provenance digest of it.

## The control shapes

A first derivation over the committed corpus plus the recorded frames with new shapes (the
capability-read slice's method) had two defects, both from the same property of the generator:
the committed corpus keeps one frame per shape, and refusals of one shape differ only in their
code. The pruning dropped `artifact.list`'s absent-owner refusal as a known shape, so
`resourceNotFound` was missing (`testFramesRecordedByThisRunValidate` failed on it); and for
`job.plan`, whose 75-frame recording the six-line corpus summarizes, the derivation over the corpus
unpublished `admissionDenied`, `inputTooLarge` and `operationUnavailable`, which no corpus frame
evidences. So:

- `generate-control-contract.py` now keeps, after one frame per shape, the smallest frame of every
  recorded refusal code the shape selection dropped, so that a derivation over the committed corpus
  publishes the same codes.
- The shapes were derived from a recording of the whole Swift suite (`run-swiftpm.sh test
  --parallel` with `ARKDECK_CONTROL_FRAME_LOG`, 2,119 frames), which includes this oracle. That
  recording alone is not a superset of main's schemas either: it differs from them for 22 methods,
  and for `history.filter.list/save`, `runtime.bundle.inspect/list/remove` and `runtime.tool.*` it
  loses properties (and `runtime.tool.register` the code `inputTooLarge`), whose shapes were
  recorded by runs outside `swift test --parallel`. So only the five methods Golden Journey 1
  needs are published, each derived from the whole recording's frames of that method together
  with its committed corpus (except `job.result`, below), and a structural check (types,
  properties, required members, enums, `anyOf`) found that each new schema admits everything
  main's did. The 17 other methods keep
  main's schemas and corpora; among their unpublished recorded shapes are `artifact.export`'s
  `outcomeUnknown` and `sensitiveAccessDenied`.

| Method | Refusal codes added | Other shapes added | Corpus lines |
| --- | --- | --- | --- |
| `agent.run` | `admissionDenied`, `bindingRevisionStale`, `idempotencyConflict`, `invalidInput`, `resourceNotFound` | request `target` (`targetId`, optional `expectedBindingRevision`) and `inputs.durationSeconds`; error detail `executionId`; result `failureCode` as a string, a null `nextAction`, a published Session's `catalogGeneration` and `manifestSha256` and a null `reasonCode` | 10 → 21 |
| `agent.status` | `resourceNotFound` | the published Session's facts | 9 → 11 |
| `artifact.list` | `invalidCursor`, `resourceNotFound` | request `cursor`; a string `nextCursor` | 10 → 16 |
| `job.plan` | — | `inputs.durationSeconds` in the planned request | 6 → 9 |
| `job.result` | — | `inputs.durationSeconds` in the request | 21 → 23 |

`admissionDenied`, a string `failureCode` and a null `nextAction` on `agent.run` come from other
suites' executions refused at admission: recorded before, published now. Every refusal code the
five schemas publish has a corpus frame, except `job.plan`'s `inputTooLarge`, whose frame exceeds
the generator's 64 KiB sample bound, as it did before. `job.result` is derived from its committed
corpus and this oracle's two frames: with the whole recording's other new shapes its corpus passes
the generator's bound of 24 shapes, which cuts by sort order — there, two committed shapes, one of
them the refusal whose `nextAction` has no `retryAfter` that the Rust corpus tests read (the gate's
first run failed on it); now all 21 committed lines stay. `x-arkdeck-sampleCounts` now counts the
frames each of the five was derived from. `rust/scripts/generate-contract.py --write` refreshed
the checkout manifest and the Rust bindings (105 methods, 662 recorded shapes).

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Oracle, recorded | `ARKDECK_RUST_AGENT_EXECUTION_RECORD=/private/tmp/xpa014-agent-execution-oracle-r{3,4} run-swiftpm.sh test --filter AgentExecutionOracleContractTests` | 1 test, 0 failures each; the two recordings identical |
| Oracles and schemas, compare mode | `ARKDECK_CONTROL_FRAME_LOG=<every recorded frame of the five methods> run-swiftpm.sh test --filter 'ArkDeckContractTests.(AgentExecutionOracleContractTests\|ObserveDeviceOracleContractTests\|CaptureDiagnosticsOracleContractTests\|ControlMethodSchemaContractTests)'` | 7 tests, 0 failures: the three oracles byte for byte, the committed corpus and every recorded frame of the five methods valid under the new schemas |
| Whole Swift suite, recorded | `ARKDECK_CONTROL_FRAME_LOG=/private/tmp/xpa014-frames-full-r1 run-swiftpm.sh test --parallel` | 2,671 tests; failures only in `testFramesRecordedByThisRunValidate`, against main's schemas |
| Rust manifest | `rust/scripts/generate-contract.py --write`, then `--check` | 105 methods, 662 recorded shapes; the check passes |
| Rust contract tests | `cargo test -p arkdeck-contract` | every target passes, `corpus_parity` 8 of 8 |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local` over the three commits of the stack (merge base
`aa4cc8d8`), with `ARKDECK_PYTHON` naming `.venv-sdd` and the planner run from a virtual environment
carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `59caa92a` | `gate exit=1`: the common checks and the Swift lane passed; the Rust lane's `corpus_parity` failed `reconciled_finish_time_and_optional_retry_after_keep_their_value_types` ("job.result: missing recorded nextAction without retryAfter"): the whole-recording derivation of `job.result` had cut that frame at the 24-shape bound (above) | `/private/tmp/xpa014-agent-oracle-gate-20260914-r1.log`, SHA-256 `437e72315e87dd3c7bac12633aad66a5bdf14b037631b9d6616779fcb0c94b91` |
| r2 | `cf187736` (`job.result` re-derived as above) | `gate exit=0`: the common checks, SDD (0 errors, 0 warnings, 121 acceptance IDs), the Swift lane (full parallel, 2,665 tests, then the serialized lanes) and the Rust lane on the development and candidate views (Clippy, workspace tests, the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-agent-oracle-gate-20260914-r2.log`, SHA-256 `21e27652f1b43b2307b42050c95dac527976dddd62b2d4a2c5a969ae861b34d5` |
| r3 | `e060d927` (this commit alone, rebased onto main `eedc0a0a`) | `gate exit=0`: the common checks, SDD (0 errors, 0 warnings, 121 acceptance IDs), the Swift lane (full parallel, 2,668 tests, then the serialized lanes) and the Rust lane on the development and candidate views (Clippy, workspace tests, the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-agent-oracle-gate-20260914-r3.log`, SHA-256 `cd7de3848dd7407c5fd3f865b4d87e318b336e0b9f243735fe437ee75c17d689` |

The amends after r2 only fill in this row and the base. Both runs used the stack on `aa4cc8d8`;
after #1918 merged, this commit was replayed without conflict onto #1921's new head `f0968697`
(main `b274093c`, the same #1921 patch), and after #1921 merged, onto main `cdfd18ad`, again
without conflict. Main's commits since `aa4cc8d8` touch none of this commit's files except
`tasks.md`, and no contract input: on `cdfd18ad` `generate-contract.py --check` passes (105
methods, 662 recorded shapes) and SDD reports 0 errors and 0 warnings.

After #1920, #1924 and #1928 merged, this commit was rebased onto main `eedc0a0a`.
`HDCOracleHarness.swift` conflicted where #1924 had added the code-sign helper to
`composition(...)` and the Artifact store to `Composition`; the resolution keeps both beside
`agentExecutions`, and `tasks.md` keeps both bullets. On `eedc0a0a` the five HDC oracles (this
one, `observe.device@1`, `capture.diagnostics@1`, `debug.hap@1` and the app-owned native
library deploy) and the schema tests pass in compare mode (9 tests, 0 failures, 1 skipped),
`generate-contract.py --check` passes (105 methods, 662 recorded shapes), SDD reports 0 errors
and 0 warnings, and r3 gated the rebased commit. The amend after r3 only records the rebase.

## Not run, and why

- No Rust replay: the Rust daemon serves neither `artifact.list` nor `agent.run`/`agent.status`
  yet (lane A's next slices replay this fixture with `rust/scripts/check-corpus-replay.py` and an
  in-process replay test); until then the replay records these methods as not served.
- No device, no real HDC: the fake answers what the daemon asks.
- The runbook §2.1 HAR path (an execution without a target, `human-action.*`, `agent.resume`) is
  not oracled here: it needs the Target observation owner over candidate listing and physical
  relations, and its action and resume references are random.
