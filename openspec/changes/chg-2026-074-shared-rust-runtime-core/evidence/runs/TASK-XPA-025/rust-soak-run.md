# Rust owner lifecycle soak — 2026-09-19

Scope: first `arkdeck-soak` slice of TASK-XPA-025 / SPK-11, macOS only.
This is simulated-provider workload evidence, never real-device acceptance.

## Workload and production path

The fixture composes production Rust Target observation/adoption, Job admission,
SQLite owner, runner, cancellation, durable journals, Artifact publication and
Session publication. A closed in-memory HDC dispatcher supplies observation
receipts; it creates no child process and has no live device transport.

Each ten-job cycle has eight immediate successes, one never-started cancellation,
and one clean preflight Job deliberately retained. All owners are dropped between
cycles, then the next fresh owner runs retained preflight Jobs through the same
production runner. Final draining completes the final retained Job. This is the
Swift soak fixture's existing restart workload, not running-intent reconciliation;
unknown outcomes and torn journals are refused, never replayed or repaired.

The fixture preserves the Swift CLI flags and `arkdeck-runtime-soak/v1` metric field
names. It persists metrics atomically after each cycle; derives counts from actual
jobs/files/journals; verifies terminal states and Artifact payload digests; reads the
complete cleanup ledger, including unindexed rows; and applies the existing
32 MiB max-RSS-growth and 16-FD-growth limits from the first completed cycle.
Resource samples come from this process, not placeholders or child probes.

## Validation

- `cargo check --offline -p arkdeck-soak`: passed (8.46 s).
- `cargo test --offline --locked -p arkdeck-soak -- --test-threads=1`:
  passed, 4 tests (2 unit, 2 integration), zero failures. The workload test
  executes the ten-job mix and verifies all nine successful Jobs, including
  the final fresh-owner preflight continuation (4.76 s integration test time).
  These are development test durations, not reference-host performance samples.
- `cargo clippy --offline --locked -p arkdeck-soak --all-targets -- -D warnings`:
  passed, including dependency checks.
- `cargo test --offline --locked -p arkdeck-platform --lib self_resources::
  -- --test-threads=1` and the same command with `continuous_clock::`: passed,
  one test each, no physical system suspend.
- `cargo test --offline --locked -p arkdeck-hoststore --test job_run
  --test job_cancel --test job_publication -- --test-threads=1`: passed,
  three existing production-owner differential regression tests.
- Explicit crate dependency boundary: passed; existing crate edges unchanged.
- `cargo fmt --all` and `git diff --check`: passed at implementation checkpoint.
- Final unified repository verification: PASS, exit 0 (2026-09-19).
  Common checks, Rust workspace tests, Clippy, published/candidate contract
  checks, cargo-deny and cargo-vet all passed (36 fully audited packages).
  Swift and App lanes were not selected for this Rust-only slice.
  Log: `/private/tmp/arkdeck-soak-gate-r3.log`.

  ```sh
  ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python \
    /private/tmp/arkdeck-validation-venv/bin/python scripts/ci/plan.py \
    --repo-root . --base-revision origin/main --head-revision HEAD \
    --merge-base --include-worktree --run-local
  ```

  This is not a complete SPK-11 pass.

Bounded tests cover the real workload, owner
reopen and final drain, exact terminal counts, persisted metrics, torn journal
refusal without repair, corrupted Artifact refusal, orphan cleanup debt, and
rejection of nonempty state not owned by this fixture. Public verification also
requires the private marker and exclusive root lock before opening existing stores.
Complete valid journals with either outstanding intent or unknown outcome refuse
startup with zero observed simulated-dispatch attempts, unchanged journal bytes,
and no new owner state or metrics. Failed resource gates cannot publish a
`completed` snapshot; each normal cycle persists its `running` snapshot first.

## Clock semantics

Overall duration and `elapsedSeconds` use an injectable elapsed clock backed by
Darwin `CLOCK_MONOTONIC`, which advances across sleep (REQ-NFR-001 and
`scripts/bench/clocks.py`). Rust `std::Instant` is deliberately not used for this
budget. Audit timestamps still use UTC. The inter-cycle wait rechecks the explicit
continuous clock in at most one-second sleep slices, so it does not assume
`std::thread::sleep` shares those suspend semantics. An injected suspend jump tests
budget expiry; this is not a physical host sleep measurement. The Swift fixture
used wall-clock Date for its overall budget; the Rust implementation preserves
sleep-inclusive elapsed semantics while avoiding wall-clock adjustment errors.

## Release smoke run

A release binary ran with `--duration-seconds 60 --restart-interval-seconds 5
--jobs-per-cycle 10` in `/private/tmp/arkdeck-soak-release-smoke-20260919`.
It exited successfully after eight cycles and final drain (64 elapsed seconds):
80 terminal Jobs, 72 succeeded with verified Artifact evidence, eight cancelled,
zero active Jobs and zero cleanup debt. Max-RSS growth was 3,194,880 bytes and
FD growth zero; simulated-provider child process count was zero. The exact
metrics are in `release-smoke-metrics.json`. This short candidate host run is
not a qualified baseline or a 24-hour soak.

Integration initially found two omissions: the new journal helper was after a
test module (Clippy), and the new first-party crate lacked its explicit
`deny.toml` entry. Both were corrected. The second unified run passed workspace
and contract checks but failed the final deny check before that correction;
the final complete rerun passed as recorded above.

## Explicit remaining gaps

- This slice calls production owners directly; it does not exercise the socket
  client/server leg used by the Swift fixture.
- No benchmark launcher, baseline, workflow or installed service is switched here.
- No 24-hour soak or three-run reference-host performance baseline is claimed.
- Standalone daemon live-RSS plateau/steady sampling remains distinct from this
  fixture's `getrusage` lifetime maximum RSS and growth gates.
- All fixture identities and receipts stay in its marked private state root.
  They are not trusted hardware evidence and must never be used for device dispatch.
