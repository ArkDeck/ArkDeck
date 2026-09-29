# SPK-8 negative cases, software part (TASK-XPA-019, macOS, 2026-09-28)

TASK-XPA-019 / CHG-2026-074, stage S slice S4 of the 2026-09-28 close-out prompt. Base: protected
`main` `fa8d9d81b` (#2306). This slice makes SPK-8's two negative cases runnable, one command each,
against the installed pure-Rust daemon in stage A. Nothing here ran against the installed Runtime,
launchd, a device or a team signing identity; nothing here is SPK-8 or device evidence.

- (a) A client not signed by team 8AQTYW5FKR is refused by `com.arkdeck.agentd`, with zero dispatch.
- (b) The App facing a daemon of another version/build reports the mismatch with its remedy and does
  not hang. The App's server requirement pins `CFBundleShortVersionString` and `CFBundleVersion`
  (`AgentXPCContract.swift`, `serverCodeRequirement`).

The positive case (`FacadeRollbackUITests/testInstalledPureRustHistoryFilterRoundTrip`,
`scripts/ci/installed_rust_ui.py`) is unchanged and still runs in stage A.

## What libxpc does in each case

Measured on this host (macOS 27.0, Darwin 27.0.0) with an anonymous in-process listener, the same
shape as the Rust daemon's `arkdeck_mach_listen`
(`rust/crates/arkdeck-platform/src/macos_control.c`: euid check, then
`xpc_connection_set_peer_code_signing_requirement` on each peer before activation):

| Setup | Client's reply | Listener handler entries |
|---|---|---|
| no requirement | `frame` dictionary | 1 |
| listener requires the App identity; client is ad hoc | `XPC_ERROR_CONNECTION_INTERRUPTED`, then event `CONNECTION_INVALID` | 0 |
| client pins a server version/build the listener does not have | `XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT` ("Peer Forbidden") | 1 |

This agrees with SPK-2 on macOS 26 (`evidence/runs/TASK-XPA-003/spk-2-run.md:52`, B/C/F refused
with 0 messages, client interrupted then invalid in 1.2–6.1 ms; `results/a-client-pin-wrong.json`,
client-side pin failure "Peer Forbidden"). So (a) is observable from the client as "cut off, no reply
frame", and (b) as a distinct libxpc error the App can name.

## Change

- **App transport names a release mismatch.** Before, the App reported (b) as "Runtime transport
  mismatch or interruption; run runtime service update", the same words as a crash. `XPCConnectionBox`
  (`Packages/ArkDeckKit/Sources/ArkDeckClientKit/RuntimeXPCRequestTransport.swift`) now maps
  `XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT`, on the reply or the connection event, to
  "Runtime release does not match this App (requires ArkDeck Runtime <version> build <build> signed
  by the ArkDeck team); run runtime service update", with this App's own version and build. Every
  other error keeps its wording; no request is replayed and the 5 s health bound is unchanged. The box
  gains a `connect` seam (default: the fixed Mach lookup) so tests can use an anonymous endpoint.
- **App smoke report carries the reason.** `ArkDeck --runtime-readonly-smoke` (`ArkDeckApp.swift`)
  adds `unavailableReason`: the words History (or the filter) shows when the Runtime is unusable,
  at most 512 characters, no Job data. Schema version unchanged (additive key).
- **(a) client:** `scripts/ci/spk8_foreign_client.swift`, a bare tool. `probe` sends one read-only
  `health` frame to `com.arkdeck.agentd`, pinning the answering service to the inspected daemon's team,
  identifier, version and build, and classifies libxpc's answer: `refused`, `answered`,
  `answeredMalformed`, `serverRequirementUnmet`, `noAnswer` (5 s), `otherError`. `self-test` runs the
  same round trip against a listener requiring the App identity and a control listener with none.
