# TASK-XPA-014 — agent executions that wait for a person on the Rust owner (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: protected main `c1cd1ea4`; no stack. That main carries the
physical-assistance oracle and the control shapes it re-derived (#1950). The tests read that oracle's
fixture. The Rust control gate rewrites an answer outside its method's schema to `internalError`, so
a waiting execution's `agent.run` answer needs that PR's schema. The slice was built on #1950's
branch and replayed onto this main once #1950 merged. Its commit dropped as already upstream, and
nothing conflicted. Every record and answer here is synthetic host data from that oracle; nothing is device evidence
(POL-VERIFY-001, POL-MODE-001). No Swift file changes.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| The Rust `agent.run`/`agent.status` (#1932) and `agent.list`/`agent.abandon` (#1945), and their CLI leaves (#1935, #1946); the physical-assistance oracle and its control shapes (#1950) | Swift's physical-assistance actions in `AgentExecutionStore`'s records, checked as Swift checks them; the waiting action's projection and `nextAction`; a waiting execution run again, abandoned, or out of time; `tests/agent_human_action_records.rs` | The Target observation owner with USB relations (lane B's relation port first); an execution without a target raising an action; `agent.resume`, the human-action owner and its routes, and the oracle's full replay; `target.adopt`/`target.availability`; `runtime.hdc.*` |

## What the Rust owner does

It follows Swift's `RuntimeAgentHumanAction` and the store's `validate` (`AgentExecutionStore.swift`),
and `RuntimeAgentExecutionCoordinator`'s run, abandonment, `observeBudget` and
`expireWaitingActions` (`AgentExecutionCoordinator.swift`).

- **The record.** A record's `actions` are Swift's: `actionID`, `executionID`, `resumeReference`,
  `kind` (`connectDevice`, `trustDevice` or `selectDevice`), `createdAt`, `expiresAt` and `status`
  (`waiting`, `resolvedByFreshProbe` or `expired`). When present, they also hold the `observation`
  the action names (its `candidate`, `observationID` and `generation`), a `resolvedSelection`, and a
  device selection's `selections` (each a `reference` and its observation). They are read as
  `Codable` reads them, dropping a member Swift does not know, and written as Swift's canonical
  encoder writes them: keys sorted, nil members left out. Before this slice the owner refused every
  record with an action as `recordUnreadable`.
- **Swift's checks.** A record whose actions fail the store's `validate` is still
  `recordUnreadable`. The actions must meet all of these:
  - at most 128 actions, all of this execution and of a published status;
  - at most one waiting, the last, and it waits exactly while the execution is `waitingForHuman`;
  - unique action identities and resume references, each a valid identifier;
  - each created within the execution's life, from its creation to its high-water mark, and expiring
    at its orchestration deadline;
  - at most 1,000 choices, with unique references;
  - a device selection names no single observation and offers at least one choice; any other action
    offers none and resolves none; a resolution is one of the choices.
- **The answer.** While the execution waits, its projection's `humanAction` is the waiting action as
  `arkdeck.human-action/1`. It carries:
  - its owner;
  - the category, reason and least human action of its kind (below);
  - its resume reference;
  - a selection schema: `null`, or a string enumerating the choices;
  - the choices with their candidate keys;
  - `newDispatchCount: 0`.

  Its `nextAction` names the action: its owner, the resource, the reason, the resume reference and
  `expiresAt`. An `agent.list` item leaves `humanAction` out, as before.

  | Kind | Category | Reason | Least human action |
  | --- | --- | --- | --- |
  | `connectDevice` | `physicalConnection` | `device.notObserved` | `human.connectOrPowerDevice` |
  | `trustDevice` | `deviceTrustPrompt` | `device.trustPending` | `human.acceptDeviceTrustPrompt` |
  | `selectDevice` | `ambiguousIdentity` | `device.identityAmbiguous` | `human.confirmDeviceIdentity` |
- **Run again while it waits.** `agent.run` of a waiting execution reads the budget as Swift's
  `observeBudget` does: the high-water mark advances in one more generation, and the execution
  answers as it waits. Running it again never resumes it. At the deadline, or on a clock behind the
  high-water mark, the run is refused (`orchestrationBudgetExpired`, `orchestrationClockUntrusted`).
  The execution then ends (`budgetExpired`, `clockUntrusted`) in the same write that expires its
  action.
- **Abandoned while it waits.** At the generation its caller read, `agent.abandon` makes it
  `abandoned` in one more generation, and its action `expired` in the same write. At another
  generation it is still `resourceConflict`.
- **Unchanged.** An execution without a target is still `operationUnavailable`, so nothing here
  raises an action. `agent.resume` and `human-action.*` keep the control foundation's refusal. No
  daemon, control or CLI code changes.

## Tests

**Units** (`agent_execution.rs`) run over the oracle's four records, their labels read as valid
identities:
- connect: completed after a reconnect;
- trust: abandoned while it waited;
- ambiguous: waiting for a selection;
- unproven: refused before any action.

The unit tests:
- `swift_physical_assistance_records_round_trip_byte_for_byte`: each record decodes and encodes to
  the same bytes.
- `waiting_and_abandoned_executions_project_as_swift_answered`:
  - the waiting execution's projection is the oracle's `ambiguous.run` answer;
  - the abandoned one's is its `trust.abandon` answer;
  - the completed one projects no action and reads its result next.
- `actions_swift_would_not_read_are_refused`: the waiting record is read, and six changes to it are
  refused:
  - the execution no longer waiting;
  - an action expiring past the deadline;
  - a device selection naming one observation;
  - two waiting actions;
  - an unpublished kind;
  - a resolution the action never offered.

**`tests/agent_human_action_records.rs`** runs over a private root seeded with the oracle's Target
document and its four records.
- `rust_answers_the_swift_executions_that_wait_for_a_person`:
  - `agent.status` answers the waiting and the abandoned execution as the oracle did (T1: equal
    JSON).
  - `agent.list` lists the four in the oracle's order. Each item is its answer without
    `humanAction`, and the waiting one's `nextAction` names its action.
  - `agent.run` of the waiting execution answers as it waits at generation 4, its action still
    waiting.
  - `agent.abandon` at generation 4 answers `abandoned` at 5, with no `humanAction` or `nextAction`,
    and the record keeps the action `expired`.
  - `agent.run` of the abandoned execution answers as the oracle's `trust.rerun`, without a write.
- `a_waiting_execution_out_of_time_ends_with_its_action_expired`: it runs the waiting execution on a
  clock at its deadline and on one behind its high-water mark.
  - The run is refused with `orchestrationBudgetExpired` and `orchestrationClockUntrusted`.
  - The record ends `budgetExpired` and `clockUntrusted` at generation 4, its `failureCode` the
    refusal's and its action `expired`.
  - `agent.status` answers it without an action.

  This is Swift's `observeBudget` as its code reads. The oracle's clock is frozen, so it records no
  such exchange.

## Real processes

The daemon now reads records that hold actions, so the four oracles its harness replays were
replayed against it (`python3 rust/scripts/check-corpus-replay.py --fixture
rust/tests/fixtures/<oracle> --record /private/tmp/xpa014-har-records-harness-<oracle>-r1.json`):

| Oracle | Result | Summary SHA-256 |
| --- | --- | --- |
| `agent-execution` | PASS: 29 exchanges, 57 checks | `8cd65951370ffef407c8b154b77f2e55ed0e4932139f6ce6552221343070894f` |
| `agent-lifecycle` | PASS: 25 exchanges, 58 checks | `9b7c5513648d3503fecb4403b9d7de81ed61bc75d8e09924b5783454f2f4dffe` |
| `observe-device` | PASS: 28 exchanges, 57 checks | `01e80dc163d94c7f2e1109f473813f0d66798d9513322600f86bcbadef62de87`, byte-identical to #1938's |
| `capture-diagnostics` | PASS: 28 exchanges, 57 checks | `2a39988150305cc0146d8e2b87882e8efae941de4248d9aac43068cd68a610bb`, byte-identical to #1938's |

These ran on #1950's branch. After the rebase onto `c1cd1ea4`, everything passed again with the
same counts:
- the build;
- the tests below;
- all four replays, their summaries byte-identical to the first ones (`-r2.json`);
- the read-only check.

The harness does not replay the physical-assistance oracle: its runs name no target.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Owner units | `cargo test -p arkdeck-hoststore --lib` | 154 passed, 5 ignored |
| In-process | `cargo test -p arkdeck-hoststore --test agent_human_action_records --test agent_execution --test agent_lifecycle` | 2, 1 and 1 passed |
| Control and daemon | `cargo test -p arkdeck-control -p arkdeck-agentd` | pass; `read_only` 15 of 15 |
| Real processes | `check-corpus-replay.py` on four oracles | PASS on all four (above) |
| Read-only host check | `rust/scripts/check-readonly.py` (from the virtual environment carrying jsonschema) | PASS: 124 control responses, 12 CLI envelopes, 115 valid requests |
| Union merge | `python3 scripts/check_union_merge.py` | ok |
| Lint | `cargo fmt --all`; `cargo clippy --workspace --all-targets -- -D warnings` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | formatted; clean for all three |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local` (merge base `c1cd1ea4`), with `ARKDECK_PYTHON` naming `.venv-sdd` and the planner run from a virtual environment
carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `bb9be630` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 740 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-agent-human-action-records-gate-20260914-r1.log`, SHA-256 `3f965ef4eb46de8605861bb842378d168e7b8aec2d30797aa223a3d78d013aec` |

The amend after r1 only fills in this row.

## Not run, and why

- **The oracle's full replay.** Its runs name no target. Replaying them needs the Target observation
  owner with USB relations, raising an action, the resume path and the human-action owner, which are
  the next slices. This slice reads the records those runs leave, not the runs.
- **Resolving an action.** Nothing here marks an action `resolvedByFreshProbe` or records a
  selection; that is the resume path. The records the oracle's resume left are read and written back
  as they are.
- **Restart carry-over.** Nothing resumes anything after a restart (L.1 item 13); a waiting
  execution stays as its record says.
- No device, no real HDC.
