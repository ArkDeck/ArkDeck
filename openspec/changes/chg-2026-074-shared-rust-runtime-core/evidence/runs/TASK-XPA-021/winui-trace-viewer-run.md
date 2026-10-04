# TASK-XPA-021 / TASK-XPA-020 — WinUI Trace, Trace viewer and UI dump Viewer, 2026-10-01

- Tasks: TASK-XPA-021 (Trace on Windows: capture, the viewer's scope per decision 5) and the
  Viewer surface of TASK-XPA-020, WM5 (`docs/design/cross-platform/windows-phase-agent-prompt.md`),
  the third of the remaining surface PRs (Debug #2430, Flash #2442; Diagnostics next). The lead's
  instruction: full macOS parity over the scripted transport, the real daemon's refusal shown as it
  is; the Trace viewer stays an honest unavailable state, not an ArkTrace port (decision 5). The
  proposed maintainer ruling "macOS logic is the standard" is on hold, so nothing here relies on it.
- Base: branch `agent/xpa-021-winui-trace-viewer-20261001`, one commit on `origin/main` `3efba88c` (after #2428, #2443, #2444 and #2445);
  nothing is force-pushed.
- Host: the Windows 11 x64 reference host, non-elevated; .NET SDK 10.0.401, Windows App SDK 2.5.1,
  MSTest 4.4.1, FlaUI.UIA3 5.0.0; `ARKDECK_DEV_SIGNER_THUMBPRINT` exported in the gate. No system
  setting changed; no package registered; no device, `hdc` or DAYU200. Only the App instances and
  daemon copies the tests and probes launched ran; none was left running.

Host evidence for the client, not device, platform or Narrator-by-ear acceptance.

## The macOS surfaces

`ArkDeckApp/Features/Trace/TraceWorkspaceView.swift`, `TraceConfigurationView.swift`,
`TraceProgressArtifactsView.swift`, `TraceViewerWorkspaceView.swift`,
`ArkDeckApp/Features/UIDump/UIDumpWorkspaceView.swift` and the facades
`TraceApplicationFacade.swift`, `UIDumpApplicationFacade.swift`, `UIDumpOfflineInspector.swift`,
`DiagnosticCapturePreset.swift`, read in full.

- **Trace:** the device, a capture profile (five presets), a duration (seconds or minutes, quick
  values), the capture blockers (availability, device, duration, buffer, probe, adapter,
  parameters, tags), one `capture.diagnostics@1` Job (`trace.probe`, `job.submit`, `job.run`,
  `job.show`, `job.cancel`), and the captured raw Trace read into the inbox and opened in the viewer.
- **Trace viewer:** the external ArkTrace engine with a macOS-only `trace_streamer`.
- **Viewer:** a UI dump capture (`capture.diagnostics@1` with the UI dump preset) on a Connected
  target, its same-Job screenshot, tree and dump read and verified, parsed and hit-tested on the
  host; the tree, the search, the properties tabs and the Advanced Dump (`componentDetail`).

## What was built

| Part | Content |
| --- | --- |
| `App.Core/Presentation/Trace.cs` | `TraceOperations` (the reference, client name, presets, the nine parameters, the preset's checks), `TraceDuration` (units, ranges, quick values, validation — minutes round up), `TraceProbe` (checked as `TraceRuntimeProbeResponseDecoding`: target and binding, dispositions, unique tags, exactly hitrace and bytrace, the nine parameters, value iff `value`, a detail when `unreadable`, complete adapter facts), `TraceTarget` (the Target joined with its one device observation, the connect key shortened), `TraceState` (the Catalog's duration and buffer ranges from `operation.describe`, the selection rule, the blockers in macOS order), `TraceInbox`, `TraceDocument`, `TraceRecents`, `TraceViewerState`; the loader's `TraceAsync`, `SubmitTraceAsync`, `OpenCapturedTraceAsync` (every `artifact.list` page, exactly one raw `trace.htrace` of the capture, read into the inbox, SHA-256 checked) and `TraceViewerAsync` (`trace.inspect` for a captured Trace). |
| `App.Core/Presentation/UIDumpCapture.cs` | The host parser, hit testing, search, raw dump and advanced-dump parse (`ViewerCaptureParser`, `ViewerHitTesting`, `UIDumpOfflineInspector` and the CLI's derivation). `UIDumpCaptureTests` replays all 19 cases of `rust/tests/fixtures/ui-dump-inspect` (the Swift CLI's goldens), 0 mismatches. |
| `App.Core/Presentation/Viewer.cs` | `ViewerTarget` (the macOS route rule: Connected, or HDC's state, a stale observation, more than one route, no route, or the observation's refusal), `ViewerAsync`, `CaptureViewAsync` (the preset, `job.run` and `job.show` checked: succeeded, known outcome, nobody waited for, no residue), `LoadViewCaptureAsync` (exactly one screenshot and tree, at most one dump, published, sensitive, 32 MiB, read and verified, parsed, with the timings), `AdvancedDumpAsync`. `ArtifactExporter.ReadAsync` reads a verified Artifact into memory through the same checked chunks. |
| `App/Pages/TracePage.cs`, `TraceViewerPage.cs`, `ViewerPage.cs` | The three pages as above. |
| Strings | All 62 `TraceLocalizable` and 65 `UIDumpLocalizable` keys, the 25 symbolic `TraceViewerLocalizable` keys and the two navigation labels (values unchanged; the three tables join the generator's inputs and the windows lane's), and Windows-only keys (below). |
| Scripted transport | `ScriptedDaemon.Viewer.cs`, scenario `viewer`, over `Testing/Recorded/viewer-workspace.json` (written by a script from the trace-probe oracle's captureEligible probe, the capture-diagnostics-trace oracle's "blocking" capture and its stored bytes, the ui-dump-inspect oracle's capture, and a published advanced dump of capture-diagnostics-read-legs): a daemon with the HDC provider's read-only probes and captures. Every other scenario answers `trace.probe` as the Windows daemon does (measured, below). |

Delegated minor decisions (pending the next rulings batch):

1. **The Trace viewer is a page, not a second window.** macOS opens a separate Trace Viewer window;
   the Windows App shows it as a navigation item beside Trace (Alt+R), which the capture opens.
   A second top-level window would be one more place a keyboard and a screen reader must find.
2. **The Trace viewer's scope** (decision 5): the macOS idle, error-banner and Inspector states,
   with the "bundled parser is unavailable" banner (its own macOS title and reason) and a
   Diagnostics line saying no parser is distributed for Windows; the Inspector shows the file's
   size and SHA-256 and the Runtime inspector's answer. No timeline, search, zoom or annotation is
   offered, because none would work; nothing is shown disabled.
3. **The App's cache** is `%TEMP%\ArkDeck` (the inbox `TraceInbox\<sha256>.htrace`, a reparse
   point refused, and the recent list), overridable with `--cache-root`: the macOS Caches
   directory's counterpart, kept apart from the Runtime's `%LOCALAPPDATA%\ArkDeck` state root.
4. **Windows-only strings:** the viewer's literal-English macOS keys (the generator's key syntax
   cannot carry them) as `windows.traceViewer.*` with the macOS values; "on this PC" for
   `trace.capture.localOnly` and Ctrl+F for `viewer.advancedDump.search.shortcut`; the three
   phrases the macOS Viewer hard-codes ("Advanced Dump", "Capturing componentDetail…", the missing
   window/component ids); the viewer's title, Back, SHA-256, engine, data quality and file-type
   lines.
5. **The component tree is a list** (one Tab stop; Up, Down, Home and End; Left and Right collapse,
   expand or move to the parent or first child, as macOS), each row the selectable
   `viewer.tree.node.<identity>`; the disclosure and the screenshot's per-component outlines are
   named, invokable UIA elements but not Tab stops, as on macOS where the tree is the keyboard path.
   The accessibility Tab-walk test names these two families as its only exceptions.
6. **No live refresh while a capture runs:** macOS refreshes the workspace every 750 ms, which
   changes nothing the page shows; the Windows page re-reads when the capture ends.
7. **Capture and Start never show disabled** (XPA-AC-8): choosing either while it cannot run says
   why (the first blocker; the Target's route; the operation's reasons).

Also here:

- The UIA snapshot test now takes its scenarios from `surfaces.json`: its fixed list had left out
  `flash`, so #2442's Flash snapshots were not exercised (they pass now, both languages).
- The Debug page's text fields store their value on `TextChanging` (see Checks).
- `scripts/ci/plan.py` adds the trace-probe and ui-dump-inspect oracles, and the four fixtures the
  App's tests already read without being declared (agent-human-action, debug-probe,
  observe-device, import-upload-current), to the windows lane's inputs; `test_plan` declares them.

## What the real daemon answers (measured; re-asserted on `3efba88c` by `TheTraceAndViewerPagesShowTheRuntimesRefusalWithoutHdc`, daemon SHA-256 `3dd2a53973ef3c0d62ac7adf571c2c5630bf9cb19d74d9200533feb5a54e8825`)

Over a development root with the recorded adopted Target (`TGT-3ba3f5f43b92`, binding 1):
`operation.list` lists `capture.diagnostics@1` `unavailable`, `provider hdc is not registered`;
`trace.probe` answers `internalError`, "Trace Runtime probing is not configured";
`device.observations` answers `rejected`, `hdc.notConfigured`; a typed Trace capture's
`job.submit` answers `invalidInput`, "provider hdc is not registered", before admission;
`trace.cache.status` answers an empty cache; `job.list` stays empty. The private-endpoint
foundation answers `trace.probe` and `device.observations` the same way.

## Accessibility

- Tab walk: Trace, the Trace viewer and the Viewer (after a capture) join the pages whose every
  action must be a Tab stop in reading order, retraced by Shift+Tab (with delegated decision 5's exceptions).
- Access keys Alt+T (Trace), Alt+R (Trace viewer), Alt+V (Viewer), unique with O, D, H, N, A, I,
  B, F, S.
- 225 % text: Trace (the `viewer` and `targets` daemons), the Trace viewer, and the Viewer after a
  capture and over the `targets` daemon.
- UIA snapshots: `trace.viewer`, `trace.targets`, `traceViewer.viewer`, `viewer.viewer` (after a
  capture), `viewer.targets`; both languages.

## Checks on the reference host

Local targeted checks (2026-10-04, after rebasing onto `3efba88c`; logs in the session scratchpad
`x3/viewer-full2.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive, this tree) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 101 passed |
| ClientKit.Tests | 42 passed, 1 skipped (`ARealArtifactSigningPublisherIsMatchedThroughWinVerifyTrust`, needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, `ARKDECK_CLIENTKIT_DAEMON` = the daemon above) | 98 passed, 1 skipped (`TheInstalledAppConnectsToTheDaemonTheCliStarted`, needs an installed package) |
| `generate-clientkit`, `generate-ui-strings`, `generate-xaml-tokens`, `generate-app-icons` `--check` | exit 0 (1076 strings) |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | 67 tests OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

Two full UI runs before the last one failed `AHapAndANativeLibraryAreChosenPlannedAndRun` (Debug,
#2430) and once a Debug Tab walk; alone each passed. The cause: the Debug fields stored their text
on `TextChanged`, which WinUI raises asynchronously, so a Run invoked right after UI Automation's
`SetValue` could read the old (empty) value under load. The fields now store it on `TextChanging`,
which is raised synchronously; the Debug tests and Tab walks then passed twice in a row together
and the full run above passed.

## Not done here, and why

1. **A Trace or UI dump capture on the real daemon:** `capture.diagnostics@1` needs the Windows HDC
   tuple, which is not registered (CHG-2026-078); the pages show the refusal.
2. **The ArkTrace timeline on Windows** (decision 5): no `trace_streamer` Windows build is
   distributed; TASK-XPA-021's parser deliverable stays open.
3. **History's hand-off into a workspace** (macOS `history.activity.open.*`: Open Trace, Viewer,
   Debug, Flash, Diagnostics, Device, each restoring the Job's context): one History feature for
   every workspace, proposed as its own PR after Diagnostics. Until then a captured Trace is
   inspected from History's Job detail.
4. **Narrator by ear, real key strokes, the system high-contrast themes and 225 % text**: as in
   `winui-settings-a11y-run.md`.
5. The new Windows-only strings' Chinese values want the maintainer's review.

CI: to be recorded by the PR's hosted run; not verified here.
