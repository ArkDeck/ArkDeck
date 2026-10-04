# TASK-XPA-020 — WinUI Diagnostics, 2026-10-04

- Task: the Diagnostics surface of TASK-XPA-020, WM5 (`docs/design/cross-platform/windows-phase-agent-prompt.md`),
  after Debug #2430, Flash #2442 and Trace/Viewer #2452. The lead's instruction: the macOS
  Diagnostics workspace at parity, Arm and Mark showing the unavailable state.
- Base: branch `agent/xpa-020-winui-diagnostics-20261004`, one commit on `origin/main` `9f26fc0a`;
  nothing is force-pushed.
- Host: the Windows 11 x64 reference host, non-elevated; .NET SDK 10.0.401, Windows App SDK 2.5.1,
  MSTest 4.4.1, FlaUI.UIA3 5.0.0; `ARKDECK_DEV_SIGNER_THUMBPRINT` exported in the gate. No system
  setting changed; no package registered; no device, `hdc` or DAYU200. Only the App instances and
  daemon copies the tests launched ran; none was left running.

Host evidence for the client, not device, platform or Narrator-by-ear acceptance.

## The macOS surface

`ArkDeckApp/Features/Diagnostics/DiagnosticsWorkspaceView.swift`, `DiagnosticsWorkspaceViewModel.swift`,
the History hand-off in `RuntimeHistoryView.swift` (`history.openDiagnostics`), and the readers
`DiagnosticSessionApplicationReader.swift`, `DiagnosticSessionOfflineInspector.swift`,
`DiagnosticSessionReading.swift`, `DiagnosticHilogSummaryReader.swift`, read in full.

- A History record's read-only context (Open Diagnostics) is read: for `capture.diagnostics@1`, the
  Job's correlation (`job.show`), its Artifacts, its evidence's typed parameters and the session's
  index, summary and markers documents, inspected by the shared offline inspector; for
  `analyzer.summarize-hilog@1`, the summary Artifact verified against the Job's facts, its lease,
  its digest, its canonical encoding and the analyzer report it records.
- The page: the alignment state, the capture pane (Arm and Mark disabled, the reason
  `diagnostic_session_capture_not_connected`), Partial, the session's Job, ring coverage and
  timeline, the marks and why a mark has no picture, what was never looked for, the missing
  products, the Artifacts with a local text preview (sensitive only by its own action) and Open
  sensitive Trace in Viewer, the selection footer; or the HiLog summary.

## What was built

| Part | Content |
| --- | --- |
| `App.Core/Presentation/DiagnosticSession.cs` | The session inspector, the reading model, the reader selection, the text preview and the App binding (`DiagnosticSessionApplication`), and the HiLog summary verifier (`DiagnosticHilogSummary`), each refusal the Swift reason code. `DiagnosticSessionTests` replays all 15 `rust/tests/fixtures/diagnostics-inspect` cases (stdout, stderr and exit byte for byte, 0 mismatches), checks every App-binding refusal, the Catalog's Artifact roles, the real job-run-hilog summary and its integrity refusals, and the analyzer oracle's reports. |
| `App.Core/Presentation/Diagnostics.cs` | `DiagnosticsState`, which History records open Diagnostics (macOS `RuntimeWorkspaceKindProjection`), and the loader: `job.show`, every `artifact.list` page, `job.evidence`, the readers over Artifacts read and checked against their digests within the caller's bound (macOS `readArtifact`), and the bounded preview. |
| `App/Pages/DiagnosticsPage.cs`, History | The page as above; History's detail shows Open Diagnostics for those records. `JobSummary` keeps `sessionId` and `workspaceKind`. |
| Strings | All 75 `DiagnosticsLocalizable` keys, `app.navigation.diagnostics`, `history.activity.open.diagnostics`, `history.context.readOnly` (values unchanged; the table joins the generator's and the windows lane's inputs) and one Windows-only key. |
| Scripted transport | `ScriptedDaemon.Diagnostics.cs`, scenario `diagnostics`, over `Testing/Recorded/diagnostics-workspace.json` (written by a script from the diagnostics-inspect oracle's session — its `job.show`, Artifact rows and the bytes the oracle read; `job.evidence` restated from that `job.show` — and job-run-hilog's recorded summary Job). |

Delegated minor decisions (pending the next rulings batch):

1. **Arm and Mark are enabled and say why they cannot run** (XPA-AC-8: no disabled placeholder):
   choosing either announces "Session capture is not available" with its detail; the pane always
   shows the reason and the macOS reason code. Mark keeps a Ctrl+M accelerator, and its label is the
   Windows-only `windows.diagnostics.capture.mark` ("Mark (Ctrl+M)"; macOS names ⌘M).
