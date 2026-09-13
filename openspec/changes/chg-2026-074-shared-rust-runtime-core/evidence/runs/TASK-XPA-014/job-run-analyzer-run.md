# Rust `job.run` for the crash-signature analyzer — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: `24430fcb`, the `job.submit` slice (#1893, open), on
`1733d375`, the `job.plan` slice (#1892, open), on protected main `7dabc3c3`. This slice runs the
`analyzer.extract-crash-signature@1` Jobs the isolated Rust development composition admits, as Swift
does, and gives the Rust CLI `job run`. Nothing installed changes. Every request, source and analyzer
answer is synthetic host data; nothing here is device evidence.

## Already on main or in #1892/#1893 / this slice / still remaining

| Already on main or in #1892/#1893 | This slice | Still remaining for TASK-XPA-014 |
| --- | --- | --- |
| Rust reads the v1 Job index, records, events and Artifact routing and writes journals, the admission index and `job-record.json` (#1863, #1879, #1889, #1891); `job.plan` (#1892) and `job.submit` (#1893) for the analyzer | `job.run` for the analyzer: pre-dispatch refusals, the write-ahead intent before the child, an identity-bound analyzer child, Swift's semantic checks, the derived Artifact under Swift's redaction and quota, the terminal and parked lanes; `arkdeck job run`; a Swift-recorded run oracle; a real-process harness whose last phase hands the Rust-run store to Swift | Session publication; execution of every other operation (device facts, Runtime capabilities, the executor hand-off); capability mint/reserve/consume; §G.4 preflight; recovery, `job.reconcile` and resumption (after the L.1 item 13 ruling); cancellation of a running Job; GJ-1..5 |

## Behaviour

`JobRunner` (`arkdeck-hoststore/src/job_run.rs`) is Swift `RuntimeJobEngine.runForTargetControl` for
this operation, in an engine composed without a Session publication writer and without a power
controller:

1. exactly one `jobId` that Swift's `AgentExecutionIntent.validIdentifier` accepts; an absent Job
   (`resourceNotFound`), an unreadable record (`recordUnreadable`) or a terminal Job
   (`resourceConflict`, "job … is …, not runnable") is refused with the zero-dispatch proof and the
   Job identity, as Swift refuses a Job it no longer holds; a non-terminal Job outside Swift's
   runnable states (a parked one) and a Job materialized against another catalog digest are refused
   with the proof alone, as Swift's driver refuses them;
2. `preflight -> running` (`steps-start`), then the source lease resolved again; a lease that no
   longer resolves fails the Job before any intent exists, with Swift's message and Swift's spelling
   of the Artifact store's error;
3. the step's exact typed action (`analyzer.analyze` with the source identity) and recovery step are
   persisted in `job-record.json` at the index's next version, and only then is the write-ahead
   `stepIntent` appended and synchronized;
4. only after the intent: the pinned analyzer, reopened by its profile path and SHA-256 and spawned
   through its retained inode in a new process group, handed `--analyze-crash-ledger` and the
   source as the `/.vol` alias of a descriptor bound to the leased digest and length; each output
   stream keeps its first 8 MiB and drains the rest, and the profile's timeout terminates the group
   (TERM, then KILL after 0.25 s);
5. Swift's semantic checks in Swift's order (exit status, truncation, byte budget, empty output, a
   JSON object or array, then `HarnessCrashLedgerAnalysis` with its schema and analyzer identity), the
   correlated `stepOutcome`, and Swift's timeline entries;
6. a verified answer is published as `crash-signature.json`: Swift's provenance envelope (the result
   re-encoded with only its declared keys, the digest of the raw output), redacted by Swift's default
   policy, identified as Swift identifies it, refused by the 8 GiB quota rather than evicting
   anything, written and sealed `0400` before the index names it, and indexed in Swift's pretty
   spelling with the step's observation window from the precise clock; a refused publication leaves
   the product in the index as `missing` with Swift's reason and fails the Job
   (`artifactPublicationFailed`);
7. `running -> finalizing -> succeeded|failed` with Swift's reasons, `finishedAtUTC`, and the final
   record. A timeout, a signal death or an unobservable child writes no outcome: the intent stays
   outstanding, the Job moves to `waitingForRecovery` with `outcomeUnknown`, and it is never run
   again.

`job.run` answers the Job's `arkdeck.job-status/1`, as Swift answers once its driver returns; every
answer the oracle records equals Swift's following `job.status`. Refusals after the admission point
carry empty details, as Swift's do. `arkdeck-agentd` routes `job.run` in the isolated composition;
concurrent calls for one Job join its one run, as Swift's callers join its one driver. The façade
still forwards the method and the standalone foundation answers `rejected`.

`arkdeck job run --job <id> [--timeout <duration>]` prints the status and exits as Swift's CLI does:
1 for a failed, cancelled or interrupted Job and 75 for an unknown outcome, with Swift's diagnostic on
stderr. A connect failure stays `runtimeUnavailable`; any reply that cannot prove zero dispatch is
`outcomeUnknown`, as for the mutation-capable `job.submit`.

Swift's redaction runs through `NSRegularExpression`, so its matching was probed rather than assumed:
`\s` is ICU's White_Space set (vertical tab and NEL included, U+001C..U+001F, U+180E, U+200B and U+FEFF
excluded), `(?i)` folds `ſ` to `s`, the Kelvin sign to `k`, and `ß`/`ẞ` to the `ss` of
`password`/`passwd` (but not the Turkish dotted and dotless i or fullwidth letters), and the
six-character minimum counts code points. The redaction unit test pins those probes.

