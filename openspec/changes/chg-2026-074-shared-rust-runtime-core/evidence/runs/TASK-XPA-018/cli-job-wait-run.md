# TASK-XPA-018 — `job wait` (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This is the first slice of the Rust CLI's
batch 1 (G5 queue slice 14; b4 in the audit's split). Base: protected main
`a5a98af1` (#2169); no stack.

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). The Runtime
under test is the fake one the CLI tests serve recorded answers from. No
Swift source or test, control schema, corpus, Catalog, `openspec/contracts`,
`openspec/specs` or constitution change.

`job wait` waits for a Job to settle and never cancels it. Swift's handler
takes one of two paths, and the Rust CLI now takes the same one for the same
options.

## The polling path

Swift's `emitJobWait` runs without `--after-cursor`, `--page-size` or the
`jsonl` stream.

- It reads `job.status` on a fresh connection each time, with a backoff that
  doubles from 250 ms to 2 s.
- The only deadline is the caller's `--timeout`. Swift's reason for no
  default: it would stop watching a flash that legitimately runs for half an
  hour.
- The deadline is judged between reads only. A read that began before the
  deadline still answers, so the wait always ends on a judged status: each
  read has the client's own 30 s budget.
- The wait ends when the status settles:

| Status | Answer |
| --- | --- |
| A terminal state, or `outcomeUnknown` | The status is emitted as a successful read. The outcome travels in the exit status: 0, 1 for failed, cancelled or interrupted, 75 for an unknown outcome (`run_exit`, shared with `job run`) |
| `waitingForHuman` | `humanActionRequired` (75) at once: `job <id> is waiting for a human action and will not settle on its own`, with `jobId` and `state` |
| A failure awaiting finalization | Checked as a full status, then `resultNotReady` (75): `Job failure finalization requires reconciliation. Run: arkdeck job reconcile --job <id>`, with the next action |
| No object, or no state | `recordUnreadable` with Swift's two messages |
| Past the deadline | `clientTimeout` (75): `stopped waiting for job <id>; it is <state> and still running`, with `jobId` and `state` |

## The event path

Swift's `emitJobEventObservation`, as `wait`, runs otherwise. It shares
`job watch`'s loop, which is now `observe_job` for both leaves.

- The durable stream is followed, rows are written as they arrive, and each
  read is retried twice on an unavailable Runtime.
- Without `--timeout`, the observation is capped at 30 s from its first
  request. That is Swift's cap as well: `bounded(by:)` intersects the
  deadlines, so the cap is never renewed.
- Each time the stream is drained, the leaf reads `job.status` and applies a
  port of Swift's `validatedObservedJobStatus` (`job_wait::observed`):

| Status | Answer |
| --- | --- |
| Next action does not match the state, or the status belongs to another Job | `recordUnreadable` |
| A complete human action | `humanActionRequired` with the next action |
| `waitingForHuman` under any other next action | `recordUnreadable` |
| An unknown or recovering outcome | `outcomeUnknown`: the observation never replays an effect |
| A pending finalization | `resultNotReady` |
| A terminal state | Drains the stream once more, then ends with that status |

- In `jsonl` the stream closes with a terminal success line that carries the
  status and the exit status it gives the process. `terminal_line` now takes
  that exit status; it was always 0.
- A failure keeps `job watch`'s `failStream`: the Job, the cursor to resume
  from, and a terminal failure line.
- Rows are printed in `human` and `jsonl` only. In `json` the one document on
  stdout is the envelope. `job watch` publishes no `json` mode, so the shared
  loop never met the case before.

## The parse

The parse follows Swift's registry, in declaration order. Every refusal
names the leaf (`command: job.wait`) and carries Swift's `details`:

| Refused | Message |
| --- | --- |
| Missing `--job` | ``​`job wait` requires --job <job-id>`` |
| `--timeout` that is not a duration of at most a day | ``​`job wait` --timeout must be a duration like `30s` (digits then ms\|s\|m\|h, no larger than 86400000ms)`` |
| `--page-size` outside 1…1000, or not plain digits | ``​`job wait` --page-size must be 1...1000``, with the value |

The event path's own checks also name the leaf:

- An exact Job identity: `invalidInput` (65).
- A bounded cursor: `invalidCursor` (65).

The polling path sends the identity as given, for the Runtime to judge.

## Differences from Swift

- **Rendering.** `human` renders pretty JSON, as every Rust leaf does, rather
  than Swift's prose.
- **The stderr line of a failed settled Job.** It is `run_exit`'s reason on
  both paths. Swift's event path says "Job reached a failed terminal state".
- **The human-action branch of the event path cannot be reached under the
  published contract.** The `job.status` schema closes `nextAction` without
  `resumeReference` or `expiresAt`, so the client refuses such an answer
  before the leaf reads it. The branch is ported and unit-tested for the day
  the contract publishes it.

## Tests

| Test | What it holds |
| --- | --- |
| `argv_fixtures.rs` | Swift's `job.wait.json`, copied byte for byte: its six cases replay with no new deviation |
| `job_wait.rs` `polling_reads_the_status_until_it_settles_and_exits_by_its_outcome` | Recorded statuses (running, then succeeded, failed, cancelled, or an unknown outcome): the settled status is the envelope's result, exiting 0, 1, 1 and 75 |
| `job_wait.rs` `polling_answers_a_person_and_a_pending_finalization_at_once` | `humanActionRequired` and `resultNotReady` with Swift's messages and details (the recorded `debug.hap@1` finalization) |
| `job_wait.rs` `the_callers_deadline_ends_the_wait_and_says_the_job_still_runs` | However many reads fit in 300 ms, `clientTimeout` with the Job's last state |
| `job_wait.rs` `the_stream_follows_the_events_and_ends_with_the_settled_status` | Recorded rows, a running status, a terminal one, one more drain. The terminal success line carries the status, its exit status (0 or 1) and the last cursor |
| `job_wait.rs` `the_stream_refuses_an_outcome_it_cannot_know` | `outcomeUnknown` with the next action, the Job and the cursor. A person under a wait action is `recordUnreadable` |
| `job_wait.rs` `a_page_size_takes_the_stream_path_without_printing_its_rows_as_json` | `--page-size` takes the stream; `json` prints one envelope |
| `job_wait.rs` `the_registrys_grammar_is_judged_before_any_request` | The five registry refusals with Swift's messages and details; the event path's identity and cursor refusals naming the leaf; the polling path sending an identity the Runtime refuses |
| `job_wait::tests` (unit) | The state/next-action table, the complete human action, and the polling judgement, including a state this build does not know |
| `job_events::stream_tests` (unit) | A terminal success line with a failed Job's exit status |

## Audit

`cli-parity-audit.py` over this build:

| | Before (`a5a98af1`) | After |
| --- | --- | --- |
| Implemented | 166 | 167 |
| Leaf missing, daemon routed | 61 | 60 |
| Owner missing | 14 | 14 |
| Tombstone | 15 | 15 |
| Registry leaves served | 126 of 209 | 127 of 209 |

The dashboard is refreshed by its own PR, as before.

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-xpa018-wait-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-xpa018-wait-clippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0; 268 passed (`arkdeck-xpa018-wait-test.log`) |
| Mutations | six, one at a time: the person check dropped; the drain after a terminal status skipped; the success line's exit status forced to 0; the page-size range dropped; rows printed in `json`; the page size no longer choosing the stream | each fails `job_wait.rs`. Sources restored by digest, rebuilt, and the suite rerun green (`arkdeck-xpa018-wait-mutations.log`, `…-rerun.log`) |
| Audit | `cli-parity-audit.py <this build>` | 167 / 60 / 14 / 15; 127 of 209 leaves served (`arkdeck-xpa018-audit-wait.md`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 (`arkdeck-xpa018-wait-sdd.log`) |

Not run, because no input they read changed:

- `generate-contract.py --check`: no contract input changed.
- The Swift tests: no Swift source changed.
- The other crates: `arkdeck-cli` has no dependents.

## CI

Pending.
