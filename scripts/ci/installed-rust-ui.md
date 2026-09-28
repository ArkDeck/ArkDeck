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

## SPK-8 negative cases (TASK-XPA-019)

Two further opt-in commands cover SPK-8's negative cases. Neither is a UI test
or uses the UI runway; each is one shell command, run from the repository root
by the maintainer, and writes `result.json` (mode 0600) into a **new** absolute
evidence directory (mode 0700) outside installed Runtime state. Exit codes:
0 `PASS`, 1 `FAIL` or `BLOCKED`, 77 `SKIPPED`. A skip is never acceptance.
These are plain shell variables: **no** `TEST_RUNNER_` prefix.

**(a) A client outside team 8AQTYW5FKR is refused, with zero dispatch.** Run it
against the installed pure-Rust daemon after `runtime service update` (runbook
step 4). It needs the same five pins as the positive case, unprefixed, plus its
own switch:

```sh
ARKDECK_SPK8_FOREIGN_CLIENT=1 \
ARKDECK_INSTALLED_RUST_APP=… ARKDECK_INSTALLED_RUST_APP_SHA256=… \
ARKDECK_INSTALLED_RUST_CLI=… ARKDECK_INSTALLED_RUST_CLI_SHA256=… \
ARKDECK_INSTALLED_RUST_DAEMON_SHA256=… \
  python3 scripts/ci/installed_spk8_negatives.py foreign-client /absolute/new/spk8-foreign-client
```

It first runs the positive case's read-only installed-identity check
(`installed_rust_ui.inspect`: pinned daemon, live launchd PID and active Mach
endpoint, production composition, no façade/Swift). It then compiles
`scripts/ci/spk8_foreign_client.swift` with `xcrun swiftc`, signs it ad hoc and
refuses to continue unless `codesign` shows no team and the daemon's App
requirement rejects it. The client first runs its in-process self-test (below),
then sends one read-only `health` frame to `com.arkdeck.agentd`, pinning the
answering service to the inspected daemon's team, identifier, version and build.
`PASS` requires libxpc to cut the client off (`connectionInterrupted` or
`connectionInvalid`) with no reply frame, within its 5 s bound, and the same
service identity (same PID) afterwards. Any reply frame is `FAIL` (the daemon's
handler ran for a foreign client); an unmet service pin is `BLOCKED` (a different
process answered); no answer is `FAIL` (hang).

**(b) The App facing another daemon release reports the mismatch and its remedy,
without hanging.** Run it when the App and the installed daemon differ in
`CFBundleShortVersionString` or `CFBundleVersion`: naturally in runbook step 1–2,
after installing the release candidate App and before `runtime service update`
(the RC's build number differs from the installed helper's). Quit ArkDeck first.

```sh
ARKDECK_SPK8_VERSION_MISMATCH=1 \
ARKDECK_SPK8_APP=/Applications/ArkDeck.app ARKDECK_SPK8_APP_SHA256=<its executable SHA-256> \
  python3 scripts/ci/installed_spk8_negatives.py version-mismatch /absolute/new/spk8-version-mismatch
```

It checks the App's team signature, production sandbox and Mach exception and its
pin, reads the live launchd owner of `com.arkdeck.agentd` (plist, `launchctl
print`, process path, bundle version), and verifies that owner is the ArkDeck
daemon or façade by team and identifier. If the owner also satisfies this App's
release pin there is no mismatch and the result is `BLOCKED`, not a pass. It then
starts the App's `--runtime-readonly-smoke` entry (production ClientKit, no
fixtures) and asks for two refreshes, each within 20 s. `PASS` requires both
reports to be disconnected with `unavailableReason` naming "Runtime release does
not match this App" and ending "run runtime service update", the App to exit on
end of input, and the launchd owner to be unchanged. The App's own transport
bounds the health exchange at 5 s; libxpc reports the failed release pin within
milliseconds. After the cutover the installed Rust daemon matches the RC App, so
a rerun then needs an older signed App build that has the smoke entry point.

**Self-test (no Runtime contact).** `python3 scripts/ci/installed_spk8_negatives.py
self-test /absolute/new/dir` compiles and signs the same client and runs it only
against anonymous in-process listeners shaped like the Rust daemon's
`arkdeck_mach_listen` (euid check and code requirement installed on each peer
before activation). It must refuse under the App requirement with zero handler
entries and detect the dispatch on a control listener with no requirement. It is
a harness check, not SPK-8 evidence.

`PYTHONDONTWRITEBYTECODE=1 python3 scripts/ci/test_installed_spk8_negatives.py`
exercises the switches, evidence-directory rules, verdicts, and the App smoke
reader against recorded stand-in Apps (answering, hanging); it is local-only
like the positive helper's tests. `RuntimeXPCRequestTransportTests` covers both
negatives in process through the App's own transport and anonymous listeners.

`AgentXPCTransportContractTests` is an in-process test of the Swift listener and
cannot run black-box against an installed daemon; it retires with the Swift
Runtime targets. Its black-box role is carried by the Rust control-plane
black-box tests and these two negatives.
