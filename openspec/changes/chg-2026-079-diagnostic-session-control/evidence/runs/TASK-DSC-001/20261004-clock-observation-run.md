# TASK-DSC-001 — trace-anchor host clock observations

2026-10-04. Follow-up to CHG-2026-079@r1. Candidate code and isolated fixtures only;
no device execution, calibration accuracy, hardware PASS or maintainer approval.

The Runtime brackets the existing trace-anchor write with host UTC and monotonic
measurements, persists the exact Job/anchor identity and publishes the observation
in the immutable marker and Session documents. There is no additional device
command, materialized plan change, Catalog change or live Control wire change.
Callback/persistence failures stop subsequent dispatch with an unknown result.
Observations do not establish recording readiness or restart authority.

CLI and ClientKit check the closed shape, Job/anchor identity, bounded monotonic
interval and UTC consistency. Millisecond labels are compared as integer
milliseconds; fractional Date formatting is never used for equality. The App
shows the measured host window or a host-clock discontinuity and retains
`cannotAlign`. The two-millisecond consistency allowance is solely the host
label precision check, never a cross-clock accuracy promise. Actual calibration
remains blocked on the reviewed operation and ground-truth experiment specified
by `docs/design/diagnostic-mode-design.md`.

## Local targeted checks

Logs: `/tmp/arkdeck-macos-closeout-20261004/`.

- `CARGO_BUILD_JOBS=2 cargo test --manifest-path rust/Cargo.toml -p arkdeck-provider-hdc diagnostic_trace::`: four tests passed, exit 0 (`clock-provider.log`). Success keeps exactly six existing dispatches; callback failure stops at the exact preceding dispatch.
- `CARGO_BUILD_JOBS=2 cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --lib diagnostic_session::`: nine tests passed, exit 0 (`clock-owner-final.log`). The initial test read the state directory as a file; its path was corrected to the persisted document, without weakening assertions.
- `CARGO_BUILD_JOBS=2 cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --test capture_diagnostics`: five tests passed, exit 0 (`clock-capture.log`). The actual fixture producer recorded the committed interactive Session; live status retains its existing closed wire shape.
- CLI diagnostics unit and recorded-contract tests passed (4 + 1, exit 0; `clock-cli-unit.log`, `clock-cli-contract.log`). Existing artifacts without measurements remain readable.
- `run-swiftpm.sh test --filter 'DiagnosticClockObservationTests|DiagnosticSessionOfflineInspectorContractTests|DiagnosticSessionReadingTests|DiagnosticCaptureFacadeTests'`: nine tests passed, exit 0 (`clock-swift-final.log`; two named historical class filters matched no tests). The initial fractional-date roundtrip rejected valid milliseconds; strict whole-second parsing plus integer milliseconds fixed that bug. Exact threshold, date-normalization, identity, malformed-number and false-calibration refusals remain covered.
- `ARKDECK_XCODE_JOBS=2 sh scripts/ci/run-xcodebuild.sh`: exit 0, TEST BUILD SUCCEEDED (`clock-app-build.log`).
- Final Clippy for provider-hdc, hoststore, CLI and their direct dependents agentd/soak: exit 0 with `--all-targets -- -D warnings` (`clock-clippy-final.log`). `CARGO_BUILD_JOBS=2 cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd -p arkdeck-cli -p arkdeck-hoststore -p arkdeck-provider-hdc -p arkdeck-soak --no-fail-fast`: exit 0 (`clock-rust-final.log`).
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`, `git diff --check` and `sh scripts/check-sdd.sh`: exit 0 (`clock-sdd-final.log`, zero errors/warnings).

No full local unified gate, actual device workflow, ground-truth calibration or
UI automation pass is claimed.

## CI

Parent Diagnostic Session PR #2465 head `600da7c8` passed Swift CI run
`37182721655` and SDD Guard `37182721439`. This follow-up is not yet pushed.
The updated PR-selected CI remains the unified gate; publication requires
maintainer review and merge into protected main.


## Main compatibility follow-up

Merged main `2d85d513d`, retaining its Device preview/deployment state and this
branch's Diagnostics state in the single conflicting design-table region. Main's
new Windows Diagnostics reader introduced shared localization entries: its two
capture-unavailable messages remain unchanged and are now Windows-only, because
the macOS capture controls replace that surface. Both clients share the updated
“Start session” label. Windows resources are regenerated from the source registry.

The signed, notarized RC3 was read-only mounted again after checking its original
DMG SHA-256. A fresh `arkdeck-agentd --cutover-preflight` without the lock option
returned exit 0 and `clear:false`, `instanceLockHeld:false`
(`rc3-preflight-latest.json`). The same retained legacy Session lacks its Manifest;
no failed publication accounts for it. Installation, positive installed SPK-8,
real SDK/signing and the installed-runtime performance baseline remain held by
that continuity gate. No state or unresolved outcome was edited or deleted.


### Local targeted checks after merging main

- Swift `DiagnosticClockObservationTests|DiagnosticSessionOfflineInspectorContractTests|DiagnosticCaptureSessionContractTests`: 16 passed, exit 0 (`clock-merge-swift.log`).
- App build-for-testing: exit 0, TEST BUILD SUCCEEDED (`clock-merge-app.log`).
- Clippy for the same five affected/direct-dependent crates: exit 0 (`clock-merge-clippy.log`). Session owner, CLI diagnostics and the actual daemon App ingress binary module all passed, exit 0 (`clock-merge-rust.log`).
- Design-system tests: 83 passed; SDD: zero errors/warnings (`clock-merge-ds.log`, `clock-merge-sdd.log`). Rust formatting, diff checks, 108-method contract generation and Windows resource/ClientKit generation checks passed.

The Windows-only unavailable resources use the generator's required `windows.`
namespace; the Windows page's resource references follow them. Its existing UI
automation identifiers and unavailable behavior are unchanged. Native Windows
execution remains a CI check. This follow-up updates the existing PR #2465.
