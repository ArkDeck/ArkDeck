# Rust Job cancellation for the crash-signature analyzer — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: protected main `ac66aaa3`. #1892 to #1896 merged while this
slice was in flight, and each squash has the same tree as the commit the stack carried. This slice
answers `job.cancel` for the `analyzer.extract-crash-signature@1` Jobs the isolated Rust
development composition admits, as the standalone Swift daemon does. Nothing installed changes.
Every request, source and analyzer answer is synthetic host data; nothing here is device evidence.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for TASK-XPA-014 |
| --- | --- | --- |
| Rust reads the v1 Job index, records, events and Artifact routing and writes journals, the admission index and `job-record.json` (#1863, #1879, #1889, #1891); `job.plan` (#1892), `job.submit` (#1893), `job.run` (#1894), `job.result`/`job.evidence` (#1895) and Session publication (#1896) for the analyzer | `job.cancel`: a Job at its admitted boundary closed with zero dispatch and published as a cancelled Session, the answers for Jobs the request leaves as they are, Swift's refusals, the serialization of a cancellation with the runs of one Job in the daemon, and `arkdeck job cancel`; a Swift-recorded cancellation oracle; the real-process harness comparing both owners' cancellations and handing the Rust-cancelled Job to a Swift daemon; the writer oracles' analyzer budget | Cancelling a running Job at its safe boundaries; execution of every other operation (device facts, Runtime capabilities, the executor hand-off); capability mint/reserve/consume; §G.4 preflight; recovery, `job.reconcile` and resumption (after the L.1 item 13 ruling); GJ-1..5 |

## Behaviour

Swift's daemon handler for `job.cancel` requires a string `jobId`, calls
`RuntimeJobEngine.requestCancel`, answers `{"cancelRequested": true}` whenever that returns, and
maps its errors without details: `jobNotFound` to `notFound` "unknown job <id>", any other engine
error to `rejected` with the error's Swift rendering, anything else to `internalError`.
`JobCanceller` (`arkdeck-hoststore/src/job_cancel.rs`) follows it for the Jobs this owner admits:

1. a missing or non-string `jobId`: `invalidParams` "jobId is required";
2. an absent Job, or an identity the owner cannot hold: `notFound` "unknown job <id>"; an unreadable
   record: `rejected` with Swift's `jobRecordUnreadable("<id>")` rendering;
3. a terminal Job, one finalizing, one waiting for recovery or reconciling, or one already
   `cancelRequested` or `cancellingAtSafeBoundary`: `cancelRequested`, nothing written;
4. a Job at its admitted `preflight` boundary (its Journal at `preflight`, no outstanding intent or
   unknown outcome, not finalized): the three journaled transitions `preflight -> cancelRequested`
   ("client-cancel before execution"), `cancelRequested -> cancellingAtSafeBoundary` ("no provider
   intent was dispatched") and `cancellingAtSafeBoundary -> cancelled` ("never-started job closed
   with zero dispatch"), the cancelled failure (`cancelled`, `cancelled`, `notAutomatic`, `none`), the
   finish time and the record, then the runner's terminal publication, now shared by both as
   `Run::release`: a cancelled Session whose Manifest has no steps, and the record's receipt;
5. a Job that has started — `running`, or any other state the request would have to stop —
   `rejected` "job <id> is <state>; the Rust Runtime cancels only a Job that never started".

`arkdeck-agentd` serializes a cancellation with the runs of one Job through the slot map that
already joins concurrent runs: a Job this owner is running is refused ("job <id> is being run; …"),
a cancellation holds the Job while it works, a concurrent cancellation joins its answer, and a run
waits it out and then runs itself, meeting the cancelled Job (`resourceConflict` "job <id> is
cancelled, not runnable" with the zero-dispatch proof). The control layer routes `job.cancel` to the
host; a host without a Job owner answers as the read-only foundation did.

`arkdeck job cancel --job <id>` sends the identity as given (Swift's `--job` grammar is opaque) and
takes no wait bound; it accepts only `{"cancelRequested": true}`, prints it and exits 0. Swift's
`CLIControlFailureMapper` classifies `job.cancel` as mutation-capable and its refusals carry no
evidence, so `notFound` is `resourceNotFound` (65), `invalidParams` is `invalidInput` (65),
`unknownMethod` is `controlMethodUnavailable` (69), `rejected` and `internalError` are
`outcomeUnknown` (75), and so is a reply lost after the request went out; a connect failure stays
`runtimeUnavailable`.

Deliberate differences from Swift:

- A Job running in this owner, or left `running`, is refused, where Swift cancels a running analyzer
  at its safe boundaries (at the top of its step loop, at the last synchronization point before the
  intent, by terminating and draining a running child, and as a no-op after a verified receipt).
  Those lanes are the next slice.
- For a resident Job waiting for recovery or already cancelling, Swift also remembers the request in
  memory for the Job's recovery or reconciliation; the Rust owner, without recovery, keeps nothing
  (L.1 item 13).
- Swift refuses a Job it holds no runtime for when that Job is not terminal or its outcome is unknown
  ("… is not resident, so its cancellation cannot be carried out"); the Rust owner reads every Job
  from its store and answers it by its recorded state.
- An I/O failure inside the zero-dispatch close answers `internalError` with this Runtime's message
  rather than Swift's rendering of the underlying error.

Found on the way, and fixed for the writer oracles: every analyzer oracle composed one analyzer
profile with the run oracle's 2 s budget, which its `sleep` answer needs. Replayed beside the
real-process harness, the cancellation oracle once parked its `answered` Job, whose Journal reads
`outcomeUnknown: process timed out before completion`, and the publication replay failed its answer
comparison once in a workspace test run beside the harness (that run left no store to inspect; the
mechanism is the same). Twenty-four replays with the CPU saturated alone passed, so load average
alone does not reproduce it. The writer oracles never run the `sleep` answer, so they now give the
analyzer the production 30 s budget (`writerTimeoutSeconds`), and both were re-recorded with it. The
plan digest covers the budget, so only `timeoutSeconds`, each Job's `materializedPlanDigest`, the
checkpoint seals over the records and the index's record digests changed; every answer apart from
the plan digest in `job.show`, every Journal, Manifest, Session file and Artifact is byte-identical.
The run oracle keeps 2 s for its timeout lane, so its other runs remain load-sensitive; splitting
that lane off is filed as a separate task.

## Shared oracle

`rust/tests/fixtures/job-cancel-analyzer/` was recorded by Swift
`JobRunAnalyzerOracleContractTests.testSwiftCancelsTheSharedAnalyzerJobs`
(`ARKDECK_RUST_JOB_CANCEL_RECORD`, finally at `/private/tmp/xpa014-job-cancel-oracle-r2`), in the
publication oracle's composition, which both writer oracles now share (`writerComposition`,
`writerAdmissions`, `writerFiles`). Each recording matched every file again in compare mode in
another process, together with the run and publication oracles.

| File | Content |
| --- | --- |
| `jobs.json` | the four Jobs admitted over their own sources before any request — `cancelled` and `succeeded` (answered), `failed` (empty) and `parked` (signal) — with each one's submit request and identity |
| `cases.json` | the twelve ordered requests and Swift's answers: cancel before run, cancel again, run after cancel (`resourceConflict` with the zero-dispatch proof), run and then cancel each of the other three Jobs, cancel an absent Job (`notFound`), `{}` and `{"jobId": 5}` (`invalidParams`) |
| `reads.json` | Swift's `job.status`, `job.show`, `job.result` and `job.evidence` of each Job: 16 reads; the cancelled Job has no start time and no step, and its evidence is `artifactIntegrityFailed` for the product it never made |
| `store/`, `sessions/`, `session-owner/`, `tree.json`, `artifacts/` | as in the publication oracle: the index, every Job file, three Sessions (the cancelled Job's without steps; the parked Job publishes none), the catalog at generation 3, the owner's lock, and the kind and mode of all 105 entries |

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Rust cancellation | `cargo test -p arkdeck-hoststore --test job_cancel` | 1 passed: the 12 answers, the 16 reads, the index rows, every Job file, Artifact and Session file, the catalog, the owner's lock and all 105 kinds and modes reproduced byte for byte, machine facts read as labels |
| Rust publication | `cargo test -p arkdeck-hoststore --test job_publication` | 1 passed on the re-recorded oracle, now through the replay support both writer replays share (`tests/support/mod.rs`) |
| Host serialization | `cargo test -p arkdeck-agentd cancellation_tests` | 2 passed: a Job this owner is running is refused without details and, once the run is over, the Job owner answers; a concurrent cancellation joins the first one's answer while a run waits it out and then runs itself |
| CLI | `cargo test -p arkdeck-cli --test job_cancel` | 3 passed: the seven current Swift argv cases (the fixture copied byte for byte from the Swift corpus), the five recorded answers and three malformed ones, and the refusal mapping |
| Workspace | `cargo test -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd` and `-p arkdeck-cli`; warnings-denied Clippy on those four crates; `cargo fmt --all --check` | passed; the one failure before the budget fix is the one described above |
| Swift oracles | `run-swiftpm.sh test --filter JobRunAnalyzerOracleContractTests` | r1 record run: 3 executed, 0 failures (the run and publication oracles compared unchanged after their composition was shared, the cancellation oracle recorded), then a compare run in a new process, 3/0; r2 with the writer budget: a record run (the run oracle compared, both writer oracles recorded) and a compare run in a new process, each 3/0 |
| Real processes | `python3 rust/scripts/check-job-run.py --swift-bin-dir <run-swiftpm debug products>` | PASS, 147 checks. The standalone Swift daemon and the Rust owner, in turn over one state root, answer the 19 runs and the nine cancellation requests identically (cancel before run, cancel again, run after cancel, cancellations of a succeeded, a failed and the parked Job, an absent Job, `{}` and `{"jobId": 5}`), every read of the 15 Jobs, and both CLIs' `job run`, `job result` and `job cancel` (a fresh Job cancelled and read back `cancelled`; an absent Job `resourceNotFound`, exit 65), and leave the same index rows, Job files, Artifacts and Session trees apart from the clock and the labels. Both publish the same 17 Sessions (the 13 terminal oracle Jobs, the two CLI-run Jobs and the two cancelled Jobs; the parked Job publishes none). A standalone Swift daemon given the Rust-run store reads all 15 Jobs and their results as the Rust owner answered them, keeps the parked one parked, answers `job.cancel` and `job.run` of the Rust-cancelled Job as the Rust owner did, lists and shows all 17 Rust-published Sessions with none unaccounted, and reads the 4 Rust-published products back. r3 on the final binaries: `/private/tmp/xpa014-harness-cancel-r3.json`, SHA-256 `c0c1434eb3ba67c98d676a75e069f40552d36d36d47d50465ee0bf202a52443f`; r1 found the same on the binaries before the CLI's last refactor (`/private/tmp/xpa014-harness-cancel-r1.json`, SHA-256 `c0a56bf87311c03cebadfe640104bb824a3ceff40c55d8151154a574114d4bea`) |
| Under load | the harness (r4) run while both writer replays loop | the harness PASS with the same summary as r3; 4 iterations of both replays, 0 failures, at load average 17–19 on 8 cores |
| Contract derivation | `generate-control-contract.py --derive-method-schemas` over the committed corpus of the nine Job methods and the recorded frames pruned to the shapes the corpus lacked | six frames survived the pruning: the cancelled Job's four reads, the failed Job's published result, and the refused `{"jobId": 5}`, which stays out of the corpus so the request schema keeps `jobId` a string (the oracle replay covers that refusal). Re-deriving changed no schema beyond its sample counts, so every schema and corpus file stays as committed and the generated contract is unchanged |

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`,
with `ARKDECK_PYTHON` on the SDD venv and the planner started from a venv holding `PyYAML` and
`jsonschema`. It ran on `6aeec7bc`, this slice before the gate result was added here, after the
stack was rebased on `b547ea29`: #1893 was `1ac63837`, #1894 `a17b9a71`, #1895 `66fb82e2` and #1896
`5887d27b`, each with the same tree as the commit its PR carried before. Against merge base
`b547ea29` the planner classified 367 changed files (the five commits of that branch) and selected
the common, design-system, Swift and Rust lanes (no App build).

- r1, `/private/tmp/xpa014-job-cancel-gate-20260914-r1.log`:
  - Common checks: planner and agent-PR workflow tests, SDD (0 errors, 0 warnings, 121 acceptance
    IDs), catalog generator tests and `--check`, design-system tests.
  - Swift full lane: `full-parallel` 2,655 tests exit 0 (the three analyzer oracle tests of
    `JobRunAnalyzerOracleContractTests` among them), `full-process-identity-race` 1 test exit 0,
    `full-viewer-scale` 5 tests exit 0.
  - Rust lane: `generate-contract.py --check`, `cargo fmt --all --check`, warnings-denied Clippy,
    workspace tests, `test_contract_checks.py` (33 tests OK), `check-contracts.py` passing both views
    with every candidate process harness and `test-macos-facade.py` (7 tests OK), `cargo deny`
    (advisories, bans, licenses and sources ok) and `cargo vet` (36 fully audited).
  - Result: the log ends `gate exit=0`; SHA-256
    `76c118d287fd861b14306de08f9b0b5ee8a5bbd6a0b7f1f0e549a273b640dfba`.
- #1893 to #1896 then merged as `178e2929`, `489c7b65`, `a0b25f8d` and `ac66aaa3`, each with the
  tree of the commit its PR carried, and this branch was rebased on `ac66aaa3`, dropping their
  copies. The slice's commit kept its tree through every rebase, so what is pushed is the gated
  content apart from this section; CI had passed on it as `346e16aa` (11 checks passed, 4 skipped).

## Not run, and why

- No cancellation of a running Job: the four Swift lanes are the next slice, and the Rust owner
  refuses such a Job until then.
- No recovery, reconciliation or resumption, and so no remembered request for a parked Job: they wait
  for the L.1 item 13 ruling.
- No Swift daemon was asked to cancel a waiting Job it holds no runtime for; the difference is
  recorded above.
- `check-job-run.py` needs the SwiftPM daemon and CLI products, so it runs by hand rather than inside
  `check-contracts.py` or CI.
- No device; DAYU200 is not attached to this host.