Deliberate differences from Swift:

- No Session is published: there is no `finalized` record, publication marker or proposal, and reads
  report the publication `unavailable` (`noCurrentPublicationRecord`), as Swift's own reads do for an
  engine without a writer.
- A Job in any resumable state (`running`, `resumeAtConfirmedSafeBoundary`,
  `recoveringByCompleteOverwrite`), or whose journal has left its admitted `preflight` boundary, is
  refused with the zero-dispatch proof. Swift resumes such a Job after its own restart recovery;
  recovery semantics are not ported before the L.1 item 13 ruling. Operations other than the
  analyzer are refused the same way.
- No idle-system-sleep assertion is taken for the analyzer's bounded run.
- The child gets the clean environment of every identity-bound spawn here (`PATH=/usr/bin:/bin`,
  `LANG=C`, `LC_ALL=C`), `/` as its directory and `/dev/null` as stdin, where Swift copies `PATH`,
  `HOME`, `TMPDIR` and `LANG` from the daemon and lets the child inherit its directory and stdin.
- Every publication recounts the published bytes of every Job index for the quota; Swift caches that
  count per process. Other Jobs' payloads are not rehashed for it.
- A tampered analyzer or source refusal carries this Runtime's error text after `dispatch refused:`.

Found on the way, not changed: Swift `FixedExecutableResolver.hashing` resolves a `/private/tmp` or
`/private/var` path to `/tmp` or `/var` (`URL.resolvingSymlinksInPath()`, probed), and the analyzer's
own physical-path identity check then fails, so a Swift daemon reports `analyzer.toolIdentityDrift`
for an analyzer kept under `/private`. The Rust profile keeps the physical path. The real-process
harness keeps its analyzer copy elsewhere.

## Shared oracle

`rust/tests/fixtures/job-run-analyzer/` was recorded by Swift `JobRunAnalyzerOracleContractTests` in
record mode (`ARKDECK_RUST_JOB_RUN_RECORD`) under the analyzer oracles' fixed physical root and lock,
with fixed clocks, a 32 KiB Artifact quota, a fixed redaction home and a 2 s analyzer timeout, through
the real `DescriptorBoundProcessDispatcher`; `provenance.json` lists the SHA-256 of each file.

