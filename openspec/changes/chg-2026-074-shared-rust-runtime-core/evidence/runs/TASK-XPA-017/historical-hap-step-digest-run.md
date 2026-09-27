# Read terminal HAP records from the earlier step-digest producer

The read-only cutover preflight on signed protected main `443e805e` refused
`job-c4a51d35f513cf0152c5b9cacec01bcb` as `unreadableRecord`. The installed Swift
Runtime read it as a terminal failed `debug.hap@1`, `outcomeUnknown: false`.
Its provenance is already documented in the TASK-SVC-002 confirmed-failure
compensation run and the September 9 published-main acceptance record. This
change does not rewrite or resubmit that Job.

## Cause and compatibility boundary

Swift commit `2fbcaa7c8` (#1773, September 8) added compensation rows to
`RuntimeJobEngine.stepSetDigest` without changing the Catalog digest. The Job
completed on September 7. Its saved digest exactly matches the earlier
producer's selected normal-step rows, rather than the later normal-plus-
compensation rows. Its request, reservation, plan and target-binding correlations
still match. Dates and Job IDs explain the investigation; they are not gates or
special cases in the implementation.

Swift's durable reader checks the digest's structure and the other admission
correlations without recomputing the step set. The Rust HAP reader additionally
recomputed the current step set for the current Catalog (the M2 HAP foundation
run describes that earlier stricter check). Preserve that check and add only an
exact earlier-producer fallback for terminal records with `outcomeUnknown: false`.
An arbitrary 64-hex digest, malformed digest, missing correlation, active state,
or unknown outcome does not qualify. Catalog step selection is still exact.

The current planner and admission still compute the complete compensation
step set. Reading preserves every durable field. It neither grants a use nor
adds old compensation authority. The normal terminal `job.run` refusal remains
before the driver; the integration test uses a dispatcher that panics on any
call and checks unchanged record, journal and capability-store bytes.

The tests use the existing Swift-produced fake-HDC HAP fixture, not local
production authority records. Swift independently reconstructs the published
old producer's fourteen selected rows, verifies its digest, and decodes and
round-trips the historical form unchanged. Rust verifies the same historical
form and negative cases for every active state, unknown terminal state, wrong
digests and missing correlations. These are fixture checks, not hardware evidence.

## Local targeted checks

On macOS with `CARGO_BUILD_JOBS=2`, worktree-local
`CARGO_TARGET_DIR=/private/tmp/arkdeck-takeover-d79c-target`, and one build/test
lane at a time:

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak`
  with `RUST_TEST_THREADS=1`: exit 0, 916 passed and 18 existing ignored cases;
  `/private/tmp/arkdeck-historical-hap-tests-serial.log`. Ignored cases require
  explicit native inventories, a quiet performance host, or invocation as
  subprocess crash fixtures; no hardware result is claimed for them.
- After making the old-digest fallback lazy on a current-digest mismatch,
  final-source `cargo test ... -p arkdeck-hoststore --lib hap_provenance_tests`
  and `cargo test ... -p arkdeck-hoststore --test debug_hap_run historical_terminal_digest_never_authorizes_run_or_compensation -- --exact`
  both exited 0 (2 and 1 tests); logs
  `/private/tmp/arkdeck-historical-hap-final-unit.log` and
  `/private/tmp/arkdeck-historical-hap-final-dispatch.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`:
  exit 0; `/private/tmp/arkdeck-historical-hap-clippy.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0;
  `/private/tmp/arkdeck-historical-hap-fmt.log`.

The first three-crate attempt with two test threads stopped in the unchanged
`crash_ledger_analyzer::an_agent_execution_of_the_analyzer_runs_its_job_to_the_end`
(expected succeeded, observed failed). The unchanged case passed alone, and
its full suite passed in the subsequent serial run. Preserve the initial
`/private/tmp/arkdeck-historical-hap-tests.log` and the exact-case rerun
`/private/tmp/arkdeck-historical-hap-analyzer-repro.log`; the initial cause was
not established, so this is not labelled a diagnosed flaky test. Assertions
and timeout behavior were not changed.

- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter HistoricalHAPRecordContractTests`:
  exit 0, one test; `/private/tmp/arkdeck-historical-hap-swift.log`.
- `sh scripts/check-sdd.sh`: exit 0; `/private/tmp/arkdeck-historical-hap-sdd.log`.

No contract input changed, so contract generation and a full local unified
gate were not run.

## CI

PR #2276, head `771c4a75`, Swift CI run `36293349702`: Rust macOS,
Linux, Windows, host-independent checks and design-system checks passed;
SDD Guard run `36293349607` passed. The Swift test lane failed in
`FlashRunOracleContractTests.testSwiftSubmitsAndRunsEveryFlashStoryAsTheRustRuntimeReplays`.
The aggregate `swift` therefore failed. App build was not selected.
Raw job log: `/private/tmp/arkdeck-pr2276-swift-ci.log`.

The failure is exactly reproducible without running a device or changing any
production record. In the checked-in `flash-run/stories/recovery` fixture,
`job-0c7b2c3dec74aedc2746781f98fdc406/job-record.json`, replace only
`consume wait <ms> ms` by `consume wait 0 ms`: SHA-256 is
`23e107cecd0ec573c6e832be2c75829ae5be848d28568e2f44c89209dd22ace7`
(the recorded index digest). Replacing it by `consume wait 1 ms` yields
`fa7243b45d2952f4a98f80e4ef92e7918b9d7fcc8dba9b066db088851570c436`
(the CI-produced digest). File and response comparisons already labelled this
host timing, but the index hashed the unlabelled SQLite BLOB.

The follow-up applies that same existing Flash normalization before the index
record hash in both Swift and Rust. Other HDC oracle callers keep their default
machine-fact-only normalization. It removes Rust's search through 0–10,000 ms
to find an old digest. The seven Flash index fixtures now hash their already
recorded, labelled Job bytes; every prior affected digest was independently
verified against those same bytes with a zero-millisecond wait. No fixture
record, outcome, field, permission or non-digest index value changed.
Database-path regression cases cover waits of 0, 1 and 10,001 ms, require an
outcome change to remain observable, and check that the default index path
still distinguishes raw waits. This fixes test determinism, not Runtime
admission or the historical reader. Follow-up local and exact-head CI results
are recorded below and in the PR delivery.

## Follow-up local targeted checks

For the CI-discovered oracle fix, with the same isolated cargo target and
`CARGO_BUILD_JOBS=2`, one build/test lane at a time:

- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter FlashRunOracleContractTests`:
  exit 0, 2 tests; `/private/tmp/arkdeck-pr2276-oracle-swift.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --test flash_run`:
  exit 0, 13 tests; `/private/tmp/arkdeck-pr2276-oracle-rust.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore --all-targets -- -D warnings`:
  exit 0; `/private/tmp/arkdeck-pr2276-oracle-clippy.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0 after
  applying the formatter's line wrapping; `/private/tmp/arkdeck-pr2276-oracle-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0; `/private/tmp/arkdeck-pr2276-oracle-sdd.log`.

Only test/oracle code and this run record changed in the follow-up. The earlier
three-crate checks and historical-record Swift test were not repeated; neither
contract generation nor the full local unified gate was run.

## Remaining cutover gate

The distinct retained Session `2026/08/rockchip-session-42f8e86d-8cbf-4aa0-a411-5e1624e9f291`
has no Manifest and contains an unresolved historical Loader transition. It
remains untouched and independently blocks cutover. This compatibility fix
does not prove that Session's unknown effect, permit replay, or claim GJ/G5
acceptance. The Runtime must retain the POL-RECOVERY-001 proof boundary.
