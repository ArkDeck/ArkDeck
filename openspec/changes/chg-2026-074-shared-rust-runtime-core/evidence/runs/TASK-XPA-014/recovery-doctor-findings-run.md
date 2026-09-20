# TASK-XPA-014 — recovery port: `doctor` names what recovery could not read

Change: CHG-2026-074-shared-rust-runtime-core@r11. The gap slice 2b left in its record: the Rust
`doctor` emitted neither `runtime.jobRecordUnreadable` nor `runtime.durableRecordsUnreadable`, so
the quarantine start-up recovery performs was visible only on the daemon's standard error, and one
recorded report of Swift's `doctor` corpus was skipped by the Rust replay for that reason
("start-up recovery, which is not ported"). Recovery is ported now (#2071, #2086), so both
findings are.

Base: protected main `047bd59e`. Branch `agent/xpa-014-recovery-doctor-findings-20260920`, no
stack. Control-side findings and their corpus replay only: the CLI's own `doctor --deep` fixed
report is TASK-XPA-018's. No Swift, Catalog, spec, schema, control-frame or fixture change, and no
new published shape: both codes are already in the recorded corpus and the report's schema.

## Ported exactly

From `AgentDaemon.doctorReport(deep:)`, in Swift's order, right after `runtime.controlReady` and
before the Catalog's findings:
- **`runtime.jobRecordUnreadable`**, one per Job start-up recovery set aside, `blocker`, scope
  `runtime`, naming the Job and the reason recovery gave, with Swift's wording ("The Job is not
  live, its record was not modified, and it still counts as active"). Recovery already answered:
  nothing is read again. The isolated daemon keeps the list its start produced
  (`Host::quarantined`, set once by `recover_active_jobs`).
- **`runtime.durableRecordsUnreadable`**, only for a deep report and only when the count is above
  zero, `blocker`, scope `runtime`, counting every row of the index this build cannot decode and
  naming at most sixteen identities in the index's order, with Swift's wording. The scan is
  `JobStore::unreadable_records(limit)` (Swift `unreadableDurableRecords(sampleLimit:)`): it reads
  the index, decodes each row as the readers do, writes nothing and grants nothing. Recovery's own
  query excludes terminal states, so the per-Job findings name only active Jobs while this one
  counts the whole ledger.

`DoctorFacts` carries both as facts of the host, as it carries the Artifact quota and the Target
store, so the control layer composes the report and the daemon states what its store holds.

## Tests

- `arkdeck-control` `tests/doctor_report.rs`: the recorded report that names an undecodable
  durable record is no longer skipped — all eight reports of Swift's corpus are reproduced byte
  for byte. What those findings state is in no `checks` entry of Swift's report, so the recorded
  host states exactly what the recorded finding states, and the replay proves this Runtime's
  wording, severity, scope and order and what they make of the report's readiness and counts.
- the same file: a quarantined Job is a blocker at index 1, before every `catalog.` finding, in
  both modes, with Swift's summary, and it makes the report not ready.
- `arkdeck-hoststore` `tests/job_owner.rs`: undecodable rows are counted whole and sampled to the
  limit in the index's order; a store this build reads whole answers zero; the scan writes
  nothing.

## Local targeted checks

Per `AGENTS.md` the unified gate is the PR's CI. Locally, from `rust/`, with `CARGO_BUILD_JOBS=2`:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --locked -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd --all-targets -- -D warnings` | 0 | clean |
| `cargo test --locked -p arkdeck-hoststore` | 0 | 471 passed, 0 failed, 14 ignored (one new) |
| `cargo test --locked -p arkdeck-control` | 0 | 24 passed, 0 failed (one new; `doctor_report` now reproduces eight reports) |
| `cargo build --locked -p arkdeck-cli`, then `cargo test --locked -p arkdeck-agentd --bin arkdeck-agentd` and the three process tests | 0 | 42 and 3 passed, 0 failed |
| `python3 rust/scripts/check-contracts.py` (PyYAML and jsonschema) | 0 | published and candidate views pass |
| `sh scripts/check-sdd.sh` (repository root) | 0 | 0 errors, 0 warnings |

Log: scratchpad `logs/checks-doctor.log`, SHA-256
`015181c1c09972bf43fb96f16474419f858b4f1f16cf74f2d9a9a7a4d34a1df8`.

## CI

The PR's `guard` and `swift` aggregate (Rust lane): recorded in the next slice's record.

## Not in this slice

- The CLI's fixed `doctor --deep` report (TASK-XPA-018).
- `doctor`'s other recovery-adjacent checks: the cleanup debt count is already ported, and
  nothing else in Swift's report reads recovery.
