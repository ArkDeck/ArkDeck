# TASK-XPA-014 — agent execution list and abandonment oracle (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: protected main `7cebb912`; no stack. Every request and
answer here is synthetic host data over `/bin/sh` scripts; nothing is device evidence
(POL-VERIFY-001, POL-MODE-001). The only Rust change is where one of #1935's tests reads the Swift
CLI's argv fixtures, which the contract check needs (below). This is the r11 Swift-only oracle for
`agent.list` and `agent.abandon`, the next methods of milestone M1's `agent.*` family. The control
schemas its frames extend are re-derived from them, so the Rust slice that serves the two methods
changes no Swift file.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| The agent execution oracle with the M1 control shapes (#1925); the Rust `agent.run`/`agent.status` and `artifact.list` (#1932), the Rust CLI's `agent run`/`agent status` (#1935) and the capture leg (#1938) | `AgentLifecycleOracleContractTests` and `rust/tests/fixtures/agent-lifecycle/`; `HDCOracleHarness` records a pager snapshot by its kind and mode; the extended control schemas re-derived | The Rust `agent.list`/`agent.abandon` and the CLI's `agent list`/`agent abandon` (lane A, next); the runbook §2.1 HAR path (an execution without a target, `human-action.*`, `agent.resume`), whose oracle needs the harness to compose USB relations and the union owner; `target.adopt`/`target.availability`; `runtime.hdc.*` |

## The oracle

`AgentLifecycleOracleContractTests.testSwiftListsAndAbandonsAgentExecutionsOverTheSharedFakeDevice`
adopts the fake device (connect key `a`×32, tool version 3.2.0d, `TGT-3ba3f5f43b92`). It composes
the daemon's agent execution owner over the harness's engine on the oracle's fixed clock
(`2026-09-14T00:00:00.000Z`), as `AgentExecutionOracleContractTests` does, and reuses that
oracle's fake answers.

It first leaves three executions as `agent run` leaves them.
- `life-observe` runs `observe.device@1` on the adopted target. Its Job's first call is held
  (mode `held`), and the oracle releases it and waits for the execution's durable completion
  (generation 7, `completed`) before anything else, so everything after it reads a settled store.
- `life-unadopted` names a target never adopted (`resourceNotFound`).
- `life-stale` runs `capture.diagnostics@1` with `{"durationSeconds": 5}` at binding revision 2
  against 1 (`bindingRevisionStale`).

Both refused runs leave their execution `orchestrating` at generation 2, without a resolved target.

| Exchange | Method | Answer |
| --- | --- | --- |
| `observed.run` | `agent.run` | `jobOwned`, generation 6 (the Job state labelled `<jobState>`) |
| `observed.status` | `agent.status` | `completed`, generation 7, Job `succeeded` |
| `unadopted.run`, `staleBinding.run` | `agent.run` | `resourceNotFound`; `bindingRevisionStale` |
| `list.all` | `agent.list` | the three, `createdAtDescExecutionIdAsc`: equal times, so by identity (`life-observe`, `life-stale`, `life-unadopted`) |
| `list.page1..3` | `agent.list` | one per page; a string `nextCursor` until the last, and a request names its cursor by the page that minted it (`<nextCursor of list.page1>`) |
| `list.completed`, `list.capture`, `list.target` | `agent.list` | by state, by operation (`life-stale`), by target. The target filter reads the execution's resolved target, so `life-stale`, whose target was never resolved, is not listed there; only `life-observe` is |
| `list.otherQuery`, `list.foreignCursor` | `agent.list` | page 1's cursor with another page size, and `not-a-cursor`: `invalidCursor` (the pager) |
| `list.longCursor` | `agent.list` | a 257-byte cursor: `invalidCursor` "cursor must be a bounded opaque string" (the handler) |
| `list.zeroPageSize`, `list.unknownState` | `agent.list` | `invalidInput` |
| `abandon.staleGeneration` | `agent.abandon` | `life-unadopted` at generation 1: `resourceConflict` "execution generation changed" |
| `abandon.orchestrating` | `agent.abandon` | `life-unadopted` at 2: `abandoned`, generation 3 |
| `abandon.again` | `agent.abandon` | at 3: the abandoned projection again, no write |
| `abandon.jobOwned` | `agent.abandon` | `life-observe`: `resourceConflict` "execution already owns a Job; use explicit job cancel", with its `jobId`; abandonment never cancels a Job |
| `abandon.absent`, `abandon.nonCanonical` | `agent.abandon` | an execution never created: `resourceNotFound`; generation `"02"`: `invalidInput` |
| `abandoned.status`, `abandoned.rerun` | `agent.status`, `agent.run` | the abandoned execution; its own intent sent again is answered from the record, with no write |
| `list.abandoned` | `agent.list` | `life-unadopted` alone |

Every owner refusal carries `phase: preAdmission` and `newDispatchCount: 0`. The refused requests
send only published parameter names with a wrong value (a range, a cursor, a state, a generation),
because a frame's parameters enter the derived request schema whether it is answered or refused.

Recorded (`ARKDECK_RUST_AGENT_LIFECYCLE_RECORD=/private/tmp/xpa014-agent-lifecycle-oracle-r1`,
installed as `rust/tests/fixtures/agent-lifecycle/`, 43 files). `cases.json` holds the target,
the one Job id, the three execution ids and 25 exchanges (13 `agent.list`, 6 `agent.abandon`,
4 `agent.run`, 2 `agent.status`). Beside it are the fake and its 5 calls (the observation's), the
Target document, the Job index and files, the Artifacts, the Session and the storage owner, and the
three execution records. The records of the executions that never reached a Job carry no `jobID`,
`target` or `submissionRequest`. Last come `tree.json` and `provenance.json`. A second recording
(`-r2`) is identical (`diff -r`).

## The harness change

Every first page makes the owner's pager (`RuntimeSnapshotPager`) write
`agent-executions/snapshots/snapshot-<revision>.json` (0600), whose name, revision and cursor tokens
are random. `HDCOracleHarness.files` now records such a file as the tree entry
`agent-executions/snapshots/snapshot-<revision>.json` with its kind and mode, and not its bytes.
The oracle has six: `list.all`, `list.page1`, `list.completed`, `list.capture`, `list.target` and
`list.abandoned`. A page's answer keeps the snapshot's revision and cursor as labels, as before.
The existing fixtures have no such file and are unchanged: the observe, capture and agent execution
oracles pass in compare mode (3 tests, 0 failures).

## The control shapes

The whole Swift suite was recorded with `ARKDECK_CONTROL_FRAME_LOG` (`run-swiftpm.sh test
--parallel`, 2,676 tests, 2,275 frames), this oracle among them in compare mode. Its only failing
test is `testFramesRecordedByThisRunValidate` against main's schemas, with 25 failures.
- 15 are the new `agent.list` and `agent.abandon` frames, this oracle's and other suites'.
- The other 10 are shapes other lanes record outside `swift test --parallel`, as #1925 found:
  `artifact.export` (`outcomeUnknown`, `sensitiveAccessDenied`), and `health`, `runtime.bundle.*`
  and `runtime.tool.*` request parameters. Those methods keep main's schemas.

So only `agent.list` and `agent.abandon` are re-derived, by #1925's procedure. Each is derived from
the whole recording's frames of that method (16 and 9) together with its committed corpus. A
structural check (types, properties, required members, enums, `anyOf`) found that each new schema
admits everything main's did, and every refusal code either publishes has a corpus frame.

| Method | Refusal codes added | Other shapes added | Corpus lines |
| --- | --- | --- | --- |
| `agent.list` | `invalidCursor`, `invalidInput` | the request's `state`, `operation`, `target`, `pageSize` and `cursor` (main's request schema admitted no member); a string `nextCursor`; an item whose `nextAction` is null | 3 → 15, the 3 committed lines kept |
| `agent.abandon` | `invalidInput`, `resourceNotFound` | — | 3 → 5 |

In `agent.abandon`'s corpus, the committed refusal of an execution that owns a Job
(`execution-hap-compensation`) gave way to this oracle's smaller frame of the same shape and code
(`life-observe`); no Rust test reads that line. `agent.run` and `agent.status` keep main's
schemas and corpora. The oracle's two new `agent.run` shapes (a stale binding sent with inputs, and
the abandoned execution's own intent answered from its record) were admitted already, and
`agent.status` has none. `x-arkdeck-sampleCounts` counts the frames each of the two was derived
from: `agent.list` error 2 → 7, request 6 → 19, result 4 → 12; `agent.abandon` error 4 → 8,
request 6 → 12, result 2 → 4. `rust/scripts/generate-contract.py --write` refreshed the checkout
manifest and the Rust bindings: 105 methods, 676 recorded shapes (662 before).

## The contract check's views and #1935's argv fixtures

The first gate (r1, on `3aca7805` over main `11f6ec06`) failed in `rust/scripts/check-contracts.py`.
Clippy stopped in both of its views on `arkdeck-cli`'s `agent_executions` test, which #1935 added.
That test read the Swift CLI's argv fixtures for `agent run`, `agent status` and `artifact list`
with `include_str!` from `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI/argv/`. A view
holds `rust/` and the contract inputs only, and those fixtures are not inputs, so the path is not
there. The views lint and test the whole workspace only when the candidate contract inputs differ
from the published ones. #1935 changed none, so its check ran the candidate view alone, with the
`arkdeck-contract` tests only; this slice's schemas and corpus are the first inputs changed since.
It is not an invalid run: the same inputs fail the same way.

The Rust CLI's other parser samples are packaged under `rust/tests/fixtures/current-cli-argv/`, and
`check-contracts.py` keeps each byte-identical to the Swift corpus (`verify_current_cli_argv`). The
three fixtures join them unchanged, and the test reads them there, so the checkout and both views
compile it.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Oracle, recorded twice | `ARKDECK_RUST_AGENT_LIFECYCLE_RECORD=/private/tmp/xpa014-agent-lifecycle-oracle-r{1,2} run-swiftpm.sh test --filter AgentLifecycleOracleContractTests` | 1 test, 0 failures each; the two recordings identical (`diff -r`), r1 installed |
| Existing oracles after the harness change | `run-swiftpm.sh test --filter 'ArkDeckContractTests.(AgentExecutionOracleContractTests\|ObserveDeviceOracleContractTests\|CaptureDiagnosticsOracleContractTests)'` | 3 tests, 0 failures: their fixtures unchanged |
| Whole Swift suite, recorded | `ARKDECK_CONTROL_FRAME_LOG=/private/tmp/xpa014-frames-lifecycle-r1 run-swiftpm.sh test --parallel` | 2,676 tests, 2,275 frames; the only failing test is `testFramesRecordedByThisRunValidate` against main's schemas (above) |
| Oracles and schemas, compare mode | `ARKDECK_CONTROL_FRAME_LOG=<the recording's 25 agent.list and agent.abandon frames> run-swiftpm.sh test --filter 'ArkDeckContractTests.(AgentExecutionOracleContractTests\|AgentLifecycleOracleContractTests\|CaptureDiagnosticsOracleContractTests\|ControlMethodSchemaContractTests\|ObserveDeviceOracleContractTests)'` | 9 tests, 0 failures. The four oracles match byte for byte. The committed corpus is valid under the new schemas, and so are the recording's 25 frames and the 110 this run recorded. |
| Rust manifest | `rust/scripts/generate-contract.py --write`, then `--check` | 105 methods, 676 recorded shapes (662 before); the check passes |
| Rust contract and control tests | `cargo test -p arkdeck-contract -p arkdeck-control` | pass; `corpus_parity` 10 of 10, `read_only` 15 of 15 |
| Packaged argv samples | `cmp` of the three against the Swift corpus; `cargo test -p arkdeck-cli --test agent_executions` | identical; 10 of 10 pass, on main `7cebb912` |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local` (merge base `7cebb912`; r1's was `11f6ec06`), with
`ARKDECK_PYTHON` naming `.venv-sdd` and the planner run from a virtual environment carrying PyYAML
6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `3aca7805` | `gate exit=1`: `check-contracts.py`, Clippy in both views on #1935's argv fixture paths (above) | `/private/tmp/xpa014-agent-lifecycle-oracle-gate-20260914-r1.log` |
| r2 | `23dffd3d` | `gate exit=0`: the common checks and SDD, the Swift lane (full parallel, 2,670 tests, then the serialized lanes), the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 1,992 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-agent-lifecycle-oracle-gate-20260914-r2.log`, SHA-256 `aaa6ef0bde6d3b1e45e9eb3a94d6b142dac0acfb23b6fc557b4ce255f1756da9` |

## Not run, and why

- **No Rust replay yet.** The Rust daemon answers `agent.list` and `agent.abandon` with the control
  foundation's `rejected`; lane A's next slice serves them and replays this fixture in-process and
  with `rust/scripts/check-corpus-replay.py`.
- **The HAR path.** The runbook §2.1 path is not oracled here: an execution without a target,
  human actions, `agent.resume`, and `agent.abandon` of an execution waiting for a person, which
  expires its action. Its oracle needs the harness to compose USB relations (any Connected candidate
  is refused without one) and the daemon's union human-action owner, and its action and resume
  references are random.
- **Snapshot bytes.** The pager's snapshot bytes are not compared, only their count, kind and mode.
- No device, no real HDC: the fake answers what the daemon asks.
