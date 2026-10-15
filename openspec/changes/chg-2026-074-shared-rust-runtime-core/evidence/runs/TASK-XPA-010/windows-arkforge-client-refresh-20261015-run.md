# Windows ArkForge client integration refresh

ArkDeck's five ArkForge dependencies now share reviewed upstream revision
`eedaa3e3bae641374e453cad302eb214d55d6b08`. This includes the Windows named-pipe
listener lifetime repair and the client used by the completed upstream Windows
campaign. The materializer supplies the client's new explicit `intent` field as
`fullRestore`; preview, primary flash and recovery retain the existing closed
recipe. The fake external-port regression checks that intent on every request.

This update does not install an ArkForge daemon bundle or publish AF-W1. A real
Windows integration still needs the matching bundle and independent agreement
between ArkDeck's Windows attachment topology and ArkForge's connector topology.
The existing task remains blocked on its real-device acceptance; upstream
standalone campaign receipts are not ArkDeck hardware evidence.

## Local targeted checks

Checks used the session's fixed Cargo runner cache on Windows x64, two build
jobs. Log paths below are private local filenames, with no device identifiers.

- `python rust/scripts/run-cargo.py fmt --all --check` hit Windows argument
  length error 206. Equivalent batched `rustfmt --check` over all Cargo target
  roots passed, exit 0 (`arkdeck-arkforge-integration-checks-2/fmt-batched.log`).
- `python rust/scripts/check-arkforge-pin.py --run-vectors` through the runner
  passed, exit 0 (`arkdeck-arkforge-integration-checks-2/pin.log`): the exact
  locked upstream wire and StepPermit vectors are unchanged.
- `clippy -p arkdeck-provider-arkforge -p arkdeck-hoststore -p arkdeck-agentd
  --all-targets -- -D warnings` through the runner passed, exit 0
  (`arkdeck-arkforge-integration-checks-2/clippy.log`).
- `test -p arkdeck-provider-arkforge` passed, exit 0, 88 tests
  (`arkdeck-arkforge-integration-checks-2/provider-test.log`).
- `test -p arkdeck-hoststore` reached 397 passes and then failed the unchanged
  `debug_hap_plan::native_swift_plans_match_with_nothing_admitted_or_dispatched`
  historical Catalog fixture, exit 101
  (`arkdeck-arkforge-integration-checks-2/hoststore-test.log`).
- `test -p arkdeck-agentd` passed its 53 spawning cases, including Flash
  execution, unknown-outcome handling and the recovery broker. It later failed
  the unchanged `windows_artifact_owner_process` historical Catalog fixture,
  exit 101 (`arkdeck-arkforge-integration-agentd-test.log`). Both historical
  suites already have separate routes in `rust/scripts/catalog-test-views.json`;
  assertions and expected bytes were not changed.
- The initial provider compile exposed the missing `intent` field; the passing
  provider test and clippy above include its repair. No local full CI gate was run.

## CI

Pending the PR's `guard` and `swift` checks. macOS and the routed historical
contract checks are left to their existing CI lanes. No real-device execution
or hardware-support promotion is claimed by this software increment.
