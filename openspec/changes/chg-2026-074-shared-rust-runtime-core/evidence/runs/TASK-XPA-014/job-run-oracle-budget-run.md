# Run oracle analyzer budgets — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: protected main `fffcaa93`, where the `job.cancel` slice
(#1897) landed. The change is test-only — the run oracle, its fixture and its Rust
replay — so no production code and nothing installed changes. Every request, source and analyzer
answer is synthetic host data; nothing here is device evidence.

## Why

The run oracle (`JobRunAnalyzerOracleContractTests.testSwiftRunsTheSharedAnalyzerOracle`, replayed
by `rust/crates/arkdeck-hoststore/tests/job_run.rs`) composed one analyzer profile with a 2 s budget
for all 20 of its runs, because its `sleep` answer must time out. Every other run's answer then
rested on 2 s of wall clock for real work. Beside the real-process harness, with the load average
near 40 on this 8-core host, the cancellation replay, which shared that budget, parked an `answered`
Job whose Journal reads `outcomeUnknown: process timed out before completion`
(`job-cancel-analyzer-run.md`). The `job.cancel` slice gave the writer oracles 30 s; the run
oracle's 19 other runs stayed exposed in the Swift test, the Rust replay and CI.

## Change

- The Swift oracle composes two engines over its one store (the same Job state directory, Artifact
  store and capability store), each with the real descriptor-bound dispatcher and no Session
  publication writer. Every Job but the timeout case's is admitted, run and read by the engine whose
  analyzer has the daemon's production budget, 30 s; the `timedOut` Job (its admission, its run, the
  `rerunParked` rerun and its four reads) by the engine with 2 s. A Swift engine runs only the Jobs
  it admitted (`runForTargetControl` answers any other Job `resourceConflict … not runnable`), so
  each Job stays with its engine. The order and every answer are unchanged.
- With the shared budget at 30 s, the writer oracles' `writerTimeoutSeconds` folds into it; the
  publication and cancellation fixtures still match byte for byte.
- The fixture's entries that ran under the short budget carry `"timeoutSeconds": 2` (`timedOut`,
  `rerunParked`), and `provenance.json` records 30. `tests/job_run.rs` builds one profile and one
  runner per budget and admits and runs each Job under its entry's budget, else the provenance's.

## Shared oracle

`rust/tests/fixtures/job-run-analyzer/` was recorded again by Swift in record mode
(`ARKDECK_RUST_JOB_RUN_RECORD=/private/tmp/xpa014-run-oracle-budget-r1`) and matched every file in
compare mode in a new process. Against the previous recording 18 of 74 files changed, all through
the plan digest, which covers the analyzer's budget: the 14 other Jobs' `materializedPlanDigest` in
their `job-record.json` and `job.show` reads, the index's 14 record digests, the two entries'
`timeoutSeconds` and the provenance. Every answer, every other read, every Journal and every
Artifact is byte-identical, and the `timedOut` Job's files did not change.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Swift oracles, record | `ARKDECK_RUST_JOB_RUN_RECORD=… run-swiftpm.sh test --filter JobRunAnalyzerOracleContractTests` | 3 executed, 0 failures: the run oracle recorded; the publication and cancellation oracles compared unchanged with the folded constant |
| Swift oracles, compare | the same filter in a new process | 3 executed, 0 failures |
| Rust replay | `cargo test -p arkdeck-hoststore --test job_run` | 1 passed on the new fixture; the adapted replay also passed on the previous fixture, whose entries all fall back to its 2 s provenance |
| Rust CLI | `cargo test -p arkdeck-cli --test job_run --test job_result` | 3 and 5 passed (both read the fixture's cases and reads) |
| Rust workspace | `cargo fmt --all --check`; `cargo test --workspace --locked` | formatted; 65 test binaries, 512 tests, 0 failures |
| Lint | `cargo clippy -p arkdeck-hoststore --tests -- -D warnings` | clean |
| Real processes | `.venv-sdd/bin/python rust/scripts/check-job-run.py --swift-bin-dir <run-swiftpm debug products>` | PASS on every one of its 132 runs in the load loops below, 147 checks each: both daemons, which compose the production budget, still give the oracle's answers for the 19 runs it compares (the `sleep` lane aside), with the 9 cancellation requests and the Swift handoff |

## Under load

Each row alternates the pre-change replay (the previous fixture and test, every run under 2 s) with
the post-change replay; both take the oracle root's lock, so they never overlap. Summary of every
run below: `/private/tmp/xpa014-run-oracle-budget-load.json`, SHA-256
`924b36709d41de3c52ba7fab229ea2d633a83d8706b45580a18871ba5f3b1b7f`.

| Condition | Pairs | Pre-change | Post-change | Harness |
| --- | --- | --- | --- | --- |
| one harness loop and two `yes`, 1-minute load 4–27 | 30 | 30 passed | 30 passed | 24 of 24 PASS |
| three concurrent harness loops and eight `yes`, 1-minute load 15–154 | 30 | 30 passed | 30 passed | 54 of 54 PASS |
| the replay stopped (`SIGSTOP`) for 2.2 s and continued for 0.1 s, over and over (95% of each replay stopped); its analyzer child, in its own process group, never stopped | 3 | 0 passed: `answered` parked in `waitingForRecovery` every time (so its rerun is refused as parked), with `redacted` or `quotaExceeded` parked as well in two of them | 3 passed | — |

The pre-change replay passed every load loop too: load alone rarely costs a run 2 s (the
`job.cancel` slice's 24 replays beside a saturated CPU passed as well). What turns a run into a
timeout is the runner itself losing its time: in the stall probe the analyzer child needs
milliseconds, yet a runner stalled past 2 s parks `answered` as `outcomeUnknown`, the failure seen
beside the harness, while the same stalls leave every post-change answer as Swift recorded it. A
harsher probe, replays at background priority beside eight `yes` at normal priority and a harness
loop, also made the pre-change replay park `redacted`, `nonZeroExit` and `quotaExceeded` (after
653 s); it starved the host, so it was stopped before its post-change replay finished. With the
replays and eight `yes` all at background priority (`taskpolicy -b`, efficiency cores only), both
replays passed 2 of 2.

Found on the way, not changed: the runner's budget clock starts before the spawn, and after a stall
its wait loop can reach the deadline check before its output readers have reported the child's end
of output, so a runner stalled past the budget can report a timeout for a child that finished
within it. The Job is then parked (`outcomeUnknown`), never misreported; under the production budget
that takes a 30 s stall of the owner process.

## Not run, and why

- The harness still skips the `sleep` mode: both daemons compose the production 30 s budget, so the
  timeout lane stays in the oracle replay, now the only run there under 2 s.
- No unified local gate: the change is test-only, and the Swift oracles, the Rust workspace tests,
  Clippy, rustfmt and the SDD check (`check-sdd.sh`: 0 errors, 0 warnings) ran instead; CI runs the
  full Swift and Rust lanes.
- No device; DAYU200 is not attached to this host.
