# TASK-XPA-014 — recovery port, slice 4a: the shared Job-state preflight table

Change: CHG-2026-074-shared-rust-runtime-core@r11. Slice 4 of the recovery port the maintainer
ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`). This half writes the table design §G.4 asks
for ("判定谓词写进 `spec/` 的状态表，两个实现共用"), pins it to the Swift implementation, and records
the oracle the Rust classifier (slice 4b) replays. Host-local only: no device, no daemon.

Base: protected main `5dac73dc` (#2022). Branch `agent/xpa-014-recovery-preflight-table-20260919`,
no stack. Files:
- `spec/recovery/job-state-preflight.json` (new) and its row in `spec/README.md`;
- `Packages/ArkDeckKit/Tests/ArkDeckContractTests/JobStatePreflightTableContractTests.swift` (new);
- `rust/tests/fixtures/job-state-preflight/` (new: `table.json`, `restart.json`, `provenance.json`);
- this record.

No Rust, production Swift, Catalog, spec schema or control-frame change.

## What the table says

| Part | Content | Source |
| --- | --- | --- |
| `states` | 13 blocking states (`queued` … `finalizing`, as §G.4 lists them), `waitingForRecovery` parked, the 6 terminal states terminal | §G.4; `JobState` |
| `unlistedState` | blocking | §G.4's fail-closed reading; Swift's restart classifier blocks any state but `waitingForRecovery` |
| `agentExecutionStates` | `orchestrating`, `waitingForHuman`, `creatingJob`, `jobOwned` active; the 5 terminal states terminal | `AgentExecutionState` |
| `capabilityUseOutcomes` | `pending` unsettled, `outcomeUnknown` parked, `confirmed` and `safeToReflash` settled | `RuntimeCapabilityUseOutcome` |
| `cutover` | the M5 preflight: which facts block and which are carried over as they are | §G.4 |
| `restart` | `runtime service restart`'s carry-over: a current Job is preserved only when `waitingForRecovery`, `outcomeUnknown`, not waiting for a human, no residue, no process in progress and finished; anything else blocks; a malformed row is refused first | `RuntimeCLI.classifyAgentdRestartCurrentJobs` |

## How the table is pinned

`JobStatePreflightTableContractTests` reads the table from `spec/` and asserts:
- its Job states are exactly `JobState.allCases`, a state is terminal exactly when
  `JobState.isTerminal` says so, and only `waitingForRecovery` is parked;
- its agent-execution states and capability-use outcomes are exactly the Swift enums' cases. The
  enums are not `CaseIterable`, so the test spells them in an exhaustive `switch`: a new case fails
  to compile until the table and the test are updated;
- Swift's restart classifier, fed one current Job per state (the 20 `JobState`s and one it does
  not know) and per flag it reads (147 rows), preserves exactly the row the table's restart rule
  preserves (`waitingForRecovery` with every flag closed) and blocks the other 146;
- 7 malformed rows (no or empty Job id, a state that is not a string, an `outcomeUnknown` that is
  not a boolean, a residue that is not an integer, a missing flag, a row that is not an object) are
  refused with exit 69 before anything is classified.

It records `table.json` (the table's bytes, so the Rust replay reads it from inside `rust/`),
`restart.json` (the rows, Swift's two lists and the refusals) and `provenance.json`. Keeping the
copy under `rust/tests/fixtures/` matters: the contract views `check-contracts.py` builds carry
only `rust/` and the registered contract inputs, so a Rust test that read `spec/recovery/`
directly would fail in the next change that alters a contract input. The Swift test compares the
copy with `spec/` byte for byte, so the two cannot drift.

## Where §G.4 and Swift's restart classifier differ (for the maintainer)

The table states both rules as they are; neither is widened or narrowed here.
1. Swift's restart classifier is stricter than §G.4's parked set. It blocks a `waitingForRecovery`
   Job whose `outcomeUnknown` flag is false, that waits for a human, owes cleanup residue, has a
   process in progress or has no finish time (`parkDebugHAPCompensation` clears the finish time),
   and it blocks a terminal Job that is still current. §G.4 carries every parked and terminal Job.
2. `outcomeUnknown` is a Job record flag, not a `JobState`; §G.4 lists it with the parked states.
   The table classes the state and names the flag only in the restart rule.
3. "未决 intent" blocks in §G.4, but a parked Job keeps its intent outstanding by design
   (`RuntimeJobEngine.swift` 4368–4375). The cutover rule therefore blocks an outstanding intent,
   unknown outcome or torn tail only in a Job that is not parked.
4. "running 的 agent execution" names no state. The table calls the four non-terminal states
   active and lets a `jobOwned` execution of a parked or terminal Job be carried over, since
   nothing of it runs; this is this change's reading and is marked as such.
5. A `pending` capability use of an already terminal Job is a known crash gap that Swift repairs
   only at the next admission on its binding; the cutover rule blocks on it.
6. §G.4 names a `runtime service update` preflight; Swift has none, only the restart one.

## Local targeted checks

Per `AGENTS.md` on main `d732e798` (#2015) the unified gate is the PR's CI; locally:

| Command | Exit | Result |
| --- | --- | --- |
| `ARKDECK_RUST_JOB_STATE_PREFLIGHT_RECORD=/private/tmp/arkdeck-job-state-preflight-r1 sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter JobStatePreflightTableContractTests` | 0 | 1 test, 0 failures |
| the same into `…-r2` | 0 | 1 test, 0 failures; `diff -r` r1 r2 empty |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter JobStatePreflightTableContractTests` (fixture installed) | 0 | 1 test, 0 failures |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

## CI

| PR | Head | Runs | Result |
| --- | --- | --- | --- |
| #2026 | `e04af9a1` | 35444830272, 35444830418, 35444830491 | 11 checks passed, `app-build` skipped; merged as `78ee48ee` |

## Not in this slice

- The Rust classifier (slice 4b): the table's classes, the restart rule replayed on this oracle,
  and the cutover rule over a state root's Jobs, agent executions and capability uses.
- The callers: the Rust `runtime service restart` leaf (XPA-018) and the M5 `runtime service
  update` preflight (XPA-017).
