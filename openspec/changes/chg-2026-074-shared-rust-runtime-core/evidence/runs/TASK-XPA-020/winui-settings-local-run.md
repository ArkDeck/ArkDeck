# TASK-XPA-020 — WinUI Settings window icon, Updates and Diagnostics, 2026-10-05

- Task: the rest of sweep item 7 of `winui-history-handoff-run.md`: macOS
  `ApplicationIconPicker`, `AutoUpdateSettingsView` and `DiagnosticsSettingsPane`
  (`RuntimeSupportBundleApplicationFacade`). Base: `1700e507b` (the #2557 head), one
  commit stacked on `agent/xpa-020-winui-settings-20261005`. Host and boundaries as the earlier
  WinUI runs; no device, `hdc` or DAYU200. None of this reaches the Runtime.

## What was built

| Part | Content |
| --- | --- |
| Icons | `generate-app-icons.py` also writes `AppIcon.Keycap.ico` and `AppIcon.Waveform.ico` from the macOS `ArkDeckKeycapIcon` and `ArkDeckWaveformIcon` imagesets (the same entries as `AppIcon.ico`); its inputs and the CI planner's windows inputs name both imagesets. |
| `App.Core/Presentation/AppPreferences.cs` | The App's own preferences file (`preferences-v1.json`, written whole through a staging file; `--preferences-root` for tests): the window icon, waveform by default as macOS `ApplicationIconChoice.defaultChoice`. |
| `App.Core/Presentation/SupportBundle.cs` | The local diagnostic bundle, as the Rust CLI's `support_bundle.rs` states Swift's: `metadata.json` (App name, version, build, Windows version, architecture), `hdc/tool-placeholder.json` (redacted and unverified only) and `bundle.json`, the scope digest over the destination, its parent folder's volume serial and file index and every entry, the manifest's size solved to a fixed point, 32 MiB at most. The preview writes nothing; the export recomputes the digest, writes a staging folder beside the destination and moves it into place only for the approved digest, never over an existing folder. |
| `SettingsPage` | General: App icon (Diagnostics / Terminal, applied to the window at once and at launch). Updates: the MSIX App Installer channel (version, feed, Check Now through `Package.CheckUpdateAvailabilityAsync`, Install with App Installer through `ms-appinstaller:`), or why a copy has none. Diagnostics: the default scope, Choose destination and preview…, the preview's destination, size, scope SHA-256, device raw and entries, Export approved preview, Show in File Explorer. |
| Launch options | `--pick-folder`, honoured only with the scripted transport, answers the folder pickers without a dialog (UI tests). |
| Strings | 33 macOS keys (values unchanged) and 12 Windows-only lines. |

Delegated minor decisions (pending the next rulings batch):

1. **Updates are App Installer's** (docs/release/windows-update.md): the App checks the package's
   feed and hands the install to App Installer; it downloads, verifies and replaces nothing itself,
   so macOS's download, verify and reveal steps and its automatic-check toggle (App Installer's
   feed sets `OnLaunch` checks) have no counterpart.
2. **The icon choice changes the window and title bar icon**; the installed package's Start and
   taskbar tiles keep the package's icon, which Windows does not let an App change.
3. **The bundle's destination is a new folder named `ArkDeck-Diagnostics-<time>` in the folder
   the person picks** (macOS: a save panel names it).
4. **The parent's identity is its volume serial number and file index** (macOS: device and
   inode).

## Checks on the reference host

Local targeted checks (2026-10-05, on `1700e507b`; logs in the session scratchpad `x3/settings3-full.log`):

| Check | Result |
| --- | --- |
| `cargo build -p arkdeck-agentd` (the daemon the UI tests drive; SHA-256 `4f8d06f9103a6c2ff58cc2290cbf394dfdd78f687a9479f2486843cac3fb8220`) | exit 0 |
| `dotnet build ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| App.Tests | 177 passed |
| ClientKit.Tests | 43 passed, 1 skipped (needs a signed release) |
| App.UITests (`ARKDECK_APP_UITESTS=1`, the daemon above) | 129 passed, 2 skipped (keyboard focus visual check; installed MSIX) |
| the four generators `--check` (the icon generator now also writes the two choices) | exit 0 |
| `python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

Stacked on #2557 (`agent/xpa-020-winui-settings-20261005`); the diff against that branch is this layer only.

CI: to be recorded by the PR's hosted run; not verified here.
