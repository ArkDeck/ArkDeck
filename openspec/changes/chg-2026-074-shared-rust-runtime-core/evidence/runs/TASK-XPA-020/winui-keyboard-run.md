# TASK-XPA-020 — WinUI keyboard commands, the Trace document type and the restored page, 2026-10-05

- Task: sweep item 8 of `winui-history-handoff-run.md`: macOS `WorkspaceKeyboardCommands`
  (Command-F, Command-R), the Trace menu, `CFBundleDocumentTypes` (OpenHarmony Trace) and
  `storedSelection`. Base: `1b4af533e` (the #2564 head), one commit stacked on
  `agent/xpa-020-winui-settings-more-20261005`. Host and boundaries as the earlier WinUI runs; no
  device, `hdc` or DAYU200.

## What was built

| Part | Content |
| --- | --- |
| `MainWindow` | Window-wide accelerators: Ctrl+F focuses the current page's search field (an element whose id ends in `.search`: History, Viewer), Ctrl+R and F5 re-read the page, Ctrl+N opens Trace to capture, Ctrl+Shift+O opens a Trace file in the Trace viewer, Ctrl+Shift+R reloads it. Each navigation is remembered and the last page comes back at launch (an explicit `--page` wins). |
| Trace document type | `Package.appxmanifest` associates `.htrace`, `.ftrace`, `.systrace` and `.trace` (the macOS document type's extensions); a file activation of the packaged App, or the path on an unpackaged copy's command line, opens in the Trace viewer. |
| `AppPreferences` | Keeps the last page beside the window icon (each value written keeps the other). |
| Tests | `KeyInput.PressControl` (Ctrl held in the App thread's input state, as Shift already was); UIA tests for Ctrl+F, Ctrl+N, Ctrl+R, a handed Trace and the restored page. |
| Strings | 1 Windows-only line. |

Delegated minor decisions (pending the next rulings batch):

1. **The Trace menu's commands are window accelerators without a menu bar** (WinUI windows have
   none); Filter Trace Processes and Search Trace Events have no counterpart because the Windows
   Trace viewer has no timeline to filter (decision 5).
2. **Ctrl+F reaches any page field whose id ends in `.search`**, rather than each page
   registering a command as macOS `focusedValue` does.
3. **The keyboard-focus assertion reads the field's own focus state**: the reference host runs
   its tests with the desktop locked, where the system focus is the lock screen.

## Checks on the reference host

Local targeted checks (2026-10-05, on `1b4af533e`; logs in the session scratchpad `x3/keys-full.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive; SHA-256 `ca1dadf2ec3d7ec287c4450e698a866dc271567288c2dcf66d48bd43c9e7db31`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 178 passed |
| ClientKit.Tests | 43 passed, 1 skipped (needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, the daemon above) | 132 passed, 2 skipped (keyboard focus visual check; installed MSIX) |
| the four generators `--check` | exit 0 |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

Stacked on #2564 (`agent/xpa-020-winui-settings-more-20261005`); the diff against that branch is this layer only.

CI: to be recorded by the PR's hosted run; not verified here.
