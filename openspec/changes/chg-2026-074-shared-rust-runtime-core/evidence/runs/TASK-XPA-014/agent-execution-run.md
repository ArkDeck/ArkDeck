# Rust `agent.run`, `agent.status` and `artifact.list` on the isolated daemon — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: protected main `b0806334`, which carries the Swift agent
execution oracle and the M1 control shapes this slice replays (#1925), the Rust `observe.device@1`
engine (#1920), the M2 oracles (#1924), the HDC process dispatch (#1928), the managed HDC server
(#1930), the HDC lifecycle executor (#1931) and the map-valued control members (#1929); no stack. This is the second slice of milestone M1 (GJ-1) under r11: the isolated Rust development
composition answers Golden Journey 1's agent entry — `agent.run` for an explicit target and
`agent.status` — and the Job owner's `artifact.list` as the Swift daemon does, against the oracle
#1925 recorded.
Nothing installed changes and no device is reached: the isolated owner runs a fixture HDC only.

## Already on main / this slice / still remaining

| Already on main, or below this commit | This slice | Still remaining for M1 (GJ-1) |
| --- | --- | --- |
| The analyzer's plan, admission, run, result, evidence, Session publication and cancellation (#1892–#1900); the capability reads (#1909); the macOS HDC server identity (#1914, #1926); `observe.device@1` end to end on the isolated daemon (#1920); the M2 oracles (#1924); the HDC process dispatch (#1928); the agent execution oracle with its control shapes (#1925); the managed HDC server (#1930); the HDC lifecycle executor (#1931); map-valued control members (#1929) | `agent.run` and `agent.status` for an explicit target — the execution record, the intent, target resolution, the typed Job request, submission, the owned Job's background run, `finishJob` and the result projection with evidence and Artifacts; `artifact.list` for Job owners; their routing and composition; the in-process replay of #1925's oracle; `artifact.list` in the observe replay; agent oracles in the real-process harness | The Rust CLI's `agent run`/`agent status` and `artifact list`; `capture.diagnostics@1` (its Jobs, then this oracle's capture run); executions without a target, `agent.list`/`resume`/`abandon`, HAR and `human-action.*`; `target.adopt`/`target.availability`; `runtime.hdc.*`; `operation.list`/`doctor` availability of the HDC operations; the daemon's HDC composed through #1928's process dispatch, and a registered HDC behind the server identity proof; the restart carry-over of owned and parked Jobs (after the §L.1 item 13 ruling); GJ-1 on the real device |

## Behaviour

- **Execution record** (`arkdeck-hoststore/src/agent_execution.rs`): Swift's
  `arkdeck.runtime-agent-execution/1` document at
  `agent-executions/execution-<sha256(executionId)>.json` — canonical JSON, `0600` in a `0700`
  directory beside the empty `snapshots/` pager directory Swift creates when the owner opens —
  atomically replaced one generation at a time and validated whenever it is read.
- **Intent**: Swift `AgentExecutionIntent` — the closed key set, Swift's messages, an orchestration
  budget of 1 ms to 24 h in canonical decimal, and the fingerprint
  `sha256(JCS(intent without executionId and reviewedPlanDigest))`. A new execution's inputs are
  checked against the Catalog descriptor ("typed operation inputs were rejected"); the same
  identity under another intent is `idempotencyConflict` with the execution identity.
- **Drive**: Swift `drive` for an explicit target — generation 1 creates the execution
  (`orchestrating`) with its deadline, 2 observes the budget, 3 records the target resolved against
  the Target owner's adopted route (a target never adopted is `resourceNotFound`, a stale expected
  revision `bindingRevisionStale`; both leave the execution orchestrating at generation 2), 4
  observes the budget again, 5 records the exact typed Job request (`creatingJob`;
  `agent-request-<seed>` and `agent-execution-<seed>` with the seed `sha256(executionId)`,
  `derivedArtifacts`), which the Job admitter then admits, and 6 records the owned Job
  (`jobOwned`), which is answered. An admitted Job whose record update was lost is found again by
  its idempotency key and fingerprint. Swift's refusal lanes: a reviewed-plan mismatch or an
  idempotency conflict ends the execution `failed`, as does any other refusal carrying the
  zero-dispatch proof (`admissionDenied`).
- **Background run**: the daemon starts the owned Job's run on its own thread over the same stores,
  registered with its running Jobs before the answer goes out, so `job.run` joins it and
  `job.cancel` reaches it; when the run returns, generation 7 records the Job's state (`completed`
  once terminal, Swift `finishJob`, whose failure changes nothing).
- **Reads**: `agent.status`, and `agent.run` of an execution that owns its Job, answer from the
  record and the Job without a write, `completed` as soon as the Job is terminal, as Swift answers.
  Swift `executionResultProjection` adds the Job's state and next action and, once the Job is
  terminal, its evidence (Swift `encodeEvidence` without parameters and Trace probes, status
  `verified` or `blocked`) and its verified Artifacts.
- **`artifact.list`** (`artifact_resources.rs`): Swift's handler checks — closed parameters
  (`invalidInput`), an absent Job owner (`resourceNotFound`), an empty cursor or one over 2,048
  bytes (`invalidCursor`) — then `RuntimeSnapshotPager`'s paging in `createdAtDescArtifactIdAsc`
  order, 1 to 1,000 per page (100 by default), cursors `<revision>.<token>`, and a cursor of another
  query or of a reclaimed snapshot refused (`invalidCursor`); refusals carry the `artifactOwner`
  proof.
- **Composition** (`arkdeck-agentd`, `arkdeck-control`): the isolated root gains a private
  `agent-executions` directory, reserved from the Session roots. A control host that does not
  implement the owner still answers the agent methods `rejected`; the Rust daemon, like Swift's,
  answers them `operationUnavailable` ("AgentExecution owner is unavailable") with the
  zero-dispatch proof whenever it composes no owner, as outside an isolated root, on macOS; on the
  other platforms no daemon composes the owner and the methods keep the foundation's `rejected`.

## Shared oracle

`rust/tests/fixtures/agent-execution/` (#1925) is recorded by Swift
`AgentExecutionOracleContractTests` with the daemon's coordinator composed over the shared fake
(`HDCOracleFake`): Golden Journey 1's two runs as its runbook and the Swift CLI send them, each held
at its Job's first call and then released, the completed execution, a rerun without a new
dispatch, an `idempotencyConflict`, the owned Jobs' reads, the observed Job's Artifacts one per page
with three refused cursors and an absent owner, five refusals before a Job and an absent execution:
29 exchanges, the fake's 11 calls and four execution records.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Agent replay | `cargo test -p arkdeck-hoststore --test agent_execution` | 1 passed: 21 of the 29 exchanges — the capture run's 8 are left out, since this Runtime does not plan `capture.diagnostics@1` — each answer's code, details and result Swift's, the Job state an accepted run read not terminal; the fake's calls the beginning of Swift's; the Target document unchanged; and every file and mode the rest leaves byte for byte: the observed Job's index row, files and Artifacts, its Session and the storage owner, and the three execution records of the observed run and of the two refusals that leave one (the Sessions retention catalog, which lists the capture Session too, is not compared). Two refused cursors differ in wording only (T2): Swift "cursor is invalid, belongs to another query or its snapshot was reclaimed", Rust "Cursor is invalid, belongs to another query, or its snapshot was reclaimed" |
| Observe replay | `cargo test -p arkdeck-hoststore --test observe_device` | 1 passed, now with its four `artifact.list` pages: all 28 answers and every file |
| Library | `cargo test -p arkdeck-hoststore --lib` | 145 passed (5 ignored), the two new `agent_execution` tests among them |
| Control and daemon | `cargo test -p arkdeck-control -p arkdeck-agentd` | passed; `artifact.list` now joins the Artifact owner's methods in the unimplemented-method check |
| Lint | `cargo fmt --all --check`; warnings-denied Clippy of `arkdeck-hoststore`, `-control`, `-agentd`, `-cli` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | passed |
| Real processes | `python3 rust/scripts/check-corpus-replay.py --fixture tests/fixtures/agent-execution` and `--fixture tests/fixtures/observe-device` | PASS: 21 exchanges over the socket at T1 (the capture run's 8 not replayed), 35 checks; and all 28 of the observe oracle, 57 checks. Summaries `/private/tmp/xpa014-agent-run-harness-agent-r5.json` (SHA-256 `a0dbac542fe4f2c9016d702b463f82ec98be6f4277901a262e5acedb5f9950ef`) and `/private/tmp/xpa014-agent-run-harness-observe-r5.json` (SHA-256 `3d23fca5670c853f80bb1f45d655abcf7624dd0eeb63d4d6dd2486033887d885`) on this stack; the runs on `cdfd18ad` before the rebase wrote the same bytes |

The harness now replays agent oracles: it holds and releases the owned Job's first call as the
oracle does and, as the oracle does, waits after the release until the execution record holds the
Job's end — a status read says `completed` as soon as the Job is terminal, before its Session is
published, which the first run found as a difference in `sessionPublication` and `generation`. A
listing is ordered by creation time on the daemon's own clock, so its pages are compared with their
items counted, and once the listing ends its items are compared across its pages and checked to
stand in the order it declares. Every execution is read again after the restart.

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local` over the two commits of the stack (merge base
`eedc0a0a`; r1, r2), then over this commit alone on main `382c5a30` (r3), with `ARKDECK_PYTHON` naming `.venv-sdd` and the planner run from a virtual
environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `2ad908a1` (on #1925's `e060d927`) | `gate exit=1`: the common checks, SDD, the Swift lane (full parallel, 2,668 tests, then the serialized lanes) and the Rust lane's format, Clippy and workspace tests on both views passed; then both views' black-box `check-readonly.py` expected `agent.run` to be refused `rejected`, as every unimplemented method is, where a daemon without an agent execution owner now answers `operationUnavailable` "AgentExecution owner is unavailable" with the zero-dispatch proof, as Swift's daemon does (`AgentDaemon.swift`). The check now expects that answer for `agent.run` and `agent.status`, and for `artifact.list` beside the Artifact owner's other reads; run directly on the same build it passes | `/private/tmp/xpa014-agent-run-gate-20260914-r1.log`, SHA-256 `ab5fd9d87732ca30a8eb2cf42fdc10757dfe19d2702eabe41547badf9ddd9987` |
| r2 | `53d82c4f` | `gate exit=0`: the common checks and SDD, the Swift lane (full parallel, 2,668 tests, then the serialized lanes), the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 1,746 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-agent-run-gate-20260914-r2.log`, SHA-256 `e85c22f1f64549a8706b9f1d899792cf05d082ff2d4392167b01c87bb7e5af13` |
| r3 | `89826998` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 634 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-agent-run-gate-20260914-r3.log`, SHA-256 `aed7b5f6aec1e5a04cdf6ece985ae50780d394d293741efd2f34814afee3efaf` |
| r4 | `f759a8c9` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 634 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-agent-run-gate-20260914-r4.log`, SHA-256 `2c75b3d85282e39390399def593147d44cb06f8aa5a7f73d00b95bb4705960cd` |

r1 ran with #1925 at `e060d927`; #1925's later amend (`105b88a4`) changed only its own evidence. The amend after r1
fixes the check, moves this commit onto `105b88a4` and adds r1; the amend after r2 only fills in its row.
After #1930 and then #1925 (as `382c5a30`) merged, this commit was replayed onto main `382c5a30`
without conflict; r3 gates it there. CI's Linux lane on `3653a66c` then showed that only the macOS
daemon composes the agent execution owner: on Linux `agent.run` and `agent.status` still answer the
foundation's `rejected`, so `check-readonly.py` expects `operationUnavailable` for them on macOS only
(`artifact.list` answers it on every platform, the control layer's default); r4 gates that change.
After #1931 and #1929 merged, this commit was replayed onto main `b0806334`; the one conflict was
`tasks.md`, where both added a bullet, and both are kept. On `b0806334`: `generate-contract.py --check` passes (105 methods, 662 recorded shapes), and so do the contract and control tests, both in-process replays, `check-corpus-replay.py` on both oracles (summaries byte-identical to the runs before #1929) and `check-readonly.py`. CI gates the
rebased commit.

## Deliberate differences from Swift

- `artifact.list` snapshots are kept by the Job owner (`jobs-state/cli-job-snapshots`); Swift keeps
  them in the Artifact root (`.imports-v1/artifact-snapshots`). A pager's own files are T2, and the
  Artifact root keeps only what the Artifact owner writes.
- The refused cursor's wording (T2, above).
- An owned Job runs on a daemon thread where Swift runs it as a task of its engine; both register
  the run before answering.
- `capture.diagnostics@1` is not planned here: its execution ends `failed` with `admissionDenied`,
  the Rust planner's proven refusal, where Swift runs the capture.
- An execution without a target is refused `operationUnavailable` and left orchestrating; Swift
  resolves one from the candidates (runbook §2.1).

## Not run, and why

- No device: DAYU200 is not attached to this host, and the isolated owner refuses a registered HDC.
- No Rust CLI `agent run`/`agent status` or `artifact list`: the next slice, against the Swift argv
  fixtures and the CLI's settlement rules.
- No capture leg: its Jobs wait for the Rust `capture.diagnostics@1`.
- No restart carry-over: an owned Job a restart interrupts is left as it is, and nothing resumes a
  run until the ruling on `evidence/adr-0009-decision-package-20260914.md`.
