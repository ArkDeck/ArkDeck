# Rust `job.result` and `job.evidence` for the crash-signature analyzer — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: `d15aca87`, the `job.run` slice (#1894, open), on `24430fcb`
(#1893, open), on `1733d375` (#1892, open), on protected main `7dabc3c3`. This slice reads the results
and evidence of the `analyzer.extract-crash-signature@1` Jobs the isolated Rust development
composition runs, as Swift does, and gives the Rust CLI `job result`. Nothing installed changes.
Every request, source and analyzer answer is synthetic host data; nothing here is device evidence.

## Already on main or in #1892–#1894 / this slice / still remaining

| Already on main or in #1892–#1894 | This slice | Still remaining for TASK-XPA-014 |
| --- | --- | --- |
| Rust reads the v1 Job index, records, events and Artifact routing and writes journals, the admission index and `job-record.json` (#1863, #1879, #1889, #1891); `job.plan` (#1892), `job.submit` (#1893) and `job.run` (#1894) for the analyzer | `job.result` and `job.evidence` for the analyzer: Swift's refusals, the evidence facts and status precedence, the inventory, the cleanup-ledger rows and next action, the bounded and race-checked read; `arkdeck job result`; Swift's spelling of an absent or unreadable Job for every Rust Job read; the run oracle's reads extended to both methods, an absent Job and open read options; the real-process harness comparing both reads, both CLIs and a Swift read of the Rust-run store | Session publication; execution of every other operation (device facts, Runtime capabilities, the executor hand-off); capability mint/reserve/consume; §G.4 preflight; recovery epochs, recovery, `job.reconcile` and resumption (after the L.1 item 13 ruling); cancellation of a running Job; GJ-1..5 |

## Behaviour

`JobResultReader` (`arkdeck-hoststore/src/job_result.rs`) is Swift `RuntimeJobResourceReader` for
`job.result` and `job.evidence`:

1. exactly one `jobId` that Swift's `AgentExecutionIntent.validIdentifier` accepts, else
   `invalidInput` ("an exact Job identity and closed read options are required") with the
   zero-dispatch proof;
2. the Job read from its durable index as Swift's `jobReadSnapshot` reads it: an absent Job is
   `notFound` ("the referenced Job does not exist") without details, an unreadable record
   `recordUnreadable` ("the referenced Job record is unreadable: <id>");
3. `job.result` of a Job that is not terminal is `resultNotReady` ("the Job has no terminal result
   yet") with the Job identity, its state, the status's next action and the proof; neither the
   evidence nor the ledger is read;
4. the evidence facts, derived once for both reads: the catalog descriptor only while the Job's
   catalog digest is the current one (else `operationUnavailable`); the Job's Artifact index rows in
   file order, each owned by the Job, its provider, its operation and its target (else
   `artifactIntegrityFailed`, the rows still reported); every published payload rehashed, all or
   nothing, where a missing or truncated row or no verified product fails the inventory; each
   required product the index lacks in `missingRequiredArtifacts` (a `missing` row counts as present);
   `resultNotReady` for a Job that is not terminal;
5. the evidence object with Swift's 26 keys: the record's identities, the authority of the default
   read-only admission (its time and reference, no consumption fingerprint), the actual effect, the
   request's inputs as `parameters`, the recorded step kinds (`[]` when this operation recorded none),
   the Job's times, null observation, recovery epoch and Trace probes, the verified products, the
   sorted blockers, and the status by Swift's precedence (`resultNotReady`, `recordUnreadable`,
   `artifactIntegrityFailed`, `operationUnavailable`, then `verified`; `stepKindsUnprovable` cannot
   arise for this operation);
6. `job.result` is `arkdeck.job-result/1`: the Job's status with `outstandingResidueCount` set to its
   outstanding ledger rows, `terminal`, `outcomeUnknown`, the evidence, the inventory (every index
   row as Swift's ten keys, sorted by name then Artifact identity, the byte count as a decimal
   string, an empty digest for a `missing` row), the Job's outstanding rows of
   `<artifacts>/cleanup-debt.json` with Swift's `cleanup-` identities, and the next action: the
   status's reconcile action for an unknown outcome, else the first cleanup row's cleanup action,
   else null;
7. the Job read again and compared, `resourceConflict` if it changed under the read; a result whose
   canonical bytes exceed 4 MiB is `inputTooLarge`.

`arkdeck-agentd` routes both methods in the isolated composition. The façade still forwards them
and the standalone foundation answers `rejected`.

`arkdeck job result --job <id> [--timeout <duration>]` checks the result as Swift's
`CLIJobReadValidation` does — the closed keys, the terminal status, the evidence, each inventory row
(owner, reference, digest, decimal byte count, privacy and status vocabularies, unique identities),
each cleanup row and the next action they imply — and exits as Swift's CLI does: 75 for an unknown
outcome, then the evidence's exit (2 unless `verified`, 75 for `resultNotReady`), then 1 for a
failed, cancelled or interrupted Job, with Swift's diagnostic on stderr. A failed analyzer Job never
publishes its required product, so its result exits 2. A refusal maps as Swift maps a bounded read:
`resultNotReady` keeps its code, exits 75 and may be retried; `notFound` is `resourceNotFound`;
`invalidInput`, `inputTooLarge` and `resourceConflict` keep their codes only with the zero-dispatch
proof. `inputTooLarge` with the proof used to become `internalError` for `job.evidence` as well; both
reads now keep it, as Swift's mapper does.

Found on the way and fixed here: every Rust Job read (`job.status`, `job.show`, `job.timeline`,
`job.events`) answered an absent Job with "The referenced Job does not exist" and an unreadable
record with "The Runtime Job snapshot is unreadable or unsupported". Swift answers "the referenced
Job does not exist" without details, and "the referenced Job record is unreadable: <id>". Nothing
pinned either spelling. The oracle now records the six Job reads of an absent Job, and
`tests/job_run.rs` pins them. The unreadable-record spelling follows Swift's source, since the oracle
records no unreadable Job.

Deliberate differences from Swift:

- Rust reads write nothing. Swift's reader creates a Job's empty Artifact directory
  (`RuntimeArtifactStore.directory(for:)`), reseals payload modes and refreshes its verification
  cache while it reads. The Rust reader therefore treats an absent Artifact directory as the empty
  index Swift would create (`inventoryAvailable: true`), and any other index failure as an integrity
  failure.
- A Job of another operation, or one carrying device observations or Trace probes, is refused
  (`rejected`, with the zero-dispatch proof) until the owners of those facts join.
- Swift reads recovery epochs for every snapshot, and this Runtime does not read them yet: a store
  holding `superseding-recovery-epochs.json` degrades the evidence (no products, null facts,
  `recordUnreadable`) instead of guessing. ADR-0009 decisions 2/4 stay unported (L.1 item 13).
- As in the run slice, no Session is published, and reads report the publication `unavailable`.

## Shared oracle

`rust/tests/fixtures/job-run-analyzer/` was recorded again by Swift
`JobRunAnalyzerOracleContractTests` in record mode (`ARKDECK_RUST_JOB_RUN_RECORD`, recorded at
`/private/tmp/xpa014-job-result-oracle-r1`), with the same root, clocks, quota, redaction home and 2 s
timeout as before. The runs, the store and the Artifacts are unchanged. The reads grew:

| File | Content |
| --- | --- |
| `reads.json` | Swift's `job.status`, `job.show`, `job.result` and `job.evidence` of each of the fifteen Jobs, and the `job.status`, `job.show`, `job.result`, `job.evidence`, `job.timeline` and `job.events` of an absent Job: 66 reads |
| `refused-reads.json` | `job.result` and `job.evidence` with open read options (`{}`) |
| `provenance.json` | the SHA-256 of each file, the new one included |

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Rust readers | `cargo test -p arkdeck-hoststore --test job_run` | 1 passed: the 20 runs, the index rows, every Job file and every Artifact index and payload as before, then all 68 recorded reads answered through the Rust readers byte for byte, errors included (details only where Swift sends them) |
| Rust CLI | `cargo test -p arkdeck-cli` | every CLI binary passed; `tests/job_result.rs` 5 (the current `job.result` argv fixture; every recorded result validated and projected verbatim with its exit — 0 for the three verified Jobs, 2 for the ten failed ones, 75 for the two parked Jobs, 65 for the absent one; the refusals of a result that disagrees with itself; a cleanup row and its next action; the exit order; the error mapping) and the evidence read now consuming 19 recorded successes |
| Contract | `cargo test -p arkdeck-contract -p arkdeck-control` | passed with the re-derived `job.evidence` schema and the grown corpus |
| Swift schemas | `run-swiftpm.sh test --filter ControlMethodSchema` | 4 executed, 1 skipped (frames of this run, without a frame log), 0 failures: the grown corpus validates against the committed schemas |
| Real processes | `python3 rust/scripts/check-job-run.py --swift-bin-dir <run-swiftpm debug products>` | PASS, 103 checks. On top of the run slice's checks: the standalone Swift daemon and the Rust owner answer `job.result` and `job.evidence` of all 14 Jobs identically apart from the clock and the Session publication (the parked Job's `resultNotReady` included); each CLI's `job result` returns the same result and exits 0 for the answered Job and 2 for the empty one; and a standalone Swift daemon given the Rust-run store answers the same `job.result` as the Rust owner for every one of the 14 Jobs, verifying the Rust-published products as it reads. Summary of r1: `/private/tmp/xpa014-job-result-harness-r1.json`, SHA-256 `d8563be2360f5d30eb678ff3358e20b36c69e9808634d467e9067be863764718` |
| Contract derivation | `generate-control-contract.py --derive-method-schemas` over the committed corpus of the eight Job read and lifecycle methods and the oracle's frames, then `generate-contract.py --write` and `--check` | `job.evidence` widened: `artifacts[].bindingRevision` may be null (a host-only product has no binding) and `parameters` gains `sourceArtifactRef`, the analyzer's input; the corpus gains four analyzer successes of `job.result` and of `job.evidence` and the absent Job's `notFound` of `job.result`, `job.evidence` and `job.events`. The oracle's frames were first pruned to the shapes the corpus lacked, so no committed line was replaced; `job.result` and the six other methods kept their committed schemas, since a re-derivation from the committed corpus alone would have narrowed `job.submit`'s error codes and collapsed repeated `job.timeline` shapes |

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`,
with `ARKDECK_PYTHON` on the SDD venv and the planner started from a venv holding `PyYAML` and
`jsonschema`. Against merge base `7dabc3c3` the planner classified 168 changed files (the four commits
of this branch) and selected the common, design-system, Swift and Rust lanes (no App build).

- r1 on `9043392b` ended `gate exit=1` (`/private/tmp/xpa014-job-result-gate-20260914-r1.log`,
  SHA-256 `6366b5b9f37a87f004947b0655f160067eb17d63c3d1764cf0242de25f33b39c`). The common checks, the
  design-system tests and the Swift lanes passed (`full-parallel` 2,653 tests exit 0,
  `full-process-identity-race` 1, `full-viewer-scale` 5); `check-contracts.py` failed in its published
  view, which builds this branch's Rust against main's corpus: there `job.evidence` has 15 recorded
  successes, and the CLI evidence test pinned the candidate corpus's 19. The same trap met the
  `job.submit` slice. The test now requires at least main's 15, and a candidate may only add results.
- r2 on `724e39ca`, `/private/tmp/xpa014-job-result-gate-20260914-r2.log`:
  - Common checks: planner and agent-PR workflow tests, SDD (0 errors, 0 warnings, 121 acceptance
    IDs), catalog generator tests and `--check`, design-system tests.
  - Swift full lane: `full-parallel` 2,653 tests exit 0 (the analyzer oracle tests among them),
    `full-process-identity-race` 1 test exit 0, `full-viewer-scale` 5 tests exit 0.
  - Rust lane: `generate-contract.py --check`, `cargo fmt --all --check`, warnings-denied Clippy,
    workspace tests, `test_contract_checks.py` (33 tests OK), `check-contracts.py` passing both views
    with every candidate process harness and `test-macos-facade.py` (7 tests OK), `cargo deny`
    (advisories, bans, licenses and sources ok) and `cargo vet` (36 fully audited).
  - Result: the log ends `gate exit=0`; SHA-256
    `9392e160fd92a0033e300808c61bfbc8e75486a1185d7bd003c695a054ec3859`.

## Not run, and why

- No other operation, capability-bearing or device-bound result, recovery epoch, recovery or
  reconciliation: TASK-XPA-014's next slices; ADR-0009 decisions 2/4 (L.1 item 13) are not ported.
- No cleanup-ledger row exists in the oracle, because the analyzer leaves none; the ledger reader
  and the cleanup next action are covered by the CLI's synthetic row and by Swift's spelling, not by
  a recording.
- `check-job-run.py` needs the SwiftPM daemon and CLI products, so it runs by hand rather than inside
  `check-contracts.py` or CI.
- No device; DAYU200 is not attached to this host.
