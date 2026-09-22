# TASK-XPA-025 — release full Job records during inventory projection

Base: protected main `73eeacc99ccabff609f1aded791c7fe6382668bf`.
Branch: `agent/xpa-025-soak-bounded-job-scan`. CHG-2026-074, macOS Runtime.

`JobStore` built each history page by first retaining every complete SQLite Job row,
including its record JSON, then decoding each record into a much smaller history row.
The active-Job census likewise loaded all terminal record payloads before discarding
them. These scans run as the soak's accumulated Job history grows.

The SQLite owner now projects one source row at a time. Job history retains only its
history projection; the active census retains only active records. Existing callers
that need full rows still receive them. The query, layout and row checks remain in
one SQLite transaction; ordering, frozen pagination and typed record failures remain
unchanged. The original cumulative query-byte limit still counts every source column,
even if the projection drops it. A failed projection drops all results and finalizes
the statement before the repository ends its transaction.

This reduces an identified history-dependent allocation. It is not, by itself, proof
that the soak RSS failure is fixed. No soak workload, Session publication, per-cycle
journal verification, interval default, resource threshold or acceptance meaning changes.

## Local targeted checks

Cargo uses `CARGO_BUILD_JOBS=2`,
`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`, and
`--manifest-path rust/Cargo.toml`.

- `cargo build -p arkdeck-cli`: exit 0; process-test prerequisite,
  `/private/tmp/arkdeck-soak-scan-cli-build.log`.
- `cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-provider-hdc
  -p arkdeck-provider-workspace -p arkdeck-client -p arkdeck-cli -p arkdeck-agentd
  -p arkdeck-soak`: exit 0; 1,117 passed, 18 existing environment-dependent tests
  ignored; `/private/tmp/arkdeck-soak-scan-tests.log`.
- `cargo clippy` for those same changed/direct-dependent crates with
  `--all-targets -- -D warnings`: exit 0; `/private/tmp/arkdeck-soak-scan-clippy.log`.
- `cargo fmt --all --check`: exit 0; `/private/tmp/arkdeck-soak-scan-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0; `/private/tmp/arkdeck-soak-scan-sdd.log`.

No contract input changed, so contract generation was not run. No Swift/App or
local unified gate ran. The normal soak tests are not long-duration acceptance.

Tests cover projected columns still counting against the original aggregate byte
budget, statement finalization after both query-budget and projection failures, and
malformed Job records refusing the whole list even when excluded by a state filter.
Existing frozen-page, Job-store and recovery tests also run.

## Diagnostic measurement

The unmodified release binary SHA-256 is
`88b683bf263d655dfaac648347854c2811026f2acf7e4926e4fef0ea5c740d33`.
An initial diagnostic retained ten Jobs per cycle and all workload/integrity/resource
checks, with a one-second pause solely to observe growth sooner. It started with no
build/test process and a one-minute load of 3.59. During the run the load rose to
18.53; the diagnostic was stopped with SIGTERM at 18 cycles. Its partial data is not a
valid performance comparison or acceptance result. Log:
`/private/tmp/arkdeck-soak-baseline-run.log`; isolated state:
`/private/tmp/arkdeck-soak-1330-baseline-20260922`.

A quiet-host comparison and the applicable long soak remain required. The historical
32 MiB failure is not closed by the unit tests or by a partial diagnostic.

## CI

Pending PR CI. Skipped performance/soak jobs do not constitute a pass.
