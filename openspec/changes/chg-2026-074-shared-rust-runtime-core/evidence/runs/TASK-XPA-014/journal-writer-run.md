# Rust Job journal writer — macOS, 2026-09-13

TASK-XPA-014 remains in progress. Base: protected main `dfdb6b68` (the slice was
written on `a102a4aa` and rebased onto #1888 without conflict). This slice gives
Rust a writer for a Job's current `journal.jsonl` with the Swift durability and
replay discipline. No daemon or CLI path writes journals yet; no admission, plan,
SQLite write, capability, recovery or execution is added, and nothing installed
changes. Every fixture is synthetic host data; nothing here is device evidence.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for TASK-XPA-014 |
| --- | --- | --- |
| Rust reads the v1 SQLite Job index, stored records, `job.events` metadata and Artifact routing (#1863, #1879) | `HostJournalAppender` (platform) and `JournalWriter`, `ReplayState`, `job_journal_events` (hoststore): durable appends validated by the closed per-event decoder and the Swift replay/append rules for all 19 kinds; a Swift-recorded oracle both writers must reproduce | admission in the published order, `job.plan` digest parity, SQLite `runtime_job` and `job-record.json` writers, capability mint/reserve/consume, agent execution, executor hand-off, §G.4 preflight, recovery (after the L.1 item 13 ruling), GJ-1..5 |

## Behaviour

`HostJournalAppender` (`arkdeck-platform/src/host_journal.rs`, beside the existing
reader and sharing its lock helper):

- Every open, repair and append holds the Job directory's `.manifest.lock`
  (Swift `SessionTerminalPublicationLock`), with the reader's existing bounded
  5-second wait instead of Swift's unbounded `flock`.
- A terminal `manifest.json` refuses creation, repair and every append.
- The writer is bound to the journal's device/inode; the path must still name
  that inode before and after each write. Ownership, single link and no
  group/world write are checked as for the reader.
- Append: when size, mtime, ctime and the SHA-256 of the last record are exactly
  as the appender left them, only that record is reread (Swift
  `JournalAppendCursor`); any other change hands the caller the complete snapshot
  (bounded at 256 MiB) to replay and validate first. The record is written in
  two parts, then fsync + `F_FULLFSYNC`, then a directory fsync; the file length
  and inode are rechecked. A failure after the write began is `OutcomeUnknown`
  and poisons the appender until a new open replays and repairs.
- Open: under the lock the caller decides whether to cut a torn tail back to the
  last complete record; truncation is fully synced with its directory.

`ReplayState` (`arkdeck-hoststore/src/job_journal_replay.rs`) ports Swift
`JournalReplay.validate` and `JournalAppendValidationState` as one state machine:
sequence, identity and schema continuity; `jobCreated` first; nothing after
`finalized`; only `finalized` after a terminal state; reconcile and abandon
outcomes followed by their exact state transition; unknown outcomes blocking new
intents and forcing `waitingForRecovery`; the mode-specific
`JobStateMachine.allowedDestinations` table; intent permission by state;
plan-only device-mutation refusal; outcome-to-intent correlation; compensation
linkage (confirmed source, exact declaration, target and binding, one unused
attempt, finalizing only in execute mode); binding revision monotonicity;
reconcile start/outcome pairing; abandon hazards; finalized certainty. Its facts
are exactly the fields of Swift `JournalReplay`.

`JournalWriter` encodes a record with the Swift-canonical encoder already proven
by the shadow corpus (`session_json::encode`), decodes it with the closed
per-event validator, validates it against the replay state under the lock,
appends, then records it. `open` repairs a torn tail only behind a durable
`jobCreated` and before terminal publication, as Swift `FileDurableJournal.init`.
`job_journal_events` spells the eight kinds the Swift engine emits (plus
`finalized`) as Swift's factories do: intent/outcome envelope keys always
present, null when absent, optional outcome text omitted when absent.

Deliberate differences from Swift, all toward refusal:

- Lock wait bounded at 5 s (as the Rust reader); snapshot bounded at 256 MiB.
- A reconcile outcome's next state is checked with the Job's own mode table on
  append as well as replay (Swift's appender accepts the union of both modes;
  its replay then applies the mode table).
- Abandon hazards are derived from outstanding intents and unknown outcomes, as
  Swift's replay does; Swift's appender keeps them incrementally and also adds
  every compensation intent. The two sets are equal because all six compensation
  kinds have `deviceMutation` as their registry minimum effect
  (`WorkflowStep.swift` metadata for stopRemoteCapture, restoreParameter,
  cleanupOwnedRemotePath, uninstallPackage, stopApplication, removePortForward).
- After a write the appender also checks the new length equals the old length
  plus the record.

## Shared oracle

`rust/tests/fixtures/journal-writer/` holds four scenarios recorded from Swift
`FileDurableJournal` by `JournalRustWriterParityContractTests` in record mode
(`ARKDECK_RUST_JOURNAL_WRITER_RECORD`), each with the facts
`DurableJournalRecovery.inspect` derived; `provenance.json` lists their SHA-256
and the producer sources.

| Scenario | Records | Replay facts |
| --- | ---: | --- |
| `succeeded` | 11 | host probe, device read with binding 1, finalize; terminal `succeeded` |
| `unknown` | 10 | device mutation with an `outcomeUnknown` outcome, reconcile started and unproven; `waitingForRecovery`, one unknown outcome, hazard `unresolved-deviceMutation-intent:reboot-device:evt-03`, `requiresRecovery` |
| `compensation` | 9 | device read declaring `stopRemoteCapture`, confirmed success, finalizing, compensation intent and outcome; terminal `failed` |
| `plan-only` | 5 | plan-only lifecycle without intents; terminal `planned` |

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Rust writer and replay | `cargo test -p arkdeck-hoststore --lib job_journal` and `--test job_journal_process_death` | 10 passed (8 unit tests; the process-exit pair in its own binary since the addendum below): each scenario reproduces the oracle bytes and facts, and so does a cold replay of the oracle; each oracle reopens, continues and survives restart; a torn tail is cut back behind `jobCreated` but refused alone or after terminal publication; six invalid records (duplicate id, sequence gap, extra payload key, orphan outcome, intent after an unknown outcome, illegal transition) and a plan-only device mutation are refused with the file unchanged; terminal publication refuses append and creation; a replaced inode is refused with both files kept; a second writer's append forces a full replay; a held manifest lock is waited for; SIGKILL-equivalent exits at `AfterPartialRecord` leave the old journal after reopen and at `AfterRecordSync` the new record |
| Rust suites | `cargo test -p arkdeck-platform -p arkdeck-hoststore` | all passed (the pre-existing ignored child helpers stay ignored) |
| Clippy | `cargo clippy --workspace --all-targets [--target x86_64-pc-windows-msvc \| x86_64-unknown-linux-gnu] -- -D warnings` | clean on all three targets |
| Swift oracle and continuation | `run-swiftpm.sh test --filter 'JournalRustWriterParityContractTests\|JournalRecoveryContractTests'` | 20 executed, 1 skipped (the existing 10k-event scale test), 0 failures: Swift writes exactly the committed bytes and facts, and repairs and continues each oracle |

The first run of the Swift command failed to start (`sh:
Packages/ArkDeckKit/Scripts/run-swiftpm.sh: No such file or directory`, exit 127,
no test ran); it was re-run with the absolute script path.

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`
on commit `b0c4a099` (merge base `dfdb6b68`), with `ARKDECK_PYTHON` on the SDD venv and the planner
started from a venv holding `PyYAML==6.0.3` and `jsonschema==4.26.0`. The planner classified 19 changed
files and selected the common, design-system, Swift and Rust lanes (no App build). Log:
`/private/tmp/xpa014-journal-writer-gate-20260913-r1.log`.

- Common checks: planner and agent-PR workflow tests, SDD (0 errors, 0 warnings, 121 acceptance IDs),
  catalog generator tests and `--check`, 83 design-system tests.
- Swift full lane: `full-parallel` 2,648 tests exit 0, `full-process-identity-race` 1 test exit 0,
  `full-viewer-scale` 5 tests exit 0.
- Rust lane: `generate-contract.py --check`, `cargo fmt --all --check`, warnings-denied Clippy,
  workspace tests, `test_contract_checks.py` (33 tests OK), `check-contracts.py` passing both views
  with every candidate process harness passing (read-only, History, Session
  owner/resources/cleanup/export, Trace cache, Bundle list/register/retirement, HDC registration, tool
  list/retirement) and `test-macos-facade.py` against the candidate build (7 tests OK), `cargo deny`
  and `cargo vet` (36 fully audited).
- Result: the log ends `gate exit=0`; SHA-256
  `6ee44776b9db986ec299a3d269b2a7cdd97dd64f3ea18954279de32a012e9618`.

This record was untracked while the gate ran, so it is not in the planner's file list;
`sh scripts/check-sdd.sh` was re-run with it present: 0 errors, 0 warnings, 121 acceptance IDs.

## Addendum: first CI run and the process-exit test binary

The first CI run of this change (Swift CI run 34764599985) passed `swift-tests` and the Ubuntu and
Windows Rust workspaces but failed the macOS Rust workspace in
`crates/arkdeck-hoststore/tests/import_upload.rs`, which this slice does not change:
`partial_and_synced_chunks_recover_only_the_uncommitted_suffix` got `WouldBlock` (errno 35)
reopening its Import owner lock right after dropping the previous owner. The same test binary's
`sigkill_upload_recovery_uses_only_durable_checkpoints` spawns child processes.

A C probe on this host settles the mechanism: while one thread spawns `/usr/bin/true`, another that
closes an `O_CLOEXEC` descriptor holding `flock(LOCK_EX | LOCK_NB)` and immediately reopens it got
`EWOULDBLOCK` on 201 of 100,000 reopens with `posix_spawn` and on 170 with fork and exec. A child
shares the parent's open-file descriptions until exec closes them, so a lock the parent released is
briefly still held. 150 local runs of the Import binary, with and without the spawning test, did not
reproduce it (load 2.2 on 8 cores); the fix for that binary belongs to TASK-XPA-013.

For the same reason this slice moved its own process-exit test out of the hoststore unit-test
binary, where other tests close and reopen owner locks, into
`crates/arkdeck-hoststore/tests/job_journal_process_death.rs`, a binary with no other test. The test
body is unchanged. After the move (log `/private/tmp/xpa014-journal-move-checks-20260913-r2.log`,
ends `checks exit=0`, SHA-256
`f306d03b98995025070b9f50c90d29ca7ea220df137851827a1fd59039ac9bbf`): `cargo fmt --all --check`;
`cargo test -p arkdeck-hoststore --lib job_journal` 8 passed and `--test job_journal_process_death`
2 passed; the platform and hoststore suites passed (hoststore unit tests 128 passed and 5 ignored,
platform unit tests 46 passed and 3 ignored, every integration binary passed); warnings-denied
Clippy is clean for macOS, Windows and Linux. No Swift, contract or design-system input changed
after the gate, so those lanes were not repeated.

## Not run, and why

- No daemon, RPC or CLI path writes journals yet, so there is no process harness
  or control-frame evidence in this slice. The first consumer is the Rust Job
  authority (admission and execution) that later XPA-014 slices build.
- SQLite `runtime_job` and `job-record.json` writers, capability and recovery are
  separate slices. Replay facts classify recorded outcomes only; ADR-0009
  decisions 2/4 (L.1 item 13) are not ported and no recovery decision is made.
- No device; DAYU200 is not attached to this host.

## Residuals

- The 256 MiB snapshot bound refuses very long journals; a streaming replay would
  lift it when the Rust authority owns long Jobs.
- The five-second lock bound matches the Rust reader, not Swift; a lock held
  longer by terminal publication returns a refusal the caller must retry.
