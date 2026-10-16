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

## Pending maintenance scenarios

The companion ArkForge adapter tests cover 0/9/7, identity drift, failed intent
persistence, stopped recording, malformed inputs with zero port calls, exact
ramdisk scope, one consumption, unknown execution and no blind retry. They do
not verify ArkDeck Runtime port composition. Before Catalog publication, add
source/plan/identity drift and restart fault tests to that composition and test
result projection through CLI, macOS Flash and Windows App.Tests.
