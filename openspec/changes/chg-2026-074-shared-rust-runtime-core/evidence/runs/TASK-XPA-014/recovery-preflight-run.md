# TASK-XPA-014 — recovery port, slice 4b: the Rust Job-state preflight classifiers

Change: CHG-2026-074-shared-rust-runtime-core@r11. Second half of slice 4 of the recovery port
the maintainer ruled on 2026-09-19 (design §L.1 item 13): the shared table slice 4a wrote
(`spec/recovery/job-state-preflight.json`, `recovery-preflight-table-run.md`) read by Rust, with the
restart classifier replayed on 4a's Swift oracle. Host-local only: no device, no daemon.

Base: protected main `78ee48ee` (#2026), which holds slice 4a and the table's recorded copy this
slice compiles in. Branch `agent/xpa-014-recovery-preflight-20260919`, no stack: first pushed
stacked on 4a and rebased onto main after 4a merged. No Swift file changes here.

## Delivered

`rust/crates/arkdeck-contract/src/job_state_preflight.rs` (all platforms; `arkdeck-contract` is
the one crate both the CLI and the host store depend on):
- `JOB_STATE_PREFLIGHT_TABLE`: the table, compiled in from
  `rust/tests/fixtures/job-state-preflight/table.json`, the copy Swift's contract test records and
  compares with `spec/` byte for byte. One file therefore feeds both implementations, and the
  copy sits inside `rust/`, which the contract views carry.
- `job_state_class`, `job_states`, `agent_execution_active`, `capability_use_unsettled`: the
  table's classes; a state, execution state or use outcome the table does not list blocks.
- `classify_restart`: Swift's `RuntimeCLI.classifyAgentdRestartCurrentJobs`. A malformed current
  Job refuses the whole list (`MalformedCurrentJob`, Swift's exit 69); a Job is preserved only when
  its state is parked and it is `outcomeUnknown`, not waiting for a human, owes no residue, has
  `processProgress: null` and a non-empty finish time; everything else blocks; both lists are
  sorted. "Parked" is read from the table, which 4a pins to `waitingForRecovery` alone.
- `cutover_preflight`: §G.4's M5 preflight over facts the caller gathers. A Job takes the most
  conservative class of the states its index row, record and journal give (none at all blocks).
  It blocks on a blocking Job; on an unresolved journal (outstanding intent, unknown outcome or
  torn tail) outside a parked Job; on an active agent execution unless it is `jobOwned` by a
  parked or terminal Job; and on an unsettled (`pending`) capability use. Parked and terminal
  Jobs and parked or settled uses are carried as they are. The reasons come back sorted; none
  means the cutover may proceed.

`job_record.rs` gains a test that the host store's own Job-state vocabulary (`STATES`) is the
table's and that its `terminal` agrees with the table's terminal class.

## Tests

- `job_state_preflight::tests` (3):
  - the table lists 20 states, parks only `waitingForRecovery`, blocks an unlisted state, and
    classes the executions and uses as 4a pins them;
  - `the_restart_classifier_decides_every_swift_case`: the 147 rows of 4a's oracle (count asserted
    `>=` 147) give Swift's blocking and preserved lists exactly, and each of the 7 malformed rows
    Swift refused is refused;
  - the cutover rule over a mix of parked, terminal, running, index-lagging, unresolved-terminal
    and unknown-state Jobs, owned and unowned executions, and pending, unknown and settled uses.
- `job_record::preflight_table_tests::the_job_states_are_the_shared_preflight_tables`.

## Local targeted checks

Per `AGENTS.md` on main `d732e798` (#2015) the unified gate is the PR's CI. Locally, with
`CARGO_BUILD_JOBS=2`:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy -p arkdeck-contract -p arkdeck-hoststore -p arkdeck-cli --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-contract` | 0 | 49 passed, 0 failed |
| `cargo test -p arkdeck-hoststore --lib` | 0 | 199 passed, 0 failed, 5 ignored |

Log: scratchpad `logs/checks-s4b.log`, SHA-256
`133cd62d02eb1141cc9e4b86b8b96e580e3e1be0ed723f8ece991c18987e00cf`.

## CI

| PR | Head | Runs | Result |
| --- | --- | --- | --- |
| #2026 (slice 4a) | `e04af9a1` | 35444830272, 35444830418, 35444830491 | all checks passed or skipped; merged |
| #2028 (this slice, stacked on 4a) | `35fb4e96` | 35445066649, 35445066705, 35445066758 | all checks passed or skipped |
| #2028 after the rebase | `9a74352b` | 35445650080, 35445650085, 35445650146 | 9 checks passed; `swift-tests`, `app-build`, `ds-interactions` skipped (a Rust-only diff); merged as `658f3e00` |

## Not in this slice

- Gathering a state root's facts for `cutover_preflight` (the Job index, records and journal
  replay, the agent executions, the capability ledger). The startup recovery of slice 2 reads the
  same active set and replay facts; the gathering lands with it or with the M5 update preflight.
- The callers: the Rust `runtime service restart` leaf (XPA-018) and `runtime service update`'s
  M5 preflight (XPA-017).
- The six §G.4 differences 4a's record lists stay open for the maintainer; this slice implements
  both rules as the table states them.