- **Harness:** `scripts/ci/installed_spk8_negatives.py {self-test|foreign-client|version-mismatch} DIR`.
  It reuses the positive helper's checks (`installed_rust_ui.inspect`, `live_pid`,
  `verify_live_endpoint`, `process_path`) and the IPC harness's App checks and report reader
  (`rust/scripts/macos-app-rust-smoke.py`: `inspect_app`, `next_report`).
  - `foreign-client` (switch `ARKDECK_SPK8_FOREIGN_CLIENT=1` plus the positive case's five pins):
    inspect the installed pure-Rust daemon; compile the client, sign it ad hoc, and refuse unless
    `codesign` shows no team and the App requirement rejects it; self-test; probe; inspect again.
    `PASS` only for a bounded cut-off with no reply frame and an unchanged identity (same PID).
  - `version-mismatch` (switch `ARKDECK_SPK8_VERSION_MISMATCH=1`, `ARKDECK_SPK8_APP`,
    `ARKDECK_SPK8_APP_SHA256`): check the App, read the live launchd owner, verify it is the ArkDeck
    daemon or façade by team and identifier, and that the live process does **not** meet this App's
    release pin, which is what libxpc evaluates (else `BLOCKED`, no mismatch to observe). Then two smoke refreshes, 20 s each; `PASS` needs both
    disconnected with the mismatch words and remedy, a clean exit, and the same launchd owner.
  - Without its switch a case prints `SKIPPED` and exits 77 before creating anything. `PASS` 0,
    `FAIL`/`BLOCKED` 1. The evidence directory must be new, absolute, outside installed state (0700);
    `result.json` is 0600. Subprocess environments drop `ARKDECK_*`, `DYLD_*`, `CFFIXED_USER_HOME`;
    third-party output is never echoed.
- **Docs:** `scripts/ci/installed-rust-ui.md` gains "SPK-8 negative cases" (switches, commands,
  verdicts). The cutover runbook's step 4 now gives the three commands; step 2 says to run (b) before
  `runtime service update`, while the RC App still faces the old helper; appendix B items 14 and 15
  are closed.

### Zero dispatch, and what (a) can and cannot show

From outside, the daemon's handler can only become visible to the client as a reply frame, so (a)
fails on any frame. That the handler is not entered at all rests on the listener: libxpc installs the
requirement before the peer is activated, and only the activated peer's event handler calls the Rust
handler (`macos_control.c`). The self-test shows the same arrangement at zero handler entries, and
`RuntimeXPCRequestTransportTests.testRuntimeRefusingAForeignClientDispatchesNothing` shows it through
the App's own transport. The probe sends only `health`, so even a wrongful dispatch changes no state.
A connection to an unregistered name would also look like `refused`; the harness therefore requires
the live launchd PID and an active Mach endpoint before and after, and the same PID both times.

### Timing of (b) in stage A

After `runtime service update`, the installed Rust daemon comes from the same RC as the App, so
there is no natural mismatch. (b) is run between runbook steps 1 and 2: RC App installed, old helper
still serving. That old helper is the façade (identifier `com.arkdeck.agentd.facade`), which the
App's identity requirement admits; only the version/build pin fails, which is the case under test.
A later rerun needs an older signed App build with the `--runtime-readonly-smoke` entry point.

## `AgentXPCTransportContractTests`

It tests the Swift listener in process (`AgentXPCEndpoint`, allowlist, frame decoding, Job binding)
and cannot run black-box against an installed daemon. It retires with the Swift Runtime targets
(stage S slice S6). Its black-box role is carried by the Rust control-plane black-box tests, namely
the App ingress door and allowlist tests replayed from Swift's oracle
(`rust/crates/arkdeck-agentd/src/app_ingress/door_tests.rs`,
`rust/tests/fixtures/app-ingress-door-oracle`, `TASK-XPA-019/app-ingress-door-refusals-run.md`),
the spawned-process control tests under `rust/crates/arkdeck-agentd/tests/`, and these two
negatives against the installed daemon. Runbook appendix B item 15 is closed on that basis.

## Tests

- `RuntimeXPCRequestTransportTests` (ClientKit), in process with anonymous listeners:
  - `testReleaseMismatchedRuntimeIsReportedWithItsRemedyWithoutHanging`: the listener answers, the
    test process fails the release-pinned `serverCodeRequirement`; the result is exactly
    `runtimeReleaseMismatchDetail`, in under 4 s (not the 5 s health timeout's words).
  - `testRuntimeRefusingAForeignClientDispatchesNothing`: the listener requires the App identity;
    the result keeps the interruption wording and the handler ran 0 times.
- `scripts/ci/test_installed_spk8_negatives.py` (12 tests, host-only): switches skip with exit 77 and
  no subprocess or directory; evidence-directory rules; release requirement quoting; self-test,
  (a) and (b) verdict tables; (a) orchestration (probe pin carries the daemon's version/build;
  restart between inspections fails); the client must be ad hoc, teamless and rejected by the App
  requirement; (b) orchestration (`BLOCKED` without an actual mismatch, App never launched; `FAIL`
  when it connects); the smoke reader against recorded stand-in Apps: one answering the mismatch
  twice and exiting, one hanging (bounded at 1 s and terminated).
- Real self-test of the compiled, ad-hoc signed client (below).

## Local targeted checks

- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter RuntimeXPCRequestTransportTests`:
  exit 0, 4 tests passed.
- `PYTHONDONTWRITEBYTECODE=1 python3 scripts/ci/test_installed_spk8_negatives.py`: exit 0, 12 tests.
- `PYTHONDONTWRITEBYTECODE=1 python3 scripts/ci/test_installed_rust_ui.py`: exit 0, 12 tests
  (positive helper unchanged).
- `python3 scripts/ci/installed_spk8_negatives.py self-test /private/tmp/claude-501/spk8-selftest-1`:
  exit 0, `PASS`; `codesign` shows `Signature=adhoc`, `TeamIdentifier=not set`; refusing listener
  `refused` / `connectionInterrupted` in 10.7 ms with 0 handler entries; control `answered` with 1.
- `foreign-client` and `version-mismatch` without switches: exit 77, `SKIPPED`, no directory created.
- `ARKDECK_XCODE_CACHE_ROOT=/private/tmp/claude-501/spk8-xcode ARKDECK_XCODE_JOBS=4 sh scripts/ci/run-xcodebuild.sh`:
  exit 0, `TEST BUILD SUCCEEDED` (App with the smoke report change); log `/private/tmp/claude-501/spk8-app-build.log`.
  The first attempt exited 74 on a transient `swift-nio` clone error (HTTP2 framing); the retry built.
- `sh scripts/check-sdd.sh`: exit 0, `check_sdd: 0 error(s), 0 warning(s)`.

Not run: the UI test (`run-ui-tests.sh`) and both installed cases. The installed cases need the
installed pure-Rust daemon and the RC App, which exist only in stage A; running them here would touch
the installed service. No UI runway was used: the App change is covered by build-for-testing, and the
smoke reader by the recorded stand-ins.

## CI

Final: #2308 head `289fcb0f7`, Swift CI run 36430301497 success (the `swift` aggregate and every selected lane), SDD Guard run 36430301088 success; squash-merged as `f574ad984` on 2026-09-28. Recorded by the docs-only follow-up (TASK-XPA-017).
