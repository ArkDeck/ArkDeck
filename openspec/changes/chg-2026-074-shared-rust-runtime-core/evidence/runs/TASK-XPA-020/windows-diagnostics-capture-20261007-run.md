# TASK-XPA-020 — Windows interactive Diagnostics capture

The Windows Diagnostics page's Arm and Mark previously returned the placeholder
`diagnostic_session_capture_not_connected`. This increment consumes the existing bounded
`capture.diagnostic-session@1` operation and `diagnostic.session.*` controls described by
CHG-2026-079 and the current macOS Diagnostics composition. It adds no operation, authority,
device profile, calibration or hardware acceptance declaration.

Arm reads the published available 600-second descriptor, Trace support, Artifact headroom,
the complete bounded same-Target Job snapshot and a unique current Connected/ready adopted
binding. It refetches that identity before submission. One acceptance must report
`deduplicated=false` and `newDispatchCount=0`; its complete stored request, original identity,
binding, Catalog, provider and materialized-plan digest must match before the single 660-second
`job.run` exchange. Runtime remains the authority for admission and device execution.

The accepted Job survives page navigation with its original scope. Fixed 120-second controls
name only that owner; each marker has a fresh ID. Lost answers trigger reads, never resend.
Stop and preparation cancellation have per-session one-shot latches. An unobserved marker or
unsettled control remains read-only. Automatic status reads use the original monotonic
660-second observation window; a late answer cannot revive expired controls. Serialized reads
and monotonic snapshot checks retain the terminal state, marker prefix and stop latch.

Completion compares the original materialization and typed evidence before opening that Job's
digest-verified products. Historical contexts expose only immutable readers, even while the
live controller exists. The new operation has its exact Catalog roles; the old capture and
HiLog readers retain their checks and golden bytes. Optional host clock observations are
closed, Job/anchor correlated and displayed as an unvalidated window or discontinuity;
alignment remains `CannotAlign`.

The new scripted scenario and embedded interactive corpus are software-only fixtures. The
interactive bytes are copied from `rust/tests/fixtures/diagnostic-session/interactive.json`;
the descriptor is derived from the committed `operation.describe` control corpus. The fake
owner admits and runs one fixed Job, acknowledges marks, closes it and serves bounded whole
documents. This does not constitute device execution, hardware evidence or Narrator-by-ear
acceptance. The signed development-root UI fixture checks missing-Target refusal and an empty
Job list without connecting to a device.

## Local targeted checks

The integrated source is based on the reviewed Device/transport/string parent
`6d6b84f685f35cde74984b220cc6d522616b7202`. Commands ran sequentially in
`D:/src/ArkDeck-wt/service-verify`; complete commands and output are retained under
`D:/src/ArkDeck-wt/tools/logs/`. The UIA environment explicitly enabled the tests, and the
native test used the current task-owned debug daemon, the existing development signer, a fresh
development state root and a private pipe. The fixture removes inherited ArkDeck/HDC inputs.
No installed Runtime, account state, DevEco/Harmony SDK, HDC or device operation was used.

| Command / scope | Result | Log |
| --- | --- | --- |
| `dotnet test windows/App.Tests/ArkDeck.App.Tests.csproj -c Release --no-restore --filter "FullyQualifiedName~DiagnosticCapture\|FullyQualifiedName~DiagnosticSessionTests\|FullyQualifiedName~DiagnosticsTests\|FullyQualifiedName~HistoryContextTests"` | exit 0; 47 passed, 0 failed/skipped | `diagnostics-core-targeted-20261007-shape-fixed.log` |
| `dotnet build windows/ArkDeck.Windows.slnx -c Release` | exit 0; 0 warnings/errors | `diagnostics-windows-build-20261007-restored.log` |
| `dotnet test windows/App.UITests/ArkDeck.App.UITests.csproj -c Release --no-build --no-restore --filter "FullyQualifiedName~DiagnosticCaptureFlowTests\|FullyQualifiedName~DiagnosticsFlowTests\|(FullyQualifiedName~PagesMatchTheirSemanticSnapshots&Name~diagnostic)"` | exit 0; 8 passed, 0 failed/skipped | `diagnostics-ui-targeted-20261007-initial.log` |
| `python rust/scripts/run-cargo.py build -p arkdeck-agentd` with stable owner `tool-select` | exit 0; current isolated sibling built | `diagnostics-isolated-daemon-build-20261007-owner.log` |
| `dotnet test windows/App.UITests/ArkDeck.App.UITests.csproj -c Release --no-build --no-restore --filter "FullyQualifiedName~RealDaemonTests.TheDiagnosticsPageRefusesCaptureWithoutAConfirmedTarget"` | exit 0; 1 passed, 0 failed/skipped | `diagnostics-isolated-native-ui-20261007.log` |
| `C:/Program Files/Git/usr/bin/sh.exe scripts/check-sdd.sh` | exit 0; 0 errors/warnings | `diagnostics-sdd-20261007-final.log` |
| `git diff --check` | exit 0 | `diagnostics-diff-20261007-final.log` |

The semantic filter was first discovered explicitly: exactly `diagnostics` and
`diagnostic-capture`, each in English and Chinese, were selected
(`diagnostics-ui-discovery-20261007.log`). Their existing role/name/live and enabled-button
assertions remain intact. The UI flow covers Arm/Mark/Stop, original owner across navigation,
own completed products and immutable History. Controller tests cover lost marker/stop/cancel
answers, one-shot submission, complete paged preflight, fresh identity and Catalog correlation,
terminal materialization, monotonic expiry and a confirmed terminal that survives late
automatic refresh. All old session-inspector oracle and binding checks in the selected classes
remain unchanged and passed.

Initial failures are retained. The first sandboxed restore failed before compilation with
`NU1900` because the public NuGet vulnerability index was unreachable
(`diagnostics-core-targeted-20261007-initial.log`). A network-capable restore then exposed the
new reader's `CS0136` local-name collision
(`diagnostics-core-targeted-20261007-network.log`); only that new local was renamed. The next
run passed 44/47 and failed three new transport cases because the scripted active `job.show`
emitted a null `outcome` instead of the published state string
(`diagnostics-core-targeted-20261007-compile-fixed.log`). The fixture was corrected, preserving
production validation and every assertion; the final 47/47 result above follows that repair.
The first solution `--no-restore` build found three missing asset files in this fresh tree
(`diagnostics-windows-build-20261007.log`); the normal restored build passed. The sandboxed
daemon build refused Git's ownership check before compiling
(`diagnostics-isolated-daemon-build-20261007.log`); the normal-owner build passed without any
global Git configuration change. These logs are not classified as invalid load runs.

The two new embedded JSON source files are saved with LF. The descriptor's outer formatting
was normalized with full parsed JSON equality; the Rust source fixture and embedded Raw
Artifact strings were not changed. The original/final formatting hashes are retained in
`diagnostics-description-lf-20261007.json`. An initial SDD wrapper invocation could not resolve
`sh.exe` before script execution (`diagnostics-sdd-20261007.log`); the explicit installed
executable passed (`diagnostics-sdd-20261007-direct.log`) and the closed-note check above also
passed. No full workspace gate or hardware/Narrator acceptance was run.

## CI

This dependent increment has not been published and its CI has not run. Parent checks belong
to the parent source and do not establish validation of this increment.
