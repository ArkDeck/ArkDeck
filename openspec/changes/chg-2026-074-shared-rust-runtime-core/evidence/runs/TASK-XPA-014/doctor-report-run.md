# TASK-XPA-014 — `doctor` computed from the Runtime's owners, as Swift's `doctorReport`

Change: CHG-2026-074-shared-rust-runtime-core@r11. Lane A (M1 methods). Host measurement only
(POL-VERIFY-001, POL-MODE-001). Base: protected main `e862d2bf`, which carries TASK-XPA-016's
managed HDC server (#2004, `b7d4edd8`): the HDC findings read that server's status. First
written stacked on #2004's head `84da14b6`; rehung after #2004 was squash-merged (its tree is
`84da14b6`'s; this change's patch-id is unchanged).

No Swift source, control schema, corpus, Catalog, entitlement, `openspec/specs` or constitution
change. No device, real HDC, installed state or Swift daemon is used.

## Why

#1994's first table row: `doctor --deep --require-healthy` on the isolated Rust daemon exits 69
because the Rust report was fixed — `provider.noneRegistered`, `hdc.notConfigured`,
`storage.artifactStoreNotConfigured`, `target.storeNotConfigured`, a Rust-only
`recovery.notConfigured` — whatever the daemon composed.

## What

`arkdeck-control`'s `doctor` is now Swift's `RuntimeControlPlaneHandler.doctorReport(deep:)`
(`AgentDaemon.swift` 1922–2207), finding by finding, order, severities, summaries, details,
`overall`/`ready`/`findingCounts` and `checks` included:

| Finding | From |
| --- | --- |
| `runtime.controlReady` | always |
| `catalog.noAvailableOperations` / `catalog.availableOperations`, `catalog.unavailableOperations` | the host's live operation availability (the same pass `operation.list` makes) |
| `provider.noneRegistered` / `provider.registered` | the providers the host answers any operation of (otherwise `provider_not_registered`), sorted — Swift `providerIDs` |
| `hdc.notConfigured` / `hdc.deepCheckSkipped` / `hdc.identityReady` / `hdc.identityUnavailable: <reasonCode>` | `HostServices::hdc_status`: the managed server's status observer when the isolated owner started one (deep mode reads its snapshot); the registered read-only provider otherwise |
| `storage.artifactStoreNotConfigured` / `storage.deepCheckSkipped` / `storage.quotaExhausted` / `storage.artifactStoreReady` / `storage.artifactStoreUnreadable` | `DoctorFacts::artifacts`: the Artifact usage owner's quota (`ArtifactUsage::quota`, Swift `totalBytesUsed()` and `quotaTotalBytes`), read in deep mode |
| `storage.sessionOutputOwnerUnavailable` | always (no Runtime owner for Session output is published) |
| `target.storeNotConfigured` / `target.noneAdopted` / `target.storeReady` / `target.storeUnreadable` | `DoctorFacts::targets`: the Target store's active Targets (`target.list`, Swift `listActive()`), in both modes |
| `target.discoveryNotConfigured` | `DoctorFacts::discovery`: Swift's `DeviceBootstrapMachine` — here the Target observation owner's sources (development HDC and Target store) or the registered read-only provider |
| `recovery.deepCheckSkipped` / `recovery.noCleanupDebt` / `recovery.cleanupDebtOutstanding` / `recovery.cleanupDebtUnreadable` | `DoctorFacts::cleanup_debt`: the Job cleanup ledger (`JobResultReader::outstanding_cleanup_debt`, Swift `engine.listCleanupDebt()`), read in deep mode; unreadable without the Job and Artifact owners, as Swift's engine without an Artifact store |

`HostServices::doctor_facts` defaults to a host with none of these owners, so a foundation host
still answers Swift's unconfigured report byte for byte (`read_only.rs`, unchanged).

**Not emitted** (start-up recovery is not ported, design §L.1 item 13): `runtime.jobRecordUnreadable`
(Swift's recovery quarantine) and `runtime.durableRecordsUnreadable` (the deep census of Job
records the build cannot decode). The Rust-only `recovery.notConfigured` is gone: a deep report
without the owners now says `recovery.cleanupDebtUnreadable`, as Swift's does.

**On the isolated daemon** with a managed server over a fixture HDC (the process test): a
standard report is `ready`, `overall: degraded` (only the Session-output warning and the
unavailable operations), so `arkdeck doctor --require-healthy` exits 0; a deep report is blocked
by exactly one finding, `hdc.identityUnavailable: hdc.identityFamilyUnavailable` — the fixture's
digest has no commandless identity family, as for Swift's observer — so `--deep
--require-healthy` exits 69. With a registered HDC under the 3.2.0f family at `127.0.0.1:8710`,
the observer can prove `arkDeckManaged` and the deep report can be ready; that needs the real
tool, which this record does not run.

## Tests

- `arkdeck-control tests/doctor_report.rs`: every result in `ControlFrames/doctor.jsonl` whose
  inputs a host can state (seven of eight: all but the one naming undecodable Job records) is
  reproduced byte for byte by a host that answers exactly the inputs the report's own `checks`
  state — available and registered counts, quota, Targets, discovery, cleanup debt, and its
  `observedAt`. A deep report with a live `arkDeckManaged` identity and readable owners is
  `ready`/`degraded` with `hdc.identityReady`; any other identity is the blocker naming its
  reason code, with the observer's four facts in `checks.hdc`; standard mode never observes it.
- `arkdeck-control tests/read_only.rs` (unchanged): the unconfigured report is Swift's line 1.
- `arkdeck-agentd tests/managed_hdc_process.rs`: the real daemon's standard and deep reports
  (published schema, `ready`, the one deep blocker, recovery and storage checks) and the real
  CLI's `doctor --require-healthy` (exit 0) and `doctor --deep --require-healthy` (exit 69).

Before the gate: `cargo clippy --workspace --all-targets --locked -D warnings` clean for macOS,
`x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`.

## Gate

Unified gate (`scripts/ci/plan.py --merge-base --include-worktree --run-local`, serialized with
every other gate on the host) on head `9745e351` (this commit before the record), stacked on
`84da14b6`, origin/main `05861555`: **exit 0** — cargo 953 passed, 0 failed, 16 ignored; the
read-only and isolated host checks PASS; no Swift lane. Log
`scratchpad/logs/doctor-report-gate-r1.log`, SHA-256 `8cb01f554223a032768d2b2c780b402d0ce77b78ebca8a4b378c862a3c29db68`.

Rehung on protected main `e862d2bf` (after #2004–#2007): **exit 0** at `c6339687` — cargo
964 passed, 0 failed, 16 ignored; the read-only and isolated host checks PASS; no Swift lane.
Log `scratchpad/logs/doctor-report-gate-r2.log`, SHA-256 `3e8c6db231f609d484856214a2f8194dec62300ebdc77534686c32fdde03678b`.

## Not run

Any device, registered HDC, installed Runtime or Swift daemon. `health` still lists no
providers (Swift feeds `health` and `doctor` from one `providerIDs`); aligning `health` is left
for its own change with its recorded frames.
