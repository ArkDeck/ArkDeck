# TASK-XPA-020 — WinUI History hand-off into the workspaces, 2026-10-04

- Task: History's hand-off into the workspace that produced a record, TASK-XPA-020, WM5, the first
  of the parity leftovers the lead assigned after #2474 (ruling 68). Base: branch
  `agent/xpa-020-winui-history-handoff-20261004`, one commit on `origin/main` `1f05dce0`; nothing is
  force-pushed.
- Host: the Windows 11 x64 reference host, non-elevated, as the earlier WinUI runs; no device,
  `hdc` or DAYU200; nothing was left running.

## The parity sweep (what the Windows App still lacks against `ArkDeckApp/`)

Recorded so the remaining slices are visible; this PR closes item 1.

1. **History's hand-off** into Trace, Viewer, Debug, Flash and Device, and the context banner. *(this PR)*
2. **History list and detail**: activity categories with counts, filters, search, saved filters
   (`history.filter.list|save|delete`), older pages, the timeline (`job.timeline`), correlation,
   parameters (the Trace parameter diff) and recovery sections.
3. **The global Job recovery banner** (`jobRecovery.*`).
4. **Overview**: the device scope and picker, the remote-server line (`overview.record.remoteServer`,
   from the App's bindings), the next step and run threads, the resume sheet and continuation
   card, the HDC environment block (its capability matrix needs an HDC).
5. **Debug's directory sources and reviewed deployment queue** (#2466, macOS
   `NativeLibraryDirectorySource`, `NativeLibraryDeploymentBatch`).
6. **The Job Inspector**: Ctrl+Shift+J, epoch relation, residue, log reading.
7. **Settings**: the app icon choice; Storage editing (`runtime.storage.policy|root`); Trace purge
   (`trace.cache.purge`) and licenses; Updates (on Windows, the MSIX App Installer feed);
   Diagnostics (the support bundle).
8. **Keyboard commands**: Ctrl+F search, Ctrl+R refresh, the Trace menu, `.htrace` association,
   the last selection restored.
9. **Device** sidebar destinations, trust steps and bounded wait, live observation, candidate
   aliases — and the Device screen workspace (screenshot, input, recording), which needs the
   Windows HDC tuple (CHG-2026-078) and a Media Foundation encoder.
10. **The ArkTrace timeline viewer** (decision 5; no Windows parser).

## What was built

| Part | Content |
| --- | --- |
| `App.Core/Presentation/HistoryContext.cs` | `HistoryWorkspaceContext` (macOS `RuntimeHistoryWorkspaceContext`): Job, operation, Target, state, mode, Session, workspace, binding (evidence, else observed), typed inputs, Artifacts; the workspace from the Runtime's `workspaceKind`, else `unambiguousKind(forOperation:)`, else `diagnosticsKind(inputs:)` over the evidence's typed inputs; Debug's tab per operation. `JobEvidenceFacts` keeps the evidence's `parameters`. |
| `App/Controls/HistoryContextBanner.cs` | The macOS `HistoryWorkspaceContextBanner` (`history.context.*`) and the `IHistoryContextPage` contract. |
| `HistoryPage` | The detail's Open button (`history.openWorkspace`, `history.activity.open.<kind>`), Open Diagnostics beside it for a `capture.diagnostics@1` record of another workspace, and "no workspace" (`history.openWorkspace.unsupported`). |
| `MainWindow.OpenHistoryWorkspace` | macOS `openHistoryWorkspace` / `openHistoryDiagnostics`: the page takes the context, then is shown and read. |
| Trace, Viewer, Debug, Flash, Device, Diagnostics | Each restores what macOS restores (README "History hand-off") and shows the banner until dismissed. |
| Strings | 14 `HistoryLocalizable`/`FlashLocalizable` keys, values unchanged. |

Delegated minor decisions (pending the next rulings batch):

1. **Device restores its Target only**: macOS reloads the record's screenshot in the Device screen
   workspace, which the Windows App does not have (sweep item 9).
2. **Trace opens the viewer directly** from the record's raw Trace, as the Trace page's own Open
   does; a record without one says why on the page (`trace.viewer.artifactInvalid`).
3. **The banner is a card at the top of the page**, with Dismiss as a named button.

## Checks on the reference host

Local targeted checks (2026-10-04, on `955cf537`; logs in the session scratchpad `x3/handoff-full.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive; SHA-256 `9c0e3022007cf08217336b41adef008e7b76de7d2951cfbb8b244ea97174d069`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 138 passed (`HistoryContextTests` 5) |
| ClientKit.Tests | 42 passed, 1 skipped (needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, the daemon above) | 115 passed, 1 skipped (needs an installed package); `HistoryHandoffFlowTests` opens a Device record and a capture record in Trace (and offers Diagnostics beside it) and dismisses the banner |
| the four generators `--check` | exit 0 |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

## Not done here, and why

Sweep items 2–10: each its own slice (9 and 10 need the HDC tuple or a Windows ArkTrace parser).

CI: to be recorded by the PR's hosted run; not verified here.
