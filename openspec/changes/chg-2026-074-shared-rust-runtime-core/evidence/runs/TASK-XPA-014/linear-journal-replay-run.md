# A Journal replay grows with its Journal, not with its square (TASK-XPA-014, macOS, 2026-09-26)

TASK-XPA-014 / CHG-2026-074. While the staged Session publication was measured (#2230), a device
mutation's proof over one retained Session with a 10,013-record Journal took 9.4 s. The proof,
`JobStore::require_mutation_state`, replays every retained Session's Journal, holding the Job
store's `activity` guard. Anything else that needs the guard waits: a record persisted, an
admission, a Journal file published. The hub put the scan speedup next in this line.

Base: protected `main` `587127475` (#2233), which holds #2230's staged Session publication.
Developed and first checked on `dc709dc3e` (#2224). Disposable host data only; nothing here is
device evidence.

## Cause

`ReplayState::validate` (`job_journal_replay.rs`) checks each record against everything before
it. For every record it asked whether any intent was still outstanding:
`self.outstanding().next().is_some()`. `outstanding()` walked every recorded intent and skipped
each completed one, so the question cost one step per intent. A Journal of n records therefore
replayed in about n²/4 steps: a step-retried read's intents accumulate, all of them completed.
Two kinds of caller paid it:
- a cold replay, among them the continuity scan, the cutover facts, the Import references and
  `job.result`;
- `JournalWriter`, which validates each record it appends.

## Change

- `ReplayState` keeps `outstanding`: the identities of the intents recorded and not completed.
  `accept` keeps it as each record is accepted:
  - an intent is added unless its identity is already completed;
  - an outcome removes the intent it correlates.
- `validate` asks whether that set is empty.
- `outstanding()` walks that set, in event identity order, and reads each intent. That is the
  order the walk over every intent gave. So the facts (`outstandingIntents`, the required
  abandonment hazards) are listed exactly as before.
- Nothing else changes: no check, fact, refusal or wording.

## Equivalence

`job_journal_replay::tests::the_outstanding_intents_kept_are_every_intent_not_completed_after_each_record`.
- **What it replays.** Every Journal in `rust/tests/fixtures`: each `.jsonl` file whose first
  record is a `jobCreated`. There are 492, most of them Swift's, as the oracles recorded them. The
  test replays each one record by record.
- **What it checks.** After each record, the intents the replay keeps equal, in the same order,
  every intent recorded and not completed. That set is what the old walk read.
- **The totals:** 6,670 records, and 2,362 outstanding intents across the checks, so the
  corpus exercises both empty and non-empty sets.
- **Negative control.** With an outcome no longer removing its intent, the test failed at the
  first completed intent (`intent-probe-host-tool`).

Every check reads the set only through `outstanding` or `outstanding()`. The set equals the old
walk after every record, so every check, fact and refusal is the old one. The oracle replays
still pass unchanged: `job_journal_writer` against Swift's four Journals and their recorded
facts, `job_publication` byte for byte, `device_reconcile`, `crash_window`, `job_cancel`,
`job_reconcile` and `pointer_input_run`.

## Cost

`job_journal_replay::tests::a_replay_of_ten_thousand_records_takes` (`#[ignore]`d).
- **The Journal.** The Swift pointer oracle's tap Journal, its evidence-model read retried 1,250,
  2,500 and 5,000 times more.
- **The proof.** `require_mutation_state` over one retained Session holding the longest.
- **The build.** Debug, as `cargo test` builds it. Five samples each. The host was not quiet:
  its 1-minute load was 4 to 6, with other sessions building.

| What | Before (median, max) | After (median, max) |
| --- | --- | --- |
| Replay of 2,513 records | 548 ms, 565 ms | 136 ms, 140 ms |
| Replay of 5,013 records | 2.05 s, 2.19 s | 249 ms, 255 ms |
| Replay of 10,013 records | 12.2 s, 15.1 s | 521 ms, 532 ms |
| Proof over one retained 10,013-record Session | 10.7 s, 13.8 s | 517 ms, 524 ms |

Before, doubling the Journal took four to six times as long; after, twice as long. What remains
is decoding and checking each record once, about 52 µs a record in a debug build.

**Again, in the hub's quiet window.** The hub's quiet window, 2026-09-26 08:44–09:04: no build ran on the host. The hub measured the
1-minute load every 15 s: a median of 2.07 with every session's builds stopped, and a median of
2.66 (max 3.35) during these measurements. This session sampled it every second
(`window-load.log`): between 1.96 and 3.42. It ran a prebuilt debug binary, the
`arkdeck-hoststore` library tests as built on `eec3df485` with the cleanup slice's change, which
touches none of the measured paths, measuring only
(`window-measure.log`). The same test, five samples each, at a 1-minute
load of 1.96 to 1.97:

| What | Median | Max |
| --- | --- | --- |
| Replay of 2,513 records | 119 ms | 134 ms |
| Replay of 5,013 records | 241 ms | 248 ms |
| Replay of 10,013 records | 490 ms | 490 ms |
| Proof over one retained 10,013-record Session | 513 ms | 516 ms |

The proof still reads and replays every retained Session each time. The next slice caches each
Session's verdict in memory. It is keyed by its files' device, inode, size, and nanosecond
modification and change times, and any difference means a full scan, as the hub ruled.

## Contract

No contract input changes, and no answer changes.

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-vj-rust-target`, logs in
`/private/tmp/arkdeck-vj-logs/`. The host was loaded (1-minute load between 4 and 25 at the
samples taken) while the crate tests ran.

**On `dc709dc3e`:**

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0 (`r-fmt.log`).
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --all-targets -- -D warnings`: exit 0 (`r-clippy.log`). The replay module is
  built on macOS only.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --no-fail-fast`: exit 0 (`r-test.log`).
  - 112 suites: 818 passed, 0 failed, 14 ignored.
  - One of the ignored is this slice's measurement. The others already existed.
- The equivalence test's negative control above.
- The measurement above, before and after (`r0-measure.log`, `r1-measure.log`).
- `sh scripts/check-sdd.sh` (validation venv): exit 0.

**After the rebase onto `587127475`,** with #2230's staged publication beside the change:
- `cargo fmt --all --check`: exit 0 (`r2-fmt.log`).
- The same clippy: exit 0 (`r2-clippy.log`).
- The equivalence test alone: passed (`r2-equivalence.log`).
- The same crate tests: exit 0 (`r2-test.log`): 113 suites, 824 passed, 0 failed, 17 ignored.
- `sh scripts/check-sdd.sh`: exit 0.

**Not run:**
- `generate-contract.py --check` and `check-contracts.py`: no contract input changes.
- A measurement on a quiet host: the hub arranges one window for this slice, the staged
  publication's P99 and the 20b baseline together.
- The App and a device.

## CI

**Run 36196885859, on the first head `45ca09cec`: an invalid run.** The host-independent checks
failed, in "Contract isolation and provenance regression tests".
- One of `rust/scripts/test_contract_checks.py`'s 45 tests erred:
  `test_checkout_manifest_describes_the_working_tree_without_a_commit`.
- It failed after the test itself, while `TemporaryDirectory` was cleaned up: `OSError: [Errno
  39] Directory not empty: '/tmp/arkdeck-contract-tests-j2dtexjm'`. Something was still writing
  into the temporary checkout while it was removed.

The four criteria for an invalid run:
1. **The failure is outside this change.** The change touches `job_journal_replay.rs`, the README
   and this record. None of them is that test's.
2. **It is a known race class:** a directory removed while another process writes into it.
3. **It passes alone.** `python rust/scripts/test_contract_checks.py`, three times in a row
   locally (validation venv): 45 tests OK each (`r-contract-tests-{1,2,3}.log`).
4. **It is unrelated to the diff.**

The hub confirmed the reading. This session does not rerun jobs through `gh`, so this record
itself was pushed again, and the new head's run replaced the job.

The next head, `f04af96b3`, failed on macOS in "Rust helper package structure (unsigned)": the
runnable `arkdeck` was not the packaged one with its signature replaced. That was a defect of
#2218's new check, and every PR on `33c161b19` or later failed it. #2236 fixed the check. This
slice was then rebased onto `587127475`.

Run 36201192211, on the rebased head `c559b931f`: every selected lane passed.
- Rust workspace: macOS 14m35s, Ubuntu 1m53s, Windows 4m12s. Host-independent checks: 36s.
- `guard`; `swift` aggregate. `swift-tests` was not selected.

It merged as `21fcfa99f`. Recorded by a later slice (TASK-XPA-014, the failed publication's
Session), as AGENTS.md has it.
