# Installed pure-Rust History filter UI acceptance

This is an explicit local acceptance case in the existing `ArkDeckHDCUITests`
target, separate from fixture presentation tests and the AC-9 facade/rollback
case. It does not install or switch Runtime, register a service, modify signing
or permissions, or dispatch a device operation. Coordinate the exclusive UI
window and unlock the desktop before running it.

Set these environment variables from the verified release/install handoff:

The names below are the test runner's names. When invoking the wrapper from a
shell, export **each with `TEST_RUNNER_` prepended**, for example
`TEST_RUNNER_ARKDECK_INSTALLED_RUST_UI=1`. Xcode strips that prefix when forwarding
variables to its runner. Merely setting the unprefixed opt-in in the shell can
leave the test skipped; a skip is never acceptance.

- `ARKDECK_INSTALLED_RUST_UI=1`
- `ARKDECK_INSTALLED_RUST_APP`: absolute signed Release `ArkDeck.app` path
- `ARKDECK_INSTALLED_RUST_APP_SHA256`: its executable SHA-256
- `ARKDECK_INSTALLED_RUST_CLI`: absolute signed Rust CLI executable path
- `ARKDECK_INSTALLED_RUST_CLI_SHA256`: its executable SHA-256
- `ARKDECK_INSTALLED_RUST_DAEMON_SHA256`: installed Rust daemon executable SHA-256
- `ARKDECK_INSTALLED_RUST_EVIDENCE`: a new absolute directory with an existing
  parent, outside installed Runtime state

Quit existing ArkDeck windows first. Use the ordinary wrapper and independent
DerivedData, selecting only:

```sh
sh scripts/ci/run-ui-tests.sh \
  -only-testing:ArkDeckHDCUITests/FacadeRollbackUITests/testInstalledPureRustHistoryFilterRoundTrip
```

The test launches `XCUIApplication(url:)` at the pinned signed App, with no
fixture flags. It saves a unique search through the production History UI,
verifies the durable resource independently, relaunches the same signed App,
and applies the saved filter. App and service live process paths and dynamic
CodeDirectory signatures must match the pinned on-disk releases. The helper
also checks the fixed launchd service PID, installed receipt, production
composition, exact production App entitlements, no facade sibling, no Swift
linkage, and no parallel Runtime/facade process. It never prints launchd
environments, process arguments, filter queries or command diagnostics.

Before the UI can save, `snapshot.json` preserves the original complete query
or absent state in a private directory (0700), with file mode 0600. The current
typed CLI cannot express values beginning with `--`; such an original query
is refused before mutation. Cleanup restores via existing typed CLI commands
only if both query and generation still identify the one test-owned write.
An outside change or changed service identity prevents restoration; no value
is overwritten to make the test pass. Readback verifies the original query
and expected new generation. This restores semantic saved state, not the old
generation or timestamp, which correctly advance under the existing contract.

Keep `snapshot.json` local: it may contain a private user search. Successful
cleanup writes `restoration.json`; failed cleanup writes `restore-failed-*.json`
and fails the test, retaining the snapshot. An interrupted runner also leaves
the snapshot. After reviewing current state, the same guarded cleanup can be
invoked with `python3 scripts/ci/installed_rust_ui.py restore /absolute/evidence`;
it does not offer a force-restore or bypass the generation check.

`PYTHONDONTWRITEBYTECODE=1 python3 scripts/ci/test_installed_rust_ui.py` exercises
the host-only parsing and restoration decisions. Those tests, compilation, and
an opt-in skip are not SPK-8 evidence. Only a completed real UI run against the
verified installed pure-Rust service, including restoration, establishes this
case. This is not device or full migration acceptance.

The Python helper regression suite is local-only: the current CI planner lists
specific `scripts/ci/test_*.py` files and does not discover this new file. The
existing App CI lane compiles the Swift case, but no CI lane executes installed
UI acceptance. No CI discovery or gate was expanded for this carrier.
