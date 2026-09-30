# TASK-XPA-020 — WinUI Settings and the automated accessibility pass, 2026-09-30

- Task: TASK-XPA-020, client lane slice X3b (WM5 of `docs/design/cross-platform/windows-phase-agent-prompt.md`):
  a Settings page over what the Windows daemon serves, and an automated accessibility pass over
  every page of the Windows client.
- Base: branch `agent/xpa-020-winui-settings-a11y-20260930`, cut from `origin/main` `b350b54d`;
  written with the X3 surfaces branch (#2375) merged in, since both rewrite the same files and
  the pass covers the #2375 pages. #2375 merged before the first push, so the slice was put on
  `main` as one commit and every check below rerun there; nothing is force-pushed.
- Host: the Windows 11 x64 reference host, non-elevated; .NET SDK 10.0.401, Windows App SDK
  2.5.1, MSTest 4.4.1, FlaUI.UIA3 5.0.0. No system setting was changed (no theme, text size or
  contrast switch); no package registered; no device, `hdc` or DAYU200. Only the App instances
  and daemon copies the tests launched ran; none of this slice's processes was left running.

Host evidence for the client, not device, platform or Narrator-by-ear acceptance.

## Settings

Measured with the daemon built from `origin/main` `b350b54d` (`cargo build -p arkdeck-agentd
--locked`, SHA-256 `e00ab6ca…1dc2`), over a development root and on a private endpoint:

| Read | Development root | Private endpoint (foundation) |
| --- | --- | --- |
| `health`, `doctor` | answered (blocked; 5 blockers · 2 warnings · 3 info; Target store configured, 0 adopted) | answered |
| `runtime.hdc.status` | `rejected`, "this method is unavailable in the read-only Rust foundation" | same |
| `runtime.tool.list` | `operationUnavailable`, "Bootstrap bundle list owner is not configured" (`bootstrapRegistryOwner`) | same |
| `runtime.storage.status` | `rejected`, "Runtime storage owners are not configured" | same |
| `trace.cache.status` | `rejected`, "Trace cache owner is not configured" | same |
| `workspace.project.list|show`, `workspace.preset.list` | answered (#2366): a registered project is `unavailable`, `runtimeRestartRequired` (`workspace_runtime_restart_required`); its symbol preset listed | `operationUnavailable`, "workspace project owner is unavailable" |

The runtime service's status, verify and restart (#2344) and the signing status (#2372, open)
are CLI leaves, not daemon methods, and the App never starts, stops or replaces the Runtime
(decision 11, TASK-XPA-007), so Settings names their commands with a working copy action.

| Tab | Content |
| --- | --- |
| General (macOS) | name, version, platform, architecture; the macOS privacy assurances |
| Runtime (Windows) | `health` (status, protocol, contract identity, Catalog digest, published methods, providers); every `doctor` check and finding; `arkdeck runtime service status|verify|restart`, `arkdeck runtime signing status` |
| Toolchains (macOS) | `runtime.hdc.status` (the macOS HDC facts), `runtime.tool.list`, signing status command |
| Storage (macOS) | `runtime.storage.status`: the Runtime Artifact store and the Session root with the macOS strings |
| Trace (macOS tab) | `trace.cache.status` |
| Workspace (Windows) | projects (`workspace.project.list`), a selected project's `show` and `workspace.preset.list` |

Strings: +41 macOS entries from `SettingsLocalizable` (values unchanged; the table is added to
the generator's and the `windows` lane's inputs) and +49 Windows-only entries. Settings is a
NavigationView footer item (`app.navigation.settings`); the tabs are a Fluent `SelectorBar`.
Everything is read; no Settings write method is named (`TheAppHoldsNoRuntimeSemantics` now also
forbids the storage, tool, HDC and workspace writes).

## The accessibility pass

| Check | How | Result on this host |
| --- | --- | --- |
| Every action is a Tab stop, in reading order; Shift+Tab retraces it; no empty stop | `EveryActionIsATabStopInReadingOrder` × Overview, Device (Target detail), History (Job detail), Settings (Workspace detail): the App's in-process walk with WinUI's own Tab navigation (`FocusManager.TryMoveFocus`, `--focus-walk`), triggered by a window message; every dotted-id button of the page must be a stop, the page's stops top-to-bottom/left-to-right, the backward walk the reverse | pass (4) |
| Access keys | `EveryPageHasAnAccessKey`: UIA AccessKey "Alt, O/D/H/S" on the four navigation items, unique | pass |
| Visible keyboard focus | `KeyboardFocusIsVisible`: no source disables the system focus visuals; with an unlocked desktop, the pixels around the keyboard-focused element differ from its unfocused state | pass on the source check; the pixel part ran in one run (16 692 pixels differ around the focused Job Inspector row) and reports itself inconclusive when the workstation is locked |
| Escape closes dialogs | `EscapeClosesEveryDialog`: the rename dialog and the export preview close on Escape (posted `WM_KEYDOWN` to the input site, which works locked); nothing renamed, nothing read | pass |
| High contrast | `HighContrastDefinesEveryTokenWithSystemColours` (App.Tests): the HighContrast dictionary defines every Light/Dark token, each as a system colour; `HighContrastTokensUseTheSystemColours` (UIA): with `--high-contrast-tokens` the Settings heading's text colour (UIA TextPattern ForegroundColor) is the system window-text colour (`0`), with the product tokens it is not (`2039069`) | pass |
| 225 % text | `NothingIsClippedAtTheLargestTextSize` × 12 page states: with `--text-scale 2.25` the App's text is 2.25×; every Text and Button of the page, at every scroll position, lies inside the page viewport | pass (12) |

What the pass found and this slice fixed:

1. **Empty Tab stops.** The page host, the progress host and each Artifact result host were
   `ContentControl`s, which are Tab stops by default: focus landed on nothing. Now
   `IsTabStop = false`.
2. **Unreachable row actions.** The History Artifact rows were `ListView` items: Tab entered the
   list at the first row and left it, so the second row's Export… needed the arrow keys; local
   Tab navigation instead trapped focus at the last row. The rows are now a `SemanticList` of
   plain panels whose UIA peers are List/ListItem, so Tab walks every row's buttons and a screen
   reader still finds a list.
3. **Long values ran past the page.** Facts were a horizontal `StackPanel` (infinite width, so a
   digest or path never wrapped). Facts are now a two-column grid and action rows a `FlowPanel`
   that wraps.

Test hooks (`--text-scale`, `--high-contrast-tokens`, `--focus-walk`) exist only beside the
scripted transport; a real run ignores them (`LaunchOptionsAndTheScenarioListAgree`).

## Still for a person (not automatable here)

1. **Narrator by ear** on every page: reading order, the live regions (recovery banner, Job
   state, rename and export results, Trace inspection), the dialogs.
2. **Real key strokes**: the reference host's workstation was locked for most of this run
   (`LogonUI` in the session), where `SendInput` is refused; the tests use WinUI's own Tab
   navigation in process and posted Escape. Pressing Tab, Shift+Tab, Alt+O/D/H/S and Escape on
   an unlocked desktop, and seeing the focus rectangle on each stop, is the maintainer's check.
3. **The system high-contrast themes** (Aquatic, Desert, Dusk, Night sky) and **the system text
   size at 225 %**, which also scale WinUI's own chrome (navigation, title bar, dialogs) — not
   switched here, because this slice changes no system setting.
4. The 49 new Windows-only strings' Chinese values want the maintainer's review.

## Checks on the reference host

| Check | Result |
| --- | --- |
| `generate-clientkit.py --check`, `generate-ui-strings.py --check`, `generate-xaml-tokens.py --check` | exit 0 (105 methods; 286 strings, 170 shared with values unchanged, 116 Windows-only; tokens) |
| `dotnet build windows/ArkDeck.Windows.slnx -c Release` | exit 0, 0 warnings |
| `dotnet test … --no-build` (lane default) | App.Tests 42 passed; ClientKit.Tests 31 passed, 1 skipped; App.UITests 40 skipped |
| same with `ARKDECK_APP_UITESTS=1` and the daemon above, after merging `main` (with #2375) | App.Tests 42, ClientKit.Tests 32, App.UITests 39 passed, 1 inconclusive (`KeyboardFocusIsVisible`: workstation locked at that moment). One earlier full run had the skeleton's `TheAppShowsTheDevSignedDaemonAndItsAbsence` fail while another agent's RC smoke ran an App and a daemon on the host; its message was not kept. It passed alone 3/3, with the other real-daemon tests, and in the next full run; recorded, not resolved |
| `PYTHONUTF8=1 python -m unittest scripts/ci/test_plan.py scripts/test_agent_pr_workflow.py` | OK (66) |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check` | exit 0, exit 0 |

Real daemon (`RealDaemonTests`, a dev-signed copy over a development root):
`SettingsShowTheDevelopmentRootsRuntimeAndWorkspace` registers a project and a symbol preset
over the pipe (as the CLI does) and observes in the App: Runtime "Overall: Blocked", HDC
`unavailable (hdc.notConfigured)`, Target store "Configured · 0 adopted"; Storage, Trace and
Toolchains with the refusals of the table above; the project `runtimeRestartRequired` and its
preset `preset-f55cf382… · symbol · openharmony.arkts-symbol@1 · Timeout 600 s`; no disabled
button.

CI: to be recorded by the PR's hosted run; not verified here.
