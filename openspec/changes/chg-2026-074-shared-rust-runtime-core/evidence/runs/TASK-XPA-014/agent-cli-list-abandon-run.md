# TASK-XPA-014 — the Rust CLI's `agent list` and `agent abandon` (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: the Rust list and abandonment slice, #1945
(`agent/xpa-014-agent-list-abandon-20260914`, `ccbdb242`), over protected main `0ae4fe45`, which
carries the lifecycle oracle (#1944). It is stacked because the harness checks the CLI against the
daemon, which answers `agent.list` and `agent.abandon` from that slice on. Every request and answer
here is synthetic host data over `/bin/sh` scripts; nothing is device evidence (POL-VERIFY-001,
POL-MODE-001). No Swift file changes.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| The Rust CLI's `agent run`, `agent status` and `artifact list` (#1935); the daemon's `agent.list` and `agent.abandon` (the base PR) | `agent list` and `agent abandon` in the Rust CLI; the identity check before `agent status` sends; the harness's CLI list and abandonment | Human actions and `agent.resume` (the runbook §2.1 HAR path); `target.adopt`/`target.availability`; `runtime.hdc.*` |

## What the CLI does

Both follow Swift `RuntimeCLI.runRuntimeExecution` and the registry's leaves
(`CLIAgentExecutions.swift`, `CLICommandRegistry.swift`, `CLIArgumentParser.swift`).

- **`agent list [--state <state>] [--operation <reference>] [--target <id>] [--page-size <n>]
  [--cursor <cursor>] [--timeout <duration>]`.** The registry's grammar holds before anything is
  sent: `--state` names one of the nine published states, and `--page-size` is plain digits from
  1 to 1,000, with no sign and no leading zero (Swift's `positiveInteger`). The other options are
  opaque. Each violation is a usage error (64). The request names the resolved target `target` and
  carries the page size as an integer, as Swift's handler builds it, and the page is passed on as
  the daemon answers it, as Swift's handler emits it. `agent.list` is a bounded read
  (`CLIControlMethodRegistry`): a named refusal keeps its code only with the zero-dispatch proof, an
  unproven one is `internalError`, and a lost reply is `runtimeUnavailable`.
- **`agent abandon --execution-id <id> --expected-generation <n> [--timeout <duration>]`.** Both
  options are required, and the generation is a plain positive integer (`02` is a usage error, as
  Swift's grammar refuses a leading zero). The identity must be exact before anything is sent
  (`invalidInput`, 65, "an exact execution identity is required"), and the answer is checked as
  `executionFields` checks it. `agent.abandon` is a mutation: a named refusal keeps its code only
  with the zero-dispatch proof, and an unproven refusal or a lost reply is `outcomeUnknown` (75).
- **`agent status`** now makes the same identity check before it sends, as Swift's handler does for
  both leaves; before, the daemon refused an inexact identity with the same code.

## Tests

- **argv.** The Swift CLI's `agent.list` and `agent.abandon` argv fixtures are packaged byte for
  byte under `rust/tests/fixtures/current-cli-argv/`, where `check-contracts.py` keeps them equal to
  Swift's, and replay as Swift parses them (5 and 7 cases).
- **Requests.** `agent list` with no option, `--page-size 1`, `--state completed`, `--operation
  capture.diagnostics@1` and `--target TGT-3ba3f5f43b92` send exactly the lifecycle oracle's
  `list.all`, `list.page1`, `list.completed`, `list.capture` and `list.target` parameters, and
  `agent abandon --execution-id life-unadopted --expected-generation 2` sends `abandon.orchestrating`'s.
  A page size of 0, `01` or 1,001, an unpublished state, a generation `02` and a missing identity
  are usage errors; an inexact identity is `invalidInput`.
- **Answers.** The oracle's three abandonment answers check. Its four abandonment refusals map to
  `resourceConflict` (with the `jobId`), `resourceNotFound` and `invalidInput`, all 65, and its five
  list refusals to `invalidCursor` and `invalidInput`. An unproven or lost abandonment is
  `outcomeUnknown` (75), an unproven list refusal `internalError`, and a lost list reply
  `runtimeUnavailable`.
- **Real processes.** `check-corpus-replay.py` now has the Rust CLI list every execution, as the
  socket lists them, and abandon each at the generation its status read. On the lifecycle oracle
  (25 exchanges, 58 checks) `life-observe`, which owns a Job, is refused (`resourceConflict`, 65,
  with its `jobId`), `life-stale` is abandoned at generation 3, and `life-unadopted`, abandoned
  already, is answered as it is. On the agent execution oracle (29 exchanges, 57 checks) both
  executions own a Job and are refused. The observe and capture oracles have no execution and pass
  as before (57 checks each), their summaries byte-identical to #1938's. Summaries
  `/private/tmp/xpa014-agent-cli-harness-agent-lifecycle-r1.json` (SHA-256
  `9b7c5513648d3503fecb4403b9d7de81ed61bc75d8e09924b5783454f2f4dffe`) and
  `/private/tmp/xpa014-agent-cli-harness-agent-execution-r1.json` (SHA-256
  `8cd65951370ffef407c8b154b77f2e55ed0e4932139f6ce6552221343070894f`).

## Checks

| Check | Command | Result |
| --- | --- | --- |
| CLI tests | `cargo test -p arkdeck-cli` | pass; `agent_executions` 12 of 12, the two new tests among them |
| Real processes | `python3 rust/scripts/check-corpus-replay.py --fixture rust/tests/fixtures/<oracle>` for `agent-lifecycle`, `agent-execution`, `observe-device` and `capture-diagnostics` | PASS on all four (above) |
| Read-only host check | `rust/scripts/check-readonly.py` (from the virtual environment carrying jsonschema) | PASS |
| Lint | `cargo fmt --all`; `cargo clippy --workspace --all-targets -- -D warnings` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | formatted; clean for all three |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local` (merge base `0ae4fe45`, below the base PR's
commit), with `ARKDECK_PYTHON` naming `.venv-sdd` and the planner run from a virtual environment
carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `2bb4b9e9` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 718 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-agent-cli-list-abandon-gate-20260914-r1.log`, SHA-256 `d0713cd5047dbfdfd1f5c00475a6e6ecf413686f82e4461fb5e7e6f031b955e3` |

The amend after r1 only fills in this row and names the base PR's number. The harness runs in
Tests were made on this commit's first base (`d9132b64`, stacked on #1944 before it merged); on
the re-parented head the lifecycle and agent execution summaries are byte-identical to them
(`/private/tmp/xpa014-agent-cli-harness-<oracle>-r2.json`). #1945 was later re-pushed as `ccbdb242`,
the same tree, to re-run a macOS CI flake in another lane's test (`managed_server`), and this
commit was re-parented onto it unchanged.

## Not run, and why

- **Human actions and `agent.resume`.** The runbook §2.1 HAR path, whose oracle needs the harness
  to compose USB relations and the union human-action owner.
- **Human rendering.** `--output human` prints the answer as the other agent leaves do; the machine
  envelope is what the tests and the harness compare.
- No device, no real HDC: the fake answers what the daemon asks.
