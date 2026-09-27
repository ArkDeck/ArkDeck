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

The bot PR and exact-head CI results will be recorded in the PR delivery
after push, without amending a green head.

## Remaining cutover gate

The distinct retained Session `2026/08/rockchip-session-42f8e86d-8cbf-4aa0-a411-5e1624e9f291`
has no Manifest and contains an unresolved historical Loader transition. It
remains untouched and independently blocks cutover. This compatibility fix
does not prove that Session's unknown effect, permit replay, or claim GJ/G5
acceptance. The Runtime must retain the POL-RECOVERY-001 proof boundary.
