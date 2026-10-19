# Verification — CHG-2026-084

> Change:CHG-2026-084-arkforge-maintenance-contract@r2

Revision 2's scoped policy was published in PR #2675 as
`f67e9919f87c9cb25d285c6317cbeb0e1b1cdf5b`. The maintenance result/publication
repair was published in PR #2676 as `80d7f9ecd3e70888e3be62173856f6c595096c42`.

The implementation checks below are host/fake tests. The separate
[independent acceptance run](independent-acceptance-20261019.md) records actual
current-Catalog device results and their limits.
The historical implementation lists retain the original revision-1 checks and
their local-environment limitations. The final sections link revision-2 policy
checks and the separate device run.

## Local targeted checks

- ArkForge provider tests and version assertions: exit 0.
- Shared agentd device_access_control tests: exit 0; public Hello is exactly 1/0,
  refusal yields unsupportedProtocolVersion with the daemon reason, and the
  server observes EOF without any following request.
- Clippy for provider-arkforge and agentd, all targets: exit 0.
- Swift ArkForgeHandshakeTests: exit 0, two tests; Flash retains the typed
  protocol error and reason, while other private transport diagnostics stay hidden.
- Pinned upstream consumer_contract, swift_sdk_vectors and permit_vectors:
  exit 0; local log `/private/tmp/arkdeck-consumer-contract.log`.
- SDD Guard before this change record: exit 0; rerun with final documentation.
- Windows App.Tests/ArkForgeHandshakeTests.cs added. No local dotnet executable;
  execution is delegated to the Windows CI channel.

## CI

Final-head SDD Guard, Swift aggregate and selected platform checks passed for
PRs #2675 and #2676. Exact heads and run IDs are recorded in the acceptance run's
CI section. Results from another head do not substitute for these checks.

## Historical maintenance implementation checks (follow-up to merged #2657)

The companion ArkForge adapter tests cover 0/9/7, identity drift, failed intent
persistence, stopped recording, invalid parameters with zero port calls, exact
ramdisk scope, one consumption, unknown execution and no blind retry. The current
consumer pins merged ArkForge main `0445530207ac5e6689e61e7b51c0edd4de7f2aec`.

Local targeted checks for this implementation:

- Provider HDC partition-read tests: five passed; exact metadata/range, writable
  skip without hashing, mount/mapping/holder drift, truncation and deadline.
- Runtime `cargo test -p arkdeck-hoststore --lib`: 468 passed, 7 existing ignored;
  log `/private/tmp/arkdeck-maintenance-hoststore-tests.log`. Durable-intent tests: failed persistence stops, reopening refuses replay;
  JobStore stopped-record restart test preserves the first reason. Same-timestamp
  source ordering uses the durable admission sequence.
  The final maintenance filter passed 11 tests, including real journal append and
  reopen for both Catalog operations (`/private/tmp/arkdeck-maintenance-final-tests.log`).
- CLI maintenance tests: invalid arguments exit 2 before connection, verify 0/9/7,
  stopped/unknown restore exit 1, and a failed Job cannot report success.
- Swift `FlashMaintenanceTests`: five passed, including original ramdisk full-hash
  result, malformed-success refusal, plan/digest-before-submit, and no repeated
  `job.run` after a lost response. Log: `/private/tmp/arkdeck-maintenance-swift.log`.
- macOS App `scripts/ci/run-xcodebuild.sh`: build-for-testing passed, no App launch.
  Log: `/private/tmp/arkdeck-maintenance-appbuild.log`.
- Targeted Clippy for CLI, contract, both providers, hoststore and agentd passed
  (`/private/tmp/arkdeck-maintenance-clippy.log`).
- Provider/contract crate regression suites passed. CLI aggregate reaches three
  frozen c6 Runtime-reopen cases that intentionally require the historical Catalog;
  they remain routed to c6 in CI, with the original fixture bytes unchanged.
- Host-only `check-readonly.py`: passed with 141 control responses and 13 CLI
  envelopes; no HDC configured. Log: `/private/tmp/arkdeck-maintenance-readonly.log`.
- Historical Catalog and routing Python tests passed; the new exact Catalog view
  removes only the two declared maintenance additions when reproducing c6.
  Fixed e4 plan/Job oracles retain a separate required execution view (or the
  complete published e4 workspace receipt), without relabeling their authority.
  The routing, input/provenance and pinned-view Python tests passed.
- The maintenance journal test asserts both operations are absent in exact c6/e4
  views; the maintenance view appends every declared step and reopens the journal.
  This keeps historical parity from importing operations that did not exist.
- Historical Import reference compatibility: nine terminal-publication tests
  passed, including refusal when an old Catalog record claims a new operation.
  This compatibility affects read-only input retention, not execution authority.
- Windows decoder tests were added without a local .NET executable in the initial
  implementation run. Its platform CI was pending at that point; final publication
  CI is recorded above.

At revision 1, default destructive capability issuance remained disabled.
Plan-only refusals are read-only and produce no stopped record; submitted
admission refusals retain their own immutable stopped record. No live-device execution, hardware evidence,
production-support promotion, tag or release was performed.

## Independent entry-point acceptance follow-up

The [2026-10-19 run](independent-acceptance-20261019.md) records production
discovery and result/publication repairs, both current-Runtime refusal paths,
independent original-ramdisk restoration and a separate successful full-hash
verification Job. The ordinary nine-partition verification retains its partial
exit 9 (eight verified and mounted-writable userdata skipped). All three new
maintenance Sessions were published. The recommission result is not substituted
for either entry, and the run states its Normal/HDC scope explicitly.

## Revision-2 default restoration policy publication

The [2026-10-19 candidate checks](restoration-policy-candidate-20261019.md)
cover the exact original-ramdisk default policy, its immutable Catalog
lineage, real-owner synthetic-port integration and standard failure-code repair.
Revision 1's immutable policy remains disabled. Revision 2 was separately
published through PR #2675 after its final-head CI passed; those host checks do
not substitute for the independent device results linked above.
