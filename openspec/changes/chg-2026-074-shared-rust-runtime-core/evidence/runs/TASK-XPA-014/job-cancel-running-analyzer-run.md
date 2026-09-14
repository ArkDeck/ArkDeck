# Rust cancellation of a running analyzer Job — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: protected main `c8d20163`. While this slice was in flight
#1897 (the cancellation of a Job that never started) merged, then #1898 (the run oracle's budget)
and #1899 (the Rust owner locks' 500 ms wait); the slice was rebased onto them (see the gate
section). This slice cancels an
`analyzer.extract-crash-signature@1` Job the isolated Rust development composition is running, as
Swift's `requestCancel` and its safe-boundary lanes cancel a running analyzer. Nothing installed
changes. Every request, source and analyzer answer is synthetic host data; nothing here is device
evidence.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for TASK-XPA-014 |
| --- | --- | --- |
| Rust reads the v1 Job index, records, events and Artifact routing and writes journals, the admission index and `job-record.json` (#1863, #1879, #1889, #1891); `job.plan`, `job.submit`, `job.run`, `job.result`/`job.evidence`, Session publication and the cancellation of a Job that never started for the analyzer (#1892–#1897) | Cancelling a running analyzer Job: the request carried by the run that owns the Journal, the zero-dispatch close at the last boundary before the intent, the child's process group terminated and drained, the cancelled outcome and close, the parking lanes, the owner's serialization of a canceller with the run; a Swift-recorded running-cancellation oracle; the real-process harness cancelling a running Job on both owners | Execution of every other operation (device facts, Runtime capabilities, the executor hand-off); capability mint/reserve/consume; §G.4 preflight; recovery, `job.reconcile` and resumption (after the L.1 item 13 ruling); GJ-1..5 |

## Behaviour

Swift's `requestCancel` for a resident running Job records the request, writes
`running -> cancelRequested` ("durable client cancellation intent"), persists the record and
cancels the analyzer's dispatch task; the run then carries the request out at its safe boundaries
(`RuntimeJobEngine.swift`): at the last synchronous boundary before the intent (lines 4197–4208);
through a cancelled dispatch whose process group was drained (4340–4351) or not (4352–4358); for a
dispatch that returned although the request was made (4329–4339); and not at all once the success
commit is linearized (5165–5167). Its process layer (`ArkDeckProcess.swift`, 1433–1469) terminates
the child's group: TERM, the group looked for every 10 ms for 0.25 s, then KILL and up to a second
more; drained only when no member is left.

In the Rust owner the run alone writes the Job's Journal, so a canceller cannot write the intent
itself. `RunCancellation` (`arkdeck-hoststore/src/job_cancel.rs`) carries the request to the run:

1. The canceller records the request and waits for the run.
2. At its next boundary the run writes Swift's `running -> cancelRequested` and persists the
   record; the canceller then answers `{"cancelRequested": true}`.
3. At the last boundary before the intent the run closes the Job with zero dispatch:
   `cancelRequested -> cancellingAtSafeBoundary` ("dispatch has a confirmed safe boundary"),
   `-> cancelled` ("cancelled intent closed without publication"), the cancelled failure, the
   finish time, the record and the Session.
4. While the child runs, `VerifiedTool::run_analyzer` (`arkdeck-platform`) takes a cancellation
   probe: a cancellation seen before the spawn leaves no child, and one seen while the child runs
   terminates its group as Swift's executor does, drained only when `proc_listpids(PROC_PGRP_ONLY)`
   finds no member but the retained leader. Drained, the run records the step's confirmed `failed`
   outcome with semantic code `cancelled` and Swift's timeline entry, forgets the typed action, and
   closes the Job as above. Not drained, it parks the Job (`cancelRequested -> waitingForRecovery`,
   "outcomeUnknown: analyzer process-group drain unconfirmed").
5. A child that finished before the run saw the request parks the Job with Swift's raced-completion
   entries ("analyzer cancellation lacks process-group drain proof").
6. Once the child has finished, a request changes nothing and is answered at once.

`arkdeck-agentd` hands a canceller the run's `RunCancellation` when this owner is running the Job.
If the run ends without acting on the request, the canceller falls back to the Job's record once
the run has let go of the Job. A Job left active with no run here is refused as Swift refuses a Job
it holds no runtime for: `rejected`,
`internalFailure("job <id> is <state> but is not resident, so its cancellation cannot be carried out")`.
That replaces the refusal message of Rust's own that the previous slice gave such a Job.

Deliberate differences from Swift:

- Swift answers once the intent is durable, while its child is still being terminated; the Rust
  canceller answers once the run has acted, which for a running child is after the drain.
- A request that arrives after the child has finished is answered with nothing written, as Swift
  answers one after its success commit, even if the child's answer then fails verification. Swift's
  actor might take such a request at a later suspension point of its failure path and journal it.
- The undrained-group and raced-completion lanes follow Swift's source and are not exercised: no
  real child survives KILL, and nothing separates a child's exit from the run's next step.

Found on the way: the other session that moved the run oracle's non-timeout runs to the production
budget (#1898) found the mechanism of the 2 s flake the previous slice fixed for the writer
oracles. Load alone never reproduced it (60 A/B pairs up to load
average 154), but stopping the replay process for 2.2 s at a time parked the `answered` Job 3/3
under a 2 s budget and 0/3 under 30 s: the runner's clock starts before the spawn, and after a stall
its loop can pass the deadline before the output readers report EOF.

Also found, not changed: the platform unit test
`host_store::file_export::tests::sigkill_around_publication_preserves_original_or_complete_file_and_restart_never_replays`
failed once in a `cargo test` of the five changed crates and passed three runs alone. It lives in
the shared library test binary, where child-spawning tests have raced before; it is filed
separately.

## Shared oracle

`rust/tests/fixtures/job-cancel-running-analyzer/` was recorded by Swift
`JobRunAnalyzerOracleContractTests.testSwiftCancelsRunningAnalyzerJobs`
(`ARKDECK_RUST_JOB_CANCEL_RUNNING_RECORD`, at `/private/tmp/xpa014-job-cancel-running-oracle-r1`), in the
writer oracles' composition with the engine's two cancellation hooks, each holding only the Job it
names. The same test then ran again in compare mode in another process, with the three other
analyzer oracles, and matched every file.

| File | Content |
| --- | --- |
| `cases.json` | three Jobs, each with its submit request, the point its cancellation arrives, the `job.run` answer and the `job.cancel` answer: `drained` (the `sleep` source; cancelled once its intent is durable, while its child runs; `cancelled`), `beforeDispatch` (held at `beforeDispatchInstall`, the last boundary before the intent; `cancelled` with no intent) and `committed` (held at `afterAnalyzerCommitLinearization`; `succeeded`, the request answered with nothing written) |
| `reads.json` | Swift's `job.status`, `job.show`, `job.result` and `job.evidence` of each Job: 12 reads |
| `store/`, `sessions/`, `session-owner/`, `tree.json`, `artifacts/` | as in the other writer oracles: the index, every Job file, three Sessions (the drained Job's with its step executed and failed), the catalog at generation 3, the owner's lock, and the kind and mode of all 101 entries |

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Rust running cancellation | `cargo test -p arkdeck-hoststore --test job_cancel_running` | 1 passed: the three runs and cancellations, the 12 reads, the index rows, every Job file, Artifact and Session file, the catalog, the owner's lock and all 101 kinds and modes reproduced byte for byte, machine facts read as labels |
| Earlier oracles | `cargo test -p arkdeck-hoststore --test job_run --test job_publication --test job_cancel` | 3 passed, unchanged by the runner's new boundaries |
| Cancellation handshake | `cargo test -p arkdeck-hoststore --lib job_cancel` | 3 passed: a request answered once the run carries it; a request before the commit still the run's, one after it answered at once; a run that ends first leaving the request to the record |
| Host serialization | `cargo test -p arkdeck-agentd cancellation_tests` | 2 passed, one rewritten: a request waits in a live run and falls back to the record when the run ends |
| Analyzer child | `cargo test -p arkdeck-platform --test analyzer_process` | 8 passed, three new: a cancellation before the spawn starts no child, a cancellation drains the whole group (a background member included), and a group that ignores TERM is killed once its grace is over |
| Workspace | `cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-control -p arkdeck-cli`; warnings-denied Clippy on those crates; `cargo fmt --all --check` | passed apart from the unrelated platform test above |
| Swift oracles | `run-swiftpm.sh test --filter JobRunAnalyzerOracleContractTests[/testSwiftCancelsRunningAnalyzerJobs]` | r1 did not compile: the isolation checker cannot follow `Self` into a task, so the run is sent through the type's name. r2 recorded the oracle (1 executed, 0 failures); the compare run of all four analyzer oracles in a new process: 4 executed, 0 failures |
| Real processes | `python3 rust/scripts/check-job-run.py --swift-bin-dir <run-swiftpm debug products>` | PASS, 156 checks. Beyond the previous slice's checks, both owners cancel a Job whose analyzer child (the `sleep` source) is running once its intent is durable: the same `{"cancelRequested": true}`, the same cancelled status from the run, and the same Journal, record and Session apart from the clock. Both publish the same 18 Sessions; the Swift daemon given the Rust-run store reads all 16 Jobs as the Rust owner did. Summary: `/private/tmp/xpa014-harness-cancel-running-r1.json`, SHA-256 `81c148087f9c99c9d8f2bdf17efd3511c60d0c7768058866b6c26981d224c347` |
| Contract derivation | `generate-control-contract.py --derive-method-schemas` over the committed corpus of the nine Job methods and the recorded frames pruned to the shapes the corpus lacked | two `job.result` frames survived the pruning; re-deriving changed no schema beyond its sample counts, so every schema and corpus file stays as committed |

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`,
with `ARKDECK_PYTHON` on the SDD venv and the planner started from a venv holding `PyYAML` and
`jsonschema`. It ran on `bf29c36e`, this slice before the gate result was added here. Against merge
base `fffcaa93` the planner classified 106 changed files and selected the common, design-system,
Swift and Rust lanes (no App build).

- r1, `/private/tmp/xpa014-job-cancel-running-gate-20260914-r1.log`:
  - Common checks: planner and agent-PR workflow tests, SDD (0 errors, 0 warnings, 121 acceptance
    IDs), catalog generator tests and `--check`, design-system tests.
  - Swift full lane: `full-parallel` 2,656 tests exit 0 (the four analyzer oracle tests of
    `JobRunAnalyzerOracleContractTests` among them), `full-process-identity-race` 1 test exit 0,
    `full-viewer-scale` 5 tests exit 0.
  - Rust lane: `generate-contract.py --check`, `cargo fmt --all --check`, warnings-denied Clippy,
    workspace tests (the platform test above passed here), `test_contract_checks.py` (33 tests OK),
    `check-contracts.py` passing both views with every candidate process harness and
    `test-macos-facade.py` (7 tests OK), `cargo deny` (advisories, bans, licenses and sources ok)
    and `cargo vet` (36 fully audited).
  - Result: the log ends `gate exit=0`; SHA-256
    `bceb5d881c2b050ef45f645dff6039be62d1794e25b98d9249419d9e99c77b88`.

The slice was then rebased onto `c8d20163`, where #1898 and #1899 had merged. Both conflicts were
in test composition: the writer composition keeps #1898's shared 30 s budget (its
`writerTimeoutSeconds` is gone) and takes the engine's test hooks, and `tests/job_run.rs` keeps
#1898's runner per budget with the two new `JobRunner` fields. On the rebased tree:

- `cargo fmt --all --check`, warnings-denied Clippy and `cargo test` of `arkdeck-platform`,
  `-hoststore`, `-agentd`, `-control` and `-cli` passed, #1899's `host_lock_spawn_window` binary and
  every replay above included.
- The four analyzer oracles of `JobRunAnalyzerOracleContractTests` in compare mode: 4 executed,
  0 failures.
- `check-job-run.py` r2: PASS, 156 checks, 18 Sessions on each owner; summary
  `/private/tmp/xpa014-harness-cancel-running-r2.json`, SHA-256
  `93670465b84bb90ed1d3034b27d5ec88a3383013f2d61b4b5abb599f9159b3cd`.

The unified gate was not re-run after the rebase; CI runs its lanes on the pushed commit.

## Not run, and why

- The undrained-group and raced-completion lanes: see above.
- The `drained` case needs its cancellation to reach the run within the `sleep` source's 5 s.
  A stall of the oracle, replay or harness process longer than that between the durable intent
  and the cancellation would let the child finish first and turn the case into a succeeded run
  (the same stall mechanism as above). Lengthening the analyzer's sleep changes the analyzer's
  digest, and with it every analyzer oracle's plan digests, so it is filed separately rather than
  folded in here.
- No recovery, reconciliation or resumption: they wait for the L.1 item 13 ruling.
- `check-job-run.py` needs the SwiftPM daemon and CLI products, so it runs by hand rather than inside
  `check-contracts.py` or CI.
- No device; DAYU200 is not attached to this host.
