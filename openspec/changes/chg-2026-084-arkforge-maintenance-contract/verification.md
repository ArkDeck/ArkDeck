# Verification — CHG-2026-084

> Change:CHG-2026-084-arkforge-maintenance-contract@r1

All checks below are host/fake tests, not hardware acceptance.

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

Pending the PR's current-head SDD Guard, Swift aggregate, Rust and Windows lanes.
No result from another head substitutes for these checks.

## Maintenance implementation checks (follow-up to merged #2657)

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
- Windows decoder tests added; no local .NET executable. Windows execution is
  pending the Windows CI lane. Cross-platform CI is still pending this PR's head.

Default destructive capability issuance remains disabled. Plan-only refusals are
read-only and produce no stopped record; submitted admission refusals retain their
own immutable stopped record. No live-device execution, hardware evidence,
production-support promotion, tag or release was performed.