2. **Only Diagnostics' History hand-off is ported here.** History shows Open Diagnostics for
   `capture.diagnostics@1` records and the records whose workspace is Diagnostics (the Runtime's
   `workspaceKind`, else `analyzer.summarize-hilog`/`analyzer.extract-crash-signature`), as macOS
   shows it; the other workspaces' Open buttons are the separate History hand-off PR.
3. **Open sensitive Trace in Viewer opens the Trace viewer directly** with the Job's raw Trace (the
   Trace page's verified download); macOS routes through the Trace workspace's History context first.
4. **The timeline and the recorded hashes are show/hide buttons**, not Expanders: a WinUI Expander
   does not expose its content to UI Automation by identifier.
5. **Access key G** for Diagnostics (O, D, H, N, A, I, B, F, T, R, V, S are taken).
6. **No glyphs in accessible names**: a mark's kind is its word (Marked, Found); a refusal is its
   text, without the macOS warning symbol.
7. **Read buttons name their Artifact** ("Read locally: hilog.txt"), so a screen reader can tell the
   rows' buttons apart; the snapshot matches the macOS label as a prefix.
8. **Swift behaviours approximated** in the port (none reached by the oracle): the Artifact role is a
   table checked against the Catalog (the App has no Catalog descriptor); duplicate JSON keys are
   refused, as ClientKit's strict JSON does; grapheme clipping uses .NET's text elements.

## What the real daemon answers

Over a development root with no adopted device: no Job exists to open (no capture is admitted
without an HDC), History is empty and offers no Open Diagnostics; the Diagnostics page says no
session is open and that session capture is not connected; `job.list` stays empty
(`TheDiagnosticsPageShowsThatSessionCaptureIsNotConnected`).

## Accessibility

- Tab walk: Diagnostics with no record, with the session and with the HiLog summary open (from
  History) joins the pages whose every action is a Tab stop in reading order, retraced by Shift+Tab.
- Access keys unique: O, D, H, N, A, I, B, F, T, R, V, G, S.
- 225 % text: the same three states, the session with a text preview open.
- UIA snapshots: `diagnostics.session`, `diagnostics.hilog` (scenario `diagnostics`) and
  `diagnostics.empty` (scenario `jobs`); both languages.

## Checks on the reference host

Local targeted checks (2026-10-04; logs in the session scratchpad `x3/diag-full.log` on `1226b092`, `x3/diag-ui2.log` after rebasing onto `553a06fc`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive, this tree on `553a06fc`; SHA-256 `e4a561f8bc8c5dc644cb4b082bf097cfb36ef2d034bf6b2aa75304ae7f847b47`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 120 passed (`DiagnosticSessionTests` 13, `DiagnosticsTests` 6) |
| ClientKit.Tests | 42 passed, 1 skipped (`ARealArtifactSigningPublisherIsMatchedThroughWinVerifyTrust`, needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, `ARKDECK_CLIENTKIT_DAEMON` = the daemon above) | on `553a06fc`: 109 passed, 2 skipped (`TheInstalledAppConnectsToTheDaemonTheCliStarted`, needs an installed package; `KeyboardFocusIsVisible`, locked desktop). On `1226b092` one Settings › Storage 225 % case had failed once ("the page rendered", not touched here); the 35 large-text cases then passed twice in a row |
| `generate-clientkit`, `generate-ui-strings`, `generate-xaml-tokens`, `generate-app-icons` `--check` | exit 0 (1155 strings) |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

After rebasing onto `9f26fc0a` (#2450 composes the analyzer provider on the Windows daemon), with
the daemon rebuilt from it (SHA-256 `9d5e310648005b6254003e7fea7b2450b4d9bdd7537074940908f1e16c81cc88`):
the Release build again 0 warnings, App.Tests 120 passed, `RealDaemonTests` and
`DiagnosticsFlowTests` 13 passed, the four generators `--check` exit 0.

Also here: `SettingsShowTheDevelopmentRootsRuntimeAndWorkspace` now expects the Toolchains tab's
HDC status, which the Windows daemon answers since #2453 (`unavailable (hdc.notConfigured)`, as macOS
without an HDC host) instead of the foundation's refusal the test was written against.

## Not done here, and why

1. **A Diagnostic Session capture** (arm, append marker, stop): macOS composes no capture provider
   either; the controls state the reason.
2. **A session or HiLog summary read from the real daemon:** both need a `capture.diagnostics@1`
   Job, which needs the Windows HDC tuple (CHG-2026-078, not registered).
3. **History's hand-off into the other workspaces** (Open Trace, Viewer, Debug, Flash, Device): its
   own PR.
4. **Narrator by ear, real key strokes, the system high-contrast themes and 225 % text**: as in
   `winui-settings-a11y-run.md`.
5. The Windows-only string's Chinese value wants the maintainer's review.

CI: to be recorded by the PR's hosted run; not verified here.