| File | Content |
| --- | --- |
| `analyzer` | the oracle analyzer: the first line of its source names one of fourteen answers |
| `cases.json` | 20 runs in order over one store with each run's submit request: three published products (an answer with unknown keys, an unreadable listing, an answer that redaction rewrites), eight refused answers (non-zero exit, empty, not JSON, a JSON scalar, another analyzer version, an undecodable entry, truncated stdout, truncated stderr), a timeout, a signal death, a quota refusal, a removed source, and five refused runs (succeeded, failed and parked Jobs, an absent Job, no Job identity) |
| `reads.json` | Swift's `job.status` and `job.show` of each of the fifteen Jobs |
| `store/index.json` | the Job index a reader observes: layout, pragmas and every row |
| `store/jobs/<jobID>/` | each Job's `journal.jsonl`, `job-record.json` and `.manifest.lock` |
| `artifacts/` | the fifteen source crash logs, the three published `crash-signature.json` payloads, and every Artifact index, the quota refusal's `missing` row among them |

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Rust runner | `cargo test -p arkdeck-hoststore --test job_run` | 1 passed: the same sources and admissions, then all 20 answers, the 30 reads, the index rows, the 45 Job files and every Artifact index and payload reproduced byte for byte, payloads sealed `0400` |
| Analyzer child | `cargo test -p arkdeck-platform --test analyzer_process` | 5 passed: the source read through its inode alias, per-stream capture with drain, a timeout that removes the whole group, a signal death, refusals before any spawn |
| Units | `cargo test -p arkdeck-hoststore --lib` | the verifier's check order and envelope, the redaction probes, the precise clock's truncation |
| Rust CLI | `cargo test -p arkdeck-cli` | every CLI binary passed; `tests/job_run.rs` 3 (the current `job.run` argv fixture, every recorded status validated with its exit, mutation-capable mapping) |
| Swift oracles and schemas | `run-swiftpm.sh test --filter 'ControlMethodSchema\|JobRunAnalyzerOracleContractTests\|JobSubmitAnalyzerOracleContractTests\|JobPlanAnalyzerOracleContractTests'` | 7 executed, 1 skipped (frames of this run, without a frame log), 0 failures: the three analyzer oracles regenerate their committed fixtures and the corpus validates |
| Real processes | `python3 rust/scripts/check-job-run.py --swift-bin-dir <run-swiftpm debug products>` | PASS, 89 checks. The standalone Swift daemon and the Rust owner, in turn over one state root with the oracle analyzer, admit the oracle's Jobs with the oracle's identities and answer its 19 runs identically (the timeout lane aside), matching the oracle's answers wherever the composition matches (every run but the quota refusal, since both daemons compose 8 GiB); their `job.status`/`job.show` reads, index rows, Job files and Artifact indexes and payloads agree apart from the clock, once the Session publication only Swift composes is set aside (Swift publishes a Session for every terminal Job; the Rust owner publishes none and reads report it `unavailable`); each CLI's `job run` returns the same status and exits 0 and 1. A standalone Swift daemon given the Rust-run store reads all 14 Jobs in the states Rust left (9 `failed`, 4 `succeeded`, 1 `waitingForRecovery` still parked) and the Swift CLI reads the 4 Rust-published `crash-signature.json` payloads back at their recorded digests. Summary of r4, on `607bf009`'s binaries: `/private/tmp/xpa014-job-run-harness-r4.json`, SHA-256 `33af3bdc60396e7e120cfc75edd08202f7a6d255cac97675b290189c048d2a99` (r3 found the same on the earlier readers; r1 and r2 stopped on the harness itself: the analyzer copy under `/private` and the Import skeleton in its Artifact walk) |
| Contract | `generate-control-contract.py --derive-method-schemas` over the oracle's frames, then `generate-contract.py --write` and `--check` | `job.run` gains one corpus frame and `job.show` three; the re-derived `job.run`, `job.status` and `job.show` schemas needed no widening |

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`,
with `ARKDECK_PYTHON` on the SDD venv and the planner started from a venv holding `PyYAML` and
`jsonschema`. Against merge base `7dabc3c3` the planner classified 159 changed files (the three
commits of this branch) and selected the common, design-system, Swift and Rust lanes (no App build).

- r1 on `37df712d` ended `gate exit=1` (`/private/tmp/xpa014-job-run-gate-20260914-r1.log`, SHA-256
  `6efccc8a74ae4235cc2c77f7a804e2341cf8a723789868c5a8e6a215c8b16d81`). Every lane passed but
  `check-contracts.py`, where both views stopped in `check-readonly.py`: its unknown-command case used
  `arkdeck job run`, which the CLI now parses and refuses for its missing `--job` (`invalidOption`). The
  case now uses a verb no CLI publishes, and the check passed on its own before r2.
- r2 on `4cb87176`, `/private/tmp/xpa014-job-run-gate-20260914-r2.log`:
  - Common checks: planner and agent-PR workflow tests, SDD (0 errors, 0 warnings, 121 acceptance
    IDs), catalog generator tests and `--check`, design-system tests.
  - Swift full lane: `full-parallel` 2,653 tests exit 0 (the three analyzer oracle tests among them),
    `full-process-identity-race` 1 test exit 0, `full-viewer-scale` 5 tests exit 0.
  - Rust lane: `generate-contract.py --check`, `cargo fmt --all --check`, warnings-denied Clippy,
    workspace tests, `test_contract_checks.py` (33 tests OK), `check-contracts.py` passing both views
    with every candidate process harness and `test-macos-facade.py` (7 tests OK), `cargo deny` and
    `cargo vet` (36 fully audited).
  - Result: the log ends `gate exit=0`; SHA-256
    `1b7d1bb99b992cbae57afcb8e67e79fe785f9ed299924ee038aee651b7ed2a34`.
- CI on `618d0eca` failed only in the macOS Rust lane: the oracle replay answered `truncatedStderr` as
  parked (`waitingForRecovery`) where Swift answers `failed` (`analyzer.truncatedResult`). The analyzer
  child's output readers slept 5 ms after every empty read, so a 9 MiB stream moved at most one 64 KiB
  pipe buffer per sleep; on the CI runner that pace outlasted the oracle's 2 s timeout. The readers
  now wait for the pipe to become readable (`poll(2)`, bounded so a stop stays observable) and drain it,
  as Swift's readers are woken; the replay then passed three times with eight `yes` processes loading
  every core.
- r3 on `607bf009`, `/private/tmp/xpa014-job-run-gate-20260914-r3.log`: the same lanes and counts as r2
  (`full-parallel` 2,653 tests, the Rust lane with both contract views, 33 contract-check tests, 7
  façade tests, `cargo deny`, and `cargo vet` with 36 fully audited); the log ends `gate exit=0`;
  SHA-256 `3173d8e5f7cd893319d8a553b610cbde7a8b41dc1536c6d3a740451d08d57378`.

## Not run, and why

- No other operation, capability-bearing or device-bound run, executor hand-off, cancellation of a
  running Job, recovery or reconciliation: TASK-XPA-014's next slices; ADR-0009 decisions 2/4 (L.1 item
  13) are not ported.
- No Session publication: its storage admission, Session store and catalog registration are their own
  slice.
- The 30 s production timeout lane runs in the oracle replay at 2 s; the real-process harness skips it.
- `check-job-run.py` needs the SwiftPM daemon and CLI products, so it runs by hand rather than inside
  `check-contracts.py` or CI.
- No device; DAYU200 is not attached to this host.
